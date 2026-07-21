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
    # rate limit buckets: key => (window_start, count)
    rate_buckets::Dict{String, Tuple{DateTime, Int}}
    # last trigger time per user
    last_trigger_at::Dict{String, DateTime}
    # last seq per user/device
    last_seq::Dict{String, Int}
    lock::ReentrantLock
end

new_hardening_store() = HardeningStore(
    Dict{String, Tuple{DateTime, Int}}(),
    Dict{String, DateTime}(),
    Dict{String, Int}(),
    ReentrantLock()
)

# ---------- Validation ----------
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

function _range_check(v::AbstractVector, lo::Float64, hi::Float64, key::String)
    for x in v
        (x isa Number) || error("invalid_elem_type:$key")
        (x >= lo && x <= hi) || error("out_of_range:$key")
    end
end

function validate_ingest_payload!(payload)
    # required fields
    for k in ("device_id","mode","start_ts","end_ts","seq_no","sample_rate_hz","schema_version","idempotency_key")
        _require(payload, k)
    end

    _require_type_string(payload["device_id"], "device_id")
    _require_type_string(payload["mode"], "mode")
    _require_type_string(payload["start_ts"], "start_ts")
    _require_type_string(payload["end_ts"], "end_ts")
    _require_type_number(payload["seq_no"], "seq_no")
    _require_type_number(payload["sample_rate_hz"], "sample_rate_hz")
    _require_type_number(payload["schema_version"], "schema_version")
    _require_type_string(payload["idempotency_key"], "idempotency_key")

    mode = lowercase(String(payload["mode"]))
    (mode == "batch" || mode == "realtime") || error("invalid_mode")

    Int(payload["seq_no"]) >= 0 || error("invalid_seq_no")
    Float64(payload["sample_rate_hz"]) > 0 || error("invalid_sample_rate_hz")

    # optional arrays + bounds
    if haskey(payload, "hr")
        _require_array(payload["hr"], "hr")
        _range_check(payload["hr"], 20.0, 240.0, "hr")
    end
    if haskey(payload, "spo2")
        _require_array(payload["spo2"], "spo2")
        _range_check(payload["spo2"], 60.0, 100.0, "spo2")
    end
    if haskey(payload, "ppg")
        _require_array(payload["ppg"], "ppg")
        _range_check(payload["ppg"], -1.0e6, 1.0e6, "ppg")
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

# ---------- Rate Limit ----------
"""
Simple fixed-window limiter.
limit requests per window_sec for key.
"""
function check_rate_limit!(hs::HardeningStore, key::String; limit::Int=60, window_sec::Int=60)
    nowt = now()
    lock(hs.lock) do
        tup = get(hs.rate_buckets, key, (nowt, 0))
        win_start, count = tup
        if Dates.value(nowt - win_start) > window_sec*1000
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

# ---------- Trigger Cooldown ----------
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

# ---------- Sequence monotonicity ----------
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