module Routes

using HTTP
using JSON3
using UUIDs
using Dates
using ..Auth
using ..Config
using ..Types
using ..SessionManager
using ..IngestService
using ..TriggerService
using ..Hardening
using ..RedisStore

export make_router

function _req_id(req::HTTP.Request)
    rid = HTTP.header(req, "X-Request-Id", "")
    return isempty(rid) ? string(uuid4()) : rid
end

function _json(status::Int, body::Dict{String,Any}, req_id::String)
    body["request_id"] = req_id
    return HTTP.Response(status, ["Content-Type" => "application/json"], JSON3.write(body))
end

function _json_body(req::HTTP.Request)
    isempty(req.body) && return Dict{String,Any}()
    obj = JSON3.read(String(req.body))
    d = Dict{String,Any}()
    for (k,v) in pairs(obj)
        d[string(k)] = v
    end
    return d
end

# Robust ISO-8601 parser with 'Z' tolerance
function _parse_ts_any(x)::DateTime
    s = String(x)
    s = replace(s, 'Z' => "")
    for fmt in (dateformat"yyyy-mm-ddTHH:MM:SS.sss",
                dateformat"yyyy-mm-ddTHH:MM:SS",
                dateformat"yyyy-mm-dd HH:MM:SS")
        try
            return DateTime(s, fmt)
        catch
        end
    end
    try
        return DateTime(s)
    catch
        return now()
    end
end

function _to_points(arr)
    pts = Types.VitalsPoint[]
    for p in arr
        pd = Dict{String,Any}()
        for (k,v) in pairs(p)
            pd[string(k)] = v
        end
        ts = try
            _parse_ts_any(pd["ts"])
        catch
            now()
        end
        push!(pts, Types.VitalsPoint(ts, Float32(pd["hr"]), Float32(pd["hrv"]), Float32(pd["br"])))
    end
    return pts
end

function _touch_session_redis!(redis, user_id::String, settings)
    if redis !== nothing && redis.available
        try
            RedisStore.session_touch!(redis, user_id, settings.session_ttl_minutes * 60)
        catch
        end
    end
end

function handle_healthz(req)
    rid = _req_id(req)
    return _json(200, Dict{String,Any}("ok" => true), rid)
end

function handle_readyz(req, redis)
    rid = _req_id(req)
    return _json(200, Dict{String,Any}("ok" => true, "redis_available" => redis.available), rid)
end

function handle_status(req, settings)
    rid = _req_id(req)
    return _json(200, Dict{String,Any}("ok" => true, "service" => "biofeedback-backend", "auth_mode" => settings.auth_mode), rid)
end

function handle_trigger(req, store, settings, hs, redis)
    rid = _req_id(req)
    # Defensive payload size limit
    try
        Hardening.check_payload_size!(req.body; max_bytes=settings.max_payload_bytes)
    catch e
        return _json(413, Dict{String,Any}("ok"=>false, "error"=>string(e)), rid)
    end

    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && return _json(401, Dict{String,Any}("ok"=>false, "error"=>"unauthorized"), rid)
    _touch_session_redis!(redis, user_id, settings)

    body = try
        _json_body(req)
    catch
        return _json(400, Dict{String,Any}("ok"=>false, "error"=>"invalid_json"), rid)
    end

    try
        Hardening.validate_trigger_payload!(body)
    catch e
        return _json(400, Dict{String,Any}("ok"=>false, "error"=>"invalid_payload", "detail"=>string(e)), rid)
    end

    # Rate limit + cooldown
    if !Hardening.check_rate_limit!(hs, "trig:" * user_id; limit=settings.trigger_rate_limit_per_min, window_sec=60)
        return _json(429, Dict("ok"=>false, "error"=>"rate_limited"), rid)
    end
    if !Hardening.check_trigger_cooldown!(hs, user_id; cooldown_sec=settings.trigger_cooldown_sec)
        return _json(429, Dict("ok"=>false, "error"=>"trigger_cooldown", "cooldown_sec"=>settings.trigger_cooldown_sec), rid)
    end

    sess = SessionManager.get_or_create_session!(store, user_id)
    out = TriggerService.apply_trigger!(
        sess,
        String(body["trigger_type"]),
        settings;
        stream_duration_sec = haskey(body, "stream_duration_sec") ? Int(body["stream_duration_sec"]) : nothing
    )

    TriggerService.start_trigger_pulse_task!(sess, settings)
    return _json(200, out, rid)
end

function _apply_ingest_common(user_id, body, mode_sym, store, settings, hs, redis, rid; run_realtime::Bool)
    # Rate limit
    if !Hardening.check_rate_limit!(hs, "ing:" * user_id; limit=settings.ingest_rate_limit_per_min, window_sec=60)
        return _json(429, Dict("ok"=>false, "error"=>"rate_limited"), rid)
    end

    # Monotonic sequence enforcement (optional)
    seq_no = Int(body["seq_no"])
    device_id = String(body["device_id"])
    if settings.enforce_monotonic_seq
        if !Hardening.check_sequence_monotonic!(hs, user_id, device_id, seq_no)
            return _json(409, Dict("ok"=>false, "error"=>"non_monotonic_seq"), rid)
        end
    end

    # Idempotency (local + Redis)
    idem_key = "idem:ingest:" * user_id * ":" * device_id * ":" * String(body["idempotency_key"])
    if SessionManager.is_duplicate_idempotency_local!(store, idem_key)
        return _json(200, Dict("ok"=>true, "idempotent_repeat"=>true), rid)
    end
    redis_dup = (redis !== nothing && redis.available) ? RedisStore.idem_seen(redis, idem_key) : nothing
    if redis_dup === true
        return _json(200, Dict("ok"=>true, "idempotent_repeat"=>true), rid)
    end

    chunk = Types.SignalChunk(
        user_id,
        device_id,
        (mode_sym == :REALTIME ? Types.REALTIME : Types.BATCH),
        seq_no,
        Int(body["schema_version"]),
        String(body["idempotency_key"]),
        _to_points(body["points"])
    )

    sess = SessionManager.get_or_create_session!(store, user_id)
    out = if run_realtime
        IngestService.process_realtime!(sess, chunk, settings)
    else
        IngestService.process_batch!(sess, chunk, settings)
    end

    # Track seq and idempotency post-success
    Hardening.track_sequence!(hs, user_id, device_id, seq_no)
    SessionManager.mark_idempotency_local!(store, idem_key)
    if redis !== nothing && redis.available
        _ = RedisStore.idem_mark!(redis, idem_key, settings.idempotency_ttl_minutes * 60)
    end
    _touch_session_redis!(redis, user_id, settings)

    return _json(200, out, rid)
end

function handle_ingest_realtime(req, store, settings, hs, redis)
    rid = _req_id(req)
    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && return _json(401, Dict("ok"=>false, "error"=>"unauthorized"), rid)

    try
        Hardening.check_payload_size!(req.body; max_bytes=settings.max_payload_bytes)
    catch e
        return _json(413, Dict("ok"=>false, "error"=>string(e)), rid)
    end

    body = try
        _json_body(req)
    catch
        return _json(400, Dict("ok"=>false, "error"=>"invalid_json"), rid)
    end

    try
        Hardening.validate_ingest_payload!(body)
    catch e
        return _json(400, Dict("ok"=>false, "error"=>"invalid_payload", "detail"=>string(e)), rid)
    end

    return _apply_ingest_common(user_id, body, :REALTIME, store, settings, hs, redis, rid; run_realtime=true)
end

function handle_ingest_batch(req, store, settings, hs, redis)
    rid = _req_id(req)
    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && return _json(401, Dict("ok"=>false, "error"=>"unauthorized"), rid)

    try
        Hardening.check_payload_size!(req.body; max_bytes=settings.max_payload_bytes)
    catch e
        return _json(413, Dict("ok"=>false, "error"=>string(e)), rid)
    end

    body = try
        _json_body(req)
    catch
        return _json(400, Dict("ok"=>false, "error"=>"invalid_json"), rid)
    end

    try
        Hardening.validate_ingest_payload!(body)
    catch e
        return _json(400, Dict("ok"=>false, "error"=>"invalid_payload", "detail"=>string(e)), rid)
    end

    return _apply_ingest_common(user_id, body, :BATCH, store, settings, hs, redis, rid; run_realtime=false)
end

function make_router(store, redis, hs, settings)
    return function(req::HTTP.Request)
        t0 = time()
        rid = _req_id(req)
        route = "unknown"
        method = String(req.method)
        path = HTTP.URIs.URI(req.target).path

        try
            resp =
                if method == "GET" && path == "/healthz"
                    route = "healthz"; handle_healthz(req)
                elseif method == "GET" && path == "/readyz"
                    route = "readyz"; handle_readyz(req, redis)
                elseif method == "GET" && path == "/v1/status"
                    route = "status"; handle_status(req, settings)
                elseif method == "POST" && path == "/v1/events/trigger"
                    route = "trigger"; handle_trigger(req, store, settings, hs, redis)
                elseif method == "POST" && path == "/v1/ingest/realtime"
                    route = "ingest_realtime"; handle_ingest_realtime(req, store, settings, hs, redis)
                elseif method == "POST" && path == "/v1/ingest/batch"
                    route = "ingest_batch"; handle_ingest_batch(req, store, settings, hs, redis)
                else
                    _json(404, Dict{String,Any}("ok"=>false, "error"=>"not_found"), rid)
                end

            println("[REQ] id=$(rid) route=$(route) method=$(method) target=$(path) latency_ms=$(round((time()-t0)*1000; digits=1))")
            return resp
        catch e
            println("[REQ_ERR] id=$(rid) route=$(route) err=$(string(e)) latency_ms=$(round((time()-t0)*1000; digits=1))")
            return _json(500, Dict{String,Any}("ok"=>false, "error"=>"internal_error", "detail"=>string(e)), rid)
        end
    end
end

end # module