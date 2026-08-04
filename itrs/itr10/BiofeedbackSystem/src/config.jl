module Config

export Settings, load_settings

Base.@kwdef struct Settings
    host::String = get(ENV, "BFS_HOST", "0.0.0.0")
    port::Int = parse(Int, get(ENV, "BFS_PORT", "8000"))

    session_ttl_minutes::Int = parse(Int, get(ENV, "BFS_SESSION_TTL_MIN", "30"))
    max_sessions::Int = parse(Int, get(ENV, "BFS_MAX_SESSIONS", "100"))
    idempotency_ttl_minutes::Int = parse(Int, get(ENV, "BFS_IDEMP_TTL_MIN", "120"))

    auth_mode::String = get(ENV, "BFS_AUTH_MODE", "google_id_token")
    google_client_id::String = get(
        ENV,
        "BFS_GOOGLE_CLIENT_ID",
        "760908125337-sfppi17rht5mkv6ckcm28q2g25r5ru5i.apps.googleusercontent.com",
    )

    redis_host::String = get(ENV, "BFS_REDIS_HOST", "127.0.0.1")
    redis_port::Int = parse(Int, get(ENV, "BFS_REDIS_PORT", "6379"))
    redis_fail_mode::String = get(ENV, "BFS_REDIS_FAIL_MODE", "degraded")

    event_stream_duration_sec::Int = parse(Int, get(ENV, "BFS_EVENT_STREAM_SEC", "180"))

    max_payload_bytes::Int = parse(Int, get(ENV, "BFS_MAX_PAYLOAD_BYTES", "512000"))
    ingest_rate_limit_per_min::Int = parse(Int, get(ENV, "BFS_INGEST_RATE_LIMIT_PER_MIN", "120"))
    trigger_rate_limit_per_min::Int = parse(Int, get(ENV, "BFS_TRIGGER_RATE_LIMIT_PER_MIN", "30"))
    trigger_cooldown_sec::Int = parse(Int, get(ENV, "BFS_TRIGGER_COOLDOWN_SEC", "15"))
    enforce_monotonic_seq::Bool = lowercase(get(ENV, "BFS_ENFORCE_MONO_SEQ", "true")) == "true"
end

load_settings() = Settings()

end # module