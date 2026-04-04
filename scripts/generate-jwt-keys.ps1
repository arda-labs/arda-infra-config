# generate-jwt-keys.ps1
# Generates RSA 2048-bit keypair for Internal JWT signing (APISIX Gateway → Backend).
#
# Output:
#   ../keys/internal-jwt-private.pem  (used by APISIX Lua signer)
#   ../keys/internal-jwt-public.pem   (used by backend services for verification)
#
# Prerequisites: OpenSSL installed and in PATH.
#
# Usage:
#   .\generate-jwt-keys.ps1          # Interactive (prompts before overwrite)
#   .\generate-jwt-keys.ps1 -Auto    # Non-interactive (skip prompts)

param(
    [switch]$Auto = $false
)

$ErrorActionPreference = "Stop"

$KeysDir = Join-Path (Join-Path $PSScriptRoot "..") "keys"
$PrivateKey = Join-Path $KeysDir "internal-jwt-private.pem"
$PublicKey  = Join-Path $KeysDir "internal-jwt-public.pem"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  JWT KEYPAIR GENERATION" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Check if keys already exist
if ((Test-Path $PrivateKey) -and (Test-Path $PublicKey)) {
    Write-Host "  Keys already exist:" -ForegroundColor Yellow
    Write-Host "    Private: $PrivateKey" -ForegroundColor Gray
    Write-Host "    Public:  $PublicKey" -ForegroundColor Gray

    if ($Auto) {
        Write-Host "  Skipping (-Auto mode, existing keys preserved)." -ForegroundColor Yellow
        exit 0
    }

    $overwrite = Read-Host "  Overwrite? (y/N): "
    if ($overwrite -ne "y" -and $overwrite -ne "Y") {
        Write-Host "  Skipping (existing keys preserved)." -ForegroundColor Yellow
        exit 0
    }
}

# Ensure keys directory exists
if (-not (Test-Path $KeysDir)) {
    New-Item -ItemType Directory -Path $KeysDir -Force | Out-Null
    Write-Host "  Created directory: $KeysDir" -ForegroundColor Gray
}

# Check OpenSSL
$openssl = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $openssl) {
    Write-Host "  ERROR: OpenSSL not found in PATH" -ForegroundColor Red
    Write-Host "  Install via: https://slproweb.com/products/Win32OpenSSL.html" -ForegroundColor Yellow
    exit 1
}

Write-Host "  Generating RSA 2048-bit keypair..." -ForegroundColor Yellow

# Generate private key
& openssl genrsa -out $PrivateKey 2048 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Failed to generate private key" -ForegroundColor Red
    exit 1
}

# Extract public key from private key
& openssl rsa -in $PrivateKey -pubout -out $PublicKey 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Failed to extract public key" -ForegroundColor Red
    exit 1
}

Write-Host "  OK Keys generated:" -ForegroundColor Green
Write-Host "    Private: $PrivateKey" -ForegroundColor Gray
Write-Host "    Public:  $PublicKey" -ForegroundColor Gray

# Copy public key to backend services that need it
$backendServices = @(
    @{ Name = "arda-central-platform"; Path = Join-Path (Join-Path $PSScriptRoot ".." "..") "arda-central-platform\src\main\resources\internal-jwt-public.pem" },
    @{ Name = "arda-iam-service";      Path = Join-Path (Join-Path $PSScriptRoot ".." "..") "arda-iam-service\src\main\resources\internal-jwt-public.pem" }
)

Write-Host ""
Write-Host "  Copying public key to backend services..." -ForegroundColor Yellow

foreach ($svc in $backendServices) {
    $destDir = Split-Path $svc.Path
    if (Test-Path $destDir) {
        Copy-Item $PublicKey $svc.Path -Force
        Write-Host "    OK $($svc.Name)" -ForegroundColor Green
    } else {
        Write-Host "    SKIP $($svc.Name) (directory not found)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  JWT KEYPAIR GENERATION COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
