module TriggerService

using Dates
using ..Types

export trigger_types, apply_trigger!, refresh_hold_state!, hold_progress

const trigger_types = Set(["manual", "calendar", "bio", "system"])

function refresh_hold_state!(sess::Types.SessionContext)
    now_dt = now()

    if sess.hold_ends_at === nothing
        sess.is_holding = false
        sess.hold_steps_left = 0
        if sess.state == :EVENT_STREAMING
            sess.state = :IDLE
        end
        return nothing
    end

    remaining_ms = Dates.value(sess.hold_ends_at - now_dt)
    if remaining_ms <= 0
        sess.is_holding = false
        sess.hold_steps_left = 0
        sess.hold_started_at = nothing
        sess.hold_ends_at = nothing
        sess.state = :IDLE
        return nothing
    end

    sess.is_holding = true
    remaining_sec = cld(remaining_ms, 1000)
    sess.hold_steps_left = max(0, cld(remaining_sec, 5))
    sess.state = :EVENT_STREAMING
    return nothing
end

function hold_progress(sess::Types.SessionContext)::Float32
    if sess.hold_started_at === nothing || sess.hold_ends_at === nothing
        return 0f0
    end

    total_ms = Dates.value(sess.hold_ends_at - sess.hold_started_at)
    total_ms <= 0 && return 0f0

    elapsed_ms = Dates.value(now() - sess.hold_started_at)
    p = clamp(elapsed_ms / total_ms, 0.0, 1.0)
    return Float32(p)
end

function apply_trigger!(sess::Types.SessionContext, trigger_type::String, stream_duration_sec::Int)
    trigger_type ∉ trigger_types && error("invalid_trigger_type")

    lock(sess.lock) do
        now_dt = now()
        sess.last_seen = now_dt
        sess.state = :EVENT_STREAMING
        sess.is_holding = true
        sess.hold_started_at = now_dt
        sess.hold_ends_at = now_dt + Second(stream_duration_sec)
        sess.hold_steps_left = max(1, cld(stream_duration_sec, 5))
        sess.last_trigger_type = trigger_type

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