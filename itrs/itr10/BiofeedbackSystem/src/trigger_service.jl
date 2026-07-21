module TriggerService

using Dates
using ..Types

export trigger_types, apply_trigger!

const trigger_types = Set(["manual", "calendar", "bio", "system"])

function apply_trigger!(sess::Types.SessionContext, trigger_type::String, stream_duration_sec::Int)
    trigger_type ∉ trigger_types && error("invalid_trigger_type")

    lock(sess.lock) do
        sess.last_seen = now()
        sess.state = :EVENT_STREAMING
        sess.is_holding = true
        # if your hold step size is 5s, convert duration to steps
        sess.hold_steps_left = max(1, stream_duration_sec ÷ 5)

        # placeholder: actual RL action selection later
        # keep current interaction if already active, otherwise default 0
        sess.active_interaction = sess.active_interaction

        return Dict(
            "ok" => true,
            "state" => String(sess.state),
            "trigger_type" => trigger_type,
            "stream_now" => true,
            "stream_duration_sec" => stream_duration_sec,
            "hold_steps_left" => sess.hold_steps_left,
            "active_interaction" => sess.active_interaction
        )
    end
end

end # module