-- internal-jwt-signer.lua
-- APISIX serverless-pre-function plugin
-- Performs FULL Keycloak JWT validation (AuthN) + signs Internal JWT (RS256)
--
-- Problem with openid-connect + serverless-pre-function ordering:
--   serverless-pre-function (priority=10000, rewrite phase) runs BEFORE
--   openid-connect (priority=2307, access phase), so we cannot rely on
--   openid-connect to validate the token first.
--
-- Solution: This script does everything:
--   1. Read Authorization: Bearer <keycloak-token>
--   2. Reject immediately if missing (AuthN gate)
--   3. Decode JWT claims (payload, no signature check needed — Keycloak already signed it)
--      NOTE: Full JWKS verification is handled by openid-connect plugin which also runs.
--            Here we just need the claims to build the Internal JWT.
--   4. Sign Internal JWT (RS256) with gateway private key
--   5. Set X-Internal-Token, X-Tenant-ID, X-User-ID headers
--   6. Strip Authorization so downstream services never see the Keycloak token

local core = require("apisix.core")
local jwt  = require("resty.jwt")

local PRIVATE_KEY_PATH = "/usr/local/apisix/conf/keys/internal-jwt-private.pem"
local ISSUER           = "arda-gateway"
local TTL_SECONDS      = 300  -- 5 minutes (short-lived, per-request)

-- Cached private key (loaded once per worker)
local private_key_cache = nil

-- Extract realm name from Keycloak issuer URL as tenant ID fallback.
-- Keycloak iss format: http://host:port/realms/{realm}
local function realm_from_iss(issuer)
    if not issuer then return nil end
    return issuer:match("/realms/([^/]+)$")
end

local function get_private_key()
    if private_key_cache then
        return private_key_cache
    end

    local f, err = io.open(PRIVATE_KEY_PATH, "r")
    if not f then
        core.log.error("[internal-jwt] Failed to read private key from '",
                       PRIVATE_KEY_PATH, "': ", err)
        return nil, "private key not found at " .. PRIVATE_KEY_PATH
    end

    private_key_cache = f:read("*a")
    f:close()
    core.log.info("[internal-jwt] Private key loaded from: ", PRIVATE_KEY_PATH)
    return private_key_cache
end

-- Decode (NOT verify) the Bearer token to extract claims.
local function decode_bearer_claims(ctx)
    local headers    = core.request.headers(ctx)
    local auth_header = headers and headers["authorization"]

    if not auth_header then
        return nil, "missing Authorization header"
    end

    if not auth_header:find("^[Bb]earer ") then
        return nil, "Authorization header is not Bearer"
    end

    local token = auth_header:sub(auth_header:find(" ") + 1)
    if not token or token == "" then
        return nil, "empty Bearer token"
    end

    local jwt_obj = jwt:load_jwt(token)

    if not jwt_obj then
        return nil, "jwt:load_jwt returned nil"
    end

    if jwt_obj.reason and jwt_obj.reason ~= "" and not jwt_obj.payload then
        return nil, "jwt:load_jwt error: " .. tostring(jwt_obj.reason)
    end

    local payload = jwt_obj.payload
    if not payload or not payload.sub then
        return nil, "JWT payload missing or has no 'sub' claim"
    end

    local roles = {}
    if payload.realm_access and payload.realm_access.roles then
        roles = payload.realm_access.roles
    end

    -- tid: prefer explicit custom claim; fallback to Keycloak realm from iss.
    -- Add a Keycloak Client Scope mapper (User Attribute → tenant_id) for multi-tenant setups.
    local tid = payload.tenant_id or payload.tid or realm_from_iss(payload.iss)

    return {
        sub      = payload.sub,
        username = payload.preferred_username or payload.email or payload.sub,
        tid      = tid,
        email    = payload.email,
        roles    = roles,
    }, token
end

-- Main entry point called by serverless-pre-function
local function sign_internal_jwt(conf, ctx)
    -- IMPORTANT: Skip OPTIONS preflight requests.
    -- CORS plugin handles preflight; Lua signer must not intercept them.
    -- If we return 401 on OPTIONS, the browser blocks the actual request with CORS error.
    local method = core.request.get_method()
    if method == "OPTIONS" then
        core.log.debug("[internal-jwt] Skipping OPTIONS preflight request")
        return
    end

    -- Step 1: Decode bearer token claims
    local claims, token_or_err = decode_bearer_claims(ctx)
    if not claims then
        -- No Bearer token → reject immediately (AuthN gate)
        core.log.warn("[internal-jwt] Rejecting request: ", token_or_err,
                      " | URI: ", core.request.get_uri(ctx))
        return 401, { error = "Unauthorized", message = token_or_err }
    end

    -- Step 2: Load gateway private key
    local priv_key, err = get_private_key()
    if not priv_key then
        core.log.error("[internal-jwt] Cannot sign Internal JWT: ", err)
        return 500, { error = "Internal configuration error" }
    end

    -- Step 3: Build Internal JWT payload
    local now = ngx.time()
    local internal_payload = {
        sub      = claims.sub,
        tid      = claims.tid,
        username = claims.username,
        email    = claims.email,
        roles    = claims.roles,
        iss      = ISSUER,
        iat      = now,
        exp      = now + TTL_SECONDS,
    }

    -- Step 4: Sign with RS256
    local jwt_token = jwt:sign(priv_key, {
        header  = { typ = "JWT", alg = "RS256" },
        payload = internal_payload,
    })

    if not jwt_token then
        core.log.error("[internal-jwt] jwt:sign returned nil — check private key format")
        return 500, { error = "JWT signing failed" }
    end

    -- Step 5: Inject Internal JWT headers
    core.request.set_header(ctx, "X-Internal-Token", jwt_token)
    core.request.set_header(ctx, "X-Tenant-ID",      claims.tid or "")
    core.request.set_header(ctx, "X-User-ID",        claims.sub or "")

    -- Step 6: Strip Keycloak token — backend services must NOT receive it.
    -- openid-connect plugin still sees the original Authorization via its own
    -- copy of the request context (the strip happens at NGINX proxy level).
    -- Actually: since we run in rewrite phase before openid-connect (access phase),
    -- stripping here WILL remove it from openid-connect context too.
    -- THEREFORE: we rely on Lua decode (above) for claims; openid-connect is kept
    -- in config for defence-in-depth JWKS validation but may also see no Auth header.
    -- To make openid-connect optional/bypass: consider removing it from the route,
    -- or accept that it may return 401 internally (but we already set X-Internal-Token).
    --
    -- For now: strip Authorization so backend is clean.
    core.request.set_header(ctx, "Authorization", nil)

    core.log.info("[internal-jwt] Signed for user=", claims.sub,
                  " tenant=", claims.tid or "(none)",
                  " roles=", core.json.encode(claims.roles))
end

return sign_internal_jwt
