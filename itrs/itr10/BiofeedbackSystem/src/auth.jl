module Auth

using HTTP
using ..Config

export extract_user_id

"""
Gateway-trusted auth:
Required headers:
  X-Verified-User-Id
  X-Gateway-Secret

Optional:
  X-Auth-Issuer
"""
function extract_user_id(req::HTTP.Request, settings::Config.Settings)::Union{String, Nothing}
    if settings.auth_mode != "gateway_verified_headers"
        return nothing
    end

    gw_secret = HTTP.header(req, "X-Gateway-Secret", "")
    if gw_secret != settings.trusted_gateway_secret
        return nothing
    end

    user_id = HTTP.header(req, "X-Verified-User-Id", "")
    isempty(user_id) && return nothing

    return user_id
end

end # module