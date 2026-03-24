#!/bin/bash
# lib/prerequisites.sh - Dependency checking and installation
#
# Requires: lib/colors.sh, lib/detect.sh
# Uses globals: DISTRO_FAMILY, WIZARD_NONINTERACTIVE, DRY_RUN,
#               _SETUP_ORIG_ARGS[], _SETUP_SCRIPT_PATH, NODE_MAJOR
# Sets globals: _GNU_SED, _GNU_AWK (wrappers for GNU sed/awk)
# Exports: check_prerequisites(), check_bash4(), _detect_bash4(),
#          _sed(), _awk(), _brew_is_usable(), _ensure_homebrew()
# Dry-run: check_prerequisites has dry-run fast path (light tools only)
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Node.js major version to install when missing
NODE_MAJOR="${NODE_MAJOR:-20}"

# ---------------------------------------------------------------------------
# Homebrew (macOS only)
# ---------------------------------------------------------------------------

# Check if the current user can write to Homebrew's prefix directory.
# Returns 1 if brew is not in PATH or the prefix is not writable
# (e.g., Homebrew installed by another user).
_brew_is_usable() {
  command -v brew &>/dev/null || return 1
  local prefix
  prefix="$(brew --prefix 2>/dev/null)" || return 1
  [[ -n "$prefix" && -w "$prefix" ]]
}

# Ensure Homebrew is installed, in PATH, and writable by the current user.
# On Apple Silicon, brew lives at /opt/homebrew/bin/brew.
# On Intel, it lives at /usr/local/bin/brew.
_ensure_homebrew() {
  [[ "$DISTRO_FAMILY" != "macos" ]] && return 0

  # Try to find brew in PATH or standard locations
  if ! command -v brew &>/dev/null; then
    local brew_bin=""
    if [[ -x /opt/homebrew/bin/brew ]]; then
      brew_bin="/opt/homebrew/bin/brew"
    elif [[ -x /usr/local/bin/brew ]]; then
      brew_bin="/usr/local/bin/brew"
    fi
    if [[ -n "$brew_bin" ]]; then
      info "Adding Homebrew to PATH..."
      eval "$("$brew_bin" shellenv)"
    fi
  fi

  # If brew is found and usable (writable), we're done
  if _brew_is_usable; then
    return 0
  fi

  # Brew not found, or found but not writable (installed by another user)
  if command -v brew &>/dev/null; then
    warn "Homebrew found but not writable by current user (installed by another user)"
  fi
  info "Installing Homebrew for current user..."
  local _brew_env=""
  if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
    _brew_env="NONINTERACTIVE=1"
  fi
  if env ${_brew_env} /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    # Add newly installed Homebrew to PATH
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    if _brew_is_usable; then
      ok "Homebrew installed"
      return 0
    fi
  fi

  warn "Homebrew のインストールに失敗しました — フォントの自動インストールが制限されます"
  return 0  # Not fatal — fonts will fall back to manual download hints
}

# ---------------------------------------------------------------------------
# Package manager wrappers
# ---------------------------------------------------------------------------

# Install packages via the appropriate system package manager
_pkg_install() {
  case "$DISTRO_FAMILY" in
    macos)
      if _brew_is_usable; then
        brew install "$@"
      else
        error "Cannot install $*: Homebrew is not available or not writable."
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
    msys)
      error "Package manager not available in Git Bash."
      error "Please install $* manually using winget or from their official websites."
      return 1
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
  if is_msys; then
    error "Git not found. This should not happen in Git Bash."
    error "Please reinstall Git for Windows: https://gitforwindows.org/"
    return 1
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
  if is_msys; then
    info "Installing jq (standalone binary for Windows)..."
    local jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe"
    local jq_dest="$HOME/.local/bin/jq.exe"
    mkdir -p "$HOME/.local/bin"
    if curl -fsSL "$jq_url" -o "$jq_dest" && chmod +x "$jq_dest"; then
      # Also create a symlink without .exe for compatibility
      ln -sf "$jq_dest" "$HOME/.local/bin/jq" 2>/dev/null || true
      export PATH="$HOME/.local/bin:$PATH"
      ok "jq installed to $jq_dest"
      return 0
    else
      error "Failed to download jq. Install manually: https://jqlang.github.io/jq/download/"
      return 1
    fi
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

# ---------------------------------------------------------------------------
# GNU sed / GNU awk — required for reliable text processing
#
# macOS ships BSD sed/awk which have subtle incompatibilities.
# Detect GNU versions (gsed/gawk or sed/awk with --version), install if missing.
# Sets _GNU_SED and _GNU_AWK to the resolved binary paths.
# ---------------------------------------------------------------------------
_GNU_SED=""
_GNU_AWK=""

_detect_gnu_sed() {
  # Check if 'sed' itself is GNU
  if sed --version 2>/dev/null | grep -q "GNU sed"; then
    _GNU_SED="sed"
    return 0
  fi
  # Check for gsed (brew install gnu-sed)
  if command -v gsed &>/dev/null && gsed --version 2>/dev/null | grep -q "GNU sed"; then
    _GNU_SED="gsed"
    return 0
  fi
  return 1
}

_detect_gnu_awk() {
  # Check if 'awk' itself is GNU
  if awk --version 2>/dev/null | grep -q "GNU Awk"; then
    _GNU_AWK="awk"
    return 0
  fi
  # Check for gawk (brew install gawk)
  if command -v gawk &>/dev/null && gawk --version 2>/dev/null | grep -q "GNU Awk"; then
    _GNU_AWK="gawk"
    return 0
  fi
  return 1
}

check_gnu_sed() {
  if _detect_gnu_sed; then
    ok "GNU sed ($_GNU_SED)"
    return 0
  fi
  # Try to install: macOS via gnu-sed, Linux distros typically have GNU sed
  case "$DISTRO_FAMILY" in
    macos)  info "Installing GNU sed..."; _pkg_install gnu-sed ;;
    debian) info "Installing GNU sed..."; _pkg_install sed ;;
    rhel)   info "Installing GNU sed..."; _pkg_install sed ;;
    alpine) info "Installing GNU sed..."; _pkg_install sed ;;
  esac
  if _detect_gnu_sed; then
    ok "GNU sed installed ($_GNU_SED)"
    return 0
  fi
  warn "GNU sed not found. Install manually:"
  case "$DISTRO_FAMILY" in
    macos)  info "  brew install gnu-sed" ;;
    debian) info "  sudo apt-get install sed" ;;
    alpine) info "  sudo apk add sed" ;;
    *)      info "  Install GNU sed for your platform" ;;
  esac
  return 1
}

check_gnu_awk() {
  if _detect_gnu_awk; then
    ok "GNU awk ($_GNU_AWK)"
    return 0
  fi
  # Try to install: gawk on all platforms
  case "$DISTRO_FAMILY" in
    macos)  info "Installing GNU awk..."; _pkg_install gawk ;;
    debian) info "Installing GNU awk..."; _pkg_install gawk ;;
    rhel)   info "Installing GNU awk..."; _pkg_install gawk ;;
    alpine) info "Installing GNU awk..."; _pkg_install gawk ;;
  esac
  if _detect_gnu_awk; then
    ok "GNU awk installed ($_GNU_AWK)"
    return 0
  fi
  warn "GNU awk not found. Install manually:"
  case "$DISTRO_FAMILY" in
    macos)  info "  brew install gawk" ;;
    debian) info "  sudo apt-get install gawk" ;;
    alpine) info "  sudo apk add gawk" ;;
    *)      info "  Install GNU awk (gawk) for your platform" ;;
  esac
  return 1
}

# Portable wrappers — use these instead of raw sed/awk in kit scripts
_sed() {
  if [[ -n "$_GNU_SED" ]]; then
    "$_GNU_SED" "$@"
  else
    sed "$@"
  fi
}

_awk() {
  if [[ -n "$_GNU_AWK" ]]; then
    "$_GNU_AWK" "$@"
  else
    awk "$@"
  fi
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
    msys)   echo "tmux is not available in Git Bash" ;;
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

_persist_node_path() {
  local node_bin="$1"
  local rc_file
  case "$(basename "${SHELL:-}")" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash) rc_file="$HOME/.bashrc" ;;
    *)    rc_file="$HOME/.profile" ;;
  esac
  [[ -f "$rc_file" ]] || touch "$rc_file"
  if ! grep -q "$node_bin" "$rc_file" 2>/dev/null; then
    printf '\n# Node.js (brew keg-only, added by claude-code-starter-kit)\nexport PATH="%s:$PATH"\n' "$node_bin" >> "$rc_file"
  fi
}

_install_node() {
  case "$DISTRO_FAMILY" in
    macos)
      if _brew_is_usable; then
        brew install "node@${NODE_MAJOR}" 2>/dev/null || true
        # node@XX is keg-only (not symlinked into PATH). Add its bin dir
        # for the current session and persist it in the user's shell rc file.
        local node_prefix
        node_prefix="$(brew --prefix "node@${NODE_MAJOR}" 2>/dev/null || true)"
        if [[ -n "$node_prefix" && -d "$node_prefix/bin" ]]; then
          export PATH="$node_prefix/bin:$PATH"
          _persist_node_path "$node_prefix/bin"
        fi
      fi
      # Fall back to nvm if brew is not usable or brew install didn't work
      if ! command -v node &>/dev/null; then
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
    msys)
      # Try winget (available on Windows 10+), then fall back to nvm
      if command -v winget.exe &>/dev/null; then
        info "Installing Node.js via winget..."
        winget.exe install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements 2>/dev/null || true
        # winget installs to Program Files; add to PATH
        export PATH="/c/Program Files/nodejs:$PATH"
      fi
      if ! command -v node &>/dev/null; then
        _install_node_via_nvm
      fi
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
# ---------------------------------------------------------------------------
# Bash 4+ detection and re-exec
# ---------------------------------------------------------------------------

# _detect_bash4 - Find a Bash 4+ binary on the system
# Returns the path via stdout. Returns 1 if none found.
_detect_bash4() {
  # Check current shell first
  if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
    printf '%s' "$BASH"
    return 0
  fi

  # Search common locations
  local candidate
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
    if [[ -x "$candidate" ]]; then
      local ver
      ver="$("$candidate" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo "0")"
      if [[ "$ver" -ge 4 ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    fi
  done

  return 1
}

# check_bash4 - Ensure we're running under Bash 4+, re-exec if not
# Uses _SETUP_ORIG_ARGS (set at setup.sh top-level) to preserve CLI arguments.
# Returns 0 if already Bash 4+, re-execs on success, returns 1 on failure.
check_bash4() {
  # Already Bash 4+?
  if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
    return 0
  fi

  info "Current Bash is ${BASH_VERSION} (< 4.0). Looking for Bash 4+..."

  local new_bash
  if new_bash="$(_detect_bash4)"; then
    info "Found Bash 4+ at: $new_bash"
    info "Re-executing setup.sh under Bash 4+..."
    exec "$new_bash" "$_SETUP_SCRIPT_PATH" "${_SETUP_ORIG_ARGS[@]+"${_SETUP_ORIG_ARGS[@]}"}"
    # exec replaces the process; if we get here, exec failed
    error "Failed to re-exec under $new_bash"
    return 1
  fi

  # No Bash 4+ found
  return 1
}

# Main entry point
# ---------------------------------------------------------------------------

# Run all prerequisite checks. Returns non-zero on critical failure.
check_prerequisites() {
  section "必要なツールを確認中 / Checking prerequisites"

  # Dry-run mode: only light prerequisites (git, jq, curl) are checked.
  # Heavy installs (Homebrew, Node, etc.) are skipped entirely.
  # Interactive: offer to install missing light tools with user consent.
  # Non-interactive: list missing tools and abort without installing.
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    local _dr_missing=()
    command -v git  &>/dev/null && ok "git $(git --version | awk '{print $3}')"  || _dr_missing+=("git")
    command -v jq   &>/dev/null && ok "jq $(jq --version 2>/dev/null || echo '?')" || _dr_missing+=("jq")
    command -v curl &>/dev/null && ok "curl found" || _dr_missing+=("curl")
    if _detect_gnu_sed; then ok "GNU sed ($_GNU_SED)"; else _dr_missing+=("gnu-sed"); fi
    if _detect_gnu_awk; then ok "GNU awk ($_GNU_AWK)"; else _dr_missing+=("gawk"); fi

    if [[ ${#_dr_missing[@]} -eq 0 ]]; then
      ok "必要なツールはすべて揃っています / All prerequisites satisfied (dry-run)"
      return 0
    fi

    # Missing tools found
    warn "Dry-run に必要なツールが不足しています / Missing tools for dry-run: ${_dr_missing[*]}"

    if [[ "${WIZARD_NONINTERACTIVE:-false}" == "true" ]]; then
      error "Non-interactive dry-run: 不足ツールの導入は行いません。手動でインストールして再実行してください。"
      error "Non-interactive dry-run: will not install missing tools. Please install manually and re-run."
      return 1
    fi

    # Interactive: ask for consent before installing
    info "Dry-run のシミュレーションに上記ツールが必要です。導入しますか？"
    info "The above tools are needed to run the simulation. Install them?"
    printf "  [Y]es / [N]o ? " >&2
    local _dr_confirm=""
    if read -r _dr_confirm < /dev/tty 2>/dev/null; then
      true
    else
      _dr_confirm="n"
    fi
    case "$_dr_confirm" in
      [Yy]*)
        # Install only light prerequisites via normal check functions
        local _dr_failed=0
        for _dr_tool in "${_dr_missing[@]}"; do
          case "$_dr_tool" in
            git)     check_git     || _dr_failed=1 ;;
            jq)      check_jq      || _dr_failed=1 ;;
            curl)    check_curl    || _dr_failed=1 ;;
            gnu-sed) check_gnu_sed || _dr_failed=1 ;;
            gawk)    check_gnu_awk || _dr_failed=1 ;;
          esac
        done
        if [[ "$_dr_failed" -ne 0 ]]; then
          error "一部のツールをインストールできませんでした / Some tools could not be installed"
          return 1
        fi
        ;;
      *)
        error "Dry-run を中止しました / Dry-run aborted"
        return 1
        ;;
    esac
    ok "必要なツールはすべて揃っています / All prerequisites satisfied (dry-run)"
    return 0
  fi

  # macOS: try to ensure Homebrew is available (not fatal if it fails)
  _ensure_homebrew

  # MSYS/Git Bash: ensure ~/.local/bin is in PATH for standalone tools
  if is_msys; then
    export PATH="$HOME/.local/bin:$PATH"
  fi

  local failed=0

  check_git     || failed=1
  check_jq      || failed=1
  check_curl    || failed=1
  check_gnu_sed || failed=1
  check_gnu_awk || failed=1
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
