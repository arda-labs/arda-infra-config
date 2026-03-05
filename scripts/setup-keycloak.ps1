# Keycloak Configuration Script for Arda Platform
# Configures clients, roles, and service accounts.

$ErrorActionPreference = "Stop"

$KEYCLOAK_URL  = if ($env:KEYCLOAK_URL)            { $env:KEYCLOAK_URL }            else { "http://localhost:8081" }
$ADMIN_USER    = if ($env:KEYCLOAK_ADMIN)          { $env:KEYCLOAK_ADMIN }          else { "admin" }
$ADMIN_PASS    = if ($env:KEYCLOAK_ADMIN_PASSWORD) { $env:KEYCLOAK_ADMIN_PASSWORD } else { "admin" }
$ADMIN_REALM   = "master"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ARDA KEYCLOAK SETUP" -ForegroundColor Cyan
Write-Host "  URL: $KEYCLOAK_URL" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# --- Step 1: Get Admin Token ---
Write-Host "[1] Obtaining admin token..." -ForegroundColor Yellow
$tokenBody = @{
    grant_type = "password"
    client_id  = "admin-cli"
    username   = $ADMIN_USER
    password   = $ADMIN_PASS
}
$tokenResponse = Invoke-RestMethod -Method Post -Uri "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" -ContentType "application/x-www-form-urlencoded" -Body $tokenBody
$ACCESS_TOKEN = $tokenResponse.access_token
$authHeader = @{ Authorization = "Bearer $ACCESS_TOKEN" }
Write-Host "    ✓ OK" -ForegroundColor Green

# --- Step 2: Setup Notification Service Client ---
$CLIENT_ID = "arda-notification-service"
Write-Host "[2] Configuring client: $CLIENT_ID" -ForegroundColor Yellow

$existing = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients?clientId=$CLIENT_ID" -Headers $authHeader
if (@($existing).Count -eq 0) {
    $clientBody = @{
        clientId                = $CLIENT_ID
        name                    = "Arda Notification Service"
        enabled                 = $true
        clientAuthenticatorType = "client-secret"
        serviceAccountsEnabled  = $true
        protocol                = "openid-connect"
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients" -Headers $authHeader -ContentType "application/json" -Body $clientBody | Out-Null
    Write-Host "    ✓ Created" -ForegroundColor Green
} else {
    Write-Host "    ✓ Already exists" -ForegroundColor Green
}

# --- Step 2b: Setup Gateway Client (arda-gateway) ---
$GW_CLIENT_ID = "arda-gateway"
Write-Host "[2b] Configuring client: $GW_CLIENT_ID" -ForegroundColor Yellow

$existingGw = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients?clientId=$GW_CLIENT_ID" -Headers $authHeader
if (@($existingGw).Count -eq 0) {
    $gwClientBody = @{
        clientId                = $GW_CLIENT_ID
        name                    = "Arda API Gateway"
        enabled                 = $true
        clientAuthenticatorType = "client-secret"
        secret                  = "arda-gateway-secret-123"
        serviceAccountsEnabled  = $true
        protocol                = "openid-connect"
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients" -Headers $authHeader -ContentType "application/json" -Body $gwClientBody | Out-Null
    Write-Host "    ✓ Created (secret: arda-gateway-secret-123)" -ForegroundColor Green
} else {
    Write-Host "    ✓ Already exists" -ForegroundColor Green
}


# --- Step 3: Setup Shell Client (arda-shell) ---
# Needed for login into the Central Platform / Master Realm
$SHELL_CLIENT_ID = "arda-shell"
Write-Host "[3] Configuring client: $SHELL_CLIENT_ID" -ForegroundColor Yellow

$existingShell = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients?clientId=$SHELL_CLIENT_ID" -Headers $authHeader
if (@($existingShell).Count -eq 0) {
    $shellClientBody = @{
        clientId                  = $SHELL_CLIENT_ID
        name                      = "Arda Shell"
        enabled                   = $true
        publicClient              = $true
        standardFlowEnabled       = $true
        directAccessGrantsEnabled = $true
        redirectUris              = @("http://localhost:3000/*")
        webOrigins                = @("http://localhost:3000")
        protocol                  = "openid-connect"
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients" -Headers $authHeader -ContentType "application/json" -Body $shellClientBody | Out-Null
    Write-Host "    ✓ Created" -ForegroundColor Green
} else {
    Write-Host "    ✓ Already exists" -ForegroundColor Green
}

# --- Step 4: Role Mapping for Notification Service ---
# Get Client UUID (Notification Service)
$CLIENT_ID = "arda-notification-service"
$clientList = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients?clientId=$CLIENT_ID" -Headers $authHeader
$CLIENT_UUID = $clientList[0].id

# Assign realm-level 'admin' role to service account
# NOTE: Client-level roles from master-realm are NOT embedded in the JWT by Keycloak 26,
# even with fullScopeAllowed=true. Realm-level 'admin' role is required for
# the Admin REST API to accept requests from the service account token.
Write-Host "    Assigning realm 'admin' role to service account..." -ForegroundColor Gray
$saUser = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients/$CLIENT_UUID/service-account-user" -Headers $authHeader
$SA_ID = $saUser.id
$adminRole = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/roles/admin" -Headers $authHeader
$realmRoleBody = ConvertTo-Json -Compress -InputObject @( @{ id = $adminRole.id; name = $adminRole.name } )
Invoke-RestMethod -Method Post -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/users/$SA_ID/role-mappings/realm" -Headers $authHeader -ContentType "application/json" -Body $realmRoleBody | Out-Null
Write-Host "    ✓ Realm 'admin' role assigned to service account" -ForegroundColor Green

# Get Secret
$secretObj = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/clients/$CLIENT_UUID/client-secret" -Headers $authHeader
$SECRET = $secretObj.value

# --- Step 5: Create PLATFORM_ADMIN realm role ---
Write-Host "[5] Creating realm role: PLATFORM_ADMIN" -ForegroundColor Yellow
$existingRoles = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/roles" -Headers $authHeader
$roleExists = $existingRoles | Where-Object { $_.name -eq "PLATFORM_ADMIN" }
if (-not $roleExists) {
    $roleBody = @{
        name        = "PLATFORM_ADMIN"
        description = "Platform administrator - receives system-wide notifications"
    } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/roles" -Headers $authHeader -ContentType "application/json" -Body $roleBody | Out-Null
    Write-Host "    ✓ Created" -ForegroundColor Green
} else {
    Write-Host "    ✓ Already exists" -ForegroundColor Green
}

# --- Step 6: Create super_admin user ---
Write-Host "[6] Creating user: super_admin" -ForegroundColor Yellow
$existingUsers = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/users?username=super_admin&exact=true" -Headers $authHeader
if (@($existingUsers).Count -eq 0) {
    $userBody = @{
        username    = "super_admin"
        enabled     = $true
        credentials = @(
            @{
                type      = "password"
                value     = "123456"
                temporary = $false
            }
        )
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Post -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/users" -Headers $authHeader -ContentType "application/json" -Body $userBody | Out-Null
    Write-Host "    ✓ Created (password: 123456)" -ForegroundColor Green
} else {
    Write-Host "    ✓ Already exists" -ForegroundColor Green
}

# --- Step 7: Assign PLATFORM_ADMIN role to super_admin ---
Write-Host "[7] Assigning PLATFORM_ADMIN role to super_admin" -ForegroundColor Yellow
$superAdminUser = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/users?username=super_admin&exact=true" -Headers $authHeader
$SUPER_ADMIN_ID = $superAdminUser[0].id
$platformAdminRole = Invoke-RestMethod -Method Get -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/roles/PLATFORM_ADMIN" -Headers $authHeader
# Build a minimal array with only id+name to avoid ConvertTo-Json depth truncation issues
$assignBody = ConvertTo-Json -Compress -InputObject @(
    @{ id = $platformAdminRole.id; name = $platformAdminRole.name }
)
Invoke-RestMethod -Method Post -Uri "$KEYCLOAK_URL/admin/realms/$ADMIN_REALM/users/$SUPER_ADMIN_ID/role-mappings/realm" -Headers $authHeader -ContentType "application/json" -Body $assignBody | Out-Null
Write-Host "    ✓ Role assigned" -ForegroundColor Green

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  CLIENT SECRET: $SECRET" -ForegroundColor Cyan
Write-Host "  Update arda-notification environment variables with this." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  super_admin / 123456  →  role: PLATFORM_ADMIN (master)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
