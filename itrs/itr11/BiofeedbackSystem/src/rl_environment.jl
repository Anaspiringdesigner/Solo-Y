# ============================================================
# rl_environment.jl
# Biofeedback RL Environment
# - Trigger-based (not continuous)
# - 1 action per trigger
# - 3 min hold minimum
# - Reward = mean(0.8×ΔHRV − 0.2×ΔHR) over hold window
# ============================================================

module RLEnvironment

using ReinforcementLearning
using Random
using Statistics

# ── Constants ────────────────────────────────────────────────
const N_ACTIONS        = 5
const LATENT_DIM       = 32
const STATE_DIM        = 36

const STRESS_HRV_THRESH  = 0.65f0
const STRESS_HR_THRESH   = 1.20f0
const STRESS_CONSEC_WIN  = 12
const BASELINE_WINDOW_SIZE = 120

const W_HRV = 0.8f0
const W_HR  = 0.2f0

const HOLD_STEPS = 36

const TRIGGER_CALENDAR = 0
const TRIGGER_BIO      = 1
const TRIGGER_USER     = 2

# ── Trigger Struct ───────────────────────────────────────────
struct Trigger
    trigger_type :: Int
    timestamp    :: String
    avg_hr       :: Float32
    avg_hrv      :: Float32
    avg_br       :: Float32
    z            :: Vector{Float32}
end

# ── Reward Sample ────────────────────────────────────────────
struct RewardSample
    hr  :: Float32
    hrv :: Float32
end

# ── Environment Struct ───────────────────────────────────────
mutable struct BiofeedbackEnv <: AbstractEnv
    state           :: Vector{Float32}
    avg_hr          :: Float32
    avg_hrv         :: Float32
    avg_br          :: Float32
    trigger_type    :: Int
    prev_hr         :: Float32
    prev_hrv        :: Float32
    hold_counter    :: Int
    current_action  :: Int
    is_holding      :: Bool
    reward_samples  :: Vector{RewardSample}
    last_reward     :: Float32
    hr_history      :: Vector{Float32}
    hrv_history     :: Vector{Float32}
    baseline_hr     :: Float32
    baseline_hrv    :: Float32
    stress_counter  :: Int
    is_terminated   :: Bool
    total_steps     :: Int
    pending_trigger :: Union{Trigger, Nothing}
end

# ── Constructor ──────────────────────────────────────────────
function BiofeedbackEnv()
    BiofeedbackEnv(
        zeros(Float32, STATE_DIM),
        70.0f0,
        50.0f0,
        15.0f0,
        TRIGGER_BIO,
        70.0f0,
        50.0f0,
        0,
        0,
        false,
        RewardSample[],
        0.0f0,
        Float32[],
        Float32[],
        70.0f0,
        50.0f0,
        0,
        false,
        0,
        nothing
    )
end

# ── RLBase Interface ─────────────────────────────────────────
RLBase.state_space(env::BiofeedbackEnv) =
    Space(fill(-Inf32..Inf32, STATE_DIM))

RLBase.action_space(env::BiofeedbackEnv) =
    Base.OneTo(N_ACTIONS)

RLBase.state(env::BiofeedbackEnv) = env.state

RLBase.reward(env::BiofeedbackEnv) = env.last_reward

RLBase.is_terminated(env::BiofeedbackEnv) = env.is_terminated

function RLBase.reset!(env::BiofeedbackEnv)
    env.state           = zeros(Float32, STATE_DIM)
    env.is_terminated   = false
    env.last_reward     = 0.0f0
    env.hold_counter    = 0
    env.is_holding      = false
    env.reward_samples  = RewardSample[]
    env.pending_trigger = nothing
    env.stress_counter  = 0
    println("[ENV] Reset")
    return nothing
end

# ── State Builder ────────────────────────────────────────────
function build_state(z            :: Vector{Float32},
                     avg_hr       :: Float32,
                     avg_hrv      :: Float32,
                     avg_br       :: Float32,
                     trigger_type :: Int)::Vector{Float32}
    hr_norm      = (avg_hr  - 70.0f0) / 40.0f0
    hrv_norm     = (avg_hrv - 50.0f0) / 50.0f0
    br_norm      = (avg_br  - 15.0f0) / 10.0f0
    trigger_norm = Float32(trigger_type) / 2.0f0
    return vcat(z, [hr_norm, hrv_norm, br_norm, trigger_norm])
end

# ── Baseline Updater ─────────────────────────────────────────
function update_baseline!(env :: BiofeedbackEnv,
                           hr  :: Float32,
                           hrv :: Float32)
    currently_stressed = (
        length(env.hr_history) >= STRESS_CONSEC_WIN &&
        hrv < env.baseline_hrv * STRESS_HRV_THRESH  &&
        hr  > env.baseline_hr  * STRESS_HR_THRESH
    )

    if !currently_stressed
        push!(env.hr_history,  hr)
        push!(env.hrv_history, hrv)

        if length(env.hr_history) > BASELINE_WINDOW_SIZE
            popfirst!(env.hr_history)
            popfirst!(env.hrv_history)
        end

        if length(env.hr_history) >= 12
            env.baseline_hr  = sum(env.hr_history)  /
                                length(env.hr_history)
            env.baseline_hrv = sum(env.hrv_history) /
                                length(env.hrv_history)
        end
    else
        println("[BASELINE] Frozen — baseline preserved at " *
                "HR=$(round(env.baseline_hr, digits=1)) " *
                "HRV=$(round(env.baseline_hrv, digits=1))")
    end
end

# ── Stress Detector ──────────────────────────────────────────
function check_stress!(env :: BiofeedbackEnv,
                        hr  :: Float32,
                        hrv :: Float32)::Bool

    length(env.hr_history) < STRESS_CONSEC_WIN && return false

    hrv_stressed = hrv < env.baseline_hrv * STRESS_HRV_THRESH
    hr_stressed  = hr  > env.baseline_hr  * STRESS_HR_THRESH

    if hrv_stressed && hr_stressed
        env.stress_counter += 1
        println("[STRESS] Counter: $(env.stress_counter)/" *
                "$(STRESS_CONSEC_WIN) | " *
                "HR=$(round(hr, digits=1)) > " *
                "baseline $(round(env.baseline_hr * STRESS_HR_THRESH, digits=1)) | " *
                "HRV=$(round(hrv, digits=1)) < " *
                "baseline $(round(env.baseline_hrv * STRESS_HRV_THRESH, digits=1))")
    else
        if env.stress_counter > 0
            println("[STRESS] Counter reset at $(env.stress_counter)")
        end
        env.stress_counter = 0
    end

    if env.stress_counter >= STRESS_CONSEC_WIN
        env.stress_counter = 0
        println("[STRESS] ⚡ TRIGGER FIRED — sustained stress detected")
        return true
    end

    return false
end

# ── Reward Calculator ────────────────────────────────────────
function compute_hold_reward(samples::Vector{RewardSample})::Float32
    isempty(samples) && return 0.0f0

    rewards = Float32[]
    for i in 2:length(samples)
        prev = samples[i-1]
        curr = samples[i]

        Δhrv = clamp((curr.hrv - prev.hrv) /
                     (abs(prev.hrv) + 1f-6), -1f0, 1f0)
        Δhr  = clamp((curr.hr  - prev.hr)  /
                     (abs(prev.hr)  + 1f-6), -1f0, 1f0)

        r = W_HRV * Δhrv - W_HR * Δhr
        push!(rewards, clamp(r, -1f0, 1f0))
    end

    isempty(rewards) && return 0.0f0
    return sum(rewards) / length(rewards)
end

# ── Environment Step ─────────────────────────────────────────
function (env::BiofeedbackEnv)(action::Int)
    @assert 1 <= action <= N_ACTIONS "Invalid action: $action"

    action_idx         = action - 1
    env.current_action = action_idx
    env.is_holding     = true
    env.hold_counter   = HOLD_STEPS
    env.reward_samples = RewardSample[]

    push!(env.reward_samples,
          RewardSample(env.avg_hr, env.avg_hrv))

    println("[ENV] Action taken: $(action_idx) | " *
            "Hold for $(HOLD_STEPS) steps (3 min)")

    env.total_steps += 1
end

# ── Ingest New Data Window ────────────────────────────────────
function ingest_window!(env      :: BiofeedbackEnv,
                         z        :: Vector{Float32},
                         avg_hr   :: Float32,
                         avg_hrv  :: Float32,
                         avg_br   :: Float32,
                         end_time :: String)

    update_baseline!(env, avg_hr, avg_hrv)

    env.prev_hr  = env.avg_hr
    env.prev_hrv = env.avg_hrv
    env.avg_hr   = avg_hr
    env.avg_hrv  = avg_hrv
    env.avg_br   = avg_br

    if env.is_holding
        push!(env.reward_samples,
              RewardSample(avg_hr, avg_hrv))

        env.hold_counter -= 1
        println("[ENV] Hold: $(env.hold_counter)/" *
                "$(HOLD_STEPS) steps remaining")

        if env.hold_counter <= 0
            env.last_reward   = compute_hold_reward(env.reward_samples)
            env.is_holding    = false
            env.is_terminated = true

            println("[ENV] ✅ Hold complete | " *
                    "reward=$(round(env.last_reward, digits=4)) | " *
                    "action=$(env.current_action)")
        end
    end

    trigger_fired = false
    trigger       = nothing

    if !env.is_holding
        stressed = check_stress!(env, avg_hr, avg_hrv)
        if stressed
            trigger = Trigger(
                TRIGGER_BIO,
                end_time,
                avg_hr, avg_hrv, avg_br,
                z
            )
            env.state        = build_state(z, avg_hr, avg_hrv,
                                            avg_br, TRIGGER_BIO)
            env.trigger_type = TRIGGER_BIO
            trigger_fired    = true
        end
    end

    return trigger_fired, trigger
end

# ── External Trigger ─────────────────────────────────────────
function fire_external_trigger!(env          :: BiofeedbackEnv,
                                 z            :: Vector{Float32},
                                 avg_hr       :: Float32,
                                 avg_hrv      :: Float32,
                                 avg_br       :: Float32,
                                 trigger_type :: Int,
                                 end_time     :: String)
    if env.is_holding
        println("[ENV] Trigger ignored — hold in progress " *
                "($(env.hold_counter) steps remaining)")
        return false
    end

    env.state         = build_state(z, avg_hr, avg_hrv,
                                     avg_br, trigger_type)
    env.trigger_type  = trigger_type
    env.avg_hr        = avg_hr
    env.avg_hrv       = avg_hrv
    env.avg_br        = avg_br
    env.is_terminated = false

    println("[ENV] ⚡ External trigger: type=$(trigger_type) | " *
            "HR=$(round(avg_hr, digits=1)) " *
            "HRV=$(round(avg_hrv, digits=1))")
    return true
end

end # module RLEnvironment