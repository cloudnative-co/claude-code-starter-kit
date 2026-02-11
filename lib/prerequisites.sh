#!/bin/bash
# lib/prerequisites.sh - Dependency checking and installation
# Requires: lib/colors.sh and lib/detect.sh to be sourced first
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Node.js major version to install when missing
NODE_MAJOR="${NODE_MAJOR:-20}"

# ---------------------------------------------------------------------------
# Homebrew (macOS only)
# ---------------------------------------------------------------------------

# Ensure Homebrew is installed and in PATH.
# On Apple Silicon, brew lives at /opt/homebrew/bin/brew.
# On Intel, it lives at /usr/local/bin/brew.
_ensure_homebrew() {
  [[ "$DISTRO_FAMILY" != "macos" ]] && return 0

  # Already in PATH
  if command -v brew &>/dev/null; then
    return 0
  fi

  # Installed but not in PATH (common on Apple Silicon after fresh install)
  local brew_bin=""
  if [[ -x /opt/homebrew/bin/brew ]]; then
    brew_bin="/opt/homebrew/bin/brew"
  elif [[ -x /usr/local/bin/brew ]]; then
    brew_bin="/usr/local/bin/brew"
  fi

  if [[ -n "$brew_bin" ]]; then
    info "Adding Homebrew to PATH..."
    eval "$("$brew_bin" shellenv)"
    return 0
  fi

  # Not installed at all - install it
  info "Homebrew not found. Installing Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add to PATH for this session
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  if command -v brew &>/dev/null; then
    ok "Homebrew installed"
  else
    error "Homebrew installation completed but 'brew' not found in PATH."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Package manager wrappers
# ---------------------------------------------------------------------------

# Install packages via the appropriate system package manager
_pkg_install() {
  case "$DISTRO_FAMILY" in
    macos)
      brew install "$@"
      ;;
    debian)
      sudo apt-get update -qq && sudo apt-get install -y "$@"
      ;;
    rhel)
      sudo dnf install -y "$@"
      ;;
    alpine)
      sudo apk add --no-cache "$@"
      ;;
    *)
      error "Unsupported package manager for DISTRO_FAMILY=$DISTRO_FAMILY"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Individual checks and installers
# ---------------------------------------------------------------------------

check_git() {
  if command -v git &>/dev/null; then
    ok "git $(git --version | awk '{print $3}')"
    return 0
  fi
  info "Installing git..."
  _pkg_install git
  ok "git installed"
}

check_jq() {
  if command -v jq &>/dev/null; then
    ok "jq $(jq --version 2>/dev/null || echo '?')"
    return 0
  fi
  info "Installing jq..."
  _pkg_install jq
  ok "jq installed"
}

check_curl() {
  if command -v curl &>/dev/null; then
    ok "curl found"
    return 0
  fi
  info "Installing curl..."
  _pkg_install curl
  ok "curl installed"
}

check_tmux() {
  if command -v tmux &>/dev/null; then
    ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}')"
    return 0
  fi
  warn "tmux not found (optional). Install with: $(_tmux_install_hint)"
  return 0 # Optional - do not fail
}

_tmux_install_hint() {
  case "$DISTRO_FAMILY" in
    macos)  echo "brew install tmux" ;;
    debian) echo "sudo apt-get install tmux" ;;
    rhel)   echo "sudo dnf install tmux" ;;
    alpine) echo "sudo apk add tmux" ;;
    *)      echo "see https://github.com/tmux/tmux/wiki/Installing" ;;
  esac
}

check_node() {
  if command -v node &>/dev/null; then
    ok "node $(node --version)"
    return 0
  fi
  info "Node.js not found. Installing Node.js ${NODE_MAJOR}.x..."
  if _install_node && command -v node &>/dev/null; then
    ok "node $(node --version) installed"
  else
    error "Failed to install Node.js."
    _show_node_manual_instructions
    return 1
  fi
}

_install_node() {
  case "$DISTRO_FAMILY" in
    macos)
      brew install "node@${NODE_MAJOR}"
      ;;
    debian)
      # NodeSource setup for Debian/Ubuntu
      if ! curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -; then
        _show_node_manual_instructions
        return 1
      fi
      sudo apt-get install -y nodejs
      ;;
    rhel)
      if ! curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | sudo bash -; then
        _show_node_manual_instructions
        return 1
      fi
      sudo dnf install -y nodejs
      ;;
    alpine)
      sudo apk add --no-cache "nodejs" "npm"
      ;;
    *)
      _show_node_manual_instructions
      return 1
      ;;
  esac
}

_show_node_manual_instructions() {
  error "Could not install Node.js automatically."
  error "Please install Node.js ${NODE_MAJOR}.x manually:"
  error "  - Official installer: https://nodejs.org/en/download/"
  error "  - Using nvm:         https://github.com/nvm-sh/nvm"
  error "  - Using fnm:         https://github.com/Schniz/fnm"
}

check_dos2unix() {
  # Only relevant for WSL environments
  if [[ "$IS_WSL" != "true" ]]; then
    return 0
  fi
  if command -v dos2unix &>/dev/null; then
    ok "dos2unix found (WSL)"
    return 0
  fi
  info "Installing dos2unix (recommended for WSL)..."
  _pkg_install dos2unix
  ok "dos2unix installed"
}

check_gh() {
  if command -v gh &>/dev/null; then
    ok "gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
    return 0
  fi
  warn "GitHub CLI (gh) not found (optional)."
  warn "  Install: https://cli.github.com/"
  case "$DISTRO_FAMILY" in
    macos)  warn "  Or: brew install gh" ;;
    debian) warn "  Or: https://github.com/cli/cli/blob/trunk/docs/install_linux.md" ;;
    rhel)   warn "  Or: sudo dnf install gh" ;;
    *)      ;;
  esac
  return 0 # Optional - do not fail
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

# Run all prerequisite checks. Returns non-zero on critical failure.
check_prerequisites() {
  section "Checking prerequisites"

  # macOS: ensure Homebrew is available before checking other deps
  _ensure_homebrew || {
    error "Homebrew is required on macOS. Please install it manually and re-run."
    return 1
  }

  local failed=0

  check_git   || failed=1
  check_jq    || failed=1
  check_curl  || failed=1
  check_node  || failed=1
  check_tmux
  check_dos2unix
  check_gh

  if [[ "$failed" -ne 0 ]]; then
    error "Some required dependencies could not be installed."
    error "Please install them manually and re-run the setup."
    return 1
  fi

  ok "All required prerequisites satisfied"
  return 0
}
