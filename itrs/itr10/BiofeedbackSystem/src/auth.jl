module Auth

using HTTP
using JSON3
using Base64
using SHA
using ..Config

export extract_user_id

const GOOGLE_CERTS_URL = "https://www.googleapis.com/oauth2/v3/certs"

function _b64url_decode(input::AbstractString)
    s = replace(String(input), '-' => '+', '_' => '/')
    pad = mod(4 - mod(length(s), 4), 4)
    if pad > 0
        s *= "="^pad
    end
    return base64decode(s)
end

function _parse_jwt(token::String)
    parts = split(token, '.')
    length(parts) == 3 || error("invalid_jwt_format")

    header_json = String(_b64url_decode(parts[1]))
    payload_json = String(_b64url_decode(parts[2]))
    sig = _b64url_decode(parts[3])

    header = JSON3.read(header_json)
    payload = JSON3.read(payload_json)
    signing_input = codeunits(parts[1] * "." * parts[2])

    return header, payload, sig, signing_input
end

function _json_get_str(obj, key::String, default::String = "")
    haskey(obj, key) ? String(obj[key]) : default
end

function _aud_matches(aud_value, expected::String)
    if aud_value isa AbstractString
        return String(aud_value) == expected
    elseif aud_value isa AbstractVector
        return any(x -> String(x) == expected, aud_value)
    end
    return false
end

function _check_times(payload)
    now_unix = time()
    expv = haskey(payload, "exp") ? Float64(payload["exp"]) : 0.0
    iatv = haskey(payload, "iat") ? Float64(payload["iat"]) : 0.0

    expv > 0 || error("missing_exp")
    now_unix <= expv + 60 || error("token_expired")
    iatv == 0.0 || iatv <= now_unix + 300 || error("token_iat_invalid")
end

function _verify_google_id_token(token::String, settings::Config.Settings)
    header, payload, sig, signing_input = _parse_jwt(token)

    alg = _json_get_str(header, "alg")
    alg == "RS256" || error("unsupported_alg")

    iss = _json_get_str(payload, "iss")
    iss in ("accounts.google.com", "https://accounts.google.com") || error("invalid_issuer")

    _aud_matches(payload["aud"], settings.google_client_id) || error("invalid_audience")
    _check_times(payload)

    sub = _json_get_str(payload, "sub")
    isempty(sub) && error("missing_sub")

    # NOTE:
    # For a production-hard verification path in Julia, use a JWT/JWK verification
    # library or implement RSA signature validation against Google's JWK cert set.
    # This step currently validates token structure + issuer + audience + timing.
    # Add cryptographic signature verification before production launch.

    return sub
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
    catch
        return nothing
    end
end

end # module