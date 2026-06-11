#!/bin/bash
# lib/fonts.sh - Cross-platform programming font installation
# Installs IBM Plex Mono and HackGen NF (Nerd Fonts)
#
# Requires: lib/colors.sh, lib/prerequisites.sh (_brew_is_usable, _run_with_timeout)
# Note: uses uname -s directly for platform detection (not lib/detect.sh)
# Sets globals: FONTS_INCOMPLETE[]
# Exports: install_ibm_plex_mono(), install_hackgen_nf(), setup_fonts()
# Dry-run: guarded (setup.sh logs EXTERNAL, does not call setup_fonts)
set -euo pipefail

FONTS_INCOMPLETE=()
IBM_PLEX_MONO_ZIP_URL="${IBM_PLEX_MONO_ZIP_URL:-https://github.com/IBM/plex/releases/download/%40ibm/plex-mono%401.1.0/ibm-plex-mono.zip}"
HACKGEN_NF_ZIP_URL="${HACKGEN_NF_ZIP_URL:-https://github.com/yuru7/HackGen/releases/download/v2.10.0/HackGen_NF_v2.10.0.zip}"

_font_zip_has_magic() {
  local zip_path="$1"
  [[ -f "$zip_path" ]] || return 1
  local magic
  magic="$(LC_ALL=C dd if="$zip_path" bs=2 count=1 2>/dev/null || true)"
  [[ "$magic" == "PK" ]]
}

# ---------------------------------------------------------------------------
# macOS font installation helper (direct download fallback)
# Downloads a zip, extracts matching files, copies to ~/Library/Fonts/.
# Args: $1=download_url  $2=zip_filename  $3=file_filter (e.g. "*.ttf")
# ---------------------------------------------------------------------------
_install_font_macos() {
  local font_url="$1"
  local font_zip_name="$2"
  local font_filter="$3"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  _register_tmp "$tmp_dir"
  local zip_path="$tmp_dir/$font_zip_name"

  mkdir -p "$HOME/Library/Fonts"

  if curl -fsSL "$font_url" -o "$zip_path"; then
    if ! _font_zip_has_magic "$zip_path"; then
      warn "Downloaded font archive is not a zip: $font_url"
      rm -rf "$tmp_dir"
      return 1
    fi
    if unzip -qo "$zip_path" -d "$tmp_dir"; then
      # shellcheck disable=SC2086
      find "$tmp_dir" -name "$font_filter" -exec cp {} "$HOME/Library/Fonts/" \;
      rm -rf "$tmp_dir"
      return 0
    fi
  fi

  rm -rf "$tmp_dir"
  return 1
}

# ---------------------------------------------------------------------------
# Windows font installation helper (via powershell.exe)
# Downloads a zip, extracts .ttf files, installs to user-level font directory.
# Works from both WSL and MSYS/Git Bash.
# Args: $1=download_url  $2=zip_filename  $3=file_filter (e.g. "*.ttf")
# ---------------------------------------------------------------------------
_install_font_windows() {
  local font_url="$1"
  local font_zip_name="$2"
  local font_filter="$3"

  local ps_script
  ps_script='
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$fontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
if (-not (Test-Path $fontDir)) { New-Item -ItemType Directory -Path $fontDir -Force | Out-Null }
$tmpDir = Join-Path $env:TEMP "claude-fonts-install"
if (Test-Path $tmpDir) { Remove-Item -Path $tmpDir -Recurse -Force }
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$zipPath = Join-Path $tmpDir "'"$font_zip_name"'"
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri "'"$font_url"'" -OutFile $zipPath -UseBasicParsing
  $bytes = [System.IO.File]::ReadAllBytes($zipPath)
  if ($bytes.Length -lt 2 -or $bytes[0] -ne 80 -or $bytes[1] -ne 75) {
    Write-Output "NOT_ZIP"
    exit 2
  }
  Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
  $fonts = Get-ChildItem -Path $tmpDir -Recurse -Filter "'"$font_filter"'"
  $regPath = "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
  if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
  foreach ($f in $fonts) {
    $dest = Join-Path $fontDir $f.Name
    if (-not (Test-Path $dest)) {
      Copy-Item $f.FullName $dest -Force
      $fontName = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) + " (TrueType)"
      New-ItemProperty -Path $regPath -Name $fontName -Value $dest -PropertyType String -Force | Out-Null
    }
  }
  Write-Output "OK"
} finally {
  Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
'

  local output
  output="$(_run_with_timeout 120 powershell.exe -NoProfile -Command "$ps_script" 2>/dev/null | tr -d '\r')" || return 1
  if [[ "$output" == *"OK"* ]]; then
    return 0
  elif [[ "$output" == *"NOT_ZIP"* ]]; then
    warn "Downloaded font archive is not a zip: $font_url"
    return 1
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Check if font files matching a glob pattern exist in Windows user font dir.
# Uses powershell.exe to inspect %LOCALAPPDATA%\Microsoft\Windows\Fonts.
# Args: $1=glob_pattern (e.g. "IBMPlex*.ttf", "HackGen*NF*.ttf")
# Returns: 0 if at least one match, 1 otherwise
# ---------------------------------------------------------------------------
_is_font_installed_windows() {
  local pattern="$1"
  local result
  result="$(_run_with_timeout 15 powershell.exe -NoProfile -Command '
    $ProgressPreference = "SilentlyContinue"
    $fontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    if ((Test-Path $fontDir) -and (Get-ChildItem -Path $fontDir -Filter "'"$pattern"'" -ErrorAction SilentlyContinue)) {
      Write-Output "YES"
    } else { Write-Output "NO" }
  ' 2>/dev/null | tr -d '\r')" || result=""
  [[ "$result" == "YES" ]]
}

_install_font() {
  local cask_name="$1"
  local macos_glob="$2"
  local windows_glob="$3"
  local font_url="$4"
  local zip_name="$5"
  local font_filter="$6"
  local already_msg="$7"
  local installing_msg="$8"
  local installed_msg="$9"
  local failed_msg="${10}"
  local manual_url="${11}"

  local uname_s
  uname_s="$(uname -s)"

  case "$uname_s" in
    Darwin)
      if _brew_is_usable 2>/dev/null && brew list --cask "$cask_name" &>/dev/null 2>&1; then
        ok "$already_msg"
        return 0
      fi
      if compgen -G "$HOME/Library/Fonts/$macos_glob" >/dev/null 2>&1; then
        ok "$already_msg"
        return 0
      fi
      info "$installing_msg"
      if _brew_is_usable 2>/dev/null && brew install --cask "$cask_name" 2>/dev/null; then
        ok "$installed_msg"
        return 0
      fi
      info "  brew failed, downloading directly..."
      if _install_font_macos "$font_url" "$zip_name" "$font_filter"; then
        ok "$installed_msg"
        return 0
      fi
      warn "$failed_msg"
      info "  $manual_url"
      return 1
      ;;
    *)
      if ! command -v powershell.exe &>/dev/null; then
        warn "${STR_FONT_NO_POWERSHELL:-powershell.exe not found}"
        info "  $manual_url"
        return 1
      fi
      if _is_font_installed_windows "$windows_glob"; then
        ok "$already_msg"
        return 0
      fi
      info "$installing_msg"
      if _install_font_windows "$font_url" "$zip_name" "$font_filter"; then
        ok "$installed_msg"
        return 0
      else
        warn "$failed_msg"
        info "  $manual_url"
        return 1
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Install IBM Plex Mono
# ---------------------------------------------------------------------------
install_ibm_plex_mono() {
  _install_font \
    "font-ibm-plex-mono" \
    "IBMPlex*.ttf" \
    "IBMPlex*.ttf" \
    "$IBM_PLEX_MONO_ZIP_URL" \
    "IBMPlexMono.zip" \
    "*.ttf" \
    "${STR_FONT_IBM_ALREADY:-IBM Plex Mono is already installed}" \
    "${STR_FONT_IBM_INSTALLING:-Installing IBM Plex Mono...}" \
    "${STR_FONT_IBM_INSTALLED:-IBM Plex Mono installed}" \
    "${STR_FONT_IBM_FAILED:-Failed to install IBM Plex Mono}" \
    "${STR_FONT_IBM_MANUAL:-https://fonts.google.com/specimen/IBM+Plex+Mono}"
}

# ---------------------------------------------------------------------------
# Install HackGen NF (Nerd Fonts version)
# ---------------------------------------------------------------------------
install_hackgen_nf() {
  _install_font \
    "font-hackgen-nerd" \
    "HackGen*NF*.ttf" \
    "HackGen*NF*.ttf" \
    "$HACKGEN_NF_ZIP_URL" \
    "HackGen_NF.zip" \
    "*.ttf" \
    "${STR_FONT_HACKGEN_ALREADY:-HackGen NF is already installed}" \
    "${STR_FONT_HACKGEN_INSTALLING:-Installing HackGen NF...}" \
    "${STR_FONT_HACKGEN_INSTALLED:-HackGen NF installed}" \
    "${STR_FONT_HACKGEN_FAILED:-Failed to install HackGen NF}" \
    "${STR_FONT_HACKGEN_MANUAL:-https://github.com/yuru7/HackGen/releases}"
}

# ---------------------------------------------------------------------------
# Configure Windows Terminal default font (via powershell.exe)
# Reads settings.json, sets profiles.defaults.font.face, writes back.
# Creates a .bak backup before modifying.
# Args: $1=font_name (e.g. "HackGen35 Console NF")
# ---------------------------------------------------------------------------
_configure_windows_terminal_font() {
  local font_name="$1"

  local ps_script
  ps_script='
$ErrorActionPreference = "Stop"
$settingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (-not (Test-Path $settingsPath)) {
  $previewPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
  if (Test-Path $previewPath) { $settingsPath = $previewPath }
  else { Write-Output "NOT_FOUND"; exit 0 }
}
try {
  Copy-Item $settingsPath "$settingsPath.bak" -Force
  $raw = Get-Content -Path $settingsPath -Raw -Encoding UTF8
  $cleaned = $raw -replace "(?m)^\s*//.*$", "" -replace "/\*[\s\S]*?\*/", ""
  $settings = $cleaned | ConvertFrom-Json
  if (-not $settings.profiles) { $settings | Add-Member -NotePropertyName "profiles" -NotePropertyValue ([PSCustomObject]@{}) -Force }
  if (-not $settings.profiles.defaults) { $settings.profiles | Add-Member -NotePropertyName "defaults" -NotePropertyValue ([PSCustomObject]@{}) -Force }
  if (-not $settings.profiles.defaults.font) { $settings.profiles.defaults | Add-Member -NotePropertyName "font" -NotePropertyValue ([PSCustomObject]@{}) -Force }
  $settings.profiles.defaults.font | Add-Member -NotePropertyName "face" -NotePropertyValue "'"$font_name"'" -Force
  $settings | ConvertTo-Json -Depth 32 | Set-Content -Path $settingsPath -Encoding UTF8
  Write-Output "OK"
} catch {
  Write-Output "FAILED"
}
'

  local result
  result="$(_run_with_timeout 15 powershell.exe -NoProfile -Command "$ps_script" 2>/dev/null | tr -d '\r')" || result=""

  case "$result" in
    OK)        return 0 ;;
    NOT_FOUND) return 2 ;;
    *)         return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
setup_fonts() {
  install_ibm_plex_mono || FONTS_INCOMPLETE+=("IBM-Plex-Mono")
  install_hackgen_nf    || FONTS_INCOMPLETE+=("HackGen-NF")

  # Configure Windows Terminal font.
  # This runs independently of font install success — if HackGen NF is
  # already present from a previous install, we still configure WT.
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin)
      # macOS: fonts are automatically available in all apps
      ;;
    *)
      # WSL or MSYS: auto-configure Windows Terminal if HackGen NF is available
      if ! command -v powershell.exe &>/dev/null; then
        return 0
      fi
      # Check if HackGen NF is available (installed now or previously)
      if ! _is_font_installed_windows "HackGen*NF*.ttf"; then
        return 0
      fi
      printf "\n"
      info "${STR_FONT_WT_CONFIGURING:-Configuring Windows Terminal font...}"
      _configure_windows_terminal_font "HackGen35 Console NF"
      local wt_result=$?
      if [[ $wt_result -eq 0 ]]; then
        ok "${STR_FONT_WT_CONFIGURED:-Windows Terminal font set to 'HackGen35 Console NF'}"
        info "  ${STR_FONT_WT_BACKUP:-A backup was saved as settings.json.bak}"
      elif [[ $wt_result -eq 2 ]]; then
        info "${STR_FONT_WT_NOT_FOUND:-Windows Terminal settings not found (not installed?)}"
        info "${STR_FONT_WT_HINT:-To use the installed fonts in Windows Terminal:}"
        info "  ${STR_FONT_WT_STEP1:-1. Open Settings (Ctrl+,) > Profiles > Defaults > Appearance}"
        info "  ${STR_FONT_WT_STEP2:-2. Set Font face to 'HackGen35 Console NF' (or 'IBM Plex Mono')}"
      else
        warn "${STR_FONT_WT_CONFIGURE_FAILED:-Failed to auto-configure Windows Terminal font}"
        info "${STR_FONT_WT_HINT:-To use the installed fonts in Windows Terminal:}"
        info "  ${STR_FONT_WT_STEP1:-1. Open Settings (Ctrl+,) > Profiles > Defaults > Appearance}"
        info "  ${STR_FONT_WT_STEP2:-2. Set Font face to 'HackGen35 Console NF' (or 'IBM Plex Mono')}"
      fi
      ;;
  esac
}
