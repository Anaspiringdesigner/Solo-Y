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

function init_google_verifier!(settings::Config.Settings)
    gv = GoogleVerifier()
    _google_verifier_ref[] = gv
    try
        _refresh_jwks!(gv, settings)
        println("[AUTH] Google JWKS loaded")
    catch e
        println("[AUTH] Google JWKS preload failed: $(string(e))")
    end
    return nothing
end

function _base64url_to_bytes(s::AbstractString)
    t = replace(String(s), '-' => '+', '_' => '/')
    pad = mod(4 - mod(length(t), 4), 4)
    if pad > 0
        t *= repeat("=", pad)
    end
    return Base64.base64decode(t)
end

function _jwt_parts(token::String)
    parts = split(token, '.')
    length(parts) == 3 || error("invalid_jwt_format")
    return parts
end

function _decode_jwt_json(part::String)
    bytes = _base64url_to_bytes(part)
    return JSON3.read(String(bytes))
end

function _refresh_jwks!(gv::GoogleVerifier, settings::Config.Settings)
    resp = HTTP.get(settings.google_jwks_url)
    resp.status == 200 || error("jwks_fetch_failed:$(resp.status)")

    parsed = JSON3.read(resp.body)
    keys = haskey(parsed, "keys") ? parsed["keys"] : nothing
    keys === nothing && error("jwks_missing_keys")

    fresh = Dict{String, Any}()
    for k in keys
        kid = haskey(k, "kid") ? String(k["kid"]) : ""
        isempty(kid) && continue
        fresh[kid] = k
    end

    lock(gv.lock) do
        gv.jwks = fresh
        gv.fetched_at = now()
    end
    return nothing
end

function _ensure_fresh_jwks!(gv::GoogleVerifier, settings::Config.Settings)
    needs_refresh = lock(gv.lock) do
        gv.fetched_at === nothing || Dates.value(now() - gv.fetched_at) > settings.google_jwks_refresh_sec * 1000
    end
    if needs_refresh
        _refresh_jwks!(gv, settings)
    end
end

function _jwk_for_kid(gv::GoogleVerifier, kid::String, settings::Config.Settings)
    _ensure_fresh_jwks!(gv, settings)

    jwk = lock(gv.lock) do
        get(gv.jwks, kid, nothing)
    end

    if jwk === nothing
        _refresh_jwks!(gv, settings)
        jwk = lock(gv.lock) do
            get(gv.jwks, kid, nothing)
        end
    end

    jwk === nothing && error("unknown_kid")
    return jwk
end

function _aud_matches(aud_claim, expected::String)::Bool
    if aud_claim isa AbstractString
        return String(aud_claim) == expected
    elseif aud_claim isa AbstractVector
        return any(x -> String(x) == expected, aud_claim)
    else
        return false
    end
end

function _to_dict(x)
    if x isa Dict
        return x
    elseif x isa JSON3.Object
        return Dict{String, Any}(pairs(x))
    elseif x isa NamedTuple
        return Dict{String, Any}(string(k) => v for (k, v) in pairs(x))
    else
        error("claims_not_mappable")
    end
end

function _decode_claims_unverified(token::String)
    parts = _jwt_parts(token)
    payload = _decode_jwt_json(parts[2])
    return _to_dict(payload)
end

function _verify_signature_compat!(token::String, jwk)::Nothing
    if isdefined(JWTs, :verify)
        try
            JWTs.verify(token, jwk)
            return nothing
        catch
        end
        try
            JWTs.verify(token, JWTs.JWKSet([jwk]))
            return nothing
        catch
        end
    end

    if isdefined(JWTs, :decode)
        try
            JWTs.decode(token, jwk; validate = true)
            return nothing
        catch
        end
        try
            JWTs.decode(token, JWTs.JWKSet([jwk]); validate = true)
            return nothing
        catch
        end
        try
            JWTs.decode(token, jwk)
            return nothing
        catch
        end
        try
            JWTs.decode(token, JWTs.JWKSet([jwk]))
            return nothing
        catch
        end
    end

    error("jwt_signature_verification_api_mismatch")
end

function _verify_google_id_token(token::String, settings::Config.Settings)::String
    isempty(settings.google_audience) && error("google_audience_not_configured")

    parts = _jwt_parts(token)
    header = _decode_jwt_json(parts[1])
    kid = haskey(header, "kid") ? String(header["kid"]) : error("jwt_missing_kid")
    alg = haskey(header, "alg") ? String(header["alg"]) : ""
    alg == "RS256" || error("unsupported_jwt_alg")

    gv = _google_verifier_ref[]
    jwk = _jwk_for_kid(gv, kid, settings)

    _verify_signature_compat!(token, jwk)
    claims = _decode_claims_unverified(token)

    iss = haskey(claims, "iss") ? String(claims["iss"]) : ""
    iss in settings.google_issuers || error("invalid_issuer")

    aud_claim = haskey(claims, "aud") ? claims["aud"] : ""
    _aud_matches(aud_claim, settings.google_audience) || error("invalid_audience")

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
end

function _verify_google_id_token(token::String, settings::Config.Settings, _legacy)::String
    return _verify_google_id_token(token, settings)
end

function extract_user_id(req::HTTP.Request, settings::Config.Settings)::Union{String, Nothing}
    if settings.auth_mode != "google_id_token"
        return nothing
    end

    authz = HTTP.header(req, "Authorization", "")
    startswith(lowercase(authz), "bearer ") || return nothing

    token = strip(authz[8:end])
    isempty(token) && return nothing

    try
        return _verify_google_id_token(token, settings)
    catch e
        println("[AUTH] token verification failed: $(typeof(e)) :: $(string(e))")
        return nothing
    end
end

end # module
