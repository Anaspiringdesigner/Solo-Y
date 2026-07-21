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
    spo2 = haskey(payload, "spo2") ? to_f32_vec(payload["spo2"]) : Float32[]
    ppg = haskey(payload, "ppg") ? to_f32_vec(payload["ppg"]) : Float32[]
    ax = haskey(payload, "accel_x") ? to_f32_vec(payload["accel_x"]) : Float32[]
    ay = haskey(payload, "accel_y") ? to_f32_vec(payload["accel_y"]) : Float32[]
    az = haskey(payload, "accel_z") ? to_f32_vec(payload["accel_z"]) : Float32[]

    return Types.SignalChunk(
        user_id, device_id, mode, start_ts, end_ts, seq_no, sample_rate_hz,
        hr, spo2, ppg, ax, ay, az, schema_version, idempotency_key
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

        # Phase-1 feature updates (simple rolling overwrite)
        sess.latest_features["avg_hr"] = mean_or_zero(chunk.hr)
        sess.latest_features["avg_spo2"] = mean_or_zero(chunk.spo2)
        sess.latest_features["avg_ppg"] = mean_or_zero(chunk.ppg)
    end
end

end # module