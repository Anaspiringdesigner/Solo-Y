include("src/BiofeedbackSystem.jl")

using HTTP
using Dates
using .BiofeedbackSystem

function main()
    settings = BiofeedbackSystem.Config.load_settings()
    store = BiofeedbackSystem.SessionManager.new_store(settings)
    redis = BiofeedbackSystem.RedisStore.init_redis(settings)
    router = BiofeedbackSystem.Routes.make_router(store, redis, settings)

    println("="^70)
    println("Biofeedback Backend (Phase-2)")
    println("="^70)
    println("Host: $(settings.host)")
    println("Port: $(settings.port)")
    println("Auth mode: $(settings.auth_mode)")
    println("Redis: $(settings.redis_host):$(settings.redis_port) | available=$(redis.available)")
    println("Redis fail mode: $(settings.redis_fail_mode)")
    println("Event stream default sec: $(settings.event_stream_duration_sec)")
    println("="^70)

    @async begin
        while true
            sleep(60)
            removed = BiofeedbackSystem.SessionManager.cleanup_expired!(store)
            if removed > 0
                println("[CLEANUP] Removed expired sessions: $removed @ $(now())")
            end
        end
    end

    HTTP.serve(router, settings.host, settings.port)
end

main()