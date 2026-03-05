# APISIX Gateway Configuration Script (V2)
# Configures routes with:
# - openid-connect plugin for Keycloak AuthN
# - serverless-pre-function for Internal JWT signing
# - CORS and proxy-rewrite

$ErrorActionPreference = "Stop"

$APISIX_ADMIN = if ($env:APISIX_ADMIN_URL) { $env:APISIX_ADMIN_URL } else { "http://localhost:9180" }
$ADMIN_KEY    = if ($env:APISIX_ADMIN_KEY)  { $env:APISIX_ADMIN_KEY }  else { "edd1c9f034335f136f87ad84b625c8f1" }

# Keycloak configuration
$KEYCLOAK_URL       = if ($env:KEYCLOAK_URL)       { $env:KEYCLOAK_URL }       else { "http://arda-keycloak:8080" }
$KEYCLOAK_REALM     = if ($env:KEYCLOAK_REALM)     { $env:KEYCLOAK_REALM }     else { "master" }
$KEYCLOAK_CLIENT_ID = if ($env:KEYCLOAK_CLIENT_ID) { $env:KEYCLOAK_CLIENT_ID } else { "arda-gateway" }

$headers = @{
    "X-API-KEY"    = $ADMIN_KEY
    "Content-Type" = "application/json"
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ARDA APISIX GATEWAY SETUP (V2 — Internal JWT)" -ForegroundColor Cyan
Write-Host "  Admin URL:     $APISIX_ADMIN" -ForegroundColor Cyan
Write-Host "  Keycloak URL:  $KEYCLOAK_URL" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ── Lua signer: load and pre-escape as a JSON string ─────────────────────────
# We must NOT put the Lua code into a hashtable and call ConvertTo-Json — that
# causes an OutOfMemoryException in PS 5.x for large strings with special chars.
# Instead we JSON-escape it once upfront using JavaScriptSerializer, then splice
# the resulting quoted string directly into manually-built JSON bodies.
$LuaSignerPath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "apisix") (Join-Path "plugins" "internal-jwt-signer.lua")
$LuaSignerJson = "null"   # default: no Lua, will be omitted from routes
if (Test-Path $LuaSignerPath) {
    $luaRaw = Get-Content $LuaSignerPath -Raw
    Add-Type -AssemblyName System.Web.Extensions
    $jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $jss.MaxJsonLength = [int]::MaxValue
    $LuaSignerJson = $jss.Serialize($luaRaw)   # produces a properly-escaped JSON string literal
    Write-Host "--> Loaded Lua signer ($($luaRaw.Length) bytes)" -ForegroundColor Green
} else {
    Write-Host "--> WARNING: Lua signer not found at $LuaSignerPath. Routes will be without Internal JWT." -ForegroundColor Yellow
}

# ── OpenID Connect plugin config (serialised once, reused) ───────────────────
$oidcPluginConfig = @{
    client_id                              = $KEYCLOAK_CLIENT_ID
    client_secret                          = "arda-gateway-secret-123"
    discovery                              = "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/.well-known/openid-configuration"

    bearer_only                            = $true
    introspection_endpoint_auth_method     = "client_secret_post"
    set_userinfo_header                    = $false
    set_id_token_header                    = $false
    set_access_token_header                = $false
}
$oidcJson = $oidcPluginConfig | ConvertTo-Json -Compress   # safe — no problematic strings


# ── Helper: build "plugins" JSON block (with optional Lua signer) ─────────────
# PHASE ORDER:
#   rewrite: serverless-pre-function (priority 10000)
#            — Lua signer reads Authorization Bearer, decodes Keycloak JWT claims,
#              signs Internal JWT (RS256), sets X-Internal-Token, strips Authorization.
#   rewrite: proxy-rewrite (priority 1008)
#            — rewrites URI path for upstream service.
#   access:  cors (CORS preflight handling)
# Result: backend receives X-Internal-Token, X-Tenant-ID, X-User-ID. No Keycloak token.
function Build-Plugins-Json([string]$proxyRewriteJson) {
    $corsJson = '{"allow_origins":"**","allow_methods":"**","allow_headers":"**","expose_headers":"**","allow_credential":true,"max_age":3600}'
    $base = "{""proxy-rewrite"":$proxyRewriteJson,""cors"":$corsJson"
    if ($LuaSignerJson -ne "null") {
        $base += ",""serverless-pre-function"":{""phase"":""rewrite"",""functions"":[$LuaSignerJson]}"
    } else {
        # No Lua signer available — fallback to openid-connect for AuthN
        # WARNING: This mode is less secure (Keycloak token forwarded to backend)
        Write-Host "    WARNING: Using openid-connect fallback (no Lua signer)" -ForegroundColor Yellow
        $base += ",""openid-connect"":$oidcJson"
    }
    return $base + "}"
}

# ── Helper: PUT a route ───────────────────────────────────────────────────────
function Put-Route([string]$id, [string]$body) {
    try {
        Invoke-RestMethod -Method Put -Uri "$APISIX_ADMIN/apisix/admin/routes/$id" `
            -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
        Write-Host "    OK" -ForegroundColor Green
    } catch {
        Write-Host "    FAILED: $_" -ForegroundColor Red
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Host "    Response: $responseBody" -ForegroundColor DarkRed
        }
    }
}


# ── Helper: Create Authenticated Route ────────────────────────────────────────
function Setup-Authenticated-Route {
    param (
        [string]$Id,
        [string]$Name,
        [string]$UriPath,
        [string]$TargetHost,
        [int]$TargetPort,
        [string]$RewritePrefix = ""
    )

    Write-Host "--> Configuring service: $Name ($Id) [AuthN Enabled]" -ForegroundColor Yellow

    $rewriteJson = "{""regex_uri"":[""^$UriPath(.*)"",""$RewritePrefix`$1""]}"
    $pluginsJson  = Build-Plugins-Json $rewriteJson
    $upstream = @{ type = "roundrobin"; nodes = @{ "${TargetHost}:${TargetPort}" = 1 } } | ConvertTo-Json -Compress
    $body = "{""name"":""$Name"",""uri"":""$UriPath/*"",""plugins"":$pluginsJson,""upstream"":$upstream}"

    Put-Route -id $Id -body $body
}

# ── Helper: Create Public Route (no AuthN) ────────────────────────────────────
function Setup-Public-Route {
    param (
        [string]$Id,
        [string]$Name,
        [string]$UriPath,
        [string]$TargetHost,
        [int]$TargetPort,
        [string]$RewritePrefix = ""
    )

    Write-Host "--> Configuring service: $Name ($Id) [Public]" -ForegroundColor Yellow

    $corsJson = '{"allow_origins":"**","allow_methods":"**","allow_headers":"**","expose_headers":"**","allow_credential":true,"max_age":3600}'
    $pluginsJson = "{""proxy-rewrite"":{""regex_uri"":[""^$UriPath(.*)"",""$RewritePrefix`$1""]},""cors"":$corsJson}"
    $upstream    = @{ type = "roundrobin"; nodes = @{ "${TargetHost}:${TargetPort}" = 1 } } | ConvertTo-Json -Compress
    $body = "{""name"":""$Name"",""uri"":""$UriPath/*"",""plugins"":$pluginsJson,""upstream"":$upstream}"

    Put-Route -id $Id -body $body
}

# ============================================================
# --- Authenticated Routes (Gateway AuthN + Internal JWT) ---
# ============================================================

# 1. Central Platform (Port 8000)
Setup-Authenticated-Route -Id "arda-central" -Name "Central Platform" -UriPath "/api/central" -TargetHost "host.docker.internal" -TargetPort 8000

# 2. IAM Service (Port 8001)
Setup-Authenticated-Route -Id "arda-iam" -Name "IAM Service" -UriPath "/api/iam" -TargetHost "host.docker.internal" -TargetPort 8001

# 3. CRM Service (Port 8010)
Setup-Authenticated-Route -Id "arda-crm" -Name "CRM Service" -UriPath "/api/crm" -TargetHost "host.docker.internal" -TargetPort 8010

# 4. BPM Service (Port 8020)
Setup-Authenticated-Route -Id "arda-bpm" -Name "BPM Service" -UriPath "/api/bpm" -TargetHost "host.docker.internal" -TargetPort 8020

# ============================================================
# --- Special Routes ---
# ============================================================

# 5. Notification Service (Port 8090) — SSE + REST
Write-Host "--> Configuring service: Notification Service [AuthN Enabled]" -ForegroundColor Yellow

# SSE Upstream (Long Timeout)
$sseUpstream = @{
    id      = "up-notif-sse"
    name    = "Notification SSE"
    type    = "roundrobin"
    nodes   = @{ "arda-notification:8090" = 1 }
    timeout = @{ connect = 6; send = 3600; read = 3600 }
} | ConvertTo-Json
Invoke-RestMethod -Method Put -Uri "$APISIX_ADMIN/apisix/admin/upstreams/up-notif-sse" -Headers $headers -Body $sseUpstream | Out-Null

# SSE Route (with AuthN)
$ssePluginsJson = Build-Plugins-Json '{"uri":"/notifications/stream"}'
$sseBody = "{""id"":""notif-sse"",""uri"":""/api/notifications/stream"",""upstream_id"":""up-notif-sse"",""plugins"":$ssePluginsJson}"
try {
    Invoke-RestMethod -Method Put -Uri "$APISIX_ADMIN/apisix/admin/routes/notif-sse" `
        -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($sseBody)) | Out-Null
} catch { Write-Host "    SSE route FAILED: $_" -ForegroundColor Red }

# REST Route (with AuthN)
$notifPluginsJson = Build-Plugins-Json '{"regex_uri":["/api/notifications(.*)","\/notifications$1"]}'
$notifUpstream    = '{"type":"roundrobin","nodes":{"arda-notification:8090":1}}'
$notifBody = "{""id"":""notif-rest"",""uris"":[""/api/notifications"",""/api/notifications/*""]," +
             """upstream"":$notifUpstream,""plugins"":$notifPluginsJson}"
try {
    Invoke-RestMethod -Method Put -Uri "$APISIX_ADMIN/apisix/admin/routes/notif-rest" `
        -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($notifBody)) | Out-Null
} catch { Write-Host "    Notif REST route FAILED: $_" -ForegroundColor Red }

Write-Host "    OK" -ForegroundColor Green

# ============================================================
# --- Public Routes (no AuthN) ---
# ============================================================

# 6. Public Tenant Lookup (for login page tenant validation)
Setup-Public-Route -Id "arda-central-public" -Name "Central Platform Public" -UriPath "/api/central/v1/public" -TargetHost "host.docker.internal" -TargetPort 8000 -RewritePrefix "/v1/public"

# 7. Frontend Shell (Domain wildcard)
Write-Host "--> Configuring route: Frontend Shell (*.arda.io.vn) [Public]" -ForegroundColor Yellow
$feBody = @{
    id       = "frontend-shell"
    hosts    = @("*.arda.io.vn")
    uri      = "/*"
    upstream = @{
        type  = "roundrobin"
        nodes = @{ "host.docker.internal:3000" = 1 }
    }
} | ConvertTo-Json
Invoke-RestMethod -Method Put -Uri "$APISIX_ADMIN/apisix/admin/routes/frontend-shell" -Headers $headers -Body $feBody | Out-Null
Write-Host "    OK" -ForegroundColor Green

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SETUP COMPLETE (V2 — Gateway AuthN + Internal JWT)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
