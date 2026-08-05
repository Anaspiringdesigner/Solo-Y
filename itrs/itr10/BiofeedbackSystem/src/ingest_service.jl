module IngestService

using Dates
using Statistics
using ..Types
using ..SessionManager

export parse_chunk, apply_chunk!, to_mode

function to_mode(mode_str::AbstractString)::Types.IngestMode
    m = lowercase(strip(mode_str))
    if m == "batch"
        return Types.BATCH
    elseif m == "realtime"
        return Types.REALTIME
    else
        error("invalid_mode")
    end
end

function parse_ts(x)
    s = String(x)
    s = replace(s, "Z" => "")
    if occursin(".", s)
        s = split(s, ".")[1]
    end
    return DateTime(s)
end

function parse_chunk(payload, user_id::String)::Types.SignalChunk
    device_id = String(payload["device_id"])
    mode = to_mode(String(payload["mode"]))
    seq_no = Int(payload["seq_no"])
    schema_version = Int(payload["schema_version"])
    idempotency_key = String(payload["idempotency_key"])

    pts_raw = payload["points"]
    pts = Types.VitalsPoint[]
    for p in pts_raw
        push!(pts, Types.VitalsPoint(
            parse_ts(p["ts"]),
            Float32(p["hr"]),
            Float32(p["hrv"]),
            Float32(p["br"]),
        ))
    end

    return Types.SignalChunk(
        user_id, device_id, mode, seq_no, schema_version, idempotency_key, pts
    )
end

mean_or_zero(v::Vector{Float32}) = isempty(v) ? 0f0 : Float32(mean(v))

function apply_chunk!(sess::Types.SessionContext, chunk::Types.SignalChunk)
    lock(sess.lock) do
        push!(sess.ring_buffer, chunk)
        sess.last_seen = now()

        if chunk.mode == Types.BATCH
            sess.state = :BATCH_SYNCING
        else
            sess.state = :EVENT_STREAMING
        end

        hrs = Float32[p.hr for p in chunk.points]
        hrvs = Float32[p.hrv for p in chunk.points]
        brs = Float32[p.br for p in chunk.points]

        sess.latest_features["avg_hr"] = mean_or_zero(hrs)
        sess.latest_features["avg_hrv"] = mean_or_zero(hrvs)
        sess.latest_features["avg_br"] = mean_or_zero(brs)
    end
end

end # module