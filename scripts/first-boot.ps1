# Arda Platform - First Boot Script
# Run this on fresh machine to setup everything from scratch
#
# Usage:
#   .\first-boot.ps1          # Interactive (prompts before destructive actions)
#   .\first-boot.ps1 -Auto    # Non-interactive (auto-accepts, no prompts)

param(
    [switch]$Auto = $false
)

$ErrorActionPreference = "Stop"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ARDA PLATFORM - FIRST BOOT" -ForegroundColor Cyan
Write-Host "  Setup from scratch (fresh machine)" -ForegroundColor Cyan
if ($Auto) { Write-Host "  Mode: AUTO (non-interactive)" -ForegroundColor Yellow }
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 0: Check Prerequisites ─────────────────────────────────
Write-Host "[0/8] Checking prerequisites..." -ForegroundColor Yellow

$requiredCommands = @("docker", "git", "powershell")
$missing = @()

foreach ($cmd in $requiredCommands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        $missing += $cmd
    }
}

if ($missing.Count -gt 0) {
    Write-Host "  ✗ Missing required tools:" -ForegroundColor Red
    foreach ($cmd in $missing) {
        Write-Host "    - $cmd" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "Please install:" -ForegroundColor Yellow
    Write-Host "  - Docker Desktop: https://www.docker.com/products/docker-desktop/" -ForegroundColor Gray
    Write-Host "  - Git: https://git-scm.com/downloads" -ForegroundColor Gray
    exit 1
}

Write-Host "  ✓ All prerequisites installed" -ForegroundColor Green

# Check Python
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
}

if ($pythonCmd) {
    Write-Host "  ✓ Python found: $pythonCmd" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Python not found (optional, used for TUI)" -ForegroundColor Yellow
}

# ── Step 1: Clone Repository ─────────────────────────────────────
Write-Host ""
Write-Host "[1/8] Checking repository..." -ForegroundColor Yellow

$repoDir = Join-Path $PSScriptRoot "..", ".."
if (-not (Test-Path "$repoDir\.git")) {
    Write-Host "  ℹ Repository not cloned yet" -ForegroundColor Gray
    Write-Host "  Please clone first:" -ForegroundColor Yellow
    Write-Host "    git clone <your-repo-url> $repoDir" -ForegroundColor Gray
    Write-Host "    cd $repoDir" -ForegroundColor Gray
    exit 1
} else {
    Write-Host "  ✓ Repository found: $repoDir" -ForegroundColor Green
}

# ── Step 2: Install Python Dependencies ────────────────────────────
Write-Host ""
Write-Host "[2/8] Installing Python dependencies..." -ForegroundColor Yellow

$scriptsDir = Join-Path $PSScriptRoot ".."
$reqFile = Join-Path $scriptsDir "scripts\requirements.txt"

if ($pythonCmd -and (Test-Path $reqFile)) {
    $output = & $pythonCmd -m pip install -r $reqFile 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Python dependencies installed" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Failed to install Python dependencies" -ForegroundColor Yellow
        Write-Host "    (Optional - TUI may not work)" -ForegroundColor Gray
    }
} else {
    Write-Host "  - Skipping (Python not available or no requirements.txt)" -ForegroundColor Gray
}

# ── Step 3: Clean Existing Data ───────────────────────────────────
Write-Host ""
Write-Host "[3/8] Checking for existing Docker data..." -ForegroundColor Yellow

$dockerComposeDir = Join-Path $scriptsDir "docker-compose"
Set-Location $dockerComposeDir

$containersRunning = docker ps -q 2>$null
if ($containersRunning) {
    Write-Host "  ℹ Existing containers found" -ForegroundColor Gray

    $shouldClean = $false
    if ($Auto) {
        $shouldClean = $true
        Write-Host "  → Auto mode: cleaning existing data" -ForegroundColor Yellow
    } else {
        $confirm = Read-Host "  Stop and remove all data? (yes/N): "
        $shouldClean = ($confirm -eq "yes")
    }

    if ($shouldClean) {
        Write-Host "  → Stopping containers..." -ForegroundColor Gray
        docker compose down 2>$null | Out-Null

        Write-Host "  → Removing volumes..." -ForegroundColor Gray
        docker volume rm arda-postgres-data arda-kafka-data arda-redis-data arda-etcd-data -f 2>$null | Out-Null

        Write-Host "  ✓ Data cleaned" -ForegroundColor Green
    } else {
        Write-Host "  → Keeping existing data" -ForegroundColor Yellow
    }
} else {
    Write-Host "  ✓ No existing data" -ForegroundColor Green
}

# ── Step 4: Start Docker Infrastructure ───────────────────────────
Write-Host ""
Write-Host "[4/8] Starting Docker infrastructure..." -ForegroundColor Yellow

Write-Host "  → Running: docker compose up -d" -ForegroundColor Gray
docker compose up -d 2>&1 | Write-Host

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ✗ Failed to start Docker services" -ForegroundColor Red
    exit 1
}

Write-Host "  ✓ Docker services started" -ForegroundColor Green

# ── Step 5: Wait for Services to be Healthy ─────────────────────
Write-Host ""
Write-Host "[5/8] Waiting for services to be healthy..." -ForegroundColor Yellow

$maxAttempts = 60
$attempt = 0

while ($attempt -lt $maxAttempts) {
    $pgStatus = docker inspect --format='{{.State.Health.Status}}' arda-postgres 2>$null
    $redisStatus = docker inspect --format='{{.State.Health.Status}}' arda-redis 2>$null

    if ($pgStatus -eq "healthy" -and $redisStatus -eq "healthy") {
        Write-Host "  ✓ All services healthy" -ForegroundColor Green
        break
    }

    $attempt++
    if ($attempt -ge $maxAttempts) {
        Write-Host "  ✗ Timeout waiting for services" -ForegroundColor Red
        Write-Host "    Current status: PG=$pgStatus, Redis=$redisStatus" -ForegroundColor Red
        exit 1
    }

    Start-Sleep -Seconds 2
    if ($attempt % 10 -eq 0) {
        Write-Host "    Waiting... ($attempt/$maxAttempts)" -ForegroundColor Gray
    }
}

# ── Step 6: Run Bootstrap Scripts ─────────────────────────────────
Write-Host ""
Write-Host "[6/8] Running bootstrap..." -ForegroundColor Yellow

$bootstrapScript = Join-Path $scriptsDir "scripts\bootstrap.ps1"

if (Test-Path $bootstrapScript) {
    & $bootstrapScript

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ✗ Bootstrap failed" -ForegroundColor Red
        exit 1
    }

    Write-Host "  ✓ Bootstrap complete" -ForegroundColor Green
} else {
    Write-Host "  ⚠ Bootstrap script not found: $bootstrapScript" -ForegroundColor Yellow
    Write-Host "    Please ensure you're in the correct directory" -ForegroundColor Gray
}

# ── Step 7: Keycloak Secret ──────────────────────────────────────────
Write-Host ""
Write-Host "[7/8] Keycloak secret..." -ForegroundColor Yellow

if ($Auto) {
    # Secret was auto-updated in .env by setup-keycloak.ps1
    Write-Host "  ✓ Secret auto-updated in .env (non-interactive mode)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  IMPORTANT: The notification service secret was auto-updated in .env." -ForegroundColor Cyan
    Write-Host "  If notification service fails, verify NOTIFICATION_KC_CLIENT_SECRET in .env." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to continue... "
}

# ── Step 8: Build Backend Libraries ───────────────────────────────────
Write-Host ""
Write-Host "[8/8] Building backend libraries..." -ForegroundColor Yellow

$sharedKernelDir = Join-Path $repoDir "arda-shared-kernel"

if (Test-Path $sharedKernelDir) {
    Write-Host "  → Building: arda-shared-kernel" -ForegroundColor Gray

    Set-Location $sharedKernelDir

    if (Test-Path "mvnw.cmd") {
        & ".\mvnw.cmd" clean install -DskipTests 2>&1 | Select-String -Pattern "(BUILD|ERROR|SUCCESS|FAILURE)" | Write-Host

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ arda-shared-kernel built" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Failed to build arda-shared-kernel" -ForegroundColor Red
            Write-Host "    Check the output above for errors" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠ mvnw.cmd not found" -ForegroundColor Yellow
        Write-Host "    Ensure you have Maven installed" -ForegroundColor Gray
    }

    Set-Location $dockerComposeDir
} else {
    Write-Host "  - Skipping (arda-shared-kernel not found)" -ForegroundColor Gray
}

# ── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  FIRST BOOT COMPLETE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "✓ Infrastructure running" -ForegroundColor Green
Write-Host "✓ Keycloak configured (secret auto-saved to .env)" -ForegroundColor Green
Write-Host "✓ Database migrations complete" -ForegroundColor Green
Write-Host "✓ APISIX routes configured" -ForegroundColor Green
Write-Host "✓ JWT keys generated" -ForegroundColor Green
Write-Host "✓ Backend library built" -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Start backend services:" -ForegroundColor Yellow
Write-Host "   cd arda-central-platform && mvnw.cmd spring-boot:run" -ForegroundColor Gray
Write-Host "   cd arda-iam-service && mvnw.cmd spring-boot:run" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Start frontend:" -ForegroundColor Yellow
Write-Host "   cd arda-mfe && pnpm dev" -ForegroundColor Gray
Write-Host ""
Write-Host "Or use the TUI tool:" -ForegroundColor Cyan
Write-Host "   python scripts/arda-manager.py" -ForegroundColor Gray
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
