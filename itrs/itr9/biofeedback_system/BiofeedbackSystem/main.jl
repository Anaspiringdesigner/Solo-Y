# ============================================================
# main.jl
# Biofeedback System — Full Pipeline
#
# Flow:
# 1. Data Streamer polls ADB every 5s
# 2. New windows → TCN Encoder → z(t)
# 3. z(t) → RL Environment (stress detection)
# 4. On trigger → RL Agent selects interaction
# 5. Action → TouchDesigner via TDBridge (OSC)
# 6. Hold 3 min → compute reward → train DQN
# ============================================================

include("src/data_streamer.jl")
include("src/tcn_encoder.jl")
include("src/rl_environment.jl")
include("src/td_bridge.jl")
include("src/rl_agent.jl")

using .DataStreamer
using .TCNEncoder
using .RLEnvironment
using .TDBridge
using .RLAgent
using HTTP
using JSON3
using Sockets
using Dates

# ── Config ───────────────────────────────────────────────────
const BRAIN_PORT = 8000

# ── AppState ─────────────────────────────────────────────────
mutable struct AppState
    avg_hr             :: Float32
    avg_hrv            :: Float32
    avg_br             :: Float32
    active_interaction :: Int
    last_reward        :: Float32
    is_holding         :: Bool
    hold_steps_left    :: Int
end

AppState() = AppState(0f0, 0f0, 0f0, 0, 0f0, false, 0)

const APP_STATE = AppState()

# ── Global Instances ─────────────────────────────────────────
const ENV_INSTANCE   = Ref{RLEnvironment.BiofeedbackEnv}(
                           RLEnvironment.BiofeedbackEnv())
const AGENT_INSTANCE = Ref{RLAgent.DQNAgent}(
                           RLAgent.DQNAgent())

# ── HTTP Handlers ─────────────────────────────────────────────

function handle_ingest(req::HTTP.Request)
    try
        payload  = JSON3.read(req.body)
        windows  = payload["windows"]
        ingested = 0

        for w in windows
            hr  = Float32.(w["hr"])
            hrv = Float32.(w["hrv"])
            br  = Float32.(w["br"])

            result = TCNEncoder.encode_window(
                hr, hrv, br,
                Float32(w["avg_hr"]),
                Float32(w["avg_hrv"]),
                Float32(w["avg_br"]),
                String(w["end_time"])
            )

            result === nothing && continue

            z = Float32.(result["z"])

            fired, trigger = RLEnvironment.ingest_window!(
                ENV_INSTANCE[],
                z,
                Float32(result["avg_hr"]),
                Float32(result["avg_hrv"]),
                Float32(result["avg_br"]),
                String(result["end_time"])
            )

            # Update app state
            APP_STATE.avg_hr          = Float32(result["avg_hr"])
            APP_STATE.avg_hrv         = Float32(result["avg_hrv"])
            APP_STATE.avg_br          = Float32(result["avg_br"])
            APP_STATE.is_holding      = ENV_INSTANCE[].is_holding
            APP_STATE.hold_steps_left = ENV_INSTANCE[].hold_counter

            # Send live vitals to TD during hold
            if ENV_INSTANCE[].is_holding
                TDBridge.send_vitals(
                    Float32(result["avg_hr"]),
                    Float32(result["avg_hrv"]),
                    Float32(result["avg_br"])
                )
                TDBridge.send_hold_progress(
                    ENV_INSTANCE[].hold_counter,
                    RLEnvironment.HOLD_STEPS
                )
            end

            # Hold just completed → train agent
            if ENV_INSTANCE[].is_terminated
                println("[MAIN] Hold complete — training agent")
                action = RLAgent.agent_step!(
                    AGENT_INSTANCE[],
                    ENV_INSTANCE[].state,
                    ENV_INSTANCE[].last_reward,
                    ENV_INSTANCE[].avg_hr,
                    ENV_INSTANCE[].avg_hrv,
                    ENV_INSTANCE[].avg_br,
                    ENV_INSTANCE[].trigger_type;
                    is_holding = false,
                    hold_steps = 0
                )
                APP_STATE.active_interaction = action
                APP_STATE.last_reward        = ENV_INSTANCE[].last_reward
                TDBridge.send_vitals(0f0, 0f0, 0f0)
                TDBridge.send_hold_progress(0, RLEnvironment.HOLD_STEPS)
                ENV_INSTANCE[].is_terminated = false
            end

            # Bio trigger fired → agent acts immediately
            if fired && !ENV_INSTANCE[].is_holding
                println("[MAIN] Bio trigger — agent selecting action")
                action = RLAgent.agent_step!(
                    AGENT_INSTANCE[],
                    ENV_INSTANCE[].state,
                    ENV_INSTANCE[].last_reward,
                    ENV_INSTANCE[].avg_hr,
                    ENV_INSTANCE[].avg_hrv,
                    ENV_INSTANCE[].avg_br,
                    ENV_INSTANCE[].trigger_type;
                    is_holding = true,
                    hold_steps = RLEnvironment.HOLD_STEPS
                )
                ENV_INSTANCE[].is_terminated = false
                ENV_INSTANCE[](action + 1)
                APP_STATE.active_interaction = action
            end

            ingested += 1
        end

        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok"       => true,
                "ingested" => ingested
            )))

    catch e
        println("[INGEST ERROR] $e")
        return HTTP.Response(500,
            JSON3.write(Dict(
                "ok"    => false,
                "error" => string(e)
            )))
    end
end


function handle_trigger(req::HTTP.Request)
    try
        payload      = JSON3.read(req.body)
        trigger_type = Int(get(payload, "trigger_type",
                               RLEnvironment.TRIGGER_USER))

        latest = TCNEncoder.STATE.latest
        if latest === nothing
            return HTTP.Response(400,
                JSON3.write(Dict(
                    "ok"     => false,
                    "reason" => "No latent available yet"
                )))
        end

        z = Float32.(latest["z"])

        fired = RLEnvironment.fire_external_trigger!(
            ENV_INSTANCE[],
            z,
            Float32(latest["avg_hr"]),
            Float32(latest["avg_hrv"]),
            Float32(latest["avg_br"]),
            trigger_type,
            String(latest["end_time"])
        )

        if fired
            action = RLAgent.agent_step!(
                AGENT_INSTANCE[],
                ENV_INSTANCE[].state,
                ENV_INSTANCE[].last_reward,
                ENV_INSTANCE[].avg_hr,
                ENV_INSTANCE[].avg_hrv,
                ENV_INSTANCE[].avg_br,
                trigger_type;
                is_holding = true,
                hold_steps = RLEnvironment.HOLD_STEPS
            )
            ENV_INSTANCE[].is_terminated = false
            ENV_INSTANCE[](action + 1)
            APP_STATE.active_interaction = action

            return HTTP.Response(200,
                JSON3.write(Dict(
                    "ok"     => true,
                    "action" => action,
                    "name"   => RLAgent.ACTION_NAMES[action]
                )))
        end

        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok"     => false,
                "reason" => "Hold in progress"
            )))

    catch e
        println("[TRIGGER ERROR] $e")
        return HTTP.Response(500,
            JSON3.write(Dict(
                "ok"    => false,
                "error" => string(e)
            )))
    end
end


function handle_status(req::HTTP.Request)
    HTTP.Response(200, JSON3.write(Dict(
        "ok"                 => true,
        "avg_hr"             => APP_STATE.avg_hr,
        "avg_hrv"            => APP_STATE.avg_hrv,
        "avg_br"             => APP_STATE.avg_br,
        "active_interaction" => APP_STATE.active_interaction,
        "interaction_name"   => RLAgent.ACTION_NAMES[
                                    APP_STATE.active_interaction],
        "last_reward"        => APP_STATE.last_reward,
        "is_holding"         => APP_STATE.is_holding,
        "hold_steps_left"    => APP_STATE.hold_steps_left,
        "replay_size"        => AGENT_INSTANCE[].replay.size,
        "epsilon"            => AGENT_INSTANCE[].epsilon,
        "step"               => AGENT_INSTANCE[].step,
        "encoder_ready"      => TCNEncoder.STATE.encoder !== nothing,
    )))
end


function handle_latest(req::HTTP.Request)
    latest = TCNEncoder.STATE.latest
    if latest === nothing
        return HTTP.Response(200, "{}")
    end
    HTTP.Response(200, JSON3.write(latest))
end


# ── Router ────────────────────────────────────────────────────
function router(req::HTTP.Request)
    if req.target == "/ingest" && req.method == "POST"
        return handle_ingest(req)
    elseif req.target == "/trigger" && req.method == "POST"
        return handle_trigger(req)
    elseif req.target == "/status" && req.method == "GET"
        return handle_status(req)
    elseif req.target == "/latest" && req.method == "GET"
        return handle_latest(req)
    else
        return HTTP.Response(404, "Not found")
    end
end


# ── Main ──────────────────────────────────────────────────────
function main()
    println("=" ^ 70)
    println("Biofeedback System — Julia Pipeline")
    println("=" ^ 70)

    # Step 1: Check TD connection
    println("\n[INIT] Checking TouchDesigner connection...")
    TDBridge.check_connection()

    # Step 2: Init encoder
    println("\n[INIT] Starting TCN Encoder...")
    TCNEncoder.init_encoder()

    # Step 3: Init RL agent
    println("\n[INIT] Starting RL Agent...")
    AGENT_INSTANCE[] = RLAgent.init_agent(load_ckpt=true)

    # Step 4: Init environment
    println("\n[INIT] Starting RL Environment...")
    ENV_INSTANCE[] = RLEnvironment.BiofeedbackEnv()

    # Step 5: Start DataStreamer in background
    println("\n[INIT] Starting ADB DataStreamer...")
    @async DataStreamer.watch()

    # Step 6: Start HTTP server
    println("\n[INIT] HTTP server starting on port $(BRAIN_PORT)...")
    println("  POST /ingest   ← windows from DataStreamer")
    println("  POST /trigger  ← calendar or user trigger")
    println("  GET  /status   ← system status for Flutter")
    println("  GET  /latest   ← latest encoded window")
    println("\n[READY] System running — waiting for data...")
    println("=" ^ 70)

    HTTP.serve(router, "0.0.0.0", BRAIN_PORT)
end

# ── Entry Point ───────────────────────────────────────────────
main()