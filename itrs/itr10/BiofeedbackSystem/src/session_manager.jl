module SessionManager

using Dates
using Base.Threads: ReentrantLock
using ..Types
using ..Config

export SessionStore, new_store, get_or_create_session!, get_session, cleanup_expired!,
       mark_idempotency_local!, is_duplicate_idempotency_local!, store_stats

mutable struct SessionStore
    sessions::Dict{String, Types.SessionContext}
    idempotency_seen_local::Dict{String, DateTime}
    lock::ReentrantLock
    settings::Config.Settings
end

function new_store(settings::Config.Settings)::SessionStore
    SessionStore(
        Dict{String, Types.SessionContext}(),
        Dict{String, DateTime}(),
        ReentrantLock(),
        settings
    )
end

function get_session(store::SessionStore, user_id::String)
    lock(store.lock) do
        get(store.sessions, user_id, nothing)
    end
end

function get_or_create_session!(store::SessionStore, user_id::String)::Types.SessionContext
    lock(store.lock) do
        sess = get(store.sessions, user_id, nothing)
        if sess === nothing
            if length(store.sessions) >= store.settings.max_sessions
                error("max_sessions_reached")
            end
            sess = Types.SessionContext(user_id)
            store.sessions[user_id] = sess
        end
        sess.last_seen = now()
        return sess
    end
end

function is_duplicate_idempotency_local!(store::SessionStore, key::String)::Bool
    lock(store.lock) do
        purge_old_local!(store)
        haskey(store.idempotency_seen_local, key)
    end
end

function mark_idempotency_local!(store::SessionStore, key::String)
    lock(store.lock) do
        store.idempotency_seen_local[key] = now()
    end
end

function purge_old_local!(store::SessionStore)
    cutoff = now() - Minute(store.settings.idempotency_ttl_minutes)
    dead = String[]
    for (k, t) in store.idempotency_seen_local
        t < cutoff && push!(dead, k)
    end
    for k in dead
        delete!(store.idempotency_seen_local, k)
    end
end

function cleanup_expired!(store::SessionStore)
    lock(store.lock) do
        cutoff = now() - Minute(store.settings.session_ttl_minutes)
        dead = String[]
        for (uid, sess) in store.sessions
            sess.last_seen < cutoff && push!(dead, uid)
        end
        for uid in dead
            delete!(store.sessions, uid)
        end
        purge_old_local!(store)
        return length(dead)
    end
end

function store_stats(store::SessionStore)
    lock(store.lock) do
        Dict(
            "active_sessions" => length(store.sessions),
            "idempotency_local_cache_size" => length(store.idempotency_seen_local)
        )
    end
end

end # module