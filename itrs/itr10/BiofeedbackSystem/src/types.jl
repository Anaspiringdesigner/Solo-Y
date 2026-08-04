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
    hrv::Vector{Float32}
    br::Vector{Float32}
    schema_version::Int
    idempotency_key::String
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
        "avg_br" => 0f0
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
    avg_hrv::Float32
    avg_br::Float32
    buffered_chunks::Int
    last_seen::String
end

end # module