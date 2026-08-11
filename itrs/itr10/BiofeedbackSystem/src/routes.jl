module Routes

using HTTP
using JSON3
using Dates
using UUIDs
using ..Config
using ..Types
using ..SessionManager
using ..IngestService
using ..TriggerService
using ..ResponseUtils

export make_router

function _req_id(req::HTTP.Request)
    rid = HTTP.header(req, "X-Request-Id", "")
    isempty(rid) ? string(uuid4()) : rid
end

function _json_body(req::HTTP.Request)
    isempty(req.body) && return Dict{String, Any}()
    return JSON3.read(String(req.body))
end

function _to_points(arr)
    pts = Types.VitalsPoint[]
    for p in arr
        ts_raw = haskey(p, "ts") ? String(p["ts"]) : (haskey(p, :ts) ? String(p[:ts]) : "")
        hr = haskey(p, "hr") ? Float32(p["hr"]) : Float32(p[:hr])
        hrv = haskey(p, "hrv") ? Float32(p["hrv"]) : Float32(p[:hrv])
        br = haskey(p, "br") ? Float32(p["br"]) : Float32(p[:br])

        ts = try
            DateTime(ts_raw)
        catch
            now()
        end
        push!(pts, Types.VitalsPoint(ts, hr, hrv, br))
    end
    return pts
end

function handle_status(req, store, settings)
    rid = _req_id(req)
    return ResponseUtils.json_response(200, Dict("ok" => true, "service" => "biofeedback-backend"); req_id = rid)
end

function handle_trigger(req, store, settings)
    rid = _req_id(req)
    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && return ResponseUtils.json_response(401, Dict("ok" => false, "error" => "unauthorized"); req_id = rid)

    body = try
        _json_body(req)
    catch
        return ResponseUtils.json_response(400, Dict("ok" => false, "error" => "invalid_json"); req_id = rid)
    end

    trigger_type = haskey(body, "trigger_type") ? String(body["trigger_type"]) :
                   (haskey(body, :trigger_type) ? String(body[:trigger_type]) : "")

    valid_types = Set(["manual", "calendar", "bio", "system"])
    (trigger_type in valid_types) || return ResponseUtils.json_response(400, Dict("ok" => false, "error" => "invalid_trigger_type"); req_id = rid)

    stream_duration_sec = nothing
    if haskey(body, "stream_duration_sec") || haskey(body, :stream_duration_sec)
        raw = haskey(body, "stream_duration_sec") ? body["stream_duration_sec"] : body[:stream_duration_sec]
        stream_duration_sec = Int(raw)
        (30 <= stream_duration_sec <= 900) || return ResponseUtils.json_response(400, Dict("ok" => false, "error" => "invalid_stream_duration_sec"); req_id = rid)
    end

    sess = SessionManager.get_or_create_session!(store, user_id)
    res = TriggerService.apply_trigger!(sess, trigger_type, settings; stream_duration_sec = stream_duration_sec)

    # start background pulse for TD updates during hold
    TriggerService.start_trigger_pulse_task!(sess, settings)

    return ResponseUtils.json_response(200, res; req_id = rid)
end

function handle_ingest_realtime(req, store, settings)
    rid = _req_id(req)
    user_id = Auth.extract_user_id(req, settings)
    user_id === nothing && return ResponseUtils.json_response(401, Dict("ok" => false, "error" => "unauthorized"); req_id = rid)

    body = try
        _json_body(req)
    catch
        return ResponseUtils.json_response(400, Dict("ok" => false, "error" => "invalid_json"); req_id = rid)
    end

    try
        device_id = haskey(body, "device_id") ? String(body["device_id"]) : String(body[:device_id])
        mode_s = haskey(body, "mode") ? String(body["mode"]) : String(body[:mode])
        seq_no = haskey(body, "seq_no") ? Int(body["seq_no"]) : Int(body[:seq_no])
        schema_version = haskey(body, "schema_version") ? Int(body["schema_version"]) : Int(body[:schema_version])
        idempotency_key = haskey(body, "idempotency_key") ? String(body["idempotency_key"]) : String(body[:idempotency_key])
        points_raw = haskey(body, "points") ? body["points"] : body[:points]

        mode = lowercase(mode_s) == "realtime" ? Types.REALTIME : Types.BATCH
        points = _to_points(points_raw)

        chunk = Types.SignalChunk(
            user_id,
            device_id,
            mode,
            seq_no,
            schema_version,
            idempotency_key,
            points
        )

        sess = SessionManager.get_or_create_session!(store, user_id)
        out = IngestService.process_realtime!(sess, chunk, settings)

        return ResponseUtils.json_response(200, out; req_id = rid)
    catch e
        println("[REQ_ERR] id=$(rid) route=ingest_realtime err=$(string(e))")
        return ResponseUtils.json_response(400, Dict("ok" => false, "error" => "invalid_payload", "detail" => string(e)); req_id = rid)
    end
end

function make_router(store, redis, hs, settings)
    return function (req::HTTP.Request)
        t0 = time()
        route = "unknown"
        rid = _req_id(req)

        try
            path = HTTP.URIs.URI(req.target).path
            method = String(req.method)

            if method == "GET" && path == "/v1/status"
                route = "status"
                resp = handle_status(req, store, settings)
                println("[REQ] id=$(rid) route=$(route) method=$(method) target=$(path) latency_ms=$(round((time()-t0)*1000; digits=1))")
                return resp
            elseif method == "POST" && path == "/v1/events/trigger"
                route = "trigger"
                resp = handle_trigger(req, store, settings)
                println("[REQ] id=$(rid) route=$(route) method=$(method) target=$(path) latency_ms=$(round((time()-t0)*1000; digits=1))")
                return resp
            elseif method == "POST" && path == "/v1/ingest/realtime"
                route = "ingest_realtime"
                resp = handle_ingest_realtime(req, store, settings)
                println("[REQ] id=$(rid) route=$(route) method=$(method) target=$(path) latency_ms=$(round((time()-t0)*1000; digits=1))")
                return resp
            else
                return ResponseUtils.json_response(404, Dict("ok" => false, "error" => "not_found"); req_id = rid)
            end
        catch e
            println("[REQ_ERR] id=$(rid) route=$(route) err=$(string(e)) latency_ms=$(round((time()-t0)*1000; digits=1))")
            return ResponseUtils.json_response(500, Dict("ok" => false, "error" => "internal_error", "detail" => string(e)); req_id = rid)
        end
    end
end

end # module