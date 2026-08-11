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

export make_router

_req_id(req::HTTP.Request) = begin
    rid = HTTP.header(req, "X-Request-Id", "")
    isempty(rid) ? string(uuid4()) : rid
end

function _json(status::Int, body::Dict{String,Any}; req_id::String="")
    if !isempty(req_id)
        body["request_id"] = req_id
    end
    HTTP.Response(status, ["Content-Type"=>"application/json"], JSON3.write(body))
end

function _json_body(req::HTTP.Request)
    isempty(req.body) && return Dict{String,Any}()
    obj = JSON3.read(String(req.body))
    d = Dict{String,Any}()
    for (k,v) in pairs(obj)
        d[string(k)] = v
    end
    d
end

function _to_points(arr)
    pts = Types.VitalsPoint[]
    for p in arr
        pd = Dict{String,Any}()
        for (k,v) in pairs(p)
            pd[string(k)] = v
        end
        ts = try DateTime(String(pd["ts"])) catch; now() end
        push!(pts, Types.VitalsPoint(ts, Float32(pd["hr"]), Float32(pd["hrv"]), Float32(pd["br"])))
    end
    pts
end

function handle_healthz(req)
    _json(200, Dict("ok"=>true); req_id=_req_id(req))
end

function handle_readyz(req, redis)
    _json(200, Dict("ok"=>true, "redis_available"=>redis.available); req_id=_req_id(req))
end

function handle_status(req, settings)
    _json(200, Dict("ok"=>true, "service"=>"biofeedback-backend", "auth_mode"=>settings.auth_mode); req_id=_req_id(req))
end

function handle_trigger(req, store, settings, hs)
    rid = _req_id(req)
    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && return _json(401, Dict("ok"=>false, "error"=>"unauthorized"); req_id=rid)

    body = try _json_body(req) catch; return _json(400, Dict("ok"=>false, "error"=>"invalid_json"); req_id=rid) end
    try Hardening.validate_trigger_payload!(body) catch e
        return _json(400, Dict("ok"=>false, "error"=>"invalid_payload", "detail"=>string(e)); req_id=rid)
    end

    sess = SessionManager.get_or_create_session!(store, user_id)
    out = TriggerService.apply_trigger!(sess, String(body["trigger_type"]), settings;
        stream_duration_sec = haskey(body, "stream_duration_sec") ? Int(body["stream_duration_sec"]) : nothing)

    TriggerService.start_trigger_pulse_task!(sess, settings)

    _json(200, out; req_id=rid)
end

function handle_ingest_realtime(req, store, settings, hs)
    rid = _req_id(req)
    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && return _json(401, Dict("ok"=>false, "error"=>"unauthorized"); req_id=rid)

    try
        Hardening.check_payload_size!(req.body; max_bytes=settings.max_payload_bytes)
    catch e
        return _json(413, Dict("ok"=>false, "error"=>string(e)); req_id=rid)
    end

    body = try _json_body(req) catch; return _json(400, Dict("ok"=>false, "error"=>"invalid_json"); req_id=rid) end
    try Hardening.validate_ingest_payload!(body) catch e
        return _json(400, Dict("ok"=>false, "error"=>"invalid_payload", "detail"=>string(e)); req_id=rid)
    end

    try
        chunk = Types.SignalChunk(
            user_id,
            String(body["device_id"]),
            lowercase(String(body["mode"])) == "realtime" ? Types.REALTIME : Types.BATCH,
            Int(body["seq_no"]),
            Int(body["schema_version"]),
            String(body["idempotency_key"]),
            _to_points(body["points"])
        )
        sess = SessionManager.get_or_create_session!(store, user_id)
        out = IngestService.process_realtime!(sess, chunk, settings)
        _json(200, out; req_id=rid)
    catch e
        println("[REQ_ERR] id=$(rid) route=ingest_realtime err=$(string(e))")
        _json(400, Dict("ok"=>false, "error"=>"invalid_payload", "detail"=>string(e)); req_id=rid)
    end
end

function handle_ingest_batch(req, store, settings, hs)
    rid = _req_id(req)
    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && return _json(401, Dict("ok"=>false, "error"=>"unauthorized"); req_id=rid)

    body = try _json_body(req) catch; return _json(400, Dict("ok"=>false, "error"=>"invalid_json"); req_id=rid) end
    try Hardening.validate_ingest_payload!(body) catch e
        return _json(400, Dict("ok"=>false, "error"=>"invalid_payload", "detail"=>string(e)); req_id=rid)
    end

    chunk = Types.SignalChunk(
        user_id,
        String(body["device_id"]),
        lowercase(String(body["mode"])) == "realtime" ? Types.REALTIME : Types.BATCH,
        Int(body["seq_no"]),
        Int(body["schema_version"]),
        String(body["idempotency_key"]),
        _to_points(body["points"])
    )
    sess = SessionManager.get_or_create_session!(store, user_id)
    out = IngestService.process_batch!(sess, chunk, settings)
    _json(200, out; req_id=rid)
end

function make_router(store, redis, hs, settings)
    return function(req::HTTP.Request)
        t0 = time()
        rid = _req_id(req)
        route = "unknown"
        path = HTTP.URIs.URI(req.target).path
        method = String(req.method)

        try
            resp =
                if method == "GET" && path == "/healthz"
                    route = "healthz"; handle_healthz(req)
                elseif method == "GET" && path == "/readyz"
                    route = "readyz"; handle_readyz(req, redis)
                elseif method == "GET" && path == "/v1/status"
                    route = "status"; handle_status(req, settings)
                elseif method == "POST" && path == "/v1/events/trigger"
                    route = "trigger"; handle_trigger(req, store, settings, hs)
                elseif method == "POST" && path == "/v1/ingest/realtime"
                    route = "ingest_realtime"; handle_ingest_realtime(req, store, settings, hs)
                elseif method == "POST" && path == "/v1/ingest/batch"
                    route = "ingest_batch"; handle_ingest_batch(req, store, settings, hs)
                else
                    _json(404, Dict("ok"=>false, "error"=>"not_found"); req_id=rid)
                end

            println("[REQ] id=$(rid) route=$(route) method=$(method) target=$(path) latency_ms=$(round((time()-t0)*1000; digits=1))")
            return resp
        catch e
            println("[REQ_ERR] id=$(rid) route=$(route) err=$(string(e)) latency_ms=$(round((time()-t0)*1000; digits=1))")
            return _json(500, Dict("ok"=>false, "error"=>"internal_error", "detail"=>string(e)); req_id=rid)
        end
    end
end

end