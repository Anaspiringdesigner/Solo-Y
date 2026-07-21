module Types

using Dates
using Base.Threads: ReentrantLock

export IngestMode, SignalChunk, SessionContext, SessionStatusDTO

@enum IngestMode::UInt8 begin
    BATCH = 1
    REALTIME = 2
end

struct SignalChunk
    user_id::String
    device_id::String
    mode::IngestMode
    start_ts::DateTime
    end_ts::DateTime
    seq_no::Int
    sample_rate_hz::Float32
    hr::Vector{Float32}
    spo2::Vector{Float32}
    ppg::Vector{Float32}
    accel_x::Vector{Float32}
    accel_y::Vector{Float32}
    accel_z::Vector{Float32}
    schema_version::Int
    idempotency_key::String
end

mutable struct SessionContext
    user_id::String
    last_seen::DateTime
    state::Symbol                      # :IDLE, :BATCH_SYNCING, :EVENT_STREAMING, etc.
    ring_buffer::Vector{SignalChunk}
    latest_features::Dict{String, Float32}
    active_interaction::Int
    is_holding::Bool
    hold_steps_left::Int
    lock::ReentrantLock
end

SessionContext(user_id::String) = SessionContext(
    user_id,
    now(),
    :IDLE,
    SignalChunk[],
    Dict{String, Float32}(
        "avg_hr" => 0f0,
        "avg_spo2" => 0f0,
        "avg_ppg" => 0f0
    ),
    0,
    false,
    0,
    ReentrantLock()
)

Base.@kwdef struct SessionStatusDTO
    ok::Bool = true
    user_id::String
    state::Symbol
    active_interaction::Int
    is_holding::Bool
    hold_steps_left::Int
    avg_hr::Float32
    avg_spo2::Float32
    avg_ppg::Float32
    buffered_chunks::Int
    last_seen::String
end

end # module