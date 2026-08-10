module Config

export Settings, load_settings

Base.@kwdef struct Settings
    host::String = get(ENV, "BFS_HOST", "0.0.0.0")
    port::Int = parse(Int, get(ENV, "BFS_PORT", "8000"))

    session_ttl_minutes::Int = parse(Int, get(ENV, "BFS_SESSION_TTL_MIN", "1440"))
    max_sessions::Int = parse(Int, get(ENV, "BFS_MAX_SESSIONS", "100"))
    idempotency_ttl_minutes::Int = parse(Int, get(ENV, "BFS_IDEMP_TTL_MIN", "120"))

    auth_mode::String = get(ENV, "BFS_AUTH_MODE", "google_id_token")
    google_audience::String = get(
        ENV,
        "BFS_GOOGLE_AUDIENCE",
        "760908125337-sfppi17rht5mkv6ckcm28q2g25r5ru5i.apps.googleusercontent.com",
    )
    google_issuers::Vector{String} = split(
        get(ENV, "BFS_GOOGLE_ISSUERS", "https://accounts.google.com,accounts.google.com"),
        ","
    )
    google_jwks_url::String = get(ENV, "BFS_GOOGLE_JWKS_URL", "https://www.googleapis.com/oauth2/v3/certs")
    google_jwks_refresh_sec::Int = parse(Int, get(ENV, "BFS_GOOGLE_JWKS_REFRESH_SEC", "3600"))
    google_clock_skew_sec::Int = parse(Int, get(ENV, "BFS_GOOGLE_CLOCK_SKEW_SEC", "120"))

    redis_host::String = get(ENV, "BFS_REDIS_HOST", "127.0.0.1")
    redis_port::Int = parse(Int, get(ENV, "BFS_REDIS_PORT", "6379"))
    redis_fail_mode::String = get(ENV, "BFS_REDIS_FAIL_MODE", "degraded")

    event_stream_duration_sec::Int = parse(Int, get(ENV, "BFS_EVENT_STREAM_SEC", "180"))
    batch_window_minutes::Int = parse(Int, get(ENV, "BFS_BATCH_WINDOW_MIN", "30"))
    bio_trigger_lookback_minutes::Int = parse(Int, get(ENV, "BFS_BIO_LOOKBACK_MIN", "30"))

    max_payload_bytes::Int = parse(Int, get(ENV, "BFS_MAX_PAYLOAD_BYTES", "512000"))
    ingest_rate_limit_per_min::Int = parse(Int, get(ENV, "BFS_INGEST_RATE_LIMIT_PER_MIN", "120"))
    trigger_rate_limit_per_min::Int = parse(Int, get(ENV, "BFS_TRIGGER_RATE_LIMIT_PER_MIN", "30"))
    trigger_cooldown_sec::Int = parse(Int, get(ENV, "BFS_TRIGGER_COOLDOWN_SEC", "15"))
    enforce_monotonic_seq::Bool = lowercase(get(ENV, "BFS_ENFORCE_MONO_SEQ", "true")) == "true"

    td_host::String = get(ENV, "BFS_TD_HOST", "127.0.0.1")
    td_port::Int = parse(Int, get(ENV, "BFS_TD_PORT", "9980"))
    td_path::String = get(ENV, "BFS_TD_PATH", "/biofeedback")

    bio_stress_threshold::Float64 = parse(Float64, get(ENV, "BFS_BIO_STRESS_THRESHOLD", "0.65"))
end

load_settings() = Settings()

end # module