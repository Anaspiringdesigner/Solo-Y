module IngestService

using Dates
using JSON3
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

parse_ts(x) = DateTime(String(x))

to_f32_vec(arr) = Float32.(arr)

function parse_chunk(payload, user_id::String)::Types.SignalChunk
    device_id = String(payload["device_id"])
    mode = to_mode(String(payload["mode"]))
    start_ts = parse_ts(payload["start_ts"])
    end_ts = parse_ts(payload["end_ts"])
    seq_no = Int(payload["seq_no"])
    sample_rate_hz = Float32(payload["sample_rate_hz"])
    schema_version = Int(payload["schema_version"])
    idempotency_key = String(payload["idempotency_key"])

    hr = haskey(payload, "hr") ? to_f32_vec(payload["hr"]) : Float32[]
    hrv = haskey(payload, "hrv") ? to_f32_vec(payload["hrv"]) : Float32[]
    br = haskey(payload, "br") ? to_f32_vec(payload["br"]) : Float32[]

    return Types.SignalChunk(
        user_id, device_id, mode, start_ts, end_ts, seq_no, sample_rate_hz,
        hr, hrv, br, schema_version, idempotency_key
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

        sess.latest_features["avg_hr"] = mean_or_zero(chunk.hr)
        sess.latest_features["avg_hrv"] = mean_or_zero(chunk.hrv)
        sess.latest_features["avg_br"] = mean_or_zero(chunk.br)
    end
end

end # module