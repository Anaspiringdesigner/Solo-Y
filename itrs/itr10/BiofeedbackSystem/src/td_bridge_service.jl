module TDBridgeService

using Sockets
using ..Config

export send_td_payload, trigger_code, build_td_messages

function _osc_pad4(n::Int)
    r = mod(n, 4)
    return r == 0 ? 0 : 4 - r
end

function _osc_string_bytes(s::AbstractString)
    data = Vector{UInt8}(codeunits(String(s)))
    push!(data, 0x00)
    pad = _osc_pad4(length(data))
    for _ in 1:pad
        push!(data, 0x00)
    end
    return data
end

function _be_i32_bytes(x::Integer)
    u = reinterpret(UInt32, Int32(x))
    return UInt8[
        UInt8((u >> 24) & 0xff),
        UInt8((u >> 16) & 0xff),
        UInt8((u >> 8) & 0xff),
        UInt8(u & 0xff),
    ]
end

function _be_f32_bytes(x::Real)
    u = reinterpret(UInt32, Float32(x))
    return UInt8[
        UInt8((u >> 24) & 0xff),
        UInt8((u >> 16) & 0xff),
        UInt8((u >> 8) & 0xff),
        UInt8(u & 0xff),
    ]
end

function _osc_message(address::String, value)
    msg = UInt8[]
    append!(msg, _osc_string_bytes(address))

    if value isa Integer || value isa Bool
        append!(msg, _osc_string_bytes(",i"))
        append!(msg, _be_i32_bytes(Int(value)))
    else
        append!(msg, _osc_string_bytes(",f"))
        append!(msg, _be_f32_bytes(Float32(value)))
    end
    return msg
end

function trigger_code(trigger_type::AbstractString)::Int
    tt = lowercase(String(trigger_type))
    if tt == "manual"
        return 1
    elseif tt == "calendar"
        return 2
    elseif tt == "bio"
        return 3
    elseif tt == "system"
        return 4
    else
        return 0
    end
end

function build_td_messages(settings::Config.Settings, payload::Dict{String, Any})
    base = settings.td_path
    hr = Float32(get(payload, "hr", 0f0))
    hrv = Float32(get(payload, "hrv", 0f0))
    br = Float32(get(payload, "br", 0f0))
    interaction = Int(get(payload, "interaction", 0))
    reward = Float32(get(payload, "reward", 0f0))
    trigger = Int(get(payload, "trigger", 0))
    holding = Int(get(payload, "holding", 0))
    hold_steps = Int(get(payload, "hold_steps", 0))
    hold_progress = Float32(get(payload, "hold_progress", 0f0))
    ping = Int(get(payload, "ping", 1))

    return [
        ("$(base)/ping", ping),
        ("$(base)/hr", hr),
        ("$(base)/hrv", hrv),
        ("$(base)/br", br),
        ("$(base)/interaction", interaction),
        ("$(base)/reward", reward),
        ("$(base)/trigger", trigger),
        ("$(base)/holding", holding),
        ("$(base)/hold_steps", hold_steps),
        ("$(base)/hold_progress", hold_progress),
    ]
end

function send_td_payload(settings::Config.Settings, payload::Dict{String, Any})::Bool
    sock = UDPSocket()
    try
        msgs = build_td_messages(settings, payload)
        for (addr, value) in msgs
            data = _osc_message(addr, value)
            send(sock, ip"$(settings.td_host)", settings.td_port, data)
        end
        println("[TD] OSC sent host=$(settings.td_host) port=$(settings.td_port) path=$(settings.td_path)")
        return true
    catch e
        println("[TD] OSC bridge error: $(string(e))")
        return false
    finally
        close(sock)
    end
end

end # module