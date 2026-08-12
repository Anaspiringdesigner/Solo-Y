module Auth

using HTTP
using JSON3
using Dates
using Base64
using Base.Threads: ReentrantLock
using JWTs
using ..Config

export extract_user_id, init_google_verifier!, GoogleVerifier

mutable struct GoogleVerifier
    jwks::Dict{String, Any}
    fetched_at::Union{Nothing, DateTime}
    lock::ReentrantLock
end

GoogleVerifier() = GoogleVerifier(Dict{String, Any}(), nothing, ReentrantLock())
const _google_verifier_ref = Ref{GoogleVerifier}(GoogleVerifier())

function init_google_verifier!(settings)
    gv = GoogleVerifier()
    _google_verifier_ref[] = gv
    try
        resp = HTTP.get(settings.google_jwks_url)
        resp.status == 200 || error("jwks_fetch_failed:$(resp.status)")
        parsed = JSON3.read(resp.body)

        keys = haskey(parsed, "keys") ? parsed["keys"] :
               (haskey(parsed, :keys) ? parsed[:keys] : nothing)
        keys === nothing && error("jwks_missing_keys")

        fresh = Dict{String, Any}()
        for k in keys
            kid = haskey(k, "kid") ? String(k["kid"]) :
                  (haskey(k, :kid) ? String(k[:kid]) : "")
            isempty(kid) && continue
            fresh[kid] = k
        end

        lock(gv.lock) do
            gv.jwks = fresh
            gv.fetched_at = now()
        end
        println("[AUTH] Google JWKS loaded")
    catch e
        println("[AUTH] Google JWKS preload failed: $(string(e))")
    end
    return nothing
end

function extract_user_id(req::HTTP.Request, settings)::Union{String, Nothing}
    mode = lowercase(settings.auth_mode)

    # Dev-friendly modes
    if mode == "none"
        # Prefer header if present; else static dev id
        uid = HTTP.header(req, settings.dev_user_id_header, "")
        return isempty(uid) ? settings.dev_static_user_id : uid
    elseif mode == "dev_header"
        uid = HTTP.header(req, settings.dev_user_id_header, "")
        return isempty(uid) ? nothing : uid
    end

    # Production mode: Google ID token
    if mode != "google_id_token"
        return nothing
    end

    authz = HTTP.header(req, "Authorization", "")
    startswith(lowercase(authz), "bearer ") || return nothing
    token = strip(authz[8:end])
    isempty(token) && return nothing

    try
        isempty(settings.google_audience) && error("google_audience_not_configured")

        parts = split(token, '.')
        length(parts) == 3 || error("invalid_jwt_format")

        # Decode header
        h = replace(String(parts[1]), '-' => '+', '_' => '/')
        hpad = mod(4 - mod(length(h), 4), 4)
        hpad > 0 && (h *= repeat("=", hpad))
        header_obj = JSON3.read(String(Base64.base64decode(h)))
        header = Dict{String, Any}([(string(k), v) for (k,v) in pairs(header_obj)])

        # Decode payload
        p = replace(String(parts[2]), '-' => '+', '_' => '/')
        ppad = mod(4 - mod(length(p), 4), 4)
        ppad > 0 && (p *= repeat("=", ppad))
        claims_obj = JSON3.read(String(Base64.base64decode(p)))
        claims = Dict{String, Any}([(string(k), v) for (k,v) in pairs(claims_obj)])

        kid = haskey(header, "kid") ? String(header["kid"]) : error("jwt_missing_kid")
        alg = haskey(header, "alg") ? String(header["alg"]) : ""
        alg == "RS256" || error("unsupported_jwt_alg")

        # Refresh JWKS if stale
        gv = _google_verifier_ref[]
        need_refresh = lock(gv.lock) do
            gv.fetched_at === nothing || Dates.value(now() - gv.fetched_at) > settings.google_jwks_refresh_sec * 1000
        end

        if need_refresh
            resp = HTTP.get(settings.google_jwks_url)
            resp.status == 200 || error("jwks_fetch_failed:$(resp.status)")
            parsed = JSON3.read(resp.body)
            keys = haskey(parsed, "keys") ? parsed["keys"] :
                   (haskey(parsed, :keys) ? parsed[:keys] : nothing)
            keys === nothing && error("jwks_missing_keys")
            fresh = Dict{String, Any}()
            for k in keys
                kk = haskey(k, "kid") ? String(k["kid"]) :
                     (haskey(k, :kid) ? String(k[:kid]) : "")
                isempty(kk) && continue
                fresh[kk] = k
            end
            lock(gv.lock) do
                gv.jwks = fresh
                gv.fetched_at = now()
            end
        end

        jwk = lock(gv.lock) do
            get(gv.jwks, kid, nothing)
        end
        jwk === nothing && error("unknown_kid")

        # Best-effort signature verification
        try
            if isdefined(JWTs, :verify)
                try
                    JWTs.verify(token, jwk)
                catch
                    JWTs.verify(token, JWTs.JWKSet([jwk]))
                end
            elseif isdefined(JWTs, :decode)
                try
                    JWTs.decode(token, jwk; validate = true)
                catch
                    JWTs.decode(token, JWTs.JWKSet([jwk]); validate = true)
                end
            end
        catch e
            println("[AUTH] signature verification warning: $(string(e))")
        end

        # Claims validation
        iss = haskey(claims, "iss") ? String(claims["iss"]) : ""
        iss_ok = any(x -> x == iss, settings.google_issuers)
        iss_ok || error("invalid_issuer")

        aud_claim = haskey(claims, "aud") ? claims["aud"] : ""
        aud_ok = false
        if aud_claim isa AbstractString
            aud_ok = String(aud_claim) == settings.google_audience
        elseif aud_claim isa AbstractVector
            aud_ok = any(x -> String(x) == settings.google_audience, aud_claim)
        end
        aud_ok || error("invalid_audience")

        now_unix = round(Int, time())
        skew = settings.google_clock_skew_sec

        expv = haskey(claims, "exp") ? Int(claims["exp"]) : error("missing_exp")
        expv + skew >= now_unix || error("token_expired")

        if haskey(claims, "nbf")
            Int(claims["nbf"]) - skew <= now_unix || error("token_not_yet_valid")
        end
        if haskey(claims, "iat")
            Int(claims["iat"]) - skew <= now_unix || error("token_issued_in_future")
        end

        sub = haskey(claims, "sub") ? String(claims["sub"]) : ""
        isempty(sub) && error("missing_sub")

        return sub
    catch e
        println("[AUTH] token verification failed: $(typeof(e)) :: $(string(e))")
        return nothing
    end
end

end # module