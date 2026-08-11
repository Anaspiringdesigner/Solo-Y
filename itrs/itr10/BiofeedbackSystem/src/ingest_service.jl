module IngestService

using Dates
using Statistics
using ..Types
using ..Config
using ..FeatureService
using ..RLService
using ..TDBridgeService
using ..TriggerService

export process_batch!, process_realtime!, refresh_hold_state!, maybe_run_live_pipeline!

function refresh_hold_state!(sess::Types.SessionContext, settings::Config.Settings)
    if !sess.is_holding
        return
    end
    if sess.hold_ends_at === nothing
        return
    end
    if now() >= sess.hold_ends_at || sess.hold_steps_left <= 0
        sess.is_holding = false
        sess.hold_steps_left = 0
        sess.state = :IDLE
    end
end

function _update_features_from_points!(sess::Types.SessionContext, points::Vector{Types.VitalsPoint})
    if isempty(points)
        return
    end

    hrs = Float32[p.hr for p in points]
    hrvs = Float32[p.hrv for p in points]
    brs = Float32[p.br for p in points]

    sess.latest_features["avg_hr"] = mean(hrs)
    sess.latest_features["avg_hrv"] = mean(hrvs)
    sess.latest_features["avg_br"] = mean(brs)
    sess.latest_features["stress_score"] = max(0f0, min(1f0, (sess.latest_features["avg_hr"] - 60f0) / 60f0))
end

function process_batch!(sess::Types.SessionContext, chunk::Types.SignalChunk, settings::Config.Settings)
    lock(sess.lock) do
        push!(sess.ring_buffer, chunk)
        _update_features_from_points!(sess, chunk.points)
        sess.last_seen = now()
    end
    return Dict("ok" => true, "mode" => "batch")
end

function maybe_run_live_pipeline!(sess::Types.SessionContext, settings::Config.Settings)::Dict{String, Any}
    local feats = Dict{String, Float32}()
    local trig_type = "none"
    local prev_action = -1
    local prev_state_key = nothing
    local reward = 0f0
    local was_holding = false

    lock(sess.lock) do
        refresh_hold_state!(sess, settings)
        feats = copy(sess.latest_features)
        trig_type = sess.last_trigger_type
        prev_action = sess.pending_eval_action
        prev_state_key = isempty(sess.last_rl_state_key) ? nothing : sess.last_rl_state_key
        reward = sess.last_reward
        was_holding = sess.is_holding
    end

    if !was_holding
        return Dict("ok" => false, "reason" => "not_holding")
    end

    # TCN-like features from FeatureService
    tcn = FeatureService.encode_tcn_features(sess)
    feats["tcn_hr"] = get(tcn, "tcn_hr", get(feats, "avg_hr", 0f0))
    feats["tcn_hrv"] = get(tcn, "tcn_hrv", get(feats, "avg_hrv", 0f0))
    feats["tcn_br"] = get(tcn, "tcn_br", get(feats, "avg_br", 0f0))
    feats["stress_score"] = get(tcn, "stress_score", get(feats, "stress_score", 0f0))

    # Hold RL action steady during active hold
    local action = -1
    local score = 0f0
    local state_key = ""

    lock(sess.lock) do
        if sess.active_interaction >= 0 && sess.pending_eval_action >= 0
            action = sess.active_interaction
            score = sess.last_rl_score
            state_key = sess.last_rl_state_key
        end
    end

    if action < 0
        trig = TDBridgeService.trigger_code(trig_type)

        # NOTE: RLService in your project expects an agent.
        # If you have a shared agent elsewhere, wire it in.
        # For now, create a lightweight one per call (works functionally).
        agent = RLService.init_agent(settings)

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

        lock(sess.lock) do
            sess.active_interaction = action
            sess.last_rl_action = action
            sess.last_rl_score = score
            sess.last_rl_state_key = state_key
            sess.pending_eval_action = action
            sess.pending_eval_started_at = now()
            sess.pending_eval_baseline_hr = get(feats, "tcn_hr", 0f0)
            sess.pending_eval_baseline_hrv = get(feats, "tcn_hrv", 0f0)
        end
    end

    local hold_steps_left = 0
    lock(sess.lock) do
        if sess.hold_steps_left > 0
            sess.hold_steps_left -= 1
        end
        refresh_hold_state!(sess, settings)
        hold_steps_left = sess.hold_steps_left
    end

    td_payload = Dict(
        "ok" => true,
        "hr" => get(feats, "tcn_hr", 0f0),
        "hrv" => get(feats, "tcn_hrv", 0f0),
        "interaction" => action,
        "holding" => hold_steps_left > 0,
        "hold_steps_left" => hold_steps_left,
        "trigger_type" => trig_type,
        "score" => score,
    )

    td_ok = TDBridgeService.send_td_payload(td_payload, settings)

    return Dict(
        "ok" => true,
        "interaction" => action,
        "score" => score,
        "holding" => hold_steps_left > 0,
        "hold_steps_left" => hold_steps_left,
        "td_ok" => td_ok,
    )
end

function process_realtime!(sess::Types.SessionContext, chunk::Types.SignalChunk, settings::Config.Settings)
    lock(sess.lock) do
        push!(sess.ring_buffer, chunk)
        _update_features_from_points!(sess, chunk.points)
        sess.last_seen = now()
    end

    _ = TriggerService.maybe_auto_trigger_bio!(sess, settings)
    pipe = maybe_run_live_pipeline!(sess, settings)

    return Dict(
        "ok" => true,
        "mode" => "realtime",
        "td_pipeline" => pipe,
    )
end

end # module