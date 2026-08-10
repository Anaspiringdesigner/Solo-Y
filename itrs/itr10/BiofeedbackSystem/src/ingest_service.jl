module IngestService

using Dates
using Statistics
using ..Types
using ..FeatureService
using ..RLService
using ..TDBridgeService
using ..TriggerService
using ..Config

export parse_chunk, apply_chunk!, to_mode, maybe_fire_bio_trigger!

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

function _trim_ring_buffer!(sess::Types.SessionContext; keep_minutes::Int=40)
    cutoff = now() - Minute(keep_minutes)
    filter!(sess.ring_buffer) do c
        any(p -> p.ts >= cutoff, c.points)
    end
end

function _latest_point(chunk::Types.SignalChunk)
    isempty(chunk.points) && return nothing
    return chunk.points[end]
end

function _run_live_pipeline!(sess::Types.SessionContext, chunk::Types.SignalChunk, settings::Config.Settings)
    TriggerService.refresh_hold_state!(sess)
    if !sess.is_holding
        return Dict("td_sent" => false, "reason" => "not_holding")
    end

    feats = FeatureService.encode_tcn_features(sess)
    rl = RLService.choose_action(feats)

    sess.last_rl_action = Int(rl["action"])
    sess.last_rl_score = Float32(rl["score"])
    sess.active_interaction = sess.last_rl_action

    pt = _latest_point(chunk)
    hr = pt === nothing ? get(sess.latest_features, "avg_hr", 0f0) : pt.hr
    hrv = pt === nothing ? get(sess.latest_features, "avg_hrv", 0f0) : pt.hrv
    br = pt === nothing ? get(sess.latest_features, "avg_br", 0f0) : pt.br

    td_payload = Dict{String, Any}(
        "ping" => 1,
        "hr" => hr,
        "hrv" => hrv,
        "br" => br,
        "interaction" => sess.active_interaction,
        "reward" => Float32(get(rl, "score", 0f0)),
        "trigger" => TDBridgeService.trigger_code(sess.last_trigger_type),
        "holding" => sess.is_holding ? 1 : 0,
        "hold_steps" => sess.hold_steps_left,
        "hold_progress" => TriggerService.hold_progress(sess),
    )

    sent = TDBridgeService.send_td_payload(settings, td_payload)
    return Dict(
        "td_sent" => sent,
        "interaction" => sess.active_interaction,
        "reward" => Float32(get(rl, "score", 0f0)),
    )
end

function maybe_fire_bio_trigger!(sess::Types.SessionContext, settings::Config.Settings)::Bool
    lock(sess.lock) do
        TriggerService.refresh_hold_state!(sess)
        if sess.is_holding
            return false
        end

        cooldown_ok = sess.last_bio_trigger_at === nothing ||
                      Dates.value(now() - sess.last_bio_trigger_at) > settings.event_stream_duration_sec * 1000
        if !cooldown_ok
            return false
        end

        if FeatureService.detect_bio_trigger(sess, settings.bio_stress_threshold)
            sess.last_bio_trigger_at = now()
            TriggerService.apply_trigger!(sess, "bio", settings.event_stream_duration_sec)
            return true
        end
        return false
    end
end

function apply_chunk!(sess::Types.SessionContext, chunk::Types.SignalChunk, settings::Config.Settings)
    lock(sess.lock) do
        push!(sess.ring_buffer, chunk)
        sess.last_seen = now()
        _trim_ring_buffer!(sess; keep_minutes = settings.batch_window_minutes + 10)

        hrs = Float32[p.hr for p in chunk.points]
        hrvs = Float32[p.hrv for p in chunk.points]
        brs = Float32[p.br for p in chunk.points]

        sess.latest_features["avg_hr"] = mean_or_zero(hrs)
        sess.latest_features["avg_hrv"] = mean_or_zero(hrvs)
        sess.latest_features["avg_br"] = mean_or_zero(brs)

        if chunk.mode == Types.BATCH
            sess.state = :BATCH_SYNCING
            train_info = FeatureService.incremental_train_tcn!(sess)
            maybe_fire_bio_trigger!(sess, settings)
            return Dict(
                "trained_on_new_data" => get(train_info, "trained_on_new_data", false),
                "td_sent" => false,
            )
        else
            TriggerService.refresh_hold_state!(sess)
            if sess.is_holding
                sess.state = :EVENT_STREAMING
                return _run_live_pipeline!(sess, chunk, settings)
            else
                sess.state = :IDLE
                return Dict("td_sent" => false, "reason" => "realtime_outside_trigger")
            end
        end
    end
end

end # module