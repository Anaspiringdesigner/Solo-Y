module TriggerService

using Dates
using ..Types
using ..Config
using ..IngestService
using ..TDBridgeService
using ..ModelBridgeService
using ..RLService

export apply_trigger!, maybe_auto_trigger_bio!, start_trigger_pulse_task!

const _pulse_tasks = Dict{String, Task}()

function _compute_hold_steps(settings::Config.Settings, stream_duration_sec::Int)
    step = max(1, settings.rl_step_sec)
    return max(1, cld(stream_duration_sec, step))
end

function apply_trigger!(
    sess::Types.SessionContext,
    trigger_type::String,
    settings::Config.Settings;
    stream_duration_sec::Union{Nothing, Int}=nothing
)::Dict{String, Any}
    now_dt = now()

    lock(sess.lock) do
        IngestService.refresh_hold_state!(sess, settings)

        if sess.is_holding
            return Dict(
                "ok" => true,
                "already_in_progress" => true,
                "state" => String(sess.state),
                "trigger_type" => sess.last_trigger_type,
                "hold_steps_left" => sess.hold_steps_left,
                "is_holding" => true,
                "active_interaction" => sess.active_interaction,
            )
        end

        dsec = stream_duration_sec === nothing ? settings.event_stream_duration_sec : stream_duration_sec
        hold_steps = _compute_hold_steps(settings, dsec)

        sess.state = :HOLDING
        sess.is_holding = true
        sess.hold_steps_left = hold_steps
        sess.hold_started_at = now_dt
        sess.hold_ends_at = now_dt + Second(dsec)

        # reset RL selection for new hold; first realtime step picks once and holds
        sess.active_interaction = -1
        sess.last_rl_action = -1
        sess.last_rl_score = 0f0
        sess.last_rl_state_key = ""
        sess.pending_eval_action = -1
        sess.pending_eval_started_at = nothing
        sess.pending_eval_baseline_hr = 0f0
        sess.pending_eval_baseline_hrv = 0f0

        sess.last_trigger_type = trigger_type
        sess.last_bio_trigger_at = trigger_type == "bio" ? now_dt : sess.last_bio_trigger_at
    end

    return Dict(
        "ok" => true,
        "trigger_type" => trigger_type,
        "state" => "HOLDING",
        "stream_duration_sec" => stream_duration_sec === nothing ? settings.event_stream_duration_sec : stream_duration_sec,
    )
end

function maybe_auto_trigger_bio!(
    sess::Types.SessionContext,
    settings::Config.Settings
)::Bool
    lock(sess.lock) do
        IngestService.refresh_hold_state!(sess, settings)
        if sess.is_holding
            return false
        end

        stress = get(sess.latest_features, "stress_score", 0f0)
        if stress < settings.bio_trigger_stress_threshold
            return false
        end

        if sess.last_bio_trigger_at !== nothing
            elapsed = Dates.value(now() - sess.last_bio_trigger_at) ÷ 1000
            if elapsed < settings.bio_trigger_cooldown_sec
                return false
            end
        end
    end

    _ = apply_trigger!(sess, "bio", settings)
    return true
end

function _pulse_key(sess::Types.SessionContext)
    return sess.user_id
end

function start_trigger_pulse_task!(sess::Types.SessionContext, settings::Config.Settings)
    key = _pulse_key(sess)
    if haskey(_pulse_tasks, key)
        t = _pulse_tasks[key]
        if !istaskdone(t)
            return
        end
    end

    t = @async begin
        try
            while true
                sleep(1.0)
                local should_continue = false
                local features = Dict{String, Float32}()
                local action = 0
                local score = 0f0
                local hold_steps_left = 0

                lock(sess.lock) do
                    IngestService.refresh_hold_state!(sess, settings)
                    should_continue = sess.is_holding
                    if should_continue
                        features = copy(sess.latest_features)
                        action = sess.active_interaction
                        score = sess.last_rl_score
                        hold_steps_left = sess.hold_steps_left
                    end
                end

                if !should_continue
                    break
                end

                if action < 0
                    # no action chosen yet; wait for first realtime ingest
                    continue
                end

                td_payload = Dict(
                    "ok" => true,
                    "hr" => get(features, "tcn_hr", get(features, "avg_hr", 0f0)),
                    "hrv" => get(features, "tcn_hrv", get(features, "avg_hrv", 0f0)),
                    "interaction" => action,
                    "holding" => true,
                    "hold_steps_left" => hold_steps_left,
                    "trigger_type" => sess.last_trigger_type,
                    "score" => score,
                )
                try
                    TDBridgeService.send_td_payload(td_payload, settings)
                catch e
                    println("[TRIGGER_PULSE] TD send failed: $(string(e))")
                end
            end
        finally
            pop!(_pulse_tasks, key, nothing)
        end
    end

    _pulse_tasks[key] = t
    return nothing
end

end # module