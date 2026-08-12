module IngestService

using Dates
using Statistics
using Base.Threads: ReentrantLock
using ..Types
using ..Config
using ..FeatureService
using ..RLService
using ..TDBridgeService
using ..TriggerService

export process_batch!, process_realtime!, refresh_hold_state!, maybe_run_live_pipeline!, init_rl_runtime!

const _agent_ref = Ref{Union{Nothing, RLService.RLAgentState}}(nothing)
const _agent_lock = ReentrantLock()
const _last_save_ref = Ref{DateTime}(DateTime(1970,1,1))

function init_rl_runtime!(settings::Config.Settings)
    lock(_agent_lock) do
        if _agent_ref[] === nothing
            agent = RLService.init_agent(settings)
            RLService.load_agent!(agent, settings.rl_state_file)
            _agent_ref[] = agent
            _last_save_ref[] = now()
        end
    end
    return nothing
end

function _get_agent(settings::Config.Settings)
    if _agent_ref[] === nothing
        init_rl_runtime!(settings)
    end
    return _agent_ref[]::RLService.RLAgentState
end

function _autosave_if_due!(settings::Config.Settings)
    nowt = now()
    if Dates.value(nowt - _last_save_ref[]) >= settings.rl_autosave_sec * 1000
        lock(_agent_lock) do
            agent = _agent_ref[]
            if agent !== nothing
                RLService.save_agent!(agent, settings.rl_state_file)
                _last_save_ref[] = now()
            end
        end
    end
end

function refresh_hold_state!(sess::Types.SessionContext, settings::Config.Settings)
    if !sess.is_holding || sess.hold_ends_at === nothing
        return
    end
    if now() >= sess.hold_ends_at || sess.hold_steps_left <= 0
        sess.is_holding = false
        sess.hold_steps_left = 0
        sess.state = :IDLE
    end
end

function _update_features_from_points!(sess::Types.SessionContext, points::Vector{Types.VitalsPoint})
    isempty(points) && return
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
    local baseline_hr = 0f0
    local baseline_hrv = 0f0

    lock(sess.lock) do
        refresh_hold_state!(sess, settings)
        feats = copy(sess.latest_features)
        trig_type = sess.last_trigger_type
        prev_action = sess.pending_eval_action
        prev_state_key = isempty(sess.last_rl_state_key) ? nothing : sess.last_rl_state_key
        reward = sess.last_reward
        was_holding = sess.is_holding
        baseline_hr = sess.pending_eval_baseline_hr
        baseline_hrv = sess.pending_eval_baseline_hrv
    end

    if !was_holding
        return Dict("ok" => false, "reason" => "not_holding")
    end

    # Extract TCN features for richer state
    tcn = FeatureService.encode_tcn_features(sess)
    feats["tcn_hr"] = get(tcn, "tcn_hr", get(feats, "avg_hr", 0f0))
    feats["tcn_hrv"] = get(tcn, "tcn_hrv", get(feats, "avg_hrv", 0f0))
    feats["tcn_br"] = get(tcn, "tcn_br", get(feats, "avg_br", 0f0))
    feats["stress_score"] = get(tcn, "stress_score", get(feats, "stress_score", 0f0))

    # Compute reward based on improvement since the last action baseline
    if prev_action >= 0 && prev_state_key !== nothing
        curr_hr = get(feats, "tcn_hr", 0f0)
        curr_hrv = get(feats, "tcn_hrv", 0f0)
        reward = RLService.compute_reward(Float32(baseline_hr), Float32(baseline_hrv), curr_hr, curr_hrv)
        lock(sess.lock) do
            sess.last_reward = reward
        end
    end

    local action = -1
    local score = 0f0

    lock(sess.lock) do
        if sess.active_interaction >= 0 && sess.pending_eval_action >= 0
            action = sess.active_interaction
            score = sess.last_rl_score
        end
    end

    if action < 0
        trig = TDBridgeService.trigger_code(trig_type)
        agent = _get_agent(settings)

        rl = lock(_agent_lock) do
            RLService.choose_action!(
                agent,
                feats,
                trig;
                prev_state_key = prev_state_key,
                prev_action = prev_action,
                reward = (prev_state_key === nothing || prev_action < 0) ? nothing : reward,
            )
        end

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

    td_ok = TDBridgeService.send_td_payload(Dict(
        "ok" => true,
        "hr" => get(feats, "tcn_hr", 0f0),
        "hrv" => get(feats, "tcn_hrv", 0f0),
        "interaction" => action,
        "holding" => hold_steps_left > 0,
        "hold_steps_left" => hold_steps_left,
        "trigger_type" => trig_type,
        "score" => score,
    ), settings)

    _autosave_if_due!(settings)

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
    return Dict("ok" => true, "mode" => "realtime", "td_pipeline" => pipe)
end

end