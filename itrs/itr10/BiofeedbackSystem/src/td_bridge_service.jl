module TDBridgeService

using Sockets
using ..Config

export send_td_payload, trigger_code

function trigger_code(trigger_type::String)::Int
    t = lowercase(trigger_type)
    if t == "manual"
        return 1
    elseif t == "calendar"
        return 2
    elseif t == "bio"
        return 3
    elseif t == "system"
        return 4
    else
        return 0
    end
end

function _send_line(sock::UDPSocket, host::IPAddr, port::Int, address::String, value)
    msg = string(address, " ", value)
    send(sock, host, port, codeunits(msg))
end

function send_td_payload(settings::Config.Settings, payload::Dict{String, Any})::Bool
    host = parse(IPAddr, settings.td_host)
    port = settings.td_port
    base = settings.td_path

    sock = UDPSocket()
    try
        _send_line(sock, host, port, string(base, "/ping"), Int(get(payload, "ping", 1)))
        _send_line(sock, host, port, string(base, "/hr"), get(payload, "hr", 0))
        _send_line(sock, host, port, string(base, "/hrv"), get(payload, "hrv", 0))
        _send_line(sock, host, port, string(base, "/br"), get(payload, "br", 0))
        _send_line(sock, host, port, string(base, "/interaction"), get(payload, "interaction", 0))
        _send_line(sock, host, port, string(base, "/reward"), get(payload, "reward", 0))
        _send_line(sock, host, port, string(base, "/trigger"), get(payload, "trigger", 0))
        _send_line(sock, host, port, string(base, "/holding"), get(payload, "holding", 0))
        _send_line(sock, host, port, string(base, "/hold_steps"), get(payload, "hold_steps", 0))
        _send_line(sock, host, port, string(base, "/hold_progress"), get(payload, "hold_progress", 0))
        println("[TD] sent hr=$(get(payload, "hr", 0)) hrv=$(get(payload, "hrv", 0)) interaction=$(get(payload, "interaction", 0)) holding=$(get(payload, "holding", 0))")
        return true
    catch e
        println("[TD] bridge error: $(string(e))")
        return false
    finally
        close(sock)
    end
end

end # module