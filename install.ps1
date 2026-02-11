# install.ps1 - Windows bootstrap for Claude Code Starter Kit
# Usage: irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex
# Git Bash mode: powershell -File install.ps1 --git-bash

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
# Helper: Check if Windows Terminal is installed
# ---------------------------------------------------------------------------
function Test-WindowsTerminal {
    $wtPaths = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
    )
    foreach ($p in $wtPaths) {
        if (Test-Path $p) { return $true }
    }
    if (Get-Command wt -ErrorAction SilentlyContinue) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Mode 1: WSL2 + Windows Terminal (default, recommended)
# ---------------------------------------------------------------------------
function Install-ViaWSL {
    # Admin check (needed for WSL install)
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Err "WSL2 のインストールには管理者権限が必要です。"
        Write-Err "Administrator privileges are required for WSL2 installation."
        Write-Host ""
        Write-Info "PowerShell を右クリックして「管理者として実行」を選択し、再度実行してください。"
        Write-Info "Right-click PowerShell, select 'Run as Administrator', then try again."
        Write-Host ""
        Write-Info "管理者権限が使えない場合は Git Bash モードをお試しください："
        Write-Info "If admin is unavailable, try Git Bash mode:"
        Write-Host "  powershell -File install.ps1 --git-bash" -ForegroundColor Yellow
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
        Write-Warn "  WSL がインストールされました。再起動が必要です。"
        Write-Warn "  WSL has been installed. RESTART REQUIRED."
        Write-Warn "============================================="
        Write-Warn ""
        Write-Warn "再起動後、もう一度このコマンドを実行してください："
        Write-Warn "After restart, run this command again:"
        Write-Warn ""
        Write-Warn '  irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex'
        Write-Warn ""
        Write-Warn "セットアップは中断した場所から自動的に再開されます。"
        Write-Warn "The setup will automatically continue from where it left off."
        Write-Warn ""
        Read-Host "Enter を押すと再起動します（Ctrl+C でキャンセル） / Press Enter to restart now (or Ctrl+C to cancel)"
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
        Write-Info "Ubuntu の初期設定が必要です。"
        Write-Info "Ubuntu needs initial user setup."
        Write-Info "新しいウィンドウが開きます。以下を行ってください："
        Write-Info "A new Ubuntu window will open. Please:"
        Write-Info "  1. UNIX ユーザー名を作成 / Create your UNIX username"
        Write-Info "  2. パスワードを設定 / Set a password"
        Write-Info "  3. 完了したらウィンドウを閉じる / Close the Ubuntu window when done"
        Write-Host ""
        Read-Host "Enter を押して Ubuntu セットアップを開始 / Press Enter to open Ubuntu setup"

        # Try to find Ubuntu launcher (name varies by version)
        $ubuntuLauncher = $null
        foreach ($exe in @("ubuntu.exe", "ubuntu2404.exe", "ubuntu2204.exe", "ubuntu2004.exe")) {
            if (Get-Command $exe -ErrorAction SilentlyContinue) {
                $ubuntuLauncher = $exe
                break
            }
        }

        if ($ubuntuLauncher) {
            Start-Process $ubuntuLauncher -Wait -ErrorAction SilentlyContinue
        } else {
            # Fallback: launch via wsl directly (runs in current terminal)
            Write-Info "Ubuntu ランチャー (ubuntu.exe) が見つかりません。WSL 経由で起動します..."
            Write-Info "Ubuntu launcher not found. Launching via WSL..."
            Write-Host ""
            Write-Warn "ユーザー名とパスワードを設定してください。"
            Write-Warn "設定が終わったら exit と入力して Enter を押してください。"
            Write-Warn "After creating your username/password, type 'exit' and press Enter."
            Write-Host ""
            wsl -d Ubuntu
        }

        Write-Info "Ubuntu の準備を待っています... / Waiting for Ubuntu to become ready..."
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
    Write-Info "WSL 内で Claude Code Starter Kit をセットアップしています..."
    Write-Info "Running Claude Code Starter Kit setup inside WSL..."

    $bootstrapScript = @'
#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"
INSTALL_DIR="$HOME/.claude-starter-kit"

# Install only missing tools (skip sudo if everything is present)
_missing=()
command -v git &>/dev/null      || _missing+=(git)
command -v curl &>/dev/null     || _missing+=(curl)
command -v jq &>/dev/null       || _missing+=(jq)
command -v dos2unix &>/dev/null || _missing+=(dos2unix)

if [[ ${#_missing[@]} -gt 0 ]] && command -v apt-get &>/dev/null; then
    echo "[INFO] Installing missing tools: ${_missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${_missing[@]}" 2>/dev/null || true
fi

# Install Node.js if not present (needed for Codex CLI / npm plugins)
if ! command -v node &>/dev/null && command -v apt-get &>/dev/null; then
    echo "[INFO] Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | sudo -E bash - 2>/dev/null || true
    sudo apt-get install -y nodejs 2>/dev/null || true
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

    # Step 4: Check if Windows Terminal is installed
    $hasWT = Test-WindowsTerminal

    Write-Host ""
    Write-Ok "Setup complete! / セットアップ完了！"
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host "  Claude Code の始め方 / Getting Started" -ForegroundColor White
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""

    if ($hasWT) {
        Write-Host "  Windows Terminal がインストール済みです。" -ForegroundColor Green
        Write-Host ""
        Write-Host "  1. Windows Terminal を開く" -ForegroundColor Green
        Write-Host "     Windows キーを押して「Terminal」と入力して Enter" -ForegroundColor White
        Write-Host ""
        Write-Host "  2. Ubuntu タブを開く" -ForegroundColor Green
        Write-Host "     タブバーの「v」をクリック → 「Ubuntu」を選択" -ForegroundColor White
        Write-Host ""
        Write-Host "  3. プロジェクトフォルダに移動して Claude Code を起動" -ForegroundColor Green
        Write-Host "     cd ~/my-project" -ForegroundColor Yellow
        Write-Host "     claude" -ForegroundColor Yellow
    } else {
        Write-Host "  推奨: Windows Terminal をインストールしてください" -ForegroundColor Yellow
        Write-Host "  Recommended: Install Windows Terminal" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Microsoft Store を開いて「Windows Terminal」と検索、" -ForegroundColor White
        Write-Host "  または以下のコマンドでインストール:" -ForegroundColor White
        Write-Host "     winget install --id=Microsoft.WindowsTerminal" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  インストール後:" -ForegroundColor Green
        Write-Host "  1. Windows Terminal を開く (Windows キー →「Terminal」)" -ForegroundColor White
        Write-Host "  2. タブバーの「v」→「Ubuntu」を選択" -ForegroundColor White
        Write-Host "  3. 以下を実行:" -ForegroundColor White
        Write-Host "     claude" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  ---" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  今すぐ使う場合 (Windows Terminal なし):" -ForegroundColor Green
        Write-Host "  PowerShell で以下を実行:" -ForegroundColor White
        Write-Host "     wsl" -ForegroundColor Yellow
        Write-Host "     claude" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Warn "注意: PowerShell から直接 claude を実行することはできません。"
    Write-Warn "Note: You cannot run claude directly from PowerShell."
    Write-Warn "必ず WSL (Ubuntu) 環境内で実行してください。"
    Write-Host ""
    Write-Host "  PowerShell からワンコマンドで起動する場合:" -ForegroundColor DarkGray
    Write-Host "  wsl -d Ubuntu -- bash -lc 'claude'" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  アンインストール / Uninstall:" -ForegroundColor DarkGray
    Write-Host "  wsl -d Ubuntu -- bash -lc '~/.claude-starter-kit/uninstall.sh'" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Mode 2: Native Windows (Git Bash) — fallback for environments without WSL
# ---------------------------------------------------------------------------
function Install-ViaGitBash {
    Write-Info "Git Bash モードでセットアップします..."
    Write-Info "Setting up Claude Code with Git Bash (native Windows)..."
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
    $bashExitCode = $LASTEXITCODE

    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue

    if ($bashExitCode -ne 0) {
        Write-Err "Setup may not have completed successfully."
        Write-Err "セットアップが正常に完了しなかった可能性があります。"
        Write-Err ""
        Write-Err "To retry / 再実行:"
        Write-Err "  Open Git Bash and run: ~/.claude-starter-kit/setup.sh"
        exit $bashExitCode
    }

    Write-Host ""
    Write-Ok "Setup complete! / セットアップ完了！"
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Claude Code の始め方" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Git Bash を開く" -ForegroundColor Green
    Write-Host ""
    Write-Host "     方法 A: デスクトップの何もない場所を右クリック" -ForegroundColor White
    Write-Host "            →「Git Bash Here」を選択" -ForegroundColor White
    Write-Host ""
    Write-Host "     方法 B: キーボードの Windows キーを押して" -ForegroundColor White
    Write-Host "            「Git Bash」と入力して Enter" -ForegroundColor White
    Write-Host ""
    Write-Host "  2. 作業したいフォルダに移動" -ForegroundColor Green
    Write-Host "     以下のように入力して Enter:" -ForegroundColor White
    Write-Host "     cd ~/Documents/my-project" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  3. Claude Code を起動" -ForegroundColor Green
    Write-Host "     以下のように入力して Enter:" -ForegroundColor White
    Write-Host "     claude" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Warn "注意: この PowerShell ウィンドウでは claude は使えません。"
    Write-Warn "      必ず上記の方法で Git Bash を開いてください。"
    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor DarkGray
    Write-Host "  アンインストール (Git Bash で実行):" -ForegroundColor DarkGray
    Write-Host "  ~/.claude-starter-kit/uninstall.sh" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main: Default to WSL2 (recommended), --git-bash for native Windows
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Claude Code Starter Kit - Windows Setup" -ForegroundColor White -BackgroundColor DarkCyan
Write-Host ""

if ($args -contains "--git-bash") {
    Install-ViaGitBash
} else {
    Install-ViaWSL
}
