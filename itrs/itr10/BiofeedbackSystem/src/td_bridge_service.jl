module TDBridgeService

using HTTP
using JSON3
using ..Config

export send_td_payload

function send_td_payload(settings::Config.Settings, payload::Dict{String, Any})::Bool
    url = "http://$(settings.td_host):$(settings.td_port)$(settings.td_path)"
    try
        resp = HTTP.post(
            url,
            ["Content-Type" => "application/json"],
            JSON3.write(payload),
        )
        ok = 200 <= resp.status < 300
        println("[TD] status=$(resp.status) ok=$(ok) url=$(url)")
        return ok
    catch e
        println("[TD] bridge error: $(string(e))")
        return false
    end
end

end # module