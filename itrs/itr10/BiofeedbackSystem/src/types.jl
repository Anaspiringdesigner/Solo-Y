module Types

using Dates
using Base.Threads: ReentrantLock

export IngestMode, VitalsPoint, SignalChunk, SessionContext, SessionStatusDTO

@enum IngestMode::UInt8 begin
    BATCH = 1
    REALTIME = 2
end

struct VitalsPoint
    ts::DateTime
    hr::Float32
    hrv::Float32
    br::Float32
end

struct SignalChunk
    user_id::String
    device_id::String
    mode::IngestMode
    seq_no::Int
    schema_version::Int
    idempotency_key::String
    points::Vector{VitalsPoint}
end

mutable struct SessionContext
    user_id::String
    last_seen::DateTime
    state::Symbol
    ring_buffer::Vector{SignalChunk}
    latest_features::Dict{String, Float32}
    active_interaction::Int
    is_holding::Bool
    hold_steps_left::Int
    hold_started_at::Union{Nothing, DateTime}
    hold_ends_at::Union{Nothing, DateTime}
    last_rl_score::Float32
    last_rl_action::Int
    last_tcn_train_at::Union{Nothing, DateTime}
    last_bio_trigger_at::Union{Nothing, DateTime}
    last_trigger_type::String
    last_reward::Float32
    pending_eval_action::Int
    pending_eval_started_at::Union{Nothing, DateTime}
    pending_eval_baseline_hr::Float32
    pending_eval_baseline_hrv::Float32
    lock::ReentrantLock
end

SessionContext(user_id::String) = SessionContext(
    user_id,
    now(),
    :IDLE,
    SignalChunk[],
    Dict{String, Float32}(
        "avg_hr" => 0f0,
        "avg_hrv" => 0f0,
        "avg_br" => 0f0,
        "stress_score" => 0f0,
    ),
    0,
    false,
    0,
    nothing,
    nothing,
    0f0,
    0,
    nothing,
    nothing,
    "none",
    0f0,
    -1,
    nothing,
    0f0,
    0f0,
    ReentrantLock(),
)

Base.@kwdef struct SessionStatusDTO
    ok::Bool = true
    user_id::String
    state::Symbol
    active_interaction::Int
    is_holding::Bool
    hold_steps_left::Int
    avg_hr::Float32
    avg_hrv::Float32
    avg_br::Float32
    buffered_chunks::Int
    last_seen::String
end

end # module