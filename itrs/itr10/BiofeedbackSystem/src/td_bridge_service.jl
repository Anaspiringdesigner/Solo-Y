module TDBridgeService

using Sockets
using ..Config

export send_td_payload, trigger_code

function trigger_code(trigger_type::AbstractString)::Int
    t = lowercase(String(trigger_type))
    t == "manual" && return 1
    t == "calendar" && return 2
    t == "bio" && return 3
    t == "system" && return 4
    return 0
end

function _send_line(sock::UDPSocket, host::IPAddr, port::Int, path::String, value)
    msg = string(path, " ", value)
    send(sock, host, port, codeunits(msg))
end

function send_td_payload(payload::Dict, settings::Config.Settings)::Bool
    try
        host = parse(IPAddr, settings.td_host)
        port = settings.td_port
        base = settings.td_path

        hr = get(payload, "hr", 0)
        hrv = get(payload, "hrv", 0)
        inter = get(payload, "interaction", 0)
        holding = get(payload, "holding", false) ? 1 : 0
        hold_left = get(payload, "hold_steps_left", 0)
        score = get(payload, "score", 0)
        trig = trigger_code(get(payload, "trigger_type", "none"))

        sock = UDPSocket()
        try
            _send_line(sock, host, port, string(base, "/hr"), hr)
            _send_line(sock, host, port, string(base, "/hrv"), hrv)
            _send_line(sock, host, port, string(base, "/interaction"), inter)
            _send_line(sock, host, port, string(base, "/holding"), holding)
            _send_line(sock, host, port, string(base, "/hold_steps_left"), hold_left)
            _send_line(sock, host, port, string(base, "/score"), score)
            _send_line(sock, host, port, string(base, "/trigger_code"), trig)
        finally
            close(sock)
        end

        println("[TD] sent hr=$(hr) hrv=$(hrv) interaction=$(inter) holding=$(holding)")
        return true
    catch e
        println("[TD] send failed: $(string(e))")
        return false
    end
end

end