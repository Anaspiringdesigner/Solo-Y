module Hardening

using Dates
using Base.Threads: ReentrantLock
using ..Types
using ..Config

export validate_ingest_payload!, validate_trigger_payload!,
       check_payload_size!, check_rate_limit!, check_trigger_cooldown!,
       check_sequence_monotonic!, track_sequence!,
       HardeningStore, new_hardening_store

mutable struct HardeningStore
    rate_buckets::Dict{String, Tuple{DateTime, Int}}
    last_trigger_at::Dict{String, DateTime}
    last_seq::Dict{String, Int}
    lock::ReentrantLock
end

new_hardening_store() = HardeningStore(
    Dict{String, Tuple{DateTime, Int}}(),
    Dict{String, DateTime}(),
    Dict{String, Int}(),
    ReentrantLock()
)

function check_payload_size!(req_body; max_bytes::Int=512_000)
    n = try
        length(req_body)
    catch
        0
    end
    n > max_bytes && error("payload_too_large")
    return nothing
end

function _require(payload, key::String)
    haskey(payload, key) || error("missing_field:$key")
    return payload[key]
end

function _require_type_string(x, key::String)
    x isa AbstractString || error("invalid_type:$key")
end

function _require_type_number(x, key::String)
    (x isa Number) || error("invalid_type:$key")
end

function _require_array(x, key::String)
    x isa AbstractVector || error("invalid_type:$key")
end

function validate_ingest_payload!(payload)
    _require(payload, "device_id")
    _require(payload, "mode")
    _require(payload, "seq_no")
    _require(payload, "schema_version")
    _require(payload, "idempotency_key")
    _require(payload, "points")

    _require_type_string(payload["device_id"], "device_id")
    _require_type_string(payload["mode"], "mode")
    _require_type_number(payload["seq_no"], "seq_no")
    _require_type_number(payload["schema_version"], "schema_version")
    _require_type_string(payload["idempotency_key"], "idempotency_key")
    _require_array(payload["points"], "points")

    mode = lowercase(String(payload["mode"]))
    (mode == "batch" || mode == "realtime") || error("invalid_mode")

    Int(payload["seq_no"]) >= 0 || error("invalid_seq_no")

    pts = payload["points"]
    length(pts) > 0 || error("empty_points")

    for p in pts
        haskey(p, "ts") || error("missing_field:points.ts")
        haskey(p, "hr") || error("missing_field:points.hr")
        haskey(p, "hrv") || error("missing_field:points.hrv")
        haskey(p, "br") || error("missing_field:points.br")

        _require_type_string(p["ts"], "points.ts")
        _require_type_number(p["hr"], "points.hr")
        _require_type_number(p["hrv"], "points.hrv")
        _require_type_number(p["br"], "points.br")

        hr = Float64(p["hr"])
        hrv = Float64(p["hrv"])
        br = Float64(p["br"])

        (hr >= 30.0 && hr <= 220.0) || error("out_of_range:points.hr")
        (hrv >= 0.0 && hrv <= 300.0) || error("out_of_range:points.hrv")
        (br >= 4.0 && br <= 40.0) || error("out_of_range:points.br")
    end

    return nothing
end

function validate_trigger_payload!(payload)
    haskey(payload, "trigger_type") || error("missing_field:trigger_type")
    tt = lowercase(String(payload["trigger_type"]))
    tt in ("manual","calendar","bio","system") || error("invalid_trigger_type")

    if haskey(payload, "stream_duration_sec")
        d = Int(payload["stream_duration_sec"])
        (d >= 30 && d <= 900) || error("invalid_stream_duration_sec")
    end
    return nothing
end

function check_rate_limit!(hs::HardeningStore, key::String; limit::Int=60, window_sec::Int=60)
    nowt = now()
    lock(hs.lock) do
        tup = get(hs.rate_buckets, key, (nowt, 0))
        win_start, count = tup
        if Dates.value(nowt - win_start) > window_sec * 1000
            hs.rate_buckets[key] = (nowt, 1)
            return true
        else
            if count + 1 > limit
                return false
            else
                hs.rate_buckets[key] = (win_start, count + 1)
                return true
            end
        end
    end
end

function check_trigger_cooldown!(hs::HardeningStore, user_id::String; cooldown_sec::Int=15)
    nowt = now()
    lock(hs.lock) do
        last = get(hs.last_trigger_at, user_id, DateTime(1970,1,1))
        if Dates.value(nowt - last) < cooldown_sec * 1000
            return false
        end
        hs.last_trigger_at[user_id] = nowt
        return true
    end
end

function check_sequence_monotonic!(hs::HardeningStore, user_id::String, device_id::String, seq_no::Int)
    key = "$user_id:$device_id"
    lock(hs.lock) do
        last = get(hs.last_seq, key, -1)
        return seq_no > last
    end
end

function track_sequence!(hs::HardeningStore, user_id::String, device_id::String, seq_no::Int)
    key = "$user_id:$device_id"
    lock(hs.lock) do
        hs.last_seq[key] = seq_no
    end
end

end # module