# install.ps1 - Windows bootstrap for Claude Code Starter Kit
# Usage: irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "[  OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Helper: Test if Ubuntu is ready (can execute commands)
# ---------------------------------------------------------------------------
function Test-UbuntuReady {
    try {
        $result = wsl -d Ubuntu -- echo "READY" 2>&1
        $cleaned = ($result | Out-String).Trim()
        return $cleaned -match "READY"
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Helper: Check if WSL command exists and works
# ---------------------------------------------------------------------------
function Test-WslInstalled {
    try {
        $null = wsl --status 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Helper: Check if Ubuntu distro is registered
# wsl -l outputs UTF-16LE with null bytes, so use .NET to decode
# ---------------------------------------------------------------------------
function Test-UbuntuRegistered {
    try {
        $rawBytes = [System.Text.Encoding]::Unicode.GetBytes("")
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo.FileName = "wsl.exe"
        $proc.StartInfo.Arguments = "-l -q"
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::Unicode
        $proc.Start() | Out-Null
        $output = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        return $output -match "Ubuntu"
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Helper: Find Git Bash
# ---------------------------------------------------------------------------
function Find-GitBash {
    $gitPaths = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($p in $gitPaths) {
        if (Test-Path $p) { return $p }
    }
    # Try to find git in PATH and derive bash.exe location
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $gitDir = Split-Path (Split-Path $gitCmd.Source)
        $candidate = Join-Path $gitDir "bin\bash.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Mode 1: Native Windows (Git Bash)
# ---------------------------------------------------------------------------
function Install-ViaGitBash {
    Write-Info "Setting up Claude Code with Native Windows (Git Bash)..."
    Write-Host ""

    # Step 1: Check for Git for Windows
    $gitBash = Find-GitBash

    if (-not $gitBash) {
        Write-Warn "Git for Windows is not installed."
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Info "Installing Git for Windows via winget..."
            winget install --id=Git.Git --accept-package-agreements --accept-source-agreements
            # Re-check after install
            $gitBash = Find-GitBash
        }
        if (-not $gitBash) {
            Write-Err "Git for Windows could not be installed automatically."
            Write-Err "Please install from: https://gitforwindows.org/"
            Write-Err "Then run this script again."
            exit 1
        }
    }
    Write-Ok "Git Bash found: $gitBash"

    # Step 2: Clone and run setup via Git Bash
    $bootstrapScript = @'
#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"
INSTALL_DIR="$HOME/.claude-starter-kit"

# Clone or update the repo
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "[INFO] Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || {
        rm -rf "$INSTALL_DIR"
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    }
else
    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
    echo "[INFO] Cloning Claude Code Starter Kit..."
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/setup.sh"
chmod +x "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true

echo "[INFO] Starting interactive setup..."
exec bash "$INSTALL_DIR/setup.sh" </dev/tty
'@

    $tempFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempFile, $bootstrapScript.Replace("`r`n", "`n"))

    & $gitBash --login -i $tempFile

    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Ok "Setup complete!"
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Next Step / " -ForegroundColor White -NoNewline
    Write-Host "次のステップ" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "Open Git Bash and run 'claude' in your project directory."
    Write-Info "Git Bash を開いてプロジェクトディレクトリで 'claude' を実行してください。"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Mode 2: WSL (Ubuntu)
# ---------------------------------------------------------------------------
function Install-ViaWSL {
    # Admin check (only needed for WSL)
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Err "WSL installation requires Administrator privileges."
        Write-Err "Right-click PowerShell and select 'Run as Administrator', then try again."
        Write-Err ""
        Write-Err "Alternatively, choose option 1 (Native Windows) which does not require admin."
        exit 1
    }

    # Windows version check
    $build = [System.Environment]::OSVersion.Version.Build
    Write-Info "Windows Build: $build"

    if ($build -lt 19041) {
        Write-Err "Windows Build $build is too old. WSL2 requires Build 19041 or later."
        Write-Err "Please update Windows and try again."
        exit 1
    }
    Write-Ok "Windows version compatible with WSL2"

    # Step 1: Ensure WSL is installed
    if (-not (Test-WslInstalled)) {
        Write-Info "WSL is not installed. Installing WSL with Ubuntu..."
        wsl --install -d Ubuntu

        Write-Host ""
        Write-Warn "============================================="
        Write-Warn "  WSL has been installed. RESTART REQUIRED."
        Write-Warn "============================================="
        Write-Warn ""
        Write-Warn "After restart, run this command again:"
        Write-Warn ""
        Write-Warn '  irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex'
        Write-Warn ""
        Write-Warn "The setup will automatically continue from where it left off."
        Write-Warn ""
        Read-Host "Press Enter to restart now (or Ctrl+C to cancel)"
        Restart-Computer -Force
        exit 0
    }

    Write-Ok "WSL is installed"

    # Step 2: Ensure Ubuntu is registered and ready
    if (-not (Test-UbuntuRegistered)) {
        Write-Info "Ubuntu is not installed in WSL. Installing..."
        wsl --install -d Ubuntu
        Write-Info "Waiting for Ubuntu installation to complete..."
        Start-Sleep -Seconds 5
    }

    if (-not (Test-UbuntuReady)) {
        Write-Host ""
        Write-Info "Ubuntu needs initial user setup."
        Write-Info "A new Ubuntu window will open. Please:"
        Write-Info "  1. Create your UNIX username"
        Write-Info "  2. Set a password"
        Write-Info "  3. Close the Ubuntu window when done"
        Write-Host ""
        Read-Host "Press Enter to open Ubuntu setup"

        Start-Process "ubuntu.exe" -Wait -ErrorAction SilentlyContinue

        Write-Info "Waiting for Ubuntu to become ready..."
        $maxWait = 120
        $waited = 0
        while (-not (Test-UbuntuReady)) {
            Start-Sleep -Seconds 3
            $waited += 3
            if ($waited -ge $maxWait) {
                Write-Err "Ubuntu did not become ready within ${maxWait} seconds."
                Write-Err "Please open Ubuntu manually, complete the setup, then run this script again."
                exit 1
            }
            Write-Host "." -NoNewline
        }
        Write-Host ""
    }

    Write-Ok "WSL2 with Ubuntu is ready"

    # Step 3: Run Linux bootstrap inside WSL
    Write-Info "Running Claude Code Starter Kit setup inside WSL..."

    $bootstrapScript = @'
#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"
INSTALL_DIR="$HOME/.claude-starter-kit"

# Install essential tools
if command -v apt-get &>/dev/null; then
    echo "[INFO] Installing dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y git curl jq dos2unix 2>/dev/null || true
fi

# Clone or update the repo
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "[INFO] Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || {
        rm -rf "$INSTALL_DIR"
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    }
else
    [[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"
    echo "[INFO] Cloning Claude Code Starter Kit..."
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

# Fix line endings for WSL
find "$INSTALL_DIR" -name "*.sh" -exec dos2unix {} \; 2>/dev/null || true
find "$INSTALL_DIR" -name "*.conf" -exec dos2unix {} \; 2>/dev/null || true

chmod +x "$INSTALL_DIR/setup.sh"
chmod +x "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true

echo "[INFO] Starting interactive setup..."
exec bash "$INSTALL_DIR/setup.sh" </dev/tty
'@

    $tempFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempFile, $bootstrapScript.Replace("`r`n", "`n"))

    $wslPath = wsl wslpath -a ($tempFile -replace '\\', '/')
    wsl bash $wslPath

    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Ok "Setup complete!"
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Next Step / 次のステップ" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "Claude Code runs inside WSL, not in PowerShell."
    Write-Info "Claude Code は WSL 内で実行します（PowerShell ではありません）。"
    Write-Host ""
    Write-Info "Option 1: Open a terminal and type 'wsl', then run 'claude'"
    Write-Info "方法 1: ターミナルで 'wsl' と入力し、'claude' を実行"
    Write-Host ""
    Write-Info "Option 2: Run directly from PowerShell:"
    Write-Info "方法 2: PowerShell から直接実行:"
    Write-Host "  wsl -d Ubuntu -- bash -lc 'cd ~ && claude'" -ForegroundColor Yellow
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main: Mode selection
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Claude Code Starter Kit - Windows Setup" -ForegroundColor White -BackgroundColor DarkCyan
Write-Host ""
Write-Host "How would you like to install?" -ForegroundColor Cyan
Write-Host "インストール方法を選択してください：" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1) Native Windows (Git Bash) - Recommended / 推奨" -ForegroundColor Green
Write-Host "     No admin required. Claude Code runs directly on Windows."
Write-Host "     管理者権限不要。Windows 上で直接 Claude Code を実行します。"
Write-Host ""
Write-Host "  2) WSL (Ubuntu) - Full Linux environment" -ForegroundColor Yellow
Write-Host "     Requires admin. Installs WSL2 + Ubuntu."
Write-Host "     管理者権限が必要。WSL2 + Ubuntu をインストールします。"
Write-Host ""

$mode = Read-Host "Choice / 選択 (1 or 2)"

switch ($mode) {
    "2" { Install-ViaWSL }
    default { Install-ViaGitBash }
}
