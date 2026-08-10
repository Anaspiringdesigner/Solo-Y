module IngestService

using Dates
using Statistics
using ..Types
using ..FeatureService
using ..RLService
using ..TDBridgeService
using ..Config

export parse_chunk, apply_chunk!, to_mode, refresh_hold_state!, maybe_run_live_pipeline!, maybe_detect_bio_trigger!

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

function refresh_hold_state!(sess::Types.SessionContext, settings::Config.Settings)
    now_dt = now()
    if sess.hold_ends_at === nothing
        sess.is_holding = false
        sess.hold_steps_left = 0
        if sess.state == :EVENT_STREAMING
            sess.state = :IDLE
        end
        return
    end

    if now_dt >= sess.hold_ends_at
        sess.is_holding = false
        sess.hold_steps_left = 0
        sess.hold_started_at = nothing
        sess.hold_ends_at = nothing
        sess.pending_eval_action = -1
        sess.pending_eval_started_at = nothing
        sess.state = :IDLE
        return
    end

    remaining_ms = Dates.value(sess.hold_ends_at - now_dt)
    step_ms = settings.hold_step_sec * 1000
    sess.is_holding = true
    sess.hold_steps_left = max(0, cld(remaining_ms, step_ms))
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

function apply_chunk!(sess::Types.SessionContext, chunk::Types.SignalChunk, settings::Config.Settings)
    lock(sess.lock) do
        push!(sess.ring_buffer, chunk)
        sess.last_seen = now()
        _update_latest_features!(sess, chunk)

        if chunk.mode == Types.BATCH
            if !sess.is_holding
                sess.state = :BATCH_SYNCING
            end
        else
            refresh_hold_state!(sess, settings)
        end
    end
end

function maybe_detect_bio_trigger!(sess::Types.SessionContext, settings::Config.Settings)::Bool
    lock(sess.lock) do
        refresh_hold_state!(sess, settings)
        if sess.is_holding
            return false
        end
        if detect_bio_trigger(sess, settings.bio_stress_threshold)
            sess.last_bio_trigger_at = now()
            return true
        end
        return false
    end
end

function maybe_run_live_pipeline!(sess::Types.SessionContext, settings::Config.Settings, agent::RLService.RLAgentState)
    lock(sess.lock) do
        refresh_hold_state!(sess, settings)
        if !sess.is_holding
            return Dict("ok" => false, "reason" => "not_holding")
        end

        feats = encode_tcn_features(sess)
        for (k, v) in feats
            sess.latest_features[k] = v
        end

        reward = sess.last_reward
        prev_state_key = nothing
        prev_action = nothing

        if sess.pending_eval_action >= 0 && sess.pending_eval_started_at !== nothing
            reward = RLService.compute_reward(
                sess.pending_eval_baseline_hr,
                sess.pending_eval_baseline_hrv,
                get(feats, "tcn_hr", 0f0),
                get(feats, "tcn_hrv", 0f0),
            )
            sess.last_reward = reward
            prev_action = sess.pending_eval_action
            prev_state_key = haskey(sess.latest_features, "rl_state_key") ? string(sess.latest_features["rl_state_key"]) : nothing
        end

        trig = TDBridgeService.trigger_code(sess.last_trigger_type)
        rl = RLService.choose_action!(
            agent,
            feats,
            trig;
            prev_state_key = prev_state_key,
            prev_action = prev_action,
            reward = prev_state_key === nothing ? nothing : reward,
        )

        action = Int(rl["action"])
        score = Float32(rl["score"])
        state_key = String(rl["state_key"])

        sess.active_interaction = action
        sess.last_rl_action = action
        sess.last_rl_score = score
        sess.latest_features["rl_state_key_hash"] = Float32(length(state_key))
        sess.pending_eval_action = action
        sess.pending_eval_started_at = now()
        sess.pending_eval_baseline_hr = get(feats, "tcn_hr", 0f0)
        sess.pending_eval_baseline_hrv = get(feats, "tcn_hrv", 0f0)

        total_steps = max(1, cld(settings.event_stream_duration_sec, settings.hold_step_sec))
        hold_progress = clamp(1f0 - (sess.hold_steps_left / total_steps), 0f0, 1f0)

        td_payload = Dict{String, Any}(
            "ping" => 1,
            "hr" => get(feats, "tcn_hr", 0f0),
            "hrv" => get(feats, "tcn_hrv", 0f0),
            "br" => get(feats, "tcn_br", 0f0),
            "interaction" => action,
            "reward" => reward,
            "trigger" => trig,
            "holding" => sess.is_holding ? 1 : 0,
            "hold_steps" => sess.hold_steps_left,
            "hold_progress" => hold_progress,
        )

        td_ok = TDBridgeService.send_td_payload(settings, td_payload)

        return Dict(
            "ok" => true,
            "td_ok" => td_ok,
            "action" => action,
            "reward" => reward,
            "score" => score,
            "hold_steps_left" => sess.hold_steps_left,
        )
    end
end

end # module