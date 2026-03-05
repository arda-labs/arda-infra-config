# Arda Platform — Full Bootstrap Script
# Run this after `docker compose down -v` or first-time setup.
# This script seeds all infrastructure data from scratch.
#
# Prerequisites:
#   - Docker Desktop running
#   - `docker compose up -d` already executed (infra services must be running)
#   - OpenSSL installed (for JWT keypair generation)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║         ARDA PLATFORM — FULL BOOTSTRAP                    ║" -ForegroundColor Cyan
Write-Host "║         PostgreSQL 18 | Redis 8 | Keycloak 26            ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$ScriptsDir = $PSScriptRoot

# ============================================================
# Step 0: Verify Docker services are running
# ============================================================
Write-Host "[0/6] Verifying Docker services..." -ForegroundColor Yellow
$pgStatus = docker inspect --format='{{.State.Health.Status}}' arda-postgres 2>$null
$redisStatus = docker inspect --format='{{.State.Health.Status}}' arda-redis 2>$null

if ($pgStatus -ne "healthy") {
    Write-Host "  ✗ arda-postgres is not healthy (status: $pgStatus)" -ForegroundColor Red
    Write-Host "  → Run: cd arda-infra-config/docker-compose && docker compose up -d" -ForegroundColor Yellow
    exit 1
}
if ($redisStatus -ne "healthy") {
    Write-Host "  ✗ arda-redis is not healthy (status: $redisStatus)" -ForegroundColor Red
    Write-Host "  → Run: cd arda-infra-config/docker-compose && docker compose up -d" -ForegroundColor Yellow
    exit 1
}
Write-Host "  ✓ PostgreSQL 18 (healthy)" -ForegroundColor Green
Write-Host "  ✓ Redis 8 (healthy)" -ForegroundColor Green

# Check other critical services
$keycloakRunning = docker ps --filter "name=arda-keycloak" --filter "status=running" -q
$kafkaRunning = docker ps --filter "name=arda-kafka" --filter "status=running" -q
if (-not $keycloakRunning) {
    Write-Host "  ✗ arda-keycloak is not running" -ForegroundColor Red
    exit 1
}
Write-Host "  ✓ Keycloak 26 (running)" -ForegroundColor Green
if ($kafkaRunning) {
    Write-Host "  ✓ Kafka (running)" -ForegroundColor Green
}

# ============================================================
# Step 1: Verify databases were created by init-db.sql
# ============================================================
Write-Host ""
Write-Host "[1/6] Verifying databases..." -ForegroundColor Yellow
$dbList = docker exec arda-postgres psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datname LIKE 'arda_%' ORDER BY datname;"
Write-Host "  Found databases:" -ForegroundColor Gray
$dbList -split "`n" | ForEach-Object { if ($_.Trim()) { Write-Host "    - $($_.Trim())" -ForegroundColor Green } }

# ============================================================
# Step 2: Run DB schema migrations
# ============================================================
Write-Host ""
Write-Host "[2/6] Running DB schema migrations..." -ForegroundColor Yellow
& "$ScriptsDir\setup-db-migrations.ps1"

# ============================================================
# Step 3: Generate JWT keypair (if not exists)
# ============================================================
Write-Host ""
Write-Host "[3/6] JWT Keypair..." -ForegroundColor Yellow
$KeyDir = Join-Path (Join-Path $ScriptsDir "..") "keys"
$PrivateKeyPath = Join-Path $KeyDir "internal-jwt-private.pem"
if (Test-Path $PrivateKeyPath) {
    Write-Host "  ✓ Keys already exist, skipping generation" -ForegroundColor Green
} else {
    Write-Host "  Generating RSA 2048-bit keypair..." -ForegroundColor Gray
    & "$ScriptsDir\generate-jwt-keypair.ps1"
}

# ============================================================
# Step 3: Wait for Keycloak to be ready
# ============================================================
Write-Host ""
Write-Host "[4/6] Waiting for Keycloak to be ready..." -ForegroundColor Yellow
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    try {
        $null = Invoke-RestMethod -Method Get -Uri "http://localhost:8081/realms/master" -TimeoutSec 3
        Write-Host "  ✓ Keycloak is ready" -ForegroundColor Green
        break
    } catch {
        $attempt++
        if ($attempt -ge $maxAttempts) {
            Write-Host "  ✗ Keycloak not ready after $maxAttempts attempts" -ForegroundColor Red
            exit 1
        }
        Write-Host "  Waiting... ($attempt/$maxAttempts)" -ForegroundColor Gray
        Start-Sleep -Seconds 2
    }
}

# ============================================================
# Step 4: Configure Keycloak
# ============================================================
Write-Host ""
Write-Host "[5/6] Configuring Keycloak..." -ForegroundColor Yellow
& "$ScriptsDir\setup-keycloak.ps1"

# ============================================================
# Step 5: Configure APISIX routes
# ============================================================
Write-Host ""
Write-Host "[6/6] Configuring APISIX routes..." -ForegroundColor Yellow
& "$ScriptsDir\setup-apisix.ps1"

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║         BOOTSTRAP COMPLETE ✓                              ║" -ForegroundColor Green
Write-Host "╠════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║                                                            ║" -ForegroundColor Green
Write-Host "║  Infrastructure:                                           ║" -ForegroundColor Green
Write-Host "║    PostgreSQL 18 .... localhost:5432  (healthy)            ║" -ForegroundColor Green
Write-Host "║    Redis 8 ......... localhost:6379  (healthy)             ║" -ForegroundColor Green
Write-Host "║    Keycloak 26 ..... localhost:8081  (ready)               ║" -ForegroundColor Green
Write-Host "║    Kafka ........... localhost:9092  (KRaft)               ║" -ForegroundColor Green
Write-Host "║    APISIX .......... localhost:9080  (gateway)             ║" -ForegroundColor Green
Write-Host "║                                                            ║" -ForegroundColor Green
Write-Host "║  Credentials:                                              ║" -ForegroundColor Green
Write-Host "║    Keycloak Admin .. admin / admin                         ║" -ForegroundColor Green
Write-Host "║    super_admin ..... super_admin / 123456                  ║" -ForegroundColor Green
Write-Host "║    PostgreSQL ...... postgres / password                   ║" -ForegroundColor Green
Write-Host "║                                                            ║" -ForegroundColor Green
Write-Host "║  Next Steps:                                               ║" -ForegroundColor Green
Write-Host "║    1. cd arda-shared-kernel && mvn clean install -DskipTests║" -ForegroundColor Green
Write-Host "║    2. cd arda-central-platform && mvn spring-boot:run      ║" -ForegroundColor Green
Write-Host "║    3. cd arda-iam-service && mvn spring-boot:run           ║" -ForegroundColor Green
Write-Host "║    4. cd arda-mfe && pnpm dev                              ║" -ForegroundColor Green
Write-Host "║                                                            ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
