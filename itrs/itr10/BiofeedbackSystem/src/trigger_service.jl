module TriggerService

using Dates
using ..Types
using ..Config

export trigger_types, apply_trigger!

const trigger_types = Set(["manual", "calendar", "bio", "system"])

function apply_trigger!(sess::Types.SessionContext, trigger_type::String, stream_duration_sec::Int, settings::Config.Settings)
    trigger_type ∉ trigger_types && error("invalid_trigger_type")

    lock(sess.lock) do
        now_dt = now()
        sess.last_seen = now_dt
        sess.state = :EVENT_STREAMING
        sess.is_holding = true
        sess.hold_started_at = now_dt
        sess.hold_ends_at = now_dt + Second(stream_duration_sec)
        sess.hold_steps_left = max(1, cld(stream_duration_sec, settings.hold_step_sec))
        sess.last_trigger_type = trigger_type
        sess.pending_eval_action = -1
        sess.pending_eval_started_at = nothing

        return Dict(
            "ok" => true,
            "state" => String(sess.state),
            "trigger_type" => trigger_type,
            "stream_now" => true,
            "stream_duration_sec" => stream_duration_sec,
            "hold_steps_left" => sess.hold_steps_left,
            "active_interaction" => sess.active_interaction,
        )
    end
end

end # module