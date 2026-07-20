using Oxygen
using HTTP
using ReentrantLock

const USER_SESSIONS = Dict{String, Any}()
const MAX_USERS = 10
const SESSION_LOCK = ReentrantLock()

function handle_websocket(session_id)
    if length(USER_SESSIONS) >= MAX_USERS
        return "Maximum number of users reached"
    end

    try
        lock(SESSION_LOCK) do
            USER_SESSIONS[session_id] = Dict{String, Any}()
        end

        while true
            msg = HTTP.get_message()
            if msg === nothing
                break
            end
            payload = JSON.parse(msg.body)
            # Process payload and update RL environment state
            # ...
        end
    finally
        lock(SESSION_LOCK) do
            delete!(USER_SESSIONS, session_id)
        end
    end
end

function main()
    HTTP.server("0.0.0.0:8080") do req, res
        if HTTP.method(req) == :GET && HTTP.path(req) == "/stream/{session_id}"
            session_id = HTTP.url_params(req)["session_id"]
            HTTP.respond(res, 200, "WebSocket connection established")
            handle_websocket(session_id)
        else
            HTTP.respond(res, 404, "Not found")
        end
    end
end

main()