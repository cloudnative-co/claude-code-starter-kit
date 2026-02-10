# install.ps1 - Windows bootstrap for Claude Code Starter Kit
# Usage: irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex
# Requires: Windows 10 Build 19041+ (WSL2 support)

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "[  OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "Claude Code Starter Kit - Windows Bootstrap" -ForegroundColor White -BackgroundColor DarkCyan
Write-Host ""

# ---------------------------------------------------------------------------
# Admin check
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script requires Administrator privileges for WSL installation."
    Write-Err "Right-click PowerShell and select 'Run as Administrator', then try again."
    exit 1
}

# ---------------------------------------------------------------------------
# Windows version check
# ---------------------------------------------------------------------------
$build = [System.Environment]::OSVersion.Version.Build
Write-Info "Windows Build: $build"

if ($build -lt 19041) {
    Write-Err "Windows Build $build is too old. WSL2 requires Build 19041 or later."
    Write-Err "Please update Windows and try again."
    exit 1
}
Write-Ok "Windows version compatible with WSL2"

# ---------------------------------------------------------------------------
# WSL status check
# ---------------------------------------------------------------------------
$wslInstalled = $false
$ubuntuAvailable = $false

try {
    $wslStatus = wsl --status 2>&1
    if ($LASTEXITCODE -eq 0) {
        $wslInstalled = $true
    }
} catch {
    $wslInstalled = $false
}

if ($wslInstalled) {
    try {
        $distros = wsl -l -q 2>&1 | Where-Object { $_ -match "Ubuntu" }
        if ($distros) {
            $ubuntuAvailable = $true
        }
    } catch {}
}

# ---------------------------------------------------------------------------
# Install WSL + Ubuntu if needed
# ---------------------------------------------------------------------------
if (-not $wslInstalled) {
    Write-Info "WSL is not installed. Installing WSL with Ubuntu..."
    wsl --install -d Ubuntu
    Write-Warn ""
    Write-Warn "WSL has been installed. A RESTART is required."
    Write-Warn "After restart:"
    Write-Warn "  1. Open Ubuntu from the Start menu"
    Write-Warn "  2. Complete the initial user setup"
    Write-Warn "  3. Run this script again"
    Write-Warn ""
    Read-Host "Press Enter to restart now (or Ctrl+C to cancel)"
    Restart-Computer -Force
    exit 0
}

if (-not $ubuntuAvailable) {
    Write-Info "Ubuntu is not installed in WSL. Installing..."
    wsl --install -d Ubuntu
    Write-Warn ""
    Write-Warn "Ubuntu has been installed in WSL."
    Write-Warn "Please complete the Ubuntu user setup, then run this script again."
    exit 0
}

Write-Ok "WSL2 with Ubuntu is available"

# ---------------------------------------------------------------------------
# Run Linux bootstrap inside WSL
# ---------------------------------------------------------------------------
Write-Info "Running Claude Code Starter Kit setup inside WSL..."

$bootstrapScript = @'
#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"
INSTALL_DIR="$HOME/.claude-starter-kit"

if command -v dos2unix &>/dev/null; then
    echo "[INFO] dos2unix available"
elif command -v apt-get &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y dos2unix git curl jq
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || {
        rm -rf "$INSTALL_DIR"
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    }
else
    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

# Fix line endings for WSL
find "$INSTALL_DIR" -name "*.sh" -exec dos2unix {} \; 2>/dev/null || true

chmod +x "$INSTALL_DIR/setup.sh"
exec bash "$INSTALL_DIR/setup.sh"
'@

$tempFile = [System.IO.Path]::GetTempFileName()
$bootstrapScript | Set-Content -Path $tempFile -NoNewline

# Convert to Unix line endings
$content = Get-Content -Path $tempFile -Raw
$content = $content -replace "`r`n", "`n"
Set-Content -Path $tempFile -Value $content -NoNewline

$wslPath = wsl wslpath -a ($tempFile -replace '\\', '/')
wsl bash $wslPath

Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue

Write-Ok "Setup complete!"
