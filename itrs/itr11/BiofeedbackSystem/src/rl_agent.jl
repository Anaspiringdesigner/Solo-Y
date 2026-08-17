# ============================================================
# rl_agent.jl
# DQN RL Agent
# PHASE 4B:
# - Expand action space from 5 TD visuals to 40 joint actions.
# - Joint action = (visual_id, dashboard_id)
# - N_ACTIONS = 5 * 8 = 40
# - Keep agent generic: it now returns an encoded joint action.
# - Main/backend will decode it and treat executed encoded action as authoritative.
#
# NOTE:
# - Old 5-action checkpoints are not compatible with this version.
# - This file detects incompatible checkpoints and starts fresh if needed.
# ============================================================

module RLAgent

using Flux
using Flux: Chain, Dense, relu
using Flux.Optimise: Adam, update!
using Random
using Statistics
using BSON: @save, @load
using Dates
import ..TDBridge

const STATE_DIM     = 36
const RL_VISUALS    = 5
const MAX_DASHBOARDS = 8
const N_ACTIONS     = RL_VISUALS * MAX_DASHBOARDS
const GAMMA         = 0.99f0
const LR            = 1f-3
const BATCH_SIZE    = 32
const REPLAY_SIZE   = 10_000
const MIN_REPLAY    = 128
const TARGET_UPDATE = 10
const EPSILON_START = 1.0f0
const EPSILON_MIN   = 0.05f0
const EPSILON_DECAY = 0.995f0

const RUN_DIR      = "rl_runs"
const CKPT_PATH    = joinpath(RUN_DIR, "dqn_ckpt.bson")
const TARGET_CKPT  = joinpath(RUN_DIR, "dqn_target.bson")
const META_PATH    = joinpath(RUN_DIR, "dqn_meta.bson")
const BEST_CKPT    = joinpath(RUN_DIR, "dqn_best.bson")
const LOG_PATH     = joinpath(RUN_DIR, "rl_log.csv")
const STATE_PATH   = joinpath(RUN_DIR, "dqn_runtime_state.bson")

const BEST_EMA_ALPHA = 0.1f0
const BEST_MIN_STEPS = 20

const ACTION_NAMES = Dict(
    0 => "Ray Casting",
    1 => "Noise Crumpling",
    2 => "Noise in Circle",
    3 => "Video Ripples",
    4 => "Flowery Noise",
)

struct Transition
    state      :: Vector{Float32}
    action     :: Int
    reward     :: Float32
    next_state :: Vector{Float32}
    done       :: Float32
end

mutable struct ReplayBuffer
    buffer   :: Vector{Transition}
    capacity :: Int
    position :: Int
    size     :: Int
end

function ReplayBuffer(capacity::Int)
    ReplayBuffer(
        Vector{Transition}(undef, capacity),
        capacity, 1, 0
    )
end

function push_transition!(buf::ReplayBuffer, t::Transition)
    buf.buffer[buf.position] = t
    buf.position = mod1(buf.position + 1, buf.capacity)
    buf.size     = min(buf.size + 1, buf.capacity)
end

function sample_batch(buf::ReplayBuffer, n::Int)::Vector{Transition}
    idx = randperm(buf.size)[1:n]
    return buf.buffer[idx]
end

function build_q_network()
    Chain(
        Dense(STATE_DIM => 128, relu),
        Dense(128       => 128, relu),
        Dense(128       => N_ACTIONS),
    )
end

mutable struct DQNAgent
    q_net             :: Chain
    target_net        :: Chain
    optimizer         :: Adam
    replay            :: ReplayBuffer
    epsilon           :: Float32
    step              :: Int
    ema_reward        :: Float32
    best_ema          :: Float32
    cumulative_reward :: Float32
    prev_state        :: Union{Vector{Float32}, Nothing}
    prev_action       :: Union{Int, Nothing}
end

function DQNAgent()
    q   = build_q_network()
    tgt = build_q_network()
    Flux.loadmodel!(tgt, Flux.state(q))
    DQNAgent(
        q, tgt,
        Adam(LR),
        ReplayBuffer(REPLAY_SIZE),
        EPSILON_START,
        0,
        0.0f0,
        -1f10,
        0.0f0,
        nothing,
        nothing,
    )
end

function q_values(net::Chain, state::Vector{Float32})::Vector{Float32}
    x = reshape(state, :, 1)
    return vec(net(x))
end

function select_action(agent::DQNAgent, state::Vector{Float32})::Tuple{Int, String}
    if rand(Float32) < agent.epsilon
        return rand(0:(N_ACTIONS-1)), "explore"
    else
        qvals  = q_values(agent.q_net, state)
        action = argmax(qvals) - 1
        return action, "exploit"
    end
end

function train_step!(agent::DQNAgent)
    agent.replay.size < MIN_REPLAY && return false

    batch = sample_batch(agent.replay, BATCH_SIZE)

    states      = hcat([t.state      for t in batch]...)
    actions     = [t.action          for t in batch]
    rewards     = [t.reward          for t in batch]
    next_states = hcat([t.next_state for t in batch]...)
    dones       = [t.done            for t in batch]

    q_next    = agent.target_net(next_states)
    max_next  = vec(maximum(q_next, dims=1))
    targets_v = rewards .+ (1f0 .- dones) .* GAMMA .* max_next

    loss, gs = Flux.withgradient(agent.q_net) do net
        q_curr  = net(states)
        q_taken = [q_curr[actions[i]+1, i] for i in 1:BATCH_SIZE]
        Flux.mse(q_taken, targets_v)
    end

    update!(agent.optimizer, agent.q_net, gs[1])
    agent.epsilon = max(EPSILON_MIN, agent.epsilon * EPSILON_DECAY)
    return true
end

function sync_target!(agent::DQNAgent)
    Flux.loadmodel!(agent.target_net, Flux.state(agent.q_net))
    println("[DQN] Target synced @ step=$(agent.step)")
end

function save_runtime_state(agent::DQNAgent)
    mkpath(RUN_DIR)

    replay_state = Dict(
        "capacity" => agent.replay.capacity,
        "position" => agent.replay.position,
        "size"     => agent.replay.size,
        "buffer"   => copy(agent.replay.buffer),
    )

    runtime = Dict(
        "prev_state"  => agent.prev_state,
        "prev_action" => agent.prev_action,
        "replay"      => replay_state,
    )

    @save STATE_PATH runtime
    println("[CKPT] Runtime state saved | replay=$(agent.replay.size)")
end

function load_runtime_state!(agent::DQNAgent)
    isfile(STATE_PATH) || return false

    @load STATE_PATH runtime

    replay_state = runtime["replay"]
    capacity     = replay_state["capacity"]

    agent.replay = ReplayBuffer(capacity)
    raw_buffer = replay_state["buffer"]
    @assert length(raw_buffer) == capacity "Replay buffer length mismatch"
    agent.replay.buffer   = raw_buffer
    agent.replay.position = replay_state["position"]
    agent.replay.size     = replay_state["size"]

    agent.prev_state  = runtime["prev_state"]
    agent.prev_action = runtime["prev_action"]

    # If previous action ids are from old incompatible checkpoints, drop them.
    if agent.prev_action !== nothing && !(0 <= agent.prev_action < N_ACTIONS)
        agent.prev_action = nothing
        agent.prev_state = nothing
    end

    println("[CKPT] Runtime state loaded | replay=$(agent.replay.size)")
    return true
end

function save_checkpoint(agent::DQNAgent)
    mkpath(RUN_DIR)

    q_net      = agent.q_net
    target_net = agent.target_net

    meta = Dict(
        "step"              => agent.step,
        "epsilon"           => agent.epsilon,
        "ema_reward"        => agent.ema_reward,
        "best_ema"          => agent.best_ema,
        "cumulative_reward" => agent.cumulative_reward,
        "n_actions"         => N_ACTIONS,
    )

    @save CKPT_PATH   q_net
    @save TARGET_CKPT target_net
    @save META_PATH   meta

    save_runtime_state(agent)

    println("[CKPT] Saved @ step=$(agent.step) ε=$(round(agent.epsilon, digits=3)) ema=$(round(agent.ema_reward, digits=4)) cum=$(round(agent.cumulative_reward, digits=4))")
end

function checkpoint_compatible()::Bool
    if !(isfile(CKPT_PATH) && isfile(TARGET_CKPT) && isfile(META_PATH))
        return false
    end
    try
        @load META_PATH meta
        saved_n_actions = get(meta, "n_actions", 5)
        return saved_n_actions == N_ACTIONS
    catch
        return false
    end
end

function load_checkpoint!(agent::DQNAgent)
    if checkpoint_compatible()
        @load CKPT_PATH   q_net
        @load TARGET_CKPT target_net
        @load META_PATH   meta

        Flux.loadmodel!(agent.q_net, Flux.state(q_net))
        Flux.loadmodel!(agent.target_net, Flux.state(target_net))

        agent.step              = meta["step"]
        agent.epsilon           = meta["epsilon"]
        agent.ema_reward        = meta["ema_reward"]
        agent.best_ema          = meta["best_ema"]
        agent.cumulative_reward = get(meta, "cumulative_reward", 0.0f0)

        println("[CKPT] Loaded compatible checkpoint | step=$(agent.step) ε=$(round(agent.epsilon, digits=3)) cum=$(round(agent.cumulative_reward, digits=4))")
        load_runtime_state!(agent)
        return true
    end

    println("[CKPT] No compatible checkpoint for N_ACTIONS=$(N_ACTIONS) — starting fresh")
    return false
end

function maybe_save_best!(agent::DQNAgent)
    agent.step < BEST_MIN_STEPS && return
    if agent.ema_reward > agent.best_ema
        agent.best_ema = agent.ema_reward
        q_net = agent.q_net
        @save BEST_CKPT q_net
        println("[BEST] New best EMA=$(round(agent.best_ema, digits=4)) @ step=$(agent.step)")
    end
end

function init_log()
    mkpath(RUN_DIR)
    isfile(LOG_PATH) && return
    open(LOG_PATH, "w") do f
        write(f, "timestamp,step,mode,action,visual_id,dashboard_id,epsilon,reward,cumulative_reward,ema_reward,avg_hr,avg_hrv,avg_br,trigger_type,replay_size,trained\n")
    end
end

function log_step(agent        :: DQNAgent,
                  mode         :: String,
                  action       :: Int,
                  visual_id    :: Int,
                  dashboard_id :: Int,
                  reward       :: Float32,
                  avg_hr       :: Float32,
                  avg_hrv      :: Float32,
                  avg_br       :: Float32,
                  trigger_type :: Int,
                  trained      :: Bool)
    open(LOG_PATH, "a") do f
        write(f,
            "$(now())," *
            "$(agent.step)," *
            "$(mode)," *
            "$(action)," *
            "$(visual_id)," *
            "$(dashboard_id)," *
            "$(round(agent.epsilon, digits=6))," *
            "$(round(reward, digits=6))," *
            "$(round(agent.cumulative_reward, digits=6))," *
            "$(round(agent.ema_reward, digits=6))," *
            "$(round(avg_hr, digits=3))," *
            "$(round(avg_hrv, digits=3))," *
            "$(round(avg_br, digits=3))," *
            "$(trigger_type)," *
            "$(agent.replay.size)," *
            "$(Int(trained))\n"
        )
    end
end

function agent_step!(agent        :: DQNAgent,
                     state        :: Vector{Float32},
                     reward       :: Float32,
                     avg_hr       :: Float32,
                     avg_hrv      :: Float32,
                     avg_br       :: Float32,
                     trigger_type :: Int;
                     is_holding   :: Bool = false,
                     hold_steps   :: Int  = 0)::Int

    if agent.prev_state !== nothing && agent.prev_action !== nothing
        push_transition!(agent.replay, Transition(
            agent.prev_state,
            agent.prev_action,
            reward,
            state,
            0.0f0,
        ))
    end

    agent.cumulative_reward += reward
    agent.ema_reward = (1f0 - BEST_EMA_ALPHA) * agent.ema_reward + BEST_EMA_ALPHA * reward

    action, mode = select_action(agent, state)
    trained = train_step!(agent)

    if agent.step % TARGET_UPDATE == 0
        sync_target!(agent)
    end

    # Decode for logging / TD preview purposes only.
    visual_id    = action ÷ MAX_DASHBOARDS
    dashboard_id = action % MAX_DASHBOARDS

    # IMPORTANT:
    # In Phase 4B, the agent returns an encoded joint action.
    # We only send the visual component to TD.
    TDBridge.send_action(
        visual_id,
        avg_hr,
        avg_hrv,
        avg_br,
        reward,
        agent.cumulative_reward,
        trigger_type,
        is_holding,
        hold_steps
    )

    maybe_save_best!(agent)

    if agent.step > 0 && agent.step % 50 == 0
        save_checkpoint(agent)
    end

    log_step(agent, mode, action, visual_id, dashboard_id, reward,
             avg_hr, avg_hrv, avg_br, trigger_type, trained)

    println("[DQN] step=$(agent.step) | mode=$(mode) | encoded_action=$(action) | visual=$(visual_id) dashboard=$(dashboard_id) | ε=$(round(agent.epsilon, digits=3)) | r=$(round(reward, digits=4)) | cum=$(round(agent.cumulative_reward, digits=4)) | ema=$(round(agent.ema_reward, digits=4)) | replay=$(agent.replay.size) | trained=$(trained)")

    agent.prev_state  = state
    agent.prev_action = action
    agent.step       += 1

    return action
end

function init_agent(; load_ckpt::Bool=true)::DQNAgent
    mkpath(RUN_DIR)
    init_log()
    agent = DQNAgent()
    if load_ckpt
        load_checkpoint!(agent)
    end
    println("[DQN] Agent ready | state_dim=$(STATE_DIM) | n_actions=$(N_ACTIONS) | ε=$(agent.epsilon) | cum=$(round(agent.cumulative_reward, digits=4))")
    return agent
end

end # module RLAgent