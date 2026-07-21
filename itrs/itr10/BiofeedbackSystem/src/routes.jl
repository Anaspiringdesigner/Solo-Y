module Routes

using HTTP
using JSON3
using Dates
using UUIDs

using ..Config
using ..Types
using ..Auth
using ..SessionManager
using ..IngestService
using ..RedisStore
using ..TriggerService
using ..Hardening

export make_router

# -------------------------
# Response helpers
# -------------------------
json_response(code::Int, body; req_id::String = "") = HTTP.Response(
    code,
    ["Content-Type" => "application/json", "X-Request-Id" => req_id],
    JSON3.write(body)
)

function require_user(req::HTTP.Request, settings::Config.Settings)
    user_id = Auth.extract_user_id(req, settings)
    if user_id === nothing || isempty(user_id)
        return nothing, json_response(401, Dict("ok" => false, "error" => "unauthorized"))
    end
    return user_id, nothing
end

# -------------------------
# Idempotency helpers
# -------------------------
function idem_check_and_mark!(
    store::SessionManager.SessionStore,
    redis::RedisStore.RedisClient,
    settings::Config.Settings,
    key::String
)
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

    # fallback local
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

function touch_session_presence!(
    redis::RedisStore.RedisClient,
    settings::Config.Settings,
    user_id::String
)
    ttl_sec = settings.session_ttl_minutes * 60
    if RedisStore.redis_available(redis)
        RedisStore.session_touch!(redis, user_id, ttl_sec)
    end
end

# -------------------------
# Request logging wrapper
# -------------------------
function with_request_logging(handler_name::String, req::HTTP.Request, f::Function)
    req_id = HTTP.header(req, "X-Request-Id", string(uuid4()))
    t0 = time()
    try
        resp = f(req_id)
        dt_ms = round((time() - t0) * 1000; digits = 2)
        println("[REQ] id=$req_id route=$handler_name method=$(req.method) target=$(req.target) latency_ms=$dt_ms")
        return resp
    catch e
        dt_ms = round((time() - t0) * 1000; digits = 2)
        println("[REQ_ERR] id=$req_id route=$handler_name err=$(string(e)) latency_ms=$dt_ms")
        return json_response(
            500,
            Dict("ok" => false, "error" => "internal_error", "detail" => string(e));
            req_id = req_id
        )
    end
end

# -------------------------
# Handlers
# -------------------------
function handle_ingest(
    req::HTTP.Request,
    store::SessionManager.SessionStore,
    redis::RedisStore.RedisClient,
    hs::Hardening.HardeningStore,
    settings::Config.Settings,
    mode::String
)
    return with_request_logging("ingest_$mode", req, req_id -> begin
        # payload size
        Hardening.check_payload_size!(req.body; max_bytes = settings.max_payload_bytes)

        # auth
        user_id, err = require_user(req, settings)
        err !== nothing && return err

        # rate limit
        ok_rate = Hardening.check_rate_limit!(
            hs,
            "ingest:$user_id";
            limit = settings.ingest_rate_limit_per_min,
            window_sec = 60
        )
        ok_rate || return json_response(429, Dict("ok" => false, "error" => "rate_limited_ingest"); req_id = req_id)

        # parse
        payload = try
            JSON3.read(req.body)
        catch
            return json_response(400, Dict("ok" => false, "error" => "invalid_json"); req_id = req_id)
        end

        # validate schema/ranges
        try
            Hardening.validate_ingest_payload!(payload)
        catch e
            return json_response(400, Dict("ok" => false, "error" => "invalid_payload", "detail" => string(e)); req_id = req_id)
        end

        # endpoint-mode consistency
        payload_mode = haskey(payload, "mode") ? String(payload["mode"]) : mode
        lowercase(payload_mode) != lowercase(mode) &&
            return json_response(400, Dict("ok" => false, "error" => "mode_endpoint_mismatch"); req_id = req_id)

        # build chunk
        chunk = try
            IngestService.parse_chunk(payload, user_id)
        catch e
            return json_response(400, Dict("ok" => false, "error" => "invalid_payload_parse", "detail" => string(e)); req_id = req_id)
        end
        
         # idempotency
        idem_key = "$(chunk.user_id):$(chunk.device_id):$(chunk.idempotency_key)"
        duplicate, idem_backend = try
            idem_check_and_mark!(store, redis, settings, idem_key)
        catch e
            return json_response(503, Dict("ok" => false, "error" => string(e)); req_id = req_id)
        end

        # monotonic sequence check
        if settings.enforce_monotonic_seq
            seq_ok = Hardening.check_sequence_monotonic!(hs, user_id, chunk.device_id, chunk.seq_no)
            seq_ok || return json_response(409, Dict("ok" => false, "error" => "non_monotonic_seq_no"); req_id = req_id)
        end

        if duplicate
            return json_response(
                200,
                Dict("ok" => true, "duplicate" => true, "idempotency_backend" => idem_backend);
                req_id = req_id
            )
        end

        # session + apply
        sess = try
            SessionManager.get_or_create_session!(store, user_id)
        catch e
            return json_response(429, Dict("ok" => false, "error" => string(e)); req_id = req_id)
        end

        IngestService.apply_chunk!(sess, chunk)
        Hardening.track_sequence!(hs, user_id, chunk.device_id, chunk.seq_no)
        touch_session_presence!(redis, settings, user_id)

        return json_response(
            200,
            Dict(
                "ok" => true,
                "duplicate" => false,
                "idempotency_backend" => idem_backend,
                "user_id" => user_id,
                "state" => String(sess.state),
                "buffered_chunks" => length(sess.ring_buffer),
                "avg_hr" => sess.latest_features["avg_hr"],
                "avg_spo2" => sess.latest_features["avg_spo2"],
                "avg_ppg" => sess.latest_features["avg_ppg"],
            );
            req_id = req_id
        )
    end)
end

function handle_status(
    req::HTTP.Request,
    store::SessionManager.SessionStore,
    settings::Config.Settings
)
    return with_request_logging("status", req, req_id -> begin
        user_id, err = require_user(req, settings)
        err !== nothing && return err

        sess = SessionManager.get_session(store, user_id)
        sess === nothing && return json_response(404, Dict("ok" => false, "error" => "session_not_found"); req_id = req_id)

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
            return json_response(200, dto; req_id = req_id)
        end
    end)
end

function handle_trigger(
    req::HTTP.Request,
    store::SessionManager.SessionStore,
    redis::RedisStore.RedisClient,
    hs::Hardening.HardeningStore,
    settings::Config.Settings
)
    return with_request_logging("trigger", req, req_id -> begin
        Hardening.check_payload_size!(req.body; max_bytes = 32_000)

        user_id, err = require_user(req, settings)
        err !== nothing && return err

        # trigger rate limit
        ok_rate = Hardening.check_rate_limit!(
            hs,
            "trigger:$user_id";
            limit = settings.trigger_rate_limit_per_min,
            window_sec = 60
        )
        ok_rate || return json_response(429, Dict("ok" => false, "error" => "rate_limited_trigger"); req_id = req_id)

        # trigger cooldown
        ok_cd = Hardening.check_trigger_cooldown!(
            hs,
            user_id;
            cooldown_sec = settings.trigger_cooldown_sec
        )
        ok_cd || return json_response(429, Dict("ok" => false, "error" => "trigger_cooldown_active"); req_id = req_id)

        payload = try
            JSON3.read(req.body)
        catch
            return json_response(400, Dict("ok" => false, "error" => "invalid_json"); req_id = req_id)
        end

        try
            Hardening.validate_trigger_payload!(payload)
        catch e
            return json_response(400, Dict("ok" => false, "error" => "invalid_payload", "detail" => string(e)); req_id = req_id)
        end

        trigger_type = String(payload["trigger_type"])
        stream_sec = haskey(payload, "stream_duration_sec") ? Int(payload["stream_duration_sec"]) :
                                                              settings.event_stream_duration_sec

        sess = SessionManager.get_or_create_session!(store, user_id)

        result = try
            TriggerService.apply_trigger!(sess, trigger_type, stream_sec)
        catch e
            return json_response(400, Dict("ok" => false, "error" => string(e)); req_id = req_id)
        end

        touch_session_presence!(redis, settings, user_id)

        # TODO (next phase): send per-user TD command here
        return json_response(200, merge(result, Dict("user_id" => user_id)); req_id = req_id)
    end)
end

# -------------------------
# Router
# -------------------------
function make_router(
    store::SessionManager.SessionStore,
    redis::RedisStore.RedisClient,
    hs::Hardening.HardeningStore,
    settings::Config.Settings
)
    return function(req::HTTP.Request)
        target = req.target
        method = String(req.method)

        if method == "GET" && target == "/healthz"
            return json_response(200, Dict("ok" => true, "service" => "biofeedback-backend"))

        elseif method == "GET" && target == "/readyz"
            return json_response(
                200,
                Dict(
                    "ok" => true,
                    "ready" => true,
                    "store" => SessionManager.store_stats(store),
                    "redis" => RedisStore.redis_stats(redis),
                )
            )

        elseif method == "POST" && target == "/v1/ingest/batch"
            return handle_ingest(req, store, redis, hs, settings, "batch")

        elseif method == "POST" && target == "/v1/ingest/realtime"
            return handle_ingest(req, store, redis, hs, settings, "realtime")

        elseif method == "POST" && target == "/v1/events/trigger"
            return handle_trigger(req, store, redis, hs, settings)

        elseif method == "GET" && target == "/v1/status"
            return handle_status(req, store, settings)

        else
            return json_response(404, Dict("ok" => false, "error" => "not_found"))
        end
    end
end

end # module