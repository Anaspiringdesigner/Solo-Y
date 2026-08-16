# ============================================================
# main.jl
# Biofeedback System — Full Pipeline
# - Robust hold pacing: advance at most once every 5s during holds.
# - Persist & restore cumulative_reward across restarts.
# - After every hold completes, send "interaction 5" to TouchDesigner.
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

const BRAIN_PORT = 8000

# ─────────────────────────────────────────────────────────────
# Hold pacing: allow one "effective" step every 5 seconds
# ─────────────────────────────────────────────────────────────
const HOLD_STEP_PERIOD_MS = 5_000
const LAST_HOLD_STEP_AT = Ref{Union{Nothing,DateTime}}(nothing)

@inline function _now_dt()::DateTime
    Dates.now()
end

@inline function _can_advance_hold(now_dt::DateTime)::Bool
    last = LAST_HOLD_STEP_AT[]
    last === nothing && return true
    return now_dt - last >= Millisecond(HOLD_STEP_PERIOD_MS)
end

@inline function _mark_hold_step(now_dt::DateTime)
    LAST_HOLD_STEP_AT[] = now_dt
end

@inline function _reset_hold_step_clock()
    LAST_HOLD_STEP_AT[] = nothing
end

# ─────────────────────────────────────────────────────────────
# Runtime persistence for cumulative_reward
# ─────────────────────────────────────────────────────────────
const RUNTIME_STATE_PATH = normpath(joinpath(@__DIR__, "models", "agent_runtime_state.json"))

function _load_runtime_cumulative_reward()::Union{Nothing,Float32}
    try
        if isfile(RUNTIME_STATE_PATH)
            txt = String(read(RUNTIME_STATE_PATH))
            obj = JSON3.read(txt)
            if haskey(obj, "cumulative_reward")
                return Float32(obj["cumulative_reward"])
            end
        end
    catch e
        println("[STATE] Load error: $e")
    end
    return nothing
end

function _save_runtime_cumulative_reward(val::Float32)
    try
        mkpath(dirname(RUNTIME_STATE_PATH))
        payload = Dict(
            "cumulative_reward" => val,
            "updated_at"        => Dates.format(Dates.now(), dateformat"yyyy-mm-ddTHH:MM:SS")
        )
        write(RUNTIME_STATE_PATH, JSON3.write(payload))
    catch e
        println("[STATE] Save error: $e")
    end
end

# ─────────────────────────────────────────────────────────────
# Post-hold TD action (non-RL interaction)
# ─────────────────────────────────────────────────────────────
# After every hold completes, show this interaction in TD.
# You said "not 4 but 5" — so we use 5 here.
const POST_HOLD_INTERACTION = 5

# Safely resolve interaction names even if RLAgent.ACTION_NAMES
# does not contain POST_HOLD_INTERACTION.
@inline function _interaction_name(idx::Int)
    try
        RLAgent.ACTION_NAMES[idx]
    catch
        idx == POST_HOLD_INTERACTION ? "PostHold" : "Unknown"
    end
end

mutable struct AppState
    avg_hr             :: Float32
    avg_hrv            :: Float32
    avg_br             :: Float32
    active_interaction :: Int
    last_reward        :: Float32
    cumulative_reward  :: Float32
    is_holding         :: Bool
    hold_steps_left    :: Int
end

AppState() = AppState(0f0, 0f0, 0f0, 0, 0f0, 0f0, false, 0)

const APP_STATE = AppState()

const ENV_INSTANCE = Ref{RLEnvironment.BiofeedbackEnv}(RLEnvironment.BiofeedbackEnv())
const AGENT_INSTANCE = Ref{RLAgent.DQNAgent}(RLAgent.DQNAgent())

function handle_ingest(req::HTTP.Request)
    try
        payload  = JSON3.read(req.body)
        windows  = payload["windows"]
        ingested = 0

        for w in windows
            # Always encode every window to keep the latest latent up to date.
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
            ingested += 1

            # Prepared values for env/UI
            avg_hr  = Float32(result["avg_hr"])
            avg_hrv = Float32(result["avg_hrv"])
            avg_br  = Float32(result["avg_br"])
            z       = Float32.(result["z"])
            end_iso = String(result["end_time"])

            # Gate environment stepping during holds by wall-clock.
            now_dt = _now_dt()
            fired  = false
            trigger = nothing

            if ENV_INSTANCE[].is_holding
                if _can_advance_hold(now_dt)
                    fired, trigger = RLEnvironment.ingest_window!(
                        ENV_INSTANCE[],
                        z,
                        avg_hr, avg_hrv, avg_br,
                        end_iso
                    )
                    _mark_hold_step(now_dt)
                else
                    fired = false
                end
            else
                fired, trigger = RLEnvironment.ingest_window!(
                    ENV_INSTANCE[],
                    z,
                    avg_hr, avg_hrv, avg_br,
                    end_iso
                )
            end

            # Update app-visible metrics.
            APP_STATE.avg_hr          = avg_hr
            APP_STATE.avg_hrv         = avg_hrv
            APP_STATE.avg_br          = avg_br
            APP_STATE.is_holding      = ENV_INSTANCE[].is_holding
            APP_STATE.hold_steps_left = ENV_INSTANCE[].hold_counter

            # While holding, keep TD overlays updated (progress is paced).
            if ENV_INSTANCE[].is_holding
                TDBridge.send_vitals(avg_hr, avg_hrv, avg_br)
                TDBridge.send_hold_progress(
                    ENV_INSTANCE[].hold_counter,
                    RLEnvironment.HOLD_STEPS
                )
            end

            # Hold complete → agent update, persist reward, reset overlays, then show interaction 5.
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
                APP_STATE.cumulative_reward  = AGENT_INSTANCE[].cumulative_reward
                _save_runtime_cumulative_reward(APP_STATE.cumulative_reward)

                # Reset TD overlays
                TDBridge.send_vitals(0f0, 0f0, 0f0)
                TDBridge.send_hold_progress(0, RLEnvironment.HOLD_STEPS)

                # Force TD to show "interaction 5" after hold ends (non-RL).
                try
                    TDBridge.send_action(
                        POST_HOLD_INTERACTION,
                        APP_STATE.avg_hr,
                        APP_STATE.avg_hrv,
                        APP_STATE.avg_br,
                        APP_STATE.last_reward,
                        APP_STATE.cumulative_reward,
                        2,       # trigger_type tag; reuse 2 (user) or any tag you prefer
                        false,   # is_holding
                        0        # hold_steps
                    )
                    APP_STATE.active_interaction = POST_HOLD_INTERACTION
                    println("[MAIN] Post-hold TD action → $(_interaction_name(POST_HOLD_INTERACTION))")
                catch e
                    println("[MAIN] Post-hold TD action error: $e")
                end

                ENV_INSTANCE[].is_terminated = false
                _reset_hold_step_clock()
            end

            # Trigger detected → start new hold, persist reward.
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
                (ENV_INSTANCE[])(action + 1)
                APP_STATE.active_interaction = action
                APP_STATE.cumulative_reward  = AGENT_INSTANCE[].cumulative_reward
                _save_runtime_cumulative_reward(APP_STATE.cumulative_reward)

                # Allow the first hold step to occur without delay.
                _reset_hold_step_clock()
            end
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
        trigger_type = Int(get(payload, "trigger_type", RLEnvironment.TRIGGER_USER))

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
            (ENV_INSTANCE[])(action + 1)
            APP_STATE.active_interaction = action
            APP_STATE.cumulative_reward  = AGENT_INSTANCE[].cumulative_reward
            _save_runtime_cumulative_reward(APP_STATE.cumulative_reward)

            # Start-of-hold: allow first paced step without delay
            _reset_hold_step_clock()

            return HTTP.Response(200,
                JSON3.write(Dict(
                    "ok"     => true,
                    "action" => action,
                    "name"   => _interaction_name(action)
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
        "interaction_name"   => _interaction_name(APP_STATE.active_interaction),
        "last_reward"        => APP_STATE.last_reward,
        "cumulative_reward"  => APP_STATE.cumulative_reward,
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

function handle_camera(req::HTTP.Request)
    try
        payload = JSON3.read(req.body)
        active  = get(payload, "active", false)
        url     = get(payload, "stream_url", "")
        lens    = get(payload, "lens", "front")

        println("[CAMERA] Stream $(active ? "started" : "stopped") | lens=$lens | url=$url")

        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok"  => true,
                "url" => url
            )))
    catch e
        println("[CAMERA ERROR] $e")
        return HTTP.Response(500,
            JSON3.write(Dict(
                "ok"    => false,
                "error" => string(e)
            )))
    end
end

function handle_force_interaction(req::HTTP.Request)
    try
        payload     = JSON3.read(req.body)
        interaction = Int(get(payload, "interaction", 0))

        # Allow 0..5 (includes the new post-hold non-RL interaction 5)
        if interaction < 0 || interaction > 5
            return HTTP.Response(400,
                JSON3.write(Dict(
                    "ok"    => false,
                    "error" => "interaction must be 0-5"
                )))
        end

        APP_STATE.active_interaction = interaction

        TDBridge.send_action(
            interaction,
            APP_STATE.avg_hr,
            APP_STATE.avg_hrv,
            APP_STATE.avg_br,
            APP_STATE.last_reward,
            APP_STATE.cumulative_reward,
            2,
            false,
            0
        )

        name = _interaction_name(interaction)
        println("[FORCE] Interaction $interaction ($name)")

        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok"          => true,
                "interaction" => interaction,
                "name"        => name
            )))
    catch e
        println("[FORCE ERROR] $e")
        return HTTP.Response(500,
            JSON3.write(Dict(
                "ok"    => false,
                "error" => string(e)
            )))
    end
end

function router(req::HTTP.Request)
    if req.target == "/ingest" && req.method == "POST"
        return handle_ingest(req)
    elseif req.target == "/trigger" && req.method == "POST"
        return handle_trigger(req)
    elseif req.target == "/status" && req.method == "GET"
        return handle_status(req)
    elseif req.target == "/latest" && req.method == "GET"
        return handle_latest(req)
    elseif req.target == "/camera" && req.method == "POST"
        return handle_camera(req)
    elseif req.target == "/force_interaction" && req.method == "POST"
        return handle_force_interaction(req)
    else
        return HTTP.Response(404, "Not found")
    end
end

function main()
    println("=" ^ 70)
    println("Biofeedback System — Julia Pipeline")
    println("=" ^ 70)

    println("\n[INIT] Checking TouchDesigner connection...")
    TDBridge.check_connection()

    println("\n[INIT] Starting TCN Encoder...")
    TCNEncoder.init_encoder()

    println("\n[INIT] Starting RL Agent...")
    AGENT_INSTANCE[] = RLAgent.init_agent(load_ckpt=true)

    # Restore cumulative_reward: prefer runtime file; fall back to agent's.
    restored = _load_runtime_cumulative_reward()
    if restored !== nothing
        AGENT_INSTANCE[].cumulative_reward = restored
        println("[INIT] Restored cumulative_reward from runtime file: $(restored)")
    else
        println("[INIT] No runtime file found; using agent state: $(AGENT_INSTANCE[].cumulative_reward)")
    end

    # Reflect in app state
    APP_STATE.cumulative_reward = AGENT_INSTANCE[].cumulative_reward

    println("\n[INIT] Starting RL Environment...")
    ENV_INSTANCE[] = RLEnvironment.BiofeedbackEnv()

    # Reset pacing clock at startup (no hold in progress).
    _reset_hold_step_clock()

    println("\n[INIT] Data transfer via Flutter app")
    println("  → Start data transfer in the Flutter app")

    # Push initial state to TouchDesigner so UI shows correct cumulative_reward.
    try
        TDBridge.send_action(
            APP_STATE.active_interaction,
            APP_STATE.avg_hr,
            APP_STATE.avg_hrv,
            APP_STATE.avg_br,
            APP_STATE.last_reward,
            APP_STATE.cumulative_reward,
            2,
            false,
            0
        )
        println("[INIT] Pushed initial state to TouchDesigner.")
    catch e
        println("[INIT] Could not push initial state to TD: $e")
    end

    println("\n[INIT] HTTP server starting on port $(BRAIN_PORT)...")
    println("  POST /ingest             ← windows from DataStreamer")
    println("  POST /trigger            ← calendar or user trigger")
    println("  GET  /status             ← system status for Flutter")
    println("  GET  /latest             ← latest encoded window")
    println("  POST /camera             ← camera stream notification")
    println("  POST /force_interaction  ← force specific interaction")
    println("\n[READY] System running — waiting for data...")
    println("=" ^ 70)

    HTTP.serve(router, "0.0.0.0", BRAIN_PORT)
end

main()