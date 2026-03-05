# setup-db-migrations.ps1
# Chạy tất cả schema migrations cho các service databases.
# An toàn để chạy nhiều lần (idempotent — dùng CREATE TABLE IF NOT EXISTS).
#
# Usage:
#   .\setup-db-migrations.ps1                          # Chạy tất cả
#   .\setup-db-migrations.ps1 -Service notification   # Chỉ chạy 1 service
#
# Yêu cầu: arda-postgres container đang healthy.

param(
    [string]$Service = "all"  # all | notification | (thêm service khác sau)
)

$ErrorActionPreference = "Stop"

$RootDir   = Join-Path (Join-Path $PSScriptRoot "..") ".."  # d:\Github\arda.io.vn
$MigsBase  = $RootDir                                        # mỗi service có thư mục migrations/ riêng

# ─── Helper ────────────────────────────────────────────────────────────────────

function Run-Migration {
    param(
        [string]$ServiceName,
        [string]$Database,
        [string]$MigrationFile
    )

    $file = Resolve-Path $MigrationFile -ErrorAction SilentlyContinue
    if (-not $file) {
        Write-Host "    ✗ File not found: $MigrationFile" -ForegroundColor Red
        return $false
    }

    $sql = Get-Content $file -Raw

    # PostgreSQL ghi NOTICE ra stderr (e.g. "relation already exists, skipping").
    # PowerShell $ErrorActionPreference = Stop sẽ throw khi thấy bất kỳ stderr nào.
    # Tạm set Continue cục bộ để tránh false-positive, chỉ kiểm tra exit code thật.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = ($sql | docker exec -i arda-postgres psql -U postgres -d $Database) 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref

    # Chỉ fail khi output chứa "ERROR" thật (không phải NOTICE/WARNING)
    $hasRealError = "$output" -match "\bERROR\b" -and "$output" -notmatch "^NOTICE"
    if ($exitCode -ne 0 -and $hasRealError) {
        Write-Host "    ✗ FAILED: $([System.IO.Path]::GetFileName($MigrationFile))" -ForegroundColor Red
        Write-Host "      $output" -ForegroundColor DarkRed
        return $false
    }

    Write-Host "    ✓ $([System.IO.Path]::GetFileName($MigrationFile))" -ForegroundColor Green
    return $true
}

function Run-ServiceMigrations {
    param(
        [string]$ServiceName,
        [string]$Database,
        [string]$MigrationsDir
    )

    Write-Host "  → [$ServiceName] db: $Database" -ForegroundColor Cyan

    if (-not (Test-Path $MigrationsDir)) {
        Write-Host "    (no migrations directory found, skipping)" -ForegroundColor Gray
        return
    }

    $files = Get-ChildItem -Path $MigrationsDir -Filter "*.sql" | Sort-Object Name
    if ($files.Count -eq 0) {
        Write-Host "    (no .sql files found)" -ForegroundColor Gray
        return
    }

    foreach ($f in $files) {
        Run-Migration -ServiceName $ServiceName -Database $Database -MigrationFile $f.FullName | Out-Null
    }
}

# ─── Header ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ARDA DB MIGRATIONS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ─── Verify postgres is healthy ───────────────────────────────────────────────

$pgStatus = docker inspect --format='{{.State.Health.Status}}' arda-postgres 2>$null
if ($pgStatus -ne "healthy") {
    Write-Host "✗ arda-postgres is not healthy (status: $pgStatus)" -ForegroundColor Red
    Write-Host "  → Run: docker compose up -d" -ForegroundColor Yellow
    exit 1
}

# ─── Run migrations ───────────────────────────────────────────────────────────

$ran = @()

if ($Service -eq "all" -or $Service -eq "notification") {
    Run-ServiceMigrations `
        -ServiceName "arda-notification" `
        -Database    "arda_notification" `
        -MigrationsDir (Join-Path (Join-Path $MigsBase "arda-notification") "migrations")
    $ran += "notification"
}

# Thêm service khác ở đây khi có migrations:
# if ($Service -eq "all" -or $Service -eq "iam") {
#     Run-ServiceMigrations `
#         -ServiceName "arda-iam-service" `
#         -Database    "arda_iam" `
#         -MigrationsDir (Join-Path $MigsBase "arda-iam-service" "migrations")
#     $ran += "iam"
# }

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  MIGRATIONS COMPLETE: $($ran -join ', ')" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
