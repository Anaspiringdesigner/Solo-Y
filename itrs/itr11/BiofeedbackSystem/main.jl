# ============================================================
# main.jl
# Biofeedback System — Full Pipeline
#
# PHASE 1 + PHASE 2 + PHASE 3 + PHASE 4B CHANGES:
#
# Phase 1:
# - Add dashboard registry for app-side intervention dashboards.
# - Seed 5 initial dashboards.
# - Max dashboards allowed at any point in time = 8.
# - Add joint action encoding helpers for:
#       Action = (TD visual, dashboard)
# - Expose dashboard metadata and encoded action info in /status.
# - Add /dashboards endpoint to list dashboard registry.
#
# Phase 2:
# - Add pending intervention state.
# - Add POST /dashboards to create new dashboard identities.
# - Add POST /confirm_action to confirm the executed dashboard.
# - Enforce max dashboard cap = 8.
# - Normalize and de-duplicate dashboard text.
# - Track proposed vs executed joint action placeholders.
#
# Phase 3:
# - Do NOT start the hold/intervention on /trigger immediately.
# - /trigger now only proposes a pending intervention.
# - /confirm_action starts the actual hold/intervention.
# - Keep active_interaction = 5 while waiting for confirmation.
# - Only switch active_interaction to the RL visual after confirmation.
#
# Phase 4B:
# - True joint-action RL:
#       encoded_action = (visual_id * 8) + dashboard_id
# - RL agent now returns encoded action in 0..39
# - Backend decodes encoded action into proposed visual + proposed dashboard
# - Executed encoded action is recomputed after user dashboard override
# - Executed encoded action becomes authoritative metadata for the intervention
#
# IMPORTANT:
# - This version expects the RL agent to use 40 actions.
# - Old 5-action DQN checkpoints are incompatible and should be treated as fresh.
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

const RL_VISUAL_IDS = collect(0:4)
const RL_VISUAL_COUNT = length(RL_VISUAL_IDS)
const MAX_DASHBOARDS = 8

mutable struct DashboardDef
    id::Int
    title::String
    instruction::String
    normalized_key::String
    created_by_user::Bool
    active::Bool
    created_at_step::Int
end

const DASHBOARD_REGISTRY = Vector{DashboardDef}()

function normalize_dashboard_text(s::AbstractString)::String
    stripped = strip(String(s))
    lowered = lowercase(stripped)
    parts = split(lowered)
    return join(parts, " ")
end

function infer_dashboard_title(instruction::AbstractString)::String
    txt = strip(String(instruction))
    isempty(txt) && return "Custom Action"
    if length(txt) <= 32
        return txt
    end
    return txt[1:32] * "..."
end

function next_dashboard_id()
    used = Set(d.id for d in DASHBOARD_REGISTRY)
    for i in 0:(MAX_DASHBOARDS - 1)
        if !(i in used)
            return i
        end
    end
    return nothing
end

function seed_initial_dashboards!()
    empty!(DASHBOARD_REGISTRY)

    initial = [
        (0, "Box Breathing",
         "Breathe for the event duration. Take a breath for 4 seconds and release it for 4 seconds."),
        (1, "Controlled Breath Hold",
         "Breathe for the event duration. Take a breath for 4 seconds, hold for 16 seconds and release it for 8 seconds."),
        (2, "Stimming Tool",
         "Pick up a stimming tool of your choice and stimm for the event duration."),
        (3, "Small Dance / Movement",
         "Do a small dance or any movement based activity for the event duration."),
        (4, "Exercise",
         "Do an exercise or two exercises for the event duration."),
    ]

    for (id, title, instruction) in initial
        push!(DASHBOARD_REGISTRY, DashboardDef(
            id,
            title,
            instruction,
            normalize_dashboard_text(instruction),
            false,
            true,
            0
        ))
    end
end

function dashboard_exists(id::Int)::Bool
    any(d -> d.id == id, DASHBOARD_REGISTRY)
end

function get_dashboard(id::Int)
    for d in DASHBOARD_REGISTRY
        if d.id == id
            return d
        end
    end
    return nothing
end

function active_dashboards()::Vector{DashboardDef}
    [d for d in DASHBOARD_REGISTRY if d.active]
end

function active_dashboard_ids()::Vector{Int}
    [d.id for d in DASHBOARD_REGISTRY if d.active]
end

function find_dashboard_by_normalized_key(key::String)
    for d in DASHBOARD_REGISTRY
        if d.normalized_key == key
            return d
        end
    end
    return nothing
end

function create_dashboard!(instruction::String;
                           title::Union{Nothing,String}=nothing,
                           created_by_user::Bool=true,
                           active::Bool=true,
                           created_at_step::Int=0)
    clean_instruction = strip(instruction)
    if isempty(clean_instruction)
        return (ok=false, dashboard=nothing, reason="instruction is empty", duplicate=false)
    end

    norm = normalize_dashboard_text(clean_instruction)
    existing = find_dashboard_by_normalized_key(norm)
    if existing !== nothing
        return (ok=true, dashboard=existing, reason="duplicate dashboard", duplicate=true)
    end

    if length(DASHBOARD_REGISTRY) >= MAX_DASHBOARDS
        return (ok=false, dashboard=nothing, reason="maximum dashboards reached", duplicate=false)
    end

    id = next_dashboard_id()
    if id === nothing
        return (ok=false, dashboard=nothing, reason="no dashboard slot available", duplicate=false)
    end

    final_title = title === nothing || isempty(strip(title)) ? infer_dashboard_title(clean_instruction) : strip(title)

    d = DashboardDef(
        id,
        final_title,
        clean_instruction,
        norm,
        created_by_user,
        active,
        created_at_step
    )
    push!(DASHBOARD_REGISTRY, d)
    sort!(DASHBOARD_REGISTRY, by = x -> x.id)

    return (ok=true, dashboard=d, reason="created", duplicate=false)
end

function encode_joint_action(visual_id::Int, dashboard_id::Int)::Int
    return visual_id * MAX_DASHBOARDS + dashboard_id
end

function decode_joint_action(encoded::Int)::Tuple{Int, Int}
    visual_id = encoded ÷ MAX_DASHBOARDS
    dashboard_id = encoded % MAX_DASHBOARDS
    return (visual_id, dashboard_id)
end

function valid_joint_action(visual_id::Int, dashboard_id::Int)::Bool
    visual_ok = visual_id in RL_VISUAL_IDS
    d = get_dashboard(dashboard_id)
    dashboard_ok = d !== nothing && d.active
    return visual_ok && dashboard_ok
end

function dashboard_to_dict(d::DashboardDef)
    Dict(
        "id" => d.id,
        "title" => d.title,
        "instruction" => d.instruction,
        "normalized_key" => d.normalized_key,
        "created_by_user" => d.created_by_user,
        "active" => d.active,
        "created_at_step" => d.created_at_step
    )
end

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

const POST_HOLD_INTERACTION = 5

@inline function _interaction_name(idx::Int)
    try
        RLAgent.ACTION_NAMES[idx]
    catch
        idx == POST_HOLD_INTERACTION ? "PostHold" : "Unknown"
    end
end

const PHASE_IDLE = "idle"
const PHASE_AWAITING_CONFIRMATION = "awaiting_confirmation"
const PHASE_CONFIRMED = "confirmed"

mutable struct AppState
    avg_hr                  :: Float32
    avg_hrv                 :: Float32
    avg_br                  :: Float32
    active_interaction      :: Int
    last_reward             :: Float32
    cumulative_reward       :: Float32
    is_holding              :: Bool
    hold_steps_left         :: Int

    proposed_dashboard_id   :: Int
    executed_dashboard_id   :: Int
    proposed_encoded_action :: Int
    executed_encoded_action :: Int

    intervention_phase      :: String
    has_pending_intervention:: Bool
    proposed_visual_id      :: Int
    executed_visual_id      :: Int
    dashboard_confirmed_at  :: String
end

AppState() = AppState(
    0f0,
    0f0,
    0f0,
    POST_HOLD_INTERACTION,
    0f0,
    0f0,
    false,
    0,
    0,
    0,
    0,
    0,
    PHASE_IDLE,
    false,
    0,
    0,
    ""
)

const APP_STATE = AppState()

const ENV_INSTANCE = Ref{RLEnvironment.BiofeedbackEnv}(RLEnvironment.BiofeedbackEnv())
const AGENT_INSTANCE = Ref{RLAgent.DQNAgent}(RLAgent.DQNAgent())

function begin_pending_intervention!(visual_id::Int; proposed_dashboard_id::Int=0)
    APP_STATE.has_pending_intervention = true
    APP_STATE.intervention_phase = PHASE_AWAITING_CONFIRMATION

    APP_STATE.proposed_visual_id = visual_id
    APP_STATE.executed_visual_id = visual_id

    APP_STATE.proposed_dashboard_id = proposed_dashboard_id
    APP_STATE.executed_dashboard_id = proposed_dashboard_id

    APP_STATE.proposed_encoded_action = encode_joint_action(visual_id, proposed_dashboard_id)
    APP_STATE.executed_encoded_action = encode_joint_action(visual_id, proposed_dashboard_id)

    APP_STATE.dashboard_confirmed_at = ""
    APP_STATE.active_interaction = POST_HOLD_INTERACTION
    APP_STATE.is_holding = false
    APP_STATE.hold_steps_left = 0
end

function confirm_pending_intervention!(executed_dashboard_id::Int)
    APP_STATE.executed_dashboard_id = executed_dashboard_id
    APP_STATE.executed_visual_id = APP_STATE.proposed_visual_id
    APP_STATE.executed_encoded_action = encode_joint_action(APP_STATE.executed_visual_id, executed_dashboard_id)
    APP_STATE.intervention_phase = PHASE_CONFIRMED
    APP_STATE.dashboard_confirmed_at = Dates.format(Dates.now(), dateformat"yyyy-mm-ddTHH:MM:SS")
end

function clear_pending_intervention!()
    APP_STATE.has_pending_intervention = false
    APP_STATE.intervention_phase = PHASE_IDLE
    APP_STATE.dashboard_confirmed_at = ""
end

function _latest_latent_payload()
    latest = TCNEncoder.STATE.latest
    latest === nothing && return nothing
    return latest
end

function start_confirmed_intervention!(trigger_type::Int)
    latest = _latest_latent_payload()
    latest === nothing && error("No latent available yet for confirmed intervention start")

    visual_id = APP_STATE.proposed_visual_id

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

    fired || error("Could not start confirmed intervention; hold may already be active")

    ENV_INSTANCE[].is_terminated = false
    (ENV_INSTANCE[])(visual_id + 1)

    APP_STATE.active_interaction = visual_id
    APP_STATE.is_holding = ENV_INSTANCE[].is_holding
    APP_STATE.hold_steps_left = ENV_INSTANCE[].hold_counter

    try
        TDBridge.send_action(
            visual_id,
            APP_STATE.avg_hr,
            APP_STATE.avg_hrv,
            APP_STATE.avg_br,
            APP_STATE.last_reward,
            APP_STATE.cumulative_reward,
            trigger_type,
            true,
            RLEnvironment.HOLD_STEPS
        )
        println("[MAIN] TD switched to confirmed visual $visual_id")
    catch e
        println("[MAIN] TD visual switch on confirm failed: $e")
    end

    _reset_hold_step_clock()
    println("[MAIN] Confirmed intervention started → visual=$visual_id dashboard=$(APP_STATE.executed_dashboard_id)")
end

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
            ingested += 1

            avg_hr  = Float32(result["avg_hr"])
            avg_hrv = Float32(result["avg_hrv"])
            avg_br  = Float32(result["avg_br"])
            z       = Float32.(result["z"])
            end_iso = String(result["end_time"])

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

            APP_STATE.avg_hr          = avg_hr
            APP_STATE.avg_hrv         = avg_hrv
            APP_STATE.avg_br          = avg_br
            APP_STATE.is_holding      = ENV_INSTANCE[].is_holding
            APP_STATE.hold_steps_left = ENV_INSTANCE[].hold_counter

            if ENV_INSTANCE[].is_holding
                TDBridge.send_vitals(avg_hr, avg_hrv, avg_br)
                TDBridge.send_hold_progress(
                    ENV_INSTANCE[].hold_counter,
                    RLEnvironment.HOLD_STEPS
                )
            end

            if ENV_INSTANCE[].is_terminated
                println("[MAIN] Hold complete — training agent")
                encoded_action = RLAgent.agent_step!(
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

                APP_STATE.last_reward        = ENV_INSTANCE[].last_reward
                APP_STATE.cumulative_reward  = AGENT_INSTANCE[].cumulative_reward
                _save_runtime_cumulative_reward(APP_STATE.cumulative_reward)

                TDBridge.send_vitals(0f0, 0f0, 0f0)
                TDBridge.send_hold_progress(0, RLEnvironment.HOLD_STEPS)

                try
                    TDBridge.send_action(
                        POST_HOLD_INTERACTION,
                        APP_STATE.avg_hr,
                        APP_STATE.avg_hrv,
                        APP_STATE.avg_br,
                        APP_STATE.last_reward,
                        APP_STATE.cumulative_reward,
                        2,
                        false,
                        0
                    )
                    APP_STATE.active_interaction = POST_HOLD_INTERACTION
                    println("[MAIN] Post-hold TD action → $(_interaction_name(POST_HOLD_INTERACTION))")
                catch e
                    println("[MAIN] Post-hold TD action error: $e")
                end

                ENV_INSTANCE[].is_terminated = false
                _reset_hold_step_clock()
                clear_pending_intervention!()
            end

            if fired && !ENV_INSTANCE[].is_holding
                println("[MAIN] Bio trigger — agent selecting encoded joint action")
                encoded_action = RLAgent.agent_step!(
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

                visual_id, dashboard_id = decode_joint_action(encoded_action)

                APP_STATE.cumulative_reward = AGENT_INSTANCE[].cumulative_reward
                _save_runtime_cumulative_reward(APP_STATE.cumulative_reward)

                begin_pending_intervention!(visual_id; proposed_dashboard_id=dashboard_id)
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

        if ENV_INSTANCE[].is_holding || APP_STATE.has_pending_intervention
            return HTTP.Response(200,
                JSON3.write(Dict(
                    "ok"     => false,
                    "reason" => "Hold or pending confirmation in progress"
                )))
        end

        encoded_action = RLAgent.agent_step!(
            AGENT_INSTANCE[],
            ENV_INSTANCE[].state,
            ENV_INSTANCE[].last_reward,
            ENV_INSTANCE[].avg_hr,
            ENV_INSTANCE[].avg_hrv,
            ENV_INSTANCE[].avg_br,
            trigger_type;
            is_holding = false,
            hold_steps = 0
        )

        visual_id, dashboard_id = decode_joint_action(encoded_action)

        APP_STATE.cumulative_reward = AGENT_INSTANCE[].cumulative_reward
        _save_runtime_cumulative_reward(APP_STATE.cumulative_reward)

        begin_pending_intervention!(visual_id; proposed_dashboard_id=dashboard_id)

        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok"               => true,
                "encoded_action"   => encoded_action,
                "proposed_visual"  => visual_id,
                "proposed_dashboard_id" => APP_STATE.proposed_dashboard_id,
                "proposed_encoded_action" => APP_STATE.proposed_encoded_action,
                "intervention_phase" => APP_STATE.intervention_phase,
                "has_pending_intervention" => APP_STATE.has_pending_intervention
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

function handle_dashboards(req::HTTP.Request)
    try
        dashboards = [dashboard_to_dict(d) for d in DASHBOARD_REGISTRY]
        active_ids = active_dashboard_ids()

        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok" => true,
                "max_dashboards" => MAX_DASHBOARDS,
                "active_dashboard_ids" => active_ids,
                "dashboard_count" => length(DASHBOARD_REGISTRY),
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

function handle_create_dashboard(req::HTTP.Request)
    try
        payload = JSON3.read(req.body)
        instruction = String(get(payload, "instruction", ""))
        title_raw = get(payload, "title", nothing)
        title = title_raw === nothing ? nothing : String(title_raw)

        created_at_step = try
            Int(AGENT_INSTANCE[].step)
        catch
            0
        end

        result = create_dashboard!(instruction;
            title=title,
            created_by_user=true,
            active=true,
            created_at_step=created_at_step
        )

        if !result.ok
            return HTTP.Response(400,
                JSON3.write(Dict(
                    "ok" => false,
                    "reason" => result.reason,
                    "max_dashboards" => MAX_DASHBOARDS,
                    "dashboard_count" => length(DASHBOARD_REGISTRY)
                )))
        end

        d = result.dashboard
        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok" => true,
                "created" => !result.duplicate,
                "duplicate" => result.duplicate,
                "reason" => result.reason,
                "dashboard" => dashboard_to_dict(d),
                "dashboard_count" => length(DASHBOARD_REGISTRY),
                "max_dashboards" => MAX_DASHBOARDS
            )))
    catch e
        println("[CREATE DASHBOARD ERROR] $e")
        return HTTP.Response(500,
            JSON3.write(Dict(
                "ok" => false,
                "error" => string(e)
            )))
    end
end

function handle_confirm_action(req::HTTP.Request)
    try
        if !APP_STATE.has_pending_intervention || APP_STATE.intervention_phase != PHASE_AWAITING_CONFIRMATION
            return HTTP.Response(400,
                JSON3.write(Dict(
                    "ok" => false,
                    "reason" => "no pending intervention awaiting confirmation"
                )))
        end

        payload = JSON3.read(req.body)
        executed_dashboard_id = Int(get(payload, "executed_dashboard_id", -1))

        d = get_dashboard(executed_dashboard_id)
        if d === nothing
            return HTTP.Response(400,
                JSON3.write(Dict(
                    "ok" => false,
                    "reason" => "dashboard does not exist"
                )))
        end
        if !d.active
            return HTTP.Response(400,
                JSON3.write(Dict(
                    "ok" => false,
                    "reason" => "dashboard is inactive"
                )))
        end

        confirm_pending_intervention!(executed_dashboard_id)

        trigger_type = try
            Int(ENV_INSTANCE[].trigger_type)
        catch
            2
        end

        start_confirmed_intervention!(trigger_type)

        return HTTP.Response(200,
            JSON3.write(Dict(
                "ok" => true,
                "intervention_phase" => APP_STATE.intervention_phase,
                "proposed_visual_id" => APP_STATE.proposed_visual_id,
                "proposed_dashboard_id" => APP_STATE.proposed_dashboard_id,
                "executed_visual_id" => APP_STATE.executed_visual_id,
                "executed_dashboard_id" => APP_STATE.executed_dashboard_id,
                "proposed_encoded_action" => APP_STATE.proposed_encoded_action,
                "executed_encoded_action" => APP_STATE.executed_encoded_action,
                "dashboard_confirmed_at" => APP_STATE.dashboard_confirmed_at,
                "active_interaction" => APP_STATE.active_interaction,
                "is_holding" => APP_STATE.is_holding,
                "hold_steps_left" => APP_STATE.hold_steps_left
            )))
    catch e
        println("[CONFIRM ACTION ERROR] $e")
        return HTTP.Response(500,
            JSON3.write(Dict(
                "ok" => false,
                "error" => string(e)
            )))
    end
end

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

        "max_dashboards" => MAX_DASHBOARDS,
        "dashboard_count" => length(DASHBOARD_REGISTRY),
        "active_dashboard_ids" => active_dashboard_ids(),

        "has_pending_intervention" => APP_STATE.has_pending_intervention,
        "intervention_phase" => APP_STATE.intervention_phase,
        "dashboard_confirmed_at" => APP_STATE.dashboard_confirmed_at,

        "proposed_visual_id" => APP_STATE.proposed_visual_id,
        "executed_visual_id" => APP_STATE.executed_visual_id,

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
    elseif req.target == "/dashboards" && req.method == "GET"
        return handle_dashboards(req)
    elseif req.target == "/dashboards" && req.method == "POST"
        return handle_create_dashboard(req)
    elseif req.target == "/confirm_action" && req.method == "POST"
        return handle_confirm_action(req)
    else
        return HTTP.Response(404, "Not found")
    end
end

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
    end

    println("\n[INIT] Starting RL Agent...")
    AGENT_INSTANCE[] = RLAgent.init_agent(load_ckpt=true)

    restored = _load_runtime_cumulative_reward()
    if restored !== nothing
        AGENT_INSTANCE[].cumulative_reward = restored
        println("[INIT] Restored cumulative_reward from runtime file: $(restored)")
    else
        println("[INIT] No runtime file found; using agent state: $(AGENT_INSTANCE[].cumulative_reward)")
    end

    APP_STATE.cumulative_reward = AGENT_INSTANCE[].cumulative_reward

    APP_STATE.proposed_dashboard_id = 0
    APP_STATE.executed_dashboard_id = 0
    APP_STATE.proposed_encoded_action = encode_joint_action(0, 0)
    APP_STATE.executed_encoded_action = encode_joint_action(0, 0)
    APP_STATE.proposed_visual_id = 0
    APP_STATE.executed_visual_id = 0
    APP_STATE.intervention_phase = PHASE_IDLE
    APP_STATE.has_pending_intervention = false
    APP_STATE.dashboard_confirmed_at = ""
    APP_STATE.active_interaction = POST_HOLD_INTERACTION
    APP_STATE.is_holding = false
    APP_STATE.hold_steps_left = 0

    println("\n[INIT] Starting RL Environment...")
    ENV_INSTANCE[] = RLEnvironment.BiofeedbackEnv()

    _reset_hold_step_clock()

    println("\n[INIT] Data transfer via Flutter app")
    println("  → Start data transfer in the Flutter app")

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
    println("  GET  /dashboards         ← list dashboard registry")
    println("  POST /dashboards         ← create new dashboard identity")
    println("  POST /confirm_action     ← confirm executed dashboard for pending intervention")
    println("\n[READY] System running — waiting for data...")
    println("=" ^ 70)

    HTTP.serve(router, "0.0.0.0", BRAIN_PORT)
end

main()