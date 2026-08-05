module Routes

using HTTP
using JSON3
using Dates
using ..Config
using ..Auth
using ..SessionManager
using ..RedisStore
using ..IngestService
using ..TriggerService
using ..Hardening

export make_router

function _json(code::Int, obj)
    return HTTP.Response(
        code,
        ["Content-Type" => "application/json"],
        JSON3.write(obj),
    )
end

function _read_json_body(req::HTTP.Request)
    isempty(req.body) && return Dict{String,Any}()
    return JSON3.read(String(req.body))
end

function _require_auth(req::HTTP.Request, settings::Config.Settings)
    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && error("unauthorized")
    return user_id
end

function make_router(
    store::SessionManager.SessionStore,
    redis::RedisStore.RedisClientState,
    hs::Hardening.HardeningStore,
    settings::Config.Settings
)
    return function (req::HTTP.Request)
        try
            path = HTTP.URIs.path(req.target)
            method = String(req.method)

            # Health
            if method == "GET" && path == "/healthz"
                return _json(200, Dict("ok" => true, "service" => "biofeedback"))
            end
            if method == "GET" && path == "/readyz"
                return _json(200, Dict("ok" => true, "redis_available" => redis.available))
            end

            # Status
            if method == "GET" && path == "/v1/status"
                user_id = _require_auth(req, settings)

                # If your SessionManager has another status function, adjust here.
                st = SessionManager.get_status(store, user_id)
                if st === nothing
                    return _json(200, Dict(
                        "avg_hr" => 0.0,
                        "avg_hrv" => 0.0,
                        "avg_br" => 0.0,
                        "active_interaction" => 0,
                        "state" => "IDLE",
                        "is_holding" => false,
                        "hold_steps_left" => 0
                    ))
                end
                return _json(200, st)
            end

            # Trigger
            if method == "POST" && path == "/v1/events/trigger"
                user_id = _require_auth(req, settings)

                Hardening.check_payload_size!(req.body; max_bytes=settings.max_payload_bytes)
                payload = _read_json_body(req)
                Hardening.validate_trigger_payload!(payload)

                ok_rate = Hardening.check_rate_limit!(
                    hs, "trigger:$user_id";
                    limit=settings.trigger_rate_limit_per_min, window_sec=60
                )
                ok_rate || return _json(429, Dict("ok" => false, "error" => "trigger_rate_limited"))

                ok_cd = Hardening.check_trigger_cooldown!(
                    hs, user_id; cooldown_sec=settings.trigger_cooldown_sec
                )
                ok_cd || return _json(429, Dict("ok" => false, "error" => "trigger_cooldown"))

                result = TriggerService.fire_trigger!(store, payload, user_id, settings)
                return _json(200, result)
            end

            # Ingest (batch + realtime) - points-only schema
            if method == "POST" && (path == "/v1/ingest/batch" || path == "/v1/ingest/realtime")
                user_id = _require_auth(req, settings)

                Hardening.check_payload_size!(req.body; max_bytes=settings.max_payload_bytes)
                payload = _read_json_body(req)
                Hardening.validate_ingest_payload!(payload)

                ok_rate = Hardening.check_rate_limit!(
                    hs, "ingest:$user_id";
                    limit=settings.ingest_rate_limit_per_min, window_sec=60
                )
                ok_rate || return _json(429, Dict("ok" => false, "error" => "ingest_rate_limited"))

                device_id = String(payload["device_id"])
                seq_no = Int(payload["seq_no"])
                idem = String(payload["idempotency_key"])

                if settings.enforce_monotonic_seq
                    ok_seq = Hardening.check_sequence_monotonic!(hs, user_id, device_id, seq_no)
                    ok_seq || return _json(409, Dict("ok" => false, "error" => "non_monotonic_seq"))
                end

                # Idempotency check via session manager
                # If your function names differ, adjust these two calls.
                if SessionManager.idempotency_seen(store, user_id, idem)
                    return _json(200, Dict("ok" => true, "dedup" => true))
                end

                result = IngestService.apply_points_payload!(store, payload, user_id)

                SessionManager.mark_idempotency!(
                    store, user_id, idem; ttl_minutes=settings.idempotency_ttl_minutes
                )
                Hardening.track_sequence!(hs, user_id, device_id, seq_no)

                return _json(200, Dict(
                    "ok" => true,
                    "dedup" => false,
                    "result" => result
                ))
            end

            return _json(404, Dict("ok" => false, "error" => "not_found"))
        catch e
            msg = string(e)
            if occursin("unauthorized", msg)
                return _json(401, Dict("ok" => false, "error" => "unauthorized"))
            elseif occursin("missing_field", msg) || occursin("invalid_", msg) || occursin("out_of_range", msg) || occursin("empty_points", msg)
                return _json(400, Dict("ok" => false, "error" => msg))
            elseif occursin("payload_too_large", msg)
                return _json(413, Dict("ok" => false, "error" => msg))
            else
                return _json(500, Dict("ok" => false, "error" => msg))
            end
        end
    end
end

end # module mn                         