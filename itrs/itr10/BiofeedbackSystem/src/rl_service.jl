module RLService

using Random
using JSON3
using Dates
using ..Config

export RLAgentState, init_agent, choose_action!, compute_reward, save_agent!, load_agent!

const ACTION_COUNT = 5

mutable struct RLAgentState
    q_table::Dict{String, Vector{Float32}}
    epsilon::Float32
    alpha::Float32
    gamma::Float32
    step::Int
    last_saved_at::DateTime
end

function init_agent(settings::Config.Settings)
    return RLAgentState(
        Dict{String, Vector{Float32}}(),
        settings.rl_epsilon,
        settings.rl_alpha,
        settings.rl_gamma,
        0,
        now(),
    )
end

function _state_key(features::Dict{String, Float32}, trigger_code::Int)
    stress_bin = Int(clamp(floor(get(features, "stress_score", 0f0) * 4f0), 0, 3))
    hr_bin = Int(clamp(floor(get(features, "tcn_hr", 0f0) / 20f0), 0, 12))
    hrv_bin = Int(clamp(floor(get(features, "tcn_hrv", 0f0) / 20f0), 0, 12))
    br_bin = Int(clamp(floor(get(features, "tcn_br", 0f0) / 5f0), 0, 12))
    return string(trigger_code, ":", stress_bin, ":", hr_bin, ":", hrv_bin, ":", br_bin)
end

function _ensure_state!(agent::RLAgentState, state_key::String)
    if !haskey(agent.q_table, state_key)
        agent.q_table[state_key] = zeros(Float32, ACTION_COUNT)
    end
    return agent.q_table[state_key]
end

function compute_reward(prev_hr::Float32, prev_hrv::Float32, curr_hr::Float32, curr_hrv::Float32)::Float32
    dh = (curr_hr - prev_hr) / max(prev_hr, 1f0)
    dhrv = (curr_hrv - prev_hrv) / max(prev_hrv, 1f0)
    reward = 0.8f0 * clamp(dhrv, -1f0, 1f0) - 0.2f0 * clamp(dh, -1f0, 1f0)
    return clamp(reward, -1f0, 1f0)
end

function choose_action!(agent::RLAgentState, features::Dict{String, Float32}, trigger_code::Int;
                        prev_state_key::Union{Nothing, String}=nothing,
                        prev_action::Union{Nothing, Int}=nothing,
                        reward::Union{Nothing, Float32}=nothing)
    state_key = _state_key(features, trigger_code)
    qvals = _ensure_state!(agent, state_key)

    if prev_state_key !== nothing && !isempty(prev_state_key) && prev_action !== nothing && reward !== nothing
        prev_q = _ensure_state!(agent, prev_state_key)
        target = reward + agent.gamma * maximum(qvals)
        prev_q[prev_action + 1] = prev_q[prev_action + 1] + agent.alpha * (target - prev_q[prev_action + 1])
    end

    action = if rand(Float32) < agent.epsilon
        rand(0:(ACTION_COUNT - 1))
    else
        argmax(qvals) - 1
    end

    score = maximum(qvals)
    agent.step += 1

    return Dict(
        "action" => action,
        "score" => score,
        "state_key" => state_key,
        "epsilon" => agent.epsilon,
    )
end

function save_agent!(agent::RLAgentState, path::String)::Bool
    try
        mkpath(dirname(path))
        serial_q = Dict{String, Vector{Float64}}()
        for (k, v) in agent.q_table
            serial_q[k] = Float64.(v)
        end
        payload = Dict(
            "epsilon" => Float64(agent.epsilon),
            "alpha" => Float64(agent.alpha),
            "gamma" => Float64(agent.gamma),
            "step" => agent.step,
            "saved_at" => string(now()),
            "q_table" => serial_q,
        )
        open(path, "w") do io
            write(io, JSON3.write(payload))
        end
        agent.last_saved_at = now()
        return true
    catch e
        println("[RL] save failed: $(string(e))")
        return false
    end
end

function load_agent!(agent::RLAgentState, path::String)::Bool
    if !isfile(path)
        return false
    end
    try
        txt = read(path, String)
        obj = JSON3.read(txt)

        qnew = Dict{String, Vector{Float32}}()
        qobj = haskey(obj, "q_table") ? obj["q_table"] : obj[:q_table]
        for (k, v) in pairs(qobj)
            qnew[string(k)] = Float32[Float32(x) for x in v]
        end

        agent.q_table = qnew
        agent.epsilon = Float32(haskey(obj, "epsilon") ? obj["epsilon"] : obj[:epsilon])
        agent.alpha = Float32(haskey(obj, "alpha") ? obj["alpha"] : obj[:alpha])
        agent.gamma = Float32(haskey(obj, "gamma") ? obj["gamma"] : obj[:gamma])
        agent.step = Int(haskey(obj, "step") ? obj["step"] : obj[:step])
        agent.last_saved_at = now()
        println("[RL] loaded state from $(path), states=$(length(agent.q_table)), step=$(agent.step)")
        return true
    catch e
        println("[RL] load failed: $(string(e))")
        return false
    end
end

end