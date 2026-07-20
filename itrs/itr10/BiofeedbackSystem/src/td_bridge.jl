# ============================================================
# td_bridge.jl
# TouchDesigner OSC Bridge
# - Builds proper OSC packets
# - Sends interaction, vitals, reward, trigger, hold status
# - Clean separation from RL agent logic
# ============================================================

module TDBridge

using Sockets

# ── Config ───────────────────────────────────────────────────
const TD_IP   = "127.0.0.1"
const TD_PORT = 7000

# ── OSC Packet Builder ────────────────────────────────────────
# Builds a valid OSC 1.0 message for a single float value
# Format: [address][type tag][float32 big-endian]

function pad4(bytes::Vector{UInt8})::Vector{UInt8}
    r = 4 - (length(bytes) % 4)
    r == 4 ? bytes : vcat(bytes, zeros(UInt8, r))
end

function build_osc_float(address::String,
                          value::Float32)::Vector{UInt8}
    # Address string — null terminated + padded to 4 bytes
    addr_bytes = pad4(vcat(Vector{UInt8}(address), 0x00))

    # Type tag string ",f" — null terminated + padded
    type_bytes = pad4(vcat(Vector{UInt8}(",f"), 0x00))

    # Float32 big-endian (network byte order)
    f_bytes = reinterpret(UInt8, [hton(value)])

    return vcat(addr_bytes, type_bytes, f_bytes)
end

function build_osc_int(address::String,
                        value::Int32)::Vector{UInt8}
    # Address string
    addr_bytes = pad4(vcat(Vector{UInt8}(address), 0x00))

    # Type tag string ",i"
    type_bytes = pad4(vcat(Vector{UInt8}(",i"), 0x00))

    # Int32 big-endian
    i_bytes = reinterpret(UInt8, [hton(value)])

    return vcat(addr_bytes, type_bytes, i_bytes)
end

# ── Low-level UDP Sender ──────────────────────────────────────
function send_udp(messages::Vector{Vector{UInt8}})::Bool
    try
        sock = UDPSocket()
        ip   = Sockets.IPv4(TD_IP)
        for msg in messages
            send(sock, ip, TD_PORT, msg)
        end
        close(sock)
        return true
    catch e
        println("[TD BRIDGE ERROR] UDP send failed: $e")
        return false
    end
end

# ── Connection Health Check ───────────────────────────────────
function check_connection()::Bool
    try
        sock = UDPSocket()
        ip   = Sockets.IPv4(TD_IP)
        # Send a test ping message
        msg  = build_osc_float("/biofeedback/ping", 1.0f0)
        send(sock, ip, TD_PORT, msg)
        close(sock)
        println("[TD BRIDGE] Connection OK → $(TD_IP):$(TD_PORT)")
        return true
    catch e
        println("[TD BRIDGE] Connection FAILED → $(TD_IP):$(TD_PORT): $e")
        return false
    end
end

# ── Main Send Function ────────────────────────────────────────
# Called by RL agent after every action selection

function send_action(action       :: Int,
                      avg_hr       :: Float32,
                      avg_hrv      :: Float32,
                      avg_br       :: Float32,
                      reward       :: Float32,
                      trigger_type :: Int,
                      is_holding   :: Bool,
                      hold_steps   :: Int)::Bool

    messages = Vector{UInt8}[
        # Core interaction selector (int)
        build_osc_int("/biofeedback/interaction",
                       Int32(action)),

        # Live vitals (float)
        build_osc_float("/biofeedback/hr",      avg_hr),
        build_osc_float("/biofeedback/hrv",     avg_hrv),
        build_osc_float("/biofeedback/br",      avg_br),

        # RL metadata (float)
        build_osc_float("/biofeedback/reward",  reward),
        build_osc_float("/biofeedback/trigger",
                         Float32(trigger_type)),

        # Hold status
        build_osc_float("/biofeedback/holding",
                         Float32(is_holding ? 1 : 0)),
        build_osc_float("/biofeedback/hold_steps",
                         Float32(hold_steps)),
    ]

    ok = send_udp(messages)

    if ok
        println("[TD BRIDGE] → interaction=$(action) " *
                "HR=$(round(avg_hr,    digits=1)) " *
                "HRV=$(round(avg_hrv,  digits=1)) " *
                "BR=$(round(avg_br,    digits=1)) " *
                "reward=$(round(reward,digits=4)) " *
                "holding=$(is_holding)")
    end

    return ok
end

# ── Send Vitals Only ──────────────────────────────────────────
# Called during hold period to keep TD updated with live data

function send_vitals(avg_hr  :: Float32,
                      avg_hrv :: Float32,
                      avg_br  :: Float32)::Bool
    messages = Vector{UInt8}[
        build_osc_float("/biofeedback/hr",  avg_hr),
        build_osc_float("/biofeedback/hrv", avg_hrv),
        build_osc_float("/biofeedback/br",  avg_br),
    ]
    return send_udp(messages)
end

# ── Send Hold Progress ────────────────────────────────────────
# Sends hold countdown to TD so interactions can
# animate based on remaining hold time

function send_hold_progress(hold_steps_remaining :: Int,
                              hold_steps_total     :: Int)::Bool
    progress = Float32(1.0 - hold_steps_remaining /
                             max(1, hold_steps_total))
    messages = Vector{UInt8}[
        build_osc_float("/biofeedback/hold_progress", progress),
        build_osc_float("/biofeedback/hold_steps",
                         Float32(hold_steps_remaining)),
    ]
    return send_udp(messages)
end

end # module TDBridge