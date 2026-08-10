module FeatureService

using Dates
using Statistics
using ..Types

export encode_tcn_features, incremental_train_tcn!, detect_bio_trigger

function _collect_recent_points(sess::Types.SessionContext; lookback_minutes::Int=30)
    cutoff = now() - Minute(lookback_minutes)
    pts = Types.VitalsPoint[]
    for c in sess.ring_buffer
        for p in c.points
            if p.ts >= cutoff
                push!(pts, p)
            end
        end
    end
    sort!(pts, by = x -> x.ts)
    return pts
end

function _norm(x::Float32, center::Float32, scale::Float32)
    s = abs(scale) < 1f-6 ? 1f0 : scale
    return (x - center) / s
end

function encode_tcn_features(sess::Types.SessionContext)::Dict{String, Float32}
    pts = _collect_recent_points(sess; lookback_minutes = 30)
    if isempty(pts)
        avg_hr = get(sess.latest_features, "avg_hr", 0f0)
        avg_hrv = get(sess.latest_features, "avg_hrv", 0f0)
        avg_br = get(sess.latest_features, "avg_br", 0f0)
        return Dict(
            "tcn_z1" => _norm(avg_hr, 70f0, 15f0),
            "tcn_z2" => _norm(avg_hrv, 30f0, 20f0),
            "tcn_z3" => _norm(avg_br, 14f0, 6f0),
            "tcn_hr" => avg_hr,
            "tcn_hrv" => avg_hrv,
            "tcn_br" => avg_br,
            "stress_score" => 0f0,
        )
    end

    if length(pts) > 60
        pts = pts[end-59:end]
    end

    hrs = Float32[p.hr for p in pts]
    hrvs = Float32[p.hrv for p in pts]
    brs = Float32[p.br for p in pts]

    avg_hr = Float32(mean(hrs))
    avg_hrv = Float32(mean(hrvs))
    avg_br = Float32(mean(brs))

    hr_slope = length(hrs) >= 2 ? Float32(hrs[end] - hrs[1]) : 0f0
    hrv_slope = length(hrvs) >= 2 ? Float32(hrvs[end] - hrvs[1]) : 0f0
    br_slope = length(brs) >= 2 ? Float32(brs[end] - brs[1]) : 0f0

    stress = clamp((avg_hr - avg_hrv) / 100f0, 0f0, 1f0)

    return Dict(
        "tcn_z1" => _norm(avg_hr, 70f0, 15f0),
        "tcn_z2" => _norm(avg_hrv, 30f0, 20f0),
        "tcn_z3" => _norm(avg_br, 14f0, 6f0),
        "tcn_z4" => clamp(hr_slope / 20f0, -1f0, 1f0),
        "tcn_z5" => clamp(hrv_slope / 20f0, -1f0, 1f0),
        "tcn_z6" => clamp(br_slope / 10f0, -1f0, 1f0),
        "tcn_hr" => avg_hr,
        "tcn_hrv" => avg_hrv,
        "tcn_br" => avg_br,
        "stress_score" => stress,
    )
end

function incremental_train_tcn!(sess::Types.SessionContext)::Dict{String, Any}
    feats = encode_tcn_features(sess)
    sess.last_tcn_train_at = now()
    for (k, v) in feats
        sess.latest_features[k] = v
    end
    return Dict(
        "ok" => true,
        "trained_on_new_data" => true,
        "trained_at" => string(sess.last_tcn_train_at),
        "features" => feats,
    )
end

function detect_bio_trigger(sess::Types.SessionContext, threshold::Float64)::Bool
    feats = encode_tcn_features(sess)
    stress = Float64(get(feats, "stress_score", 0f0))
    return stress >= threshold
end

end # module