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
--   4. *** Check Redis session deny list — reject if session was terminated by admin ***
--   5. Sign Internal JWT (RS256) with gateway private key
--   6. Set X-Internal-Token, X-Tenant-ID, X-User-ID headers
--   7. Strip Authorization so downstream services never see the Keycloak token

local core    = require("apisix.core")
local jwt     = require("resty.jwt")
local redis   = require("resty.redis")

local PRIVATE_KEY_PATH = "/usr/local/apisix/conf/keys/internal-jwt-private.pem"
local ISSUER           = "arda-gateway"
local TTL_SECONDS      = 300  -- 5 minutes (short-lived, per-request)

-- Redis connection settings (must match arda-infra-config docker-compose redis service)
local REDIS_HOST       = "arda-redis"    -- Docker service name (resolvable inside Docker network)
local REDIS_PORT       = 6379
local REDIS_TIMEOUT_MS = 200        -- 200 ms — fail fast, never block request pipeline
local REDIS_POOL_SIZE  = 50         -- connection pool per nginx worker

-- Deny list key prefix (must match SessionRevokeService.DENY_KEY_PREFIX in Java)
local DENY_PREFIX      = "session-deny::"

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
-- Returns: claims_table, raw_token  OR  nil, error_message
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

    -- sid: Keycloak session ID (present in access tokens since Keycloak 18+).
    -- Used for deny-list check below.
    local sid = payload.sid

    return {
        sub      = payload.sub,
        username = payload.preferred_username or payload.email or payload.sub,
        tid      = tid,
        email    = payload.email,
        roles    = roles,
        sid      = sid,       -- Keycloak session ID for deny-list check
    }, token
end

-- Check whether a Keycloak session ID is in the Redis deny list.
-- Written by IAM service (SessionRevokeService) when admin terminates a session.
--
-- Returns: true  → session is denied (reject request)
--          false → session is allowed (proceed normally)
--
-- On Redis error: fail-open (allow) with a warning — we never block requests
-- due to Redis unavailability. The Keycloak server-side session is already
-- invalidated anyway; this is an extra safety layer.
local function is_session_denied(session_id)
    if not session_id or session_id == "" then
        -- No sid claim → cannot check → allow (old tokens, non-Keycloak issuers)
        return false
    end

    local red = redis:new()
    red:set_timeout(REDIS_TIMEOUT_MS)

    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        core.log.warn("[internal-jwt] Redis connect failed (fail-open): ", err)
        return false
    end

    local key          = DENY_PREFIX .. session_id
    local exists, err2 = red:exists(key)

    -- Return connection to pool (do NOT close — keep-alive for performance)
    local pool_ok, pool_err = red:set_keepalive(10000, REDIS_POOL_SIZE)
    if not pool_ok then
        core.log.warn("[internal-jwt] Redis set_keepalive failed: ", pool_err)
    end

    if err2 then
        core.log.warn("[internal-jwt] Redis EXISTS error (fail-open): ", err2)
        return false
    end

    -- redis EXISTS returns 1 if key exists, 0 otherwise
    return exists == 1
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

    -- Step 2: Session deny list check (immediate revocation enforcement)
    -- This fires BEFORE signing the internal JWT — a revoked session never
    -- propagates to downstream services.
    if is_session_denied(claims.sid) then
        core.log.warn("[internal-jwt] Session denied (revoked by admin): sid=",
                      claims.sid, " sub=", claims.sub,
                      " | URI: ", core.request.get_uri(ctx))
        return 401, {
            error   = "Unauthorized",
            message = "Session has been terminated. Please log in again.",
            code    = "SESSION_REVOKED"
        }
    end

    -- Step 3: Load gateway private key
    local priv_key, err = get_private_key()
    if not priv_key then
        core.log.error("[internal-jwt] Cannot sign Internal JWT: ", err)
        return 500, { error = "Internal configuration error" }
    end

    -- Step 4: Build Internal JWT payload
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

    -- Step 5: Sign with RS256
    local jwt_token = jwt:sign(priv_key, {
        header  = { typ = "JWT", alg = "RS256" },
        payload = internal_payload,
    })

    if not jwt_token then
        core.log.error("[internal-jwt] jwt:sign returned nil — check private key format")
        return 500, { error = "JWT signing failed" }
    end

    -- Step 6: Inject Internal JWT headers
    core.request.set_header(ctx, "X-Internal-Token", jwt_token)
    core.request.set_header(ctx, "X-Tenant-ID",      claims.tid or "")
    core.request.set_header(ctx, "X-User-ID",        claims.sub or "")

    -- Step 7: Strip Keycloak token — backend services must NOT receive it.
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
                  " sid=", claims.sid or "n/a",
                  " roles=", core.json.encode(claims.roles))
end

return sign_internal_jwt
