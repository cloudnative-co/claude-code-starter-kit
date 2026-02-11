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

  # Not installed - not fatal at this stage.
  # Homebrew will be installed later only if the selected profile requires it
  # (e.g., Ghostty setup). Individual checks use alternative installers (nvm for Node.js).
  return 0
}

# ---------------------------------------------------------------------------
# Package manager wrappers
# ---------------------------------------------------------------------------

# Install packages via the appropriate system package manager
_pkg_install() {
  case "$DISTRO_FAMILY" in
    macos)
      if command -v brew &>/dev/null; then
        brew install "$@"
      else
        error "Cannot install $*: Homebrew is not available."
        return 1
      fi
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
  # Node.js is optional: Claude Code uses a native installer and no longer requires Node.js.
  # However, Node.js is still needed for Codex CLI and npm-based plugins.
  warn "Node.js not found (optional, needed for Codex CLI / npm plugins)."
  info "Installing Node.js ${NODE_MAJOR}.x..."
  if _install_node && command -v node &>/dev/null; then
    ok "node $(node --version) installed"
  else
    warn "Could not install Node.js. Codex CLI setup will be skipped if selected."
    _show_node_manual_instructions
    # Not fatal - return success since Node.js is no longer required for Claude Code itself
    return 0
  fi
}

_install_node_via_nvm() {
  info "Installing Node.js via nvm (no admin required)..."
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  mkdir -p "$NVM_DIR"
  if curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash; then
    # Load nvm into current session
    # shellcheck source=/dev/null
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    nvm install "$NODE_MAJOR"
    # nvm installer only writes to the running shell's rc file (bash).
    # If the user's login shell is zsh, also add nvm init to .zshrc.
    _ensure_nvm_in_zshrc
  else
    return 1
  fi
}

_ensure_nvm_in_zshrc() {
  local login_shell
  login_shell="$(basename "${SHELL:-}")"
  # Only needed when the login shell is zsh but we're running under bash
  [[ "$login_shell" == "zsh" ]] || return 0

  local zshrc="$HOME/.zshrc"
  # Skip if nvm init is already present
  if [[ -f "$zshrc" ]] && grep -q 'NVM_DIR' "$zshrc" 2>/dev/null; then
    return 0
  fi

  info "Adding nvm to ~/.zshrc (login shell is zsh)..."
  cat >> "$zshrc" <<'ZSHRC'

# nvm - Node Version Manager (added by claude-code-starter-kit)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
ZSHRC
}

_install_node() {
  case "$DISTRO_FAMILY" in
    macos)
      if command -v brew &>/dev/null; then
        brew install "node@${NODE_MAJOR}"
      else
        _install_node_via_nvm
      fi
      ;;
    debian)
      # Try NodeSource first, fall back to nvm
      if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" 2>/dev/null | sudo -E bash - 2>/dev/null \
         && sudo apt-get install -y nodejs 2>/dev/null; then
        :
      else
        warn "NodeSource setup failed. Falling back to nvm..."
        _install_node_via_nvm
      fi
      ;;
    rhel)
      if curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" 2>/dev/null | sudo bash - 2>/dev/null \
         && sudo dnf install -y nodejs 2>/dev/null; then
        :
      else
        warn "NodeSource setup failed. Falling back to nvm..."
        _install_node_via_nvm
      fi
      ;;
    alpine)
      sudo apk add --no-cache "nodejs" "npm"
      ;;
    *)
      _install_node_via_nvm
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
  section "必要なツールを確認中 / Checking prerequisites"

  # macOS: try to ensure Homebrew is available (not fatal if it fails)
  _ensure_homebrew

  local failed=0

  check_git   || failed=1
  check_jq    || failed=1
  check_curl  || failed=1
  check_node  # Optional: needed for Codex CLI / npm plugins only
  check_tmux
  check_dos2unix
  check_gh

  if [[ "$failed" -ne 0 ]]; then
    error "一部の必須ツールをインストールできませんでした。手動でインストールして再実行してください。"
    error "Some required dependencies could not be installed. Please install them manually and re-run."
    return 1
  fi

  ok "必要なツールはすべて揃っています / All prerequisites satisfied"
  return 0
}
