module IngestService

using Dates
using Statistics
using ..Types
using ..SessionManager

export to_mode, apply_points_payload!, parse_points

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

function _parse_ts_utc(s::AbstractString)::DateTime
    # Accepts ISO8601 like "2026-08-05T10:21:32Z" or with fractions.
    t = String(s)
    t = replace(t, "Z" => "")
    if occursin(".", t)
        # drop fractional seconds for DateTime parser stability
        head = split(t, ".")[1]
        return DateTime(head)
    end
    return DateTime(t)
end

function parse_points(payload)::Vector{NamedTuple{(:ts,:hr,:hrv,:br),Tuple{DateTime,Float64,Float64,Float64}}}
    pts_raw = payload["points"]
    out = Vector{NamedTuple{(:ts,:hr,:hrv,:br),Tuple{DateTime,Float64,Float64,Float64}}}(undef, length(pts_raw))

    for (i, p) in enumerate(pts_raw)
        ts = _parse_ts_utc(String(p["ts"]))
        hr = Float64(p["hr"])
        hrv = Float64(p["hrv"])
        br = Float64(p["br"])
        out[i] = (ts=ts, hr=hr, hrv=hrv, br=br)
    end

    return out
end

"""
Apply incoming points payload to session aggregates/state.

Expected payload shape:
{
  "device_id": "...",
  "mode": "batch|realtime",
  "seq_no": 123,
  "schema_version": 1,
  "idempotency_key": "...",
  "points": [{ "ts": "...", "hr": 72.1, "hrv": 31.2, "br": 12.4 }, ...]
}
"""
function apply_points_payload!(
    store::SessionManager.SessionStore,
    payload,
    user_id::String
)
    device_id = String(payload["device_id"])
    mode = to_mode(String(payload["mode"]))
    seq_no = Int(payload["seq_no"])
    idempotency_key = String(payload["idempotency_key"])

    points = parse_points(payload)

    # Compute simple averages from this payload chunk
    avg_hr = mean(map(p -> p.hr, points))
    avg_hrv = mean(map(p -> p.hrv, points))
    avg_br = mean(map(p -> p.br, points))

    # Update session snapshot/state
    # Keep your existing session manager contract: update signals/status snapshot.
    # If SessionManager has a different function name in your code, adjust only this call.
    SessionManager.upsert_session_from_ingest!(
        store;
        user_id=user_id,
        device_id=device_id,
        mode=mode,
        seq_no=seq_no,
        idempotency_key=idempotency_key,
        avg_hr=avg_hr,
        avg_hrv=avg_hrv,
        avg_br=avg_br,
        points_count=length(points),
        last_point_ts=points[end].ts
    )

    return (
        ok = true,
        device_id = device_id,
        mode = String(payload["mode"]),
        seq_no = seq_no,
        points_received = length(points),
        avg_hr = avg_hr,
        avg_hrv = avg_hrv,
        avg_br = avg_br
    )
end

end # module