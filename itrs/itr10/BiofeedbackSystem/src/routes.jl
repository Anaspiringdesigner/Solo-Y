module Routes

using HTTP
using JSON3
using Dates
using ..Config
using ..Types
using ..Auth
using ..SessionManager
using ..IngestService
using ..RedisStore
using ..TriggerService

export make_router

json_response(code::Int, body) = HTTP.Response(
    code,
    ["Content-Type" => "application/json"],
    JSON3.write(body)
)

function require_user(req::HTTP.Request, settings::Config.Settings)
    user_id = Auth.extract_user_id(req, settings)
    if user_id === nothing || isempty(user_id)
        return nothing, json_response(401, Dict("ok" => false, "error" => "unauthorized"))
    end
    return user_id, nothing
end

function idem_check_and_mark!(store::SessionManager.SessionStore,
                              redis::RedisStore.RedisClient,
                              settings::Config.Settings,
                              key::String)

    ttl_sec = settings.idempotency_ttl_minutes * 60

    if RedisStore.redis_available(redis)
        seen = RedisStore.idem_seen(redis, key)
        if seen === true
            return true, "redis"
        elseif seen === false
            ok = RedisStore.idem_mark!(redis, key, ttl_sec)
            if ok
                return false, "redis"
            end
        end
    end

    # fallback local (degraded or redis unavailable)
    if settings.redis_fail_mode == "fail_closed" && !RedisStore.redis_available(redis)
        error("redis_unavailable_fail_closed")
    end

    if SessionManager.is_duplicate_idempotency_local!(store, key)
        return true, "local"
    else
        SessionManager.mark_idempotency_local!(store, key)
        return false, "local"
    end
end

function touch_session_presence!(redis::RedisStore.RedisClient,
                                 settings::Config.Settings,
                                 user_id::String)
    ttl_sec = settings.session_ttl_minutes * 60
    if RedisStore.redis_available(redis)
        RedisStore.session_touch!(redis, user_id, ttl_sec)
    end
end

function handle_ingest(req::HTTP.Request, store::SessionManager.SessionStore,
                       redis::RedisStore.RedisClient,
                       settings::Config.Settings, mode::String)
    user_id, err = require_user(req, settings)
    err !== nothing && return err

    payload = try
        JSON3.read(req.body)
    catch
        return json_response(400, Dict("ok" => false, "error" => "invalid_json"))
    end

    payload_mode = haskey(payload, "mode") ? String(payload["mode"]) : mode
    lowercase(payload_mode) != lowercase(mode) &&
        return json_response(400, Dict("ok" => false, "error" => "mode_endpoint_mismatch"))

    chunk = try
        IngestService.parse_chunk(payload, user_id)
    catch e
        return json_response(400, Dict("ok" => false, "error" => "invalid_payload", "detail" => string(e)))
    end

    idem_key = "$(chunk.user_id):$(chunk.device_id):$(chunk.idempotency_key)"
    duplicate, idem_backend = try
        idem_check_and_mark!(store, redis, settings, idem_key)
    catch e
        return json_response(503, Dict("ok" => false, "error" => string(e)))
    end

    if duplicate
        return json_response(200, Dict(
            "ok" => true, "duplicate" => true,
            "idempotency_backend" => idem_backend
        ))
    end

    sess = try
        SessionManager.get_or_create_session!(store, user_id)
    catch e
        return json_response(429, Dict("ok" => false, "error" => string(e)))
    end

    IngestService.apply_chunk!(sess, chunk)
    touch_session_presence!(redis, settings, user_id)

    return json_response(200, Dict(
        "ok" => true,
        "duplicate" => false,
        "idempotency_backend" => idem_backend,
        "user_id" => user_id,
        "state" => String(sess.state),
        "buffered_chunks" => length(sess.ring_buffer),
        "avg_hr" => sess.latest_features["avg_hr"],
        "avg_spo2" => sess.latest_features["avg_spo2"],
        "avg_ppg" => sess.latest_features["avg_ppg"]
    ))
end

function handle_status(req::HTTP.Request, store::SessionManager.SessionStore, settings::Config.Settings)
    user_id, err = require_user(req, settings)
    err !== nothing && return err

    sess = SessionManager.get_session(store, user_id)
    sess === nothing && return json_response(404, Dict("ok" => false, "error" => "session_not_found"))

    lock(sess.lock) do
        dto = Types.SessionStatusDTO(
            user_id = sess.user_id,
            state = sess.state,
            active_interaction = sess.active_interaction,
            is_holding = sess.is_holding,
            hold_steps_left = sess.hold_steps_left,
            avg_hr = get(sess.latest_features, "avg_hr", 0f0),
            avg_spo2 = get(sess.latest_features, "avg_spo2", 0f0),
            avg_ppg = get(sess.latest_features, "avg_ppg", 0f0),
            buffered_chunks = length(sess.ring_buffer),
            last_seen = string(sess.last_seen),
        )
        return json_response(200, dto)
    end
end

function handle_trigger(req::HTTP.Request, store::SessionManager.SessionStore,
                        redis::RedisStore.RedisClient,
                        settings::Config.Settings)
    user_id, err = require_user(req, settings)
    err !== nothing && return err

    payload = try
        JSON3.read(req.body)
    catch
        return json_response(400, Dict("ok" => false, "error" => "invalid_json"))
    end

    trigger_type = haskey(payload, "trigger_type") ? String(payload["trigger_type"]) : "manual"
    stream_sec = haskey(payload, "stream_duration_sec") ? Int(payload["stream_duration_sec"]) :
                                                      settings.event_stream_duration_sec

    sess = SessionManager.get_or_create_session!(store, user_id)

    result = try
        TriggerService.apply_trigger!(sess, trigger_type, stream_sec)
    catch e
        return json_response(400, Dict("ok" => false, "error" => string(e)))
    end

    touch_session_presence!(redis, settings, user_id)

    # Phase-2 placeholder for TD dispatch:
    # TODO: call TDBridge per-user channel here.

    return json_response(200, merge(result, Dict("user_id" => user_id)))
end

function make_router(store::SessionManager.SessionStore,
                     redis::RedisStore.RedisClient,
                     settings::Config.Settings)
    return function(req::HTTP.Request)
        target = req.target
        method = String(req.method)

        if method == "GET" && target == "/healthz"
            return json_response(200, Dict("ok" => true, "service" => "biofeedback-backend"))

        elseif method == "GET" && target == "/readyz"
            return json_response(200, Dict(
                "ok" => true,
                "ready" => true,
                "store" => SessionManager.store_stats(store),
                "redis" => RedisStore.redis_stats(redis)
            ))

        elseif method == "POST" && target == "/v1/ingest/batch"
            return handle_ingest(req, store, redis, settings, "batch")

        elseif method == "POST" && target == "/v1/ingest/realtime"
            return handle_ingest(req, store, redis, settings, "realtime")

        elseif method == "POST" && target == "/v1/events/trigger"
            return handle_trigger(req, store, redis, settings)

        elseif method == "GET" && target == "/v1/status"
            return handle_status(req, store, settings)

        else
            return json_response(404, Dict("ok" => false, "error" => "not_found"))
        end
    end
end

end # module