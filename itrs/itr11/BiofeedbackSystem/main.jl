# ============================================================
# main.jl
# Biofeedback System — Full Pipeline
#
# PHASE 1 CHANGES:
# - Add dashboard registry for app-side intervention dashboards.
# - Seed 5 initial dashboards.
# - Max dashboards allowed at any point in time = 8.
# - Add joint action encoding helpers for:
#       Action = (TD visual, dashboard)
# - Expose dashboard metadata and encoded action info in /status.
# - Add /dashboards endpoint to list dashboard registry.
#
# IMPORTANT:
# - This phase does NOT yet change RL policy selection/training behavior.
# - RL still behaves as before for now.
# - We are only laying the data/model foundation for the upcoming phases.
#
# Existing behavior preserved:
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

# ============================================================
# PHASE 1 — DASHBOARD REGISTRY + JOINT ACTION FOUNDATIONS
# ============================================================

# RL-selectable TD visuals remain 0..4.
# TD interaction 5 is still reserved for post-hold / non-RL behavior.
const RL_VISUAL_IDS = collect(0:4)
const RL_VISUAL_COUNT = length(RL_VISUAL_IDS)

# Maximum number of dashboards allowed at any point in time.
# This fixed cap is important so later RL action encoding can stay stable.
const MAX_DASHBOARDS = 8

# Initial dashboard definitions supplied by you.
# We keep title + instruction in the registry.
mutable struct DashboardDef
    id::Int
    title::String
    instruction::String
    created_by_user::Bool
    active::Bool
    created_at_step::Int
end

# Registry holds up to MAX_DASHBOARDS dashboard identities.
const DASHBOARD_REGISTRY = Vector{DashboardDef}()

"""
    seed_initial_dashboards!()

Populate the dashboard registry with the 5 initial dashboard identities.

Dashboard IDs are 0-based so they are easier to use in a flattened action:
    encoded_action = visual_id * MAX_DASHBOARDS + dashboard_id
"""
function seed_initial_dashboards!()
    empty!(DASHBOARD_REGISTRY)

    push!(DASHBOARD_REGISTRY, DashboardDef(
        0,
        "Box Breathing",
        "Breathe for the event duration. Take a breath for 4 seconds and release it for 4 seconds.",
        false,
        true,
        0
    ))

    push!(DASHBOARD_REGISTRY, DashboardDef(
        1,
        "Controlled Breath Hold",
        "Breathe for the event duration. Take a breath for 4 seconds, hold for 16 seconds and release it for 8 seconds.",
        false,
        true,
        0
    ))

    push!(DASHBOARD_REGISTRY, DashboardDef(
        2,
        "Stimming Tool",
        "Pick up a stimming tool of your choice and stimm for the event duration.",
        false,
        true,
        0
    ))

    push!(DASHBOARD_REGISTRY, DashboardDef(
        3,
        "Small Dance / Movement",
        "Do a small dance or any movement based activity for the event duration.",
        false,
        true,
        0
    ))

    push!(DASHBOARD_REGISTRY, DashboardDef(
        4,
        "Exercise",
        "Do an exercise or two exercises for the event duration.",
        false,
        true,
        0
    ))
end

"""
    dashboard_exists(id::Int) -> Bool

Return true if the dashboard ID exists in the registry.
"""
function dashboard_exists(id::Int)::Bool
    any(d -> d.id == id, DASHBOARD_REGISTRY)
end

"""
    get_dashboard(id::Int) -> Union{DashboardDef, Nothing}

Fetch a dashboard by ID.
"""
function get_dashboard(id::Int)
    for d in DASHBOARD_REGISTRY
        if d.id == id
            return d
        end
    end
    return nothing
end

"""
    active_dashboards() -> Vector{DashboardDef}

Return only active dashboards.
"""
function active_dashboards()::Vector{DashboardDef}
    [d for d in DASHBOARD_REGISTRY if d.active]
end

"""
    active_dashboard_ids() -> Vector{Int}

Return active dashboard IDs.
"""
function active_dashboard_ids()::Vector{Int}
    [d.id for d in DASHBOARD_REGISTRY if d.active]
end

"""
    encode_joint_action(visual_id::Int, dashboard_id::Int) -> Int

Flatten a joint action (visual, dashboard) into a single integer.

We use:
    encoded = visual_id * MAX_DASHBOARDS + dashboard_id

This assumes:
- visual_id is in 0..4 for RL-controlled visuals
- dashboard_id is in 0..7 because MAX_DASHBOARDS = 8
"""
function encode_joint_action(visual_id::Int, dashboard_id::Int)::Int
    return visual_id * MAX_DASHBOARDS + dashboard_id
end

"""
    decode_joint_action(encoded::Int) -> Tuple{Int, Int}

Decode a flattened action integer into:
    (visual_id, dashboard_id)
"""
function decode_joint_action(encoded::Int)::Tuple{Int, Int}
    visual_id = encoded ÷ MAX_DASHBOARDS
    dashboard_id = encoded % MAX_DASHBOARDS
    return (visual_id, dashboard_id)
end

"""
    valid_joint_action(visual_id::Int, dashboard_id::Int) -> Bool

Check whether a visual-dashboard pair is currently valid from a registry standpoint.
This phase only checks:
- visual in RL visual range
- dashboard exists
- dashboard is active
"""
function valid_joint_action(visual_id::Int, dashboard_id::Int)::Bool
    visual_ok = visual_id in RL_VISUAL_IDS
    d = get_dashboard(dashboard_id)
    dashboard_ok = d !== nothing && d.active
    return visual_ok && dashboard_ok
end

"""
    dashboard_to_dict(d::DashboardDef) -> Dict

Serialize dashboard for JSON responses.
"""
function dashboard_to_dict(d::DashboardDef)
    Dict(
        "id" => d.id,
        "title" => d.title,
        "instruction" => d.instruction,
        "created_by_user" => d.created_by_user,
        "active" => d.active,
        "created_at_step" => d.created_at_step
    )
end

# ============================================================
# EXISTING HOLD PACING
# ============================================================

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

# ============================================================
# EXISTING RUNTIME PERSISTENCE
# ============================================================

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

# ============================================================
# EXISTING POST-HOLD TD ACTION
# ============================================================

const POST_HOLD_INTERACTION = 5

@inline function _interaction_name(idx::Int)
    try
        RLAgent.ACTION_NAMES[idx]
    catch
        idx == POST_HOLD_INTERACTION ? "PostHold" : "Unknown"
    end
end

# ============================================================
# APP STATE
#
# PHASE 1 additions:
# - proposed_dashboard_id
# - executed_dashboard_id
# - proposed_encoded_action
# - executed_encoded_action
#
# These fields are placeholders/foundations for later phases.
# They are not yet driving RL behavior.
# ============================================================

mutable struct AppState
    avg_hr                  :: Float32
    avg_hrv                 :: Float32
    avg_br                  :: Float32
    active_interaction      :: Int
    last_reward             :: Float32
    cumulative_reward       :: Float32
    is_holding              :: Bool
    hold_steps_left         :: Int

    # Phase 1 action-foundation fields
    proposed_dashboard_id   :: Int
    executed_dashboard_id   :: Int
    proposed_encoded_action :: Int
    executed_encoded_action :: Int
end

AppState() = AppState(
    0f0,   # avg_hr
    0f0,   # avg_hrv
    0f0,   # avg_br
    0,     # active_interaction
    0f0,   # last_reward
    0f0,   # cumulative_reward
    false, # is_holding
    0,     # hold_steps_left

    0,     # proposed_dashboard_id
    0,     # executed_dashboard_id
    0,     # proposed_encoded_action
    0      # executed_encoded_action
)

const APP_STATE = AppState()

const ENV_INSTANCE = Ref{RLEnvironment.BiofeedbackEnv}(RLEnvironment.BiofeedbackEnv())
const AGENT_INSTANCE = Ref{RLAgent.DQNAgent}(RLAgent.DQNAgent())

# ============================================================
# EXISTING INGEST HANDLER
#
# PHASE 1 NOTE:
# We do NOT yet modify RL action selection/training logic.
# We only initialize placeholder joint action values for status visibility.
# ============================================================

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

                # --------------------------------------------------------
                # PHASE 1 FOUNDATION ONLY:
                # We do not yet have true joint RL selection.
                # For now, we expose a placeholder dashboard pairing:
                #   visual = current selected TD interaction
                #   dashboard = 0 by default
                #
                # Later phases will replace this with real joint-action logic.
                # --------------------------------------------------------
                default_dashboard_id = 0
                APP_STATE.proposed_dashboard_id = default_dashboard_id
                APP_STATE.executed_dashboard_id = default_dashboard_id
                APP_STATE.proposed_encoded_action = encode_joint_action(action, default_dashboard_id)
                APP_STATE.executed_encoded_action = encode_joint_action(action, default_dashboard_id)

                # Start-of-hold: allow first paced step without delay.
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

# ============================================================
# EXISTING TRIGGER HANDLER
#
# PHASE 1 NOTE:
# Same as ingest path: we only initialize placeholder dashboard/action fields.
# ============================================================

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

            # --------------------------------------------------------
            # PHASE 1 FOUNDATION ONLY:
            # Default dashboard pairing until real joint selection lands.
            # --------------------------------------------------------
            default_dashboard_id = 0
            APP_STATE.proposed_dashboard_id = default_dashboard_id
            APP_STATE.executed_dashboard_id = default_dashboard_id
            APP_STATE.proposed_encoded_action = encode_joint_action(action, default_dashboard_id)
            APP_STATE.executed_encoded_action = encode_joint_action(action, default_dashboard_id)

            # Start-of-hold: allow first paced step without delay
            _reset_hold_step_clock()

            return HTTP.Response(200,
                JSON3.write(Dict(
                    "ok"               => true,
                    "action"           => action,
                    "name"             => _interaction_name(action),

                    # Phase 1 additions
                    "proposed_visual"  => action,
                    "proposed_dashboard_id" => APP_STATE.proposed_dashboard_id,
                    "proposed_encoded_action" => APP_STATE.proposed_encoded_action
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

# ============================================================
# NEW — DASHBOARDS ENDPOINT
# ============================================================

function handle_dashboards(req::HTTP.Request)
    try
        dashboards = [dashboard_to_dict(d) for d in DASHBOARD_REGISTRY]
        active_ids = active_dashboard_ids()

        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok" => true,
                "max_dashboards" => MAX_DASHBOARDS,
                "active_dashboard_ids" => active_ids,
                "dashboards" => dashboards
            )))
    catch e
        println("[DASHBOARDS ERROR] $e")
        return HTTP.Response(500,
            JSON3.write(Dict(
                "ok" => false,
                "error" => string(e)
            )))
    end
end

# ============================================================
# EXISTING STATUS HANDLER
#
# PHASE 1 additions:
# - dashboard registry summary
# - proposed/executed dashboard/action placeholders
# ============================================================

function handle_status(req::HTTP.Request)
    proposed_dashboard = get_dashboard(APP_STATE.proposed_dashboard_id)
    executed_dashboard = get_dashboard(APP_STATE.executed_dashboard_id)

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

        # -----------------------------
        # Phase 1 dashboard/joint-action data
        # -----------------------------
        "max_dashboards" => MAX_DASHBOARDS,
        "active_dashboard_ids" => active_dashboard_ids(),
        "dashboard_count" => length(DASHBOARD_REGISTRY),

        "proposed_visual_id" => APP_STATE.active_interaction in RL_VISUAL_IDS ? APP_STATE.active_interaction : -1,
        "proposed_dashboard_id" => APP_STATE.proposed_dashboard_id,
        "executed_dashboard_id" => APP_STATE.executed_dashboard_id,

        "proposed_encoded_action" => APP_STATE.proposed_encoded_action,
        "executed_encoded_action" => APP_STATE.executed_encoded_action,

        "proposed_dashboard_title" => proposed_dashboard === nothing ? "" : proposed_dashboard.title,
        "proposed_dashboard_instruction" => proposed_dashboard === nothing ? "" : proposed_dashboard.instruction,

        "executed_dashboard_title" => executed_dashboard === nothing ? "" : executed_dashboard.title,
        "executed_dashboard_instruction" => executed_dashboard === nothing ? "" : executed_dashboard.instruction
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

        # Allow 0..5 (includes the post-hold non-RL interaction 5)
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

# ============================================================
# ROUTER
# ============================================================

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
    elseif req.target == "/dashboards" && req.method == "GET"
        return handle_dashboards(req)
    else
        return HTTP.Response(404, "Not found")
    end
end

# ============================================================
# MAIN
# ============================================================

function main()
    println("=" ^ 70)
    println("Biofeedback System — Julia Pipeline")
    println("=" ^ 70)

    println("\n[INIT] Seeding dashboard registry...")
    seed_initial_dashboards!()
    println("[INIT] Dashboard registry ready: $(length(DASHBOARD_REGISTRY)) seeded / max $(MAX_DASHBOARDS)")
    for d in DASHBOARD_REGISTRY
        println("  - Dashboard $(d.id): $(d.title)")
    end

    println("\n[INIT] Checking TouchDesigner connection...")
    TDBridge.check_connection()

    println("\n[INIT] Starting TCN Encoder...")
    try
        TCNEncoder.init_encoder()
    catch e
        @error "[INIT] TCN encoder failed to initialize — continuing with fresh runtime" exception=(e, catch_backtrace())
        # Optional: if you have a helper to reset runtime, call it here
        # TCNEncoder.reset_runtime_state!()
    end

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

    # Initialize default dashboard placeholders
    APP_STATE.proposed_dashboard_id = 0
    APP_STATE.executed_dashboard_id = 0
    APP_STATE.proposed_encoded_action = encode_joint_action(0, 0)
    APP_STATE.executed_encoded_action = encode_joint_action(0, 0)

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
    println("  GET  /dashboards         ← dashboard registry")
    println("\n[READY] System running — waiting for data...")
    println("=" ^ 70)

    HTTP.serve(router, "0.0.0.0", BRAIN_PORT)
end

main()