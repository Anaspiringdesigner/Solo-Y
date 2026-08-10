module IngestService

using Dates
using Statistics
using ..Types
using ..FeatureService
using ..RLService
using ..TDBridgeService
using ..Config

export parse_chunk, apply_chunk!, to_mode, refresh_hold_state!, maybe_emit_bio_trigger!

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

function refresh_hold_state!(sess::Types.SessionContext)
    now_dt = now()
    if sess.hold_ends_at === nothing
        sess.is_holding = false
        sess.hold_steps_left = 0
        if sess.state == :EVENT_STREAMING
            sess.state = :IDLE
        end
        return
    end

    remaining_ms = Dates.value(sess.hold_ends_at - now_dt)
    if remaining_ms <= 0
        sess.is_holding = false
        sess.hold_steps_left = 0
        sess.hold_started_at = nothing
        sess.hold_ends_at = nothing
        sess.state = :IDLE
        return
    end

    sess.is_holding = true
    sess.hold_steps_left = max(1, cld(Int(remaining_ms), 5000))
    sess.state = :EVENT_STREAMING
end

function _update_latest_features!(sess::Types.SessionContext, chunk::Types.SignalChunk)
    hrs = Float32[p.hr for p in chunk.points]
    hrvs = Float32[p.hrv for p in chunk.points]
    brs = Float32[p.br for p in chunk.points]

    sess.latest_features["avg_hr"] = mean_or_zero(hrs)
    sess.latest_features["avg_hrv"] = mean_or_zero(hrvs)
    sess.latest_features["avg_br"] = mean_or_zero(brs)
end

function _trim_buffer!(sess::Types.SessionContext; keep_minutes::Int=180)
    cutoff = now() - Minute(keep_minutes)
    filter!(sess.ring_buffer) do c
        any(p.ts >= cutoff for p in c.points)
    end
end

function _run_live_pipeline!(sess::Types.SessionContext, settings::Config.Settings)
    feats = FeatureService.encode_tcn_features(sess)
    rl = RLService.choose_action(feats)

    sess.last_rl_score = Float32(rl["score"])
    sess.last_rl_action = Int(rl["action"])
    sess.active_interaction = Int(rl["action"])

    payload = Dict{String, Any}(
        "user_id" => sess.user_id,
        "state" => String(sess.state),
        "is_holding" => sess.is_holding,
        "hold_steps_left" => sess.hold_steps_left,
        "active_interaction" => sess.active_interaction,
        "rl_score" => sess.last_rl_score,
        "features" => Dict(
            "avg_hr" => get(sess.latest_features, "avg_hr", 0f0),
            "avg_hrv" => get(sess.latest_features, "avg_hrv", 0f0),
            "avg_br" => get(sess.latest_features, "avg_br", 0f0),
            "tcn_hr" => get(feats, "tcn_hr", 0f0),
            "tcn_hrv" => get(feats, "tcn_hrv", 0f0),
            "tcn_br" => get(feats, "tcn_br", 0f0),
            "stress_score" => get(feats, "stress_score", 0f0),
        ),
        "ts" => string(now()),
    )

    TDBridgeService.send_td_payload(settings, payload)
end

function apply_chunk!(sess::Types.SessionContext, chunk::Types.SignalChunk, settings::Config.Settings)
    lock(sess.lock) do
        push!(sess.ring_buffer, chunk)
        sess.last_seen = now()
        _trim_buffer!(sess)
        refresh_hold_state!(sess)
        _update_latest_features!(sess, chunk)

        if chunk.mode == Types.BATCH
            if !sess.is_holding
                sess.state = :BATCH_SYNCING
            end
            FeatureService.incremental_train_tcn!(sess)
        else
            if sess.is_holding
                _run_live_pipeline!(sess, settings)
            end
        end
    end
end

function maybe_emit_bio_trigger!(sess::Types.SessionContext, settings::Config.Settings)::Bool
    lock(sess.lock) do
        refresh_hold_state!(sess)
        if sess.is_holding
            return false
        end

        if sess.last_bio_trigger_at !== nothing
            if Dates.value(now() - sess.last_bio_trigger_at) < settings.event_stream_duration_sec * 1000
                return false
            end
        end

        if FeatureService.detect_bio_trigger(sess, settings.bio_stress_threshold)
            sess.last_bio_trigger_at = now()
            return true
        end
        return false
    end
end

end # module