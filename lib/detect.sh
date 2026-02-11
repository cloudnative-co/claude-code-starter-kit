#!/bin/bash
# lib/detect.sh - OS, architecture, and WSL detection
# Exports: OS, ARCH, DISTRO, DISTRO_FAMILY, IS_WSL, WSL_BUILD, WIN_BUILD
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OS="unknown"
ARCH="unknown"
DISTRO="unknown"
DISTRO_FAMILY="unknown"
IS_WSL=false
WSL_BUILD=0
WIN_BUILD=0

# ---------------------------------------------------------------------------
# detect_os - Populate OS, ARCH, DISTRO, DISTRO_FAMILY, IS_WSL, WSL_BUILD
# ---------------------------------------------------------------------------
detect_os() {
  local uname_s
  uname_s="$(uname -s)"

  case "$uname_s" in
    Darwin)
      OS="macos"
      _detect_macos_arch
      DISTRO="macos"
      DISTRO_FAMILY="macos"
      ;;
    Linux)
      OS="linux"
      ARCH="$(uname -m)"
      _detect_linux_distro
      _detect_wsl
      ;;
    MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*)
      OS="windows"
      ARCH="$(uname -m)"
      DISTRO="msys"
      DISTRO_FAMILY="msys"
      # Extract Windows build number (e.g. MSYS_NT-10.0-19045 → 19045)
      # Stored in WIN_BUILD (not WSL_BUILD — this is native Windows, not WSL)
      if [[ "$uname_s" =~ [0-9]+\.[0-9]+-([0-9]+) ]]; then
        WIN_BUILD="${BASH_REMATCH[1]}"
      fi
      ;;
    *)
      OS="unsupported"
      ARCH="$(uname -m)"
      ;;
  esac

  export OS ARCH DISTRO DISTRO_FAMILY IS_WSL WSL_BUILD
}

# ---------------------------------------------------------------------------
# macOS: Intel (x86_64) vs Apple Silicon (arm64)
# ---------------------------------------------------------------------------
_detect_macos_arch() {
  ARCH="$(uname -m)"
  # uname -m returns "arm64" on Apple Silicon, "x86_64" on Intel
}

# ---------------------------------------------------------------------------
# Linux: identify distribution and family
# ---------------------------------------------------------------------------
_detect_linux_distro() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO="${ID:-unknown}"

    case "$DISTRO" in
      ubuntu|debian|pop|linuxmint|elementary|zorin)
        DISTRO_FAMILY="debian"
        ;;
      fedora|rhel|centos|rocky|alma|ol)
        DISTRO_FAMILY="rhel"
        ;;
      alpine)
        DISTRO_FAMILY="alpine"
        ;;
      arch|manjaro|endeavouros)
        DISTRO_FAMILY="arch"
        ;;
      opensuse*|sles)
        DISTRO_FAMILY="suse"
        ;;
      *)
        DISTRO_FAMILY="unknown"
        ;;
    esac
  elif [[ -f /etc/alpine-release ]]; then
    DISTRO="alpine"
    DISTRO_FAMILY="alpine"
  elif [[ -f /etc/debian_version ]]; then
    DISTRO="debian"
    DISTRO_FAMILY="debian"
  elif [[ -f /etc/redhat-release ]]; then
    DISTRO="rhel"
    DISTRO_FAMILY="rhel"
  fi
}

# ---------------------------------------------------------------------------
# WSL: detect Windows Subsystem for Linux and build number
# ---------------------------------------------------------------------------
_detect_wsl() {
  if [[ -f /proc/version ]] && grep -qi "microsoft" /proc/version 2>/dev/null; then
    IS_WSL=true

    # Extract Windows build number for WSL2 compatibility check.
    # WSL2 requires Windows build >= 19041.
    if command -v wslpath &>/dev/null || [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
      local version_string
      version_string="$(< /proc/version)"
      # Pattern: Microsoft ... build NNNNN or just a version like 5.10.102.1-microsoft-standard-WSL2
      if [[ "$version_string" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        # The third segment is typically the Windows build number in WSL kernel versions
        WSL_BUILD="$(echo "${BASH_REMATCH[1]}" | cut -d'.' -f3)"
      fi
    fi

    # Fallback: try reading from powershell if available
    if [[ "$WSL_BUILD" == "0" ]] && command -v powershell.exe &>/dev/null; then
      local ps_build
      ps_build="$(powershell.exe -NoProfile -Command '[System.Environment]::OSVersion.Version.Build' 2>/dev/null | tr -d '\r')" || true
      if [[ "$ps_build" =~ ^[0-9]+$ ]]; then
        WSL_BUILD="$ps_build"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Convenience helpers
# ---------------------------------------------------------------------------

# Returns 0 (true) if running on macOS
is_macos() { [[ "$OS" == "macos" ]]; }

# Returns 0 (true) if running on Linux
is_linux() { [[ "$OS" == "linux" ]]; }

# Returns 0 (true) if running inside WSL
is_wsl() { [[ "$IS_WSL" == "true" ]]; }

# Returns 0 (true) if running in Git Bash (MSYS/MINGW) on native Windows
is_msys() { [[ "$OS" == "windows" ]]; }

# Returns 0 (true) if running on Windows (either WSL or native Git Bash)
is_windows() { is_wsl || is_msys; }

# Returns 0 (true) if Apple Silicon
is_apple_silicon() { [[ "$OS" == "macos" && "$ARCH" == "arm64" ]]; }

# Returns 0 (true) if WSL2 (build >= 19041)
is_wsl2() {
  is_wsl && [[ "$WSL_BUILD" -ge 19041 ]] 2>/dev/null
}

# Print a summary of the detected environment
print_detect_summary() {
  echo "OS=$OS  ARCH=$ARCH  DISTRO=$DISTRO  FAMILY=$DISTRO_FAMILY  WSL=$IS_WSL  WSL_BUILD=$WSL_BUILD"
}
