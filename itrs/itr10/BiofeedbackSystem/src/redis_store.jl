module RedisStore

using Dates
using Sockets
using ..Config

export RedisClient, init_redis, redis_available,
       idem_seen, idem_mark!,
       session_touch!, session_ttl_key!, redis_stats

mutable struct RedisClient
    host::String
    port::Int
    available::Bool
    last_error::Union{Nothing, String}
end

function init_redis(settings::Config.Settings)::RedisClient
    rc = RedisClient(settings.redis_host, settings.redis_port, false, nothing)
    rc.available = ping(rc)
    return rc
end

redis_available(rc::RedisClient) = rc.available

# --- very small RESP helper ---
function _redis_cmd(rc::RedisClient, parts::Vector{String})
    sock = connect(rc.host, rc.port)
    try
        req = "*$(length(parts))\r\n" * join(["\$$(ncodeunits(p))\r\n$(p)\r\n" for p in parts], "")
        write(sock, req)
        flush(sock)
        resp = String(readavailable(sock))
        return resp
    finally
        close(sock)
    end
end

function ping(rc::RedisClient)::Bool
    try
        resp = _redis_cmd(rc, ["PING"])
        rc.last_error = nothing
        return occursin("PONG", resp)
    catch e
        rc.last_error = string(e)
        return false
    end
end

function idem_seen(rc::RedisClient, key::String)::Union{Nothing, Bool}
    try
        resp = _redis_cmd(rc, ["EXISTS", key])
        # :1 or :0
        return occursin(":1", resp)
    catch e
        rc.available = false
        rc.last_error = string(e)
        return nothing
    end
end

function idem_mark!(rc::RedisClient, key::String, ttl_sec::Int)::Bool
    try
        # SET key 1 EX ttl NX
        resp = _redis_cmd(rc, ["SET", key, "1", "EX", string(ttl_sec), "NX"])
        return occursin("+OK", resp) || occursin("\$-1", resp) == false
    catch e
        rc.available = false
        rc.last_error = string(e)
        return false
    end
end

function session_touch!(rc::RedisClient, user_id::String, ttl_sec::Int)::Bool
    try
        key = "session:active:" * user_id
        _redis_cmd(rc, ["SET", key, string(Dates.now()), "EX", string(ttl_sec)])
        return true
    catch e
        rc.available = false
        rc.last_error = string(e)
        return false
    end
end

function session_ttl_key!(rc::RedisClient, user_id::String)::String
    return "session:active:" * user_id
end

function redis_stats(rc::RedisClient)
    return Dict(
        "available" => rc.available,
        "host" => rc.host,
        "port" => rc.port,
        "last_error" => rc.last_error
    )
end

end # module