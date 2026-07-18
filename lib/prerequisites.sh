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
# Node.js major version to install when missing or too old
NODE_MAJOR="${NODE_MAJOR:-24}"
NODE_MIN_MAJOR="${NODE_MIN_MAJOR:-22}"
NODE_MIN_MINOR="${NODE_MIN_MINOR:-19}"

# Portable timeout wrapper (macOS lacks `timeout` from coreutils)
_run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@"
  else
    local _stdout_file _stderr_file
    _stdout_file="$(mktemp)"
    _stderr_file="$(mktemp)"
    if declare -p _SETUP_TMP_FILES &>/dev/null; then
      _SETUP_TMP_FILES+=("$_stdout_file" "$_stderr_file")
    fi

    "$@" >"$_stdout_file" 2>"$_stderr_file" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local watcher=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    cat "$_stdout_file"
    cat "$_stderr_file" >&2
    return "$rc"
  fi
}

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

_prereq_mdm_managed() {
  case "$(printf '%s' "${KIT_MDM_MANAGED:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

_prereq_mdm_mode_valid() {
  _prereq_mdm_managed || return 0
  case "${KIT_MDM_PREREQ_MODE:-auto}" in
    auto|fail) return 0 ;;
    *)
      warn "Invalid KIT_MDM_PREREQ_MODE in managed mode (expected auto or fail)."
      return 1
      ;;
  esac
}

_prereq_mdm_fail_mode() {
  _prereq_mdm_managed || return 1
  _prereq_mdm_mode_valid || return 2
  [[ "${KIT_MDM_PREREQ_MODE:-auto}" == "fail" ]]
}

# Ensure Homebrew is installed, in PATH, and writable by the current user.
# On Apple Silicon, brew lives at /opt/homebrew/bin/brew.
# On Intel, it lives at /usr/local/bin/brew.
_ensure_homebrew() {
  _prereq_mdm_mode_valid || return 1
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

  # The privileged MDM wrapper is the sole Homebrew provisioning authority.
  # Never fall back to Homebrew's curl installer from target-user setup.
  if _prereq_mdm_managed; then
    warn "Homebrew is unavailable or not writable in MDM managed mode"
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
  _prereq_mdm_mode_valid || return 1
  if _prereq_mdm_fail_mode; then
    warn "MDM prerequisite mode is fail; will not install: $*"
    return 1
  fi
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
  if _pkg_install git && command -v git &>/dev/null; then
    ok "git installed"
    return 0
  fi
  warn "Failed to install git automatically."
  return 1
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
  if _pkg_install jq && command -v jq &>/dev/null; then
    ok "jq installed"
    return 0
  fi
  warn "Failed to install jq automatically."
  return 1
}

check_curl() {
  if command -v curl &>/dev/null; then
    ok "curl found"
    return 0
  fi
  info "Installing curl..."
  if _pkg_install curl && command -v curl &>/dev/null; then
    ok "curl installed"
    return 0
  fi
  warn "Failed to install curl automatically."
  return 1
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
  # Consume the complete version output so pipefail does not treat the
  # producer's SIGPIPE from an early grep exit as a detection failure.
  # Check if 'sed' itself is GNU
  if sed --version 2>/dev/null | grep "GNU sed" >/dev/null; then
    _GNU_SED="sed"
    return 0
  fi
  # Check for gsed (brew install gnu-sed)
  if command -v gsed &>/dev/null && gsed --version 2>/dev/null | grep "GNU sed" >/dev/null; then
    _GNU_SED="gsed"
    return 0
  fi
  return 1
}

_detect_gnu_awk() {
  # Check if 'awk' itself is GNU
  if awk --version 2>/dev/null | grep "GNU Awk" >/dev/null; then
    _GNU_AWK="awk"
    return 0
  fi
  # Check for gawk (brew install gawk)
  if command -v gawk &>/dev/null && gawk --version 2>/dev/null | grep "GNU Awk" >/dev/null; then
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
  info "Installing tmux..."
  if _pkg_install tmux; then
    ok "tmux installed"
    return 0
  fi
  warn "Failed to install tmux automatically. Install with: $(_tmux_install_hint)"
  return 1
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
  if _prereq_mdm_managed; then
    _prereq_mdm_mode_valid || return 1
    case "${KIT_MDM_REQUIRE_NODE_RUNTIME:-}" in
      false)
        ok "node runtime is not required by the managed profile"
        return 0
        ;;
      true) ;;
      *)
        warn "Invalid managed Node runtime requirement flag."
        return 1
        ;;
    esac
    _mdm_resolve_private_node_toolchain || {
      warn "The pinned root-private Node runtime is unavailable or invalid."
      return 1
    }
    # `fail` forbids acquiring/building the privileged prerequisite; it does
    # not make target-user activation read-only. A package may preseed only
    # the trusted root-private tree, so both modes create or repair the local
    # link offline. Preserve an already exact activation inode.
    if ! _mdm_validate_private_node_activation; then
      _mdm_prepare_user_local_base || return 1
      _mdm_install_component_link node "$_MDM_PREREQ_NODE" || return 1
    fi
    _mdm_validate_private_node_activation || return 1
    ok "node v$_MDM_NODE_VERSION (MDM pinned runtime)"
    return 0
  fi

  # Homebrew versioned Node formulae are keg-only. Activate an already
  # installed ordinary-user formula before deciding an install is required.
  if ! command -v node &>/dev/null; then
    _activate_existing_brew_node || true
  fi
  if command -v node &>/dev/null; then
    local node_version
    node_version="$(node --version 2>/dev/null || true)"
    if _prereq_node_version_is_supported "$node_version"; then
      ok "node $node_version"
      return 0
    fi
    warn "Node.js $node_version is below required ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}+."
  fi
  if ! command -v node &>/dev/null; then
    warn "Node.js not found."
  fi
  info "Installing Node.js ${NODE_MAJOR}.x..."
  if _install_node && command -v node &>/dev/null; then
    local installed_version
    installed_version="$(node --version 2>/dev/null || true)"
    if _prereq_node_version_is_supported "$installed_version"; then
      ok "node $installed_version installed"
      return 0
    fi
    warn "Installed Node.js $installed_version is still below required ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}+."
    _show_node_manual_instructions
    return 1
  else
    warn "Could not install Node.js automatically."
    _show_node_manual_instructions
    return 1
  fi
}

_prereq_node_version_is_supported() {
  local version="${1#v}" major minor rest
  major="${version%%.*}"
  rest="${version#*.}"
  [[ "$rest" != "$version" ]] || return 1
  minor="${rest%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  if [[ "$major" -gt "$NODE_MIN_MAJOR" ]]; then
    return 0
  fi
  [[ "$major" -eq "$NODE_MIN_MAJOR" && "$minor" -ge "$NODE_MIN_MINOR" ]]
}

_activate_existing_brew_node() {
  [[ "$DISTRO_FAMILY" == "macos" ]] || return 1
  command -v brew &>/dev/null || return 1
  local node_prefix previous_path
  node_prefix="$(brew --prefix "node@${NODE_MAJOR}" 2>/dev/null)" || return 1
  [[ -n "$node_prefix" && -x "$node_prefix/bin/node" ]] || return 1
  previous_path="$PATH"
  if ! _add_to_path_now_and_persist \
      "$node_prefix/bin" "Node.js (brew keg-only, added by claude-code-starter-kit)"; then
    export PATH="$previous_path"
    return 1
  fi
  command -v node &>/dev/null
}

_install_node_via_nvm() {
  # MDM setup must not execute an independently downloaded shell installer.
  # The wrapper provisions a target-user-writable Homebrew first; if that path
  # cannot install Node, fail and let remediation report the error.
  if _prereq_mdm_managed; then
    warn "nvm bootstrap is disabled in MDM managed mode"
    return 1
  fi
  info "Installing Node.js via nvm (no admin required)..."
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  mkdir -p "$NVM_DIR"
  if curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh | bash; then
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
  local installed_version=""
  _prereq_mdm_mode_valid || return 1
  if _prereq_mdm_fail_mode; then
    warn "MDM prerequisite mode is fail; will not install Node.js"
    return 1
  fi
  case "$DISTRO_FAMILY" in
    macos)
      if _brew_is_usable; then
        brew install "node@${NODE_MAJOR}" 2>/dev/null || true
        # node@XX is keg-only (not symlinked into PATH). Add its bin dir
        # for the current session and persist it in the user's shell rc file.
        _activate_existing_brew_node || true
      fi
      ;;
    debian)
      # Try NodeSource first. The effective PATH version is checked below;
      # package-manager success alone does not prove the old Node was replaced.
      if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" 2>/dev/null | sudo -E bash - 2>/dev/null \
         && sudo apt-get install -y nodejs 2>/dev/null; then
        :
      else
        warn "NodeSource setup failed. Falling back to nvm..."
      fi
      ;;
    rhel)
      if curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" 2>/dev/null | sudo bash - 2>/dev/null \
         && sudo dnf install -y nodejs 2>/dev/null; then
        :
      else
        warn "NodeSource setup failed. Falling back to nvm..."
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
      ;;
    *) ;;
  esac

  # An older Node still satisfies `command -v`, and a successful package
  # manager may install a newer binary behind that old PATH entry. Validate
  # the command setup will actually execute before suppressing the fallback.
  installed_version="$(node --version 2>/dev/null || true)"
  if ! _prereq_node_version_is_supported "$installed_version"; then
    _install_node_via_nvm
  fi
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
  if _pkg_install dos2unix; then
    ok "dos2unix installed"
    return 0
  fi
  warn "Failed to install dos2unix automatically."
  warn "  Or: sudo apt-get install dos2unix"
  return 1
}

check_gh() {
  if command -v gh &>/dev/null; then
    ok "gh $(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
    return 0
  fi
  info "Installing GitHub CLI (gh)..."
  if _pkg_install gh; then
    ok "gh installed"
    return 0
  fi
  warn "Failed to install GitHub CLI automatically."
  warn "  Install: https://cli.github.com/"
  case "$DISTRO_FAMILY" in
    macos)  warn "  Or: brew install gh" ;;
    debian) warn "  Or: https://github.com/cli/cli/blob/trunk/docs/install_linux.md" ;;
    rhel)   warn "  Or: sudo dnf install gh" ;;
    *)      ;;
  esac
  return 1
}

_npm_global_install() {
  local executable="$1"
  local package="$2"
  shift 2
  # Managed components have dedicated pinned-artifact installers below. A
  # generic registry install must never become a fallback authority.
  _prereq_mdm_managed && return 1
  command -v npm &>/dev/null || return 1

  local npm_prefix=""
  npm_prefix="$(npm config get prefix 2>/dev/null || echo "")"
  [[ -n "$npm_prefix" ]] || return 1
  export PATH="${npm_prefix}/bin:$PATH"

  if [[ -w "$npm_prefix" || -w "${npm_prefix}/lib" ]]; then
    local npm_args=(install -g)
    if npm "${npm_args[@]}" "$@" "$package" 2>/dev/null \
      && command -v "$executable" &>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Resolve a file through its symlink chain without depending on GNU realpath.
# Every managed component validator compares the result with a fixed absolute
# layout before executing it.
_prereq_canonical_file() {
  local path="$1" target dir base hops=0
  local sentinel=':claude-kit-prereq-readlink-end:'
  [[ "$path" == /* && ! "$path" =~ [[:cntrl:]] ]] || return 1

  while [[ -L "$path" ]]; do
    (( hops += 1 ))
    [[ "$hops" -le 16 ]] || return 1
    target="$({
      /usr/bin/readlink -n "$path" 2>/dev/null || exit 1
      printf '%s' "$sentinel"
    })" || return 1
    [[ "$target" == *"$sentinel" ]] || return 1
    target="${target%"$sentinel"}"
    [[ -n "$target" && ! "$target" =~ [[:cntrl:]] ]] || return 1
    if [[ "$target" == /* ]]; then
      path="$target"
    else
      dir="$(builtin cd -P "${path%/*}" 2>/dev/null && pwd -P)" || return 1
      path="$dir/$target"
    fi
  done

  [[ -f "$path" ]] || return 1
  dir="$(builtin cd -P "${path%/*}" 2>/dev/null && pwd -P)" || return 1
  base="${path##*/}"
  printf '%s/%s' "$dir" "$base"
}

_prereq_canonical_real_dir() {
  local path="$1" canonical
  [[ "$path" == /* && -d "$path" && ! -L "$path" ]] || return 1
  canonical="$(builtin cd -P "$path" 2>/dev/null && pwd -P)" || return 1
  [[ "$canonical" == "$path" ]]
}

_prereq_file_has_one_link() {
  local links
  if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
    links="$(/usr/bin/stat -f '%l' "$1" 2>/dev/null)" || return 1
  else
    links="$(/usr/bin/stat -c '%h' "$1" 2>/dev/null)" || return 1
  fi
  [[ "$links" == "1" ]]
}

_prereq_semver_is_valid() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
}

_prereq_cli_version_matches() {
  local output="$1" expected="$2" first_line
  first_line="${output%%$'\n'*}"
  first_line="${first_line%$'\r'}"
  case "$first_line" in
    "$expected"|"Version: $expected"|"biome $expected"|"cc-safety-net $expected")
      return 0
      ;;
    *) return 1 ;;
  esac
}

# MDM-managed hook runtimes are pinned artifacts, not package-manager state.
# The privileged wrapper distributes a root-private Node tree; target-user
# setup resolves that exact tree and never grants PATH, Homebrew, npm config,
# or an existing user-local package authority over these components.
_MDM_NODE_VERSION="24.18.0"
_MDM_NODE_NPM_VERSION="11.16.0"
_MDM_NODE_PROVENANCE_FILE=".claude-code-starter-kit-node-runtime"
_MDM_NODE_ARM64_SOURCE_URL="https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-arm64.tar.xz"
_MDM_NODE_ARM64_SOURCE_SHA256="4477b9f78efb77744cf5eb57a0e9594dba66466b38b4e93fa9f35cb907a095a6"
_MDM_NODE_ARM64_CONTENT_SHA256="3b87679d20e675468b9281755c823b528b6406ba7af6cc7086ef00e5c8af6533"
_MDM_NODE_X64_SOURCE_URL="https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-x64.tar.xz"
_MDM_NODE_X64_SOURCE_SHA256="4a3b6bc81542154430825128d9a279e8b364e8d90581544e506ef7579fd1ab6f"
_MDM_NODE_X64_CONTENT_SHA256="a9f69014ea08981c1b1822f565a39ae6970a319518ebf3e43d96ba9fc70aa209"
_MDM_BIOME_VERSION="2.5.4"
_MDM_CC_SAFETY_NET_VERSION="1.0.6"

_MDM_BIOME_ARM64_URL="https://registry.npmjs.org/@biomejs/cli-darwin-arm64/-/cli-darwin-arm64-2.5.4.tgz"
_MDM_BIOME_ARM64_ARCHIVE_SHA256="befd5504c242b0174f9f57c9b2f2b14fd106c5f4568bee1b204d1369b890a688"
_MDM_BIOME_ARM64_BINARY_SHA256="1250bb41a0409cf6c3133fc47819237eb61251624297f87158d2bed3ec123c3c"
_MDM_BIOME_ARM64_PACKAGE_SHA256="54947a4827f0a6960d84eae39de98dba707b6f9222a276beaaa54ab4014dc68c"
_MDM_BIOME_X64_URL="https://registry.npmjs.org/@biomejs/cli-darwin-x64/-/cli-darwin-x64-2.5.4.tgz"
_MDM_BIOME_X64_ARCHIVE_SHA256="12e7076f80070aa085653f67fc1cb88f658253c67eb35677fab7c80c5aceb3cb"
_MDM_BIOME_X64_BINARY_SHA256="b3dfae5422dbd86272bb8ed40afec66670ea7754531d8fbcbae7e445e5430387"
_MDM_BIOME_X64_PACKAGE_SHA256="f25fac4d876cbd18fe78753dd06fde9a12607a76006546cf6a9549a8f1fb511f"
_MDM_CC_SAFETY_NET_URL="https://registry.npmjs.org/cc-safety-net/-/cc-safety-net-1.0.6.tgz"
_MDM_CC_SAFETY_NET_ARCHIVE_SHA256="588a23f77637f34b99b6fcff68787b19d2cf692470c284ec633e982008b0a6ab"
_MDM_CC_SAFETY_NET_JS_SHA256="1ffbfafabf2fe4fc9b6bf64a8088ca3a96c2714cf8fd8afd5b1b326582c982d4"
_MDM_CC_SAFETY_NET_PACKAGE_SHA256="2e57b465553ba97e1e6f7a37655fc52e31cad4ca739140bb7af40d052e3d88c8"

_MDM_PREREQ_NODE=""
_MDM_PREREQ_NPM=""
_MDM_SELECTED_ARTIFACT_URL=""
_MDM_SELECTED_ARCHIVE_SHA256=""
_MDM_SELECTED_BINARY_SHA256=""
_MDM_SELECTED_PACKAGE_SHA256=""

_prereq_sha256_file() {
  local path="$1"
  if [[ -x /usr/bin/shasum ]]; then
    /usr/bin/shasum -a 256 "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
  elif [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
  elif [[ -x /bin/sha256sum ]]; then
    /bin/sha256sum "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
  else
    return 1
  fi
}

_prereq_stat_mode() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == "Darwin" ]]; then
    /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%a' "$1" 2>/dev/null
  fi
}

_prereq_stat_uid() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == "Darwin" ]]; then
    /usr/bin/stat -f '%u' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%u' "$1" 2>/dev/null
  fi
}

_prereq_stat_gid() {
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == "Darwin" ]]; then
    /usr/bin/stat -f '%g' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%g' "$1" 2>/dev/null
  fi
}

_prereq_mode_is() {
  [[ "$(_prereq_stat_mode "$1")" == "$2" ]]
}

_prereq_root_owned_not_writable() {
  local path="$1" mode
  [[ "$(_prereq_stat_uid "$path")" == "0" ]] || return 1
  mode="$(_prereq_stat_mode "$path")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}

_prereq_tree_acl_safe() {
  local root="$1"
  local -a status
  [[ "$(/usr/bin/uname -s 2>/dev/null)" == "Darwin" ]] || return 0
  [[ -d "$root" && ! -L "$root" ]] || return 1
  # `ls -le` emits every extended ACL entry on a separate numbered line.
  # Consume the complete recursive listing when there is no match so an ls
  # traversal error cannot be mistaken for an ACL-free tree.
  if LC_ALL=C /bin/ls -leR "$root" 2>/dev/null \
      | /usr/bin/grep -Eq '^[[:space:]]*[0-9]+:[[:space:]]'; then
    status=("${PIPESTATUS[@]}")
  else
    status=("${PIPESTATUS[@]}")
  fi
  [[ "${status[0]:-1}" -eq 0 && "${status[1]:-0}" -eq 1 ]]
}

_prereq_path_acl_safe() {
  local path="$1" listing first permissions
  [[ "$(/usr/bin/uname -s 2>/dev/null || true)" != Darwin ]] && return 0
  listing="$(LC_ALL=C /bin/ls -lde "$path" 2>/dev/null)" || return 1
  first="${listing%%$'\n'*}"
  permissions="${first%%[[:space:]]*}"
  [[ "$first" == *[[:space:]]* \
    && "$permissions" =~ ^[-bcdlps][rwxStTs-]{9}[@+]?$ \
    && "$permissions" != *+* \
    && "$listing" != *$'\n'* ]]
}

_prereq_exact_text_file() { # <regular-file> <expected-without-final-LF>
  local path="$1" expected="$2"
  [[ -x /usr/bin/python3 && ! -L /usr/bin/python3 ]] || return 1
  /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /usr/bin/python3 -I -B - "$path" "$expected" <<'PY'
import os
import stat
import sys

path, expected_text = sys.argv[1:]
expected = expected_text.encode("utf-8", "strict") + b"\n"

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, "st_flags", 0),
            getattr(value, "st_gen", 0))

try:
    before = os.lstat(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW
                         | getattr(os, "O_CLOEXEC", 0))
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                or identity(opened) != identity(before)
                or opened.st_size != len(expected)):
            raise ValueError("unsafe exact-text file")
        actual = os.read(descriptor, len(expected) + 1)
        if actual != expected or os.read(descriptor, 1):
            raise ValueError("exact-text mismatch")
    finally:
        os.close(descriptor)
    if identity(os.lstat(path)) != identity(before):
        raise ValueError("exact-text file changed")
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PY
}

_prereq_symlink_value_exact() {
  local path="$1" expected="$2" value sentinel=':claude-kit-link-end:'
  [[ -L "$path" ]] || return 1
  value="$({
    /usr/bin/readlink -n "$path" 2>/dev/null || exit 1
    printf '%s' "$sentinel"
  })" || return 1
  [[ "$value" == "$expected$sentinel" ]]
}

_prereq_dir_has_exact_entries() {
  local dir="$1"
  shift
  (
    local path name expected found
    local -a actual
    shopt -s dotglob nullglob
    actual=("$dir"/*)
    [[ "${#actual[@]}" -eq "$#" ]] || exit 1
    for path in "${actual[@]}"; do
      name="${path##*/}"
      found=false
      for expected in "$@"; do
        if [[ "$name" == "$expected" ]]; then
          found=true
          break
        fi
      done
      [[ "$found" == true ]] || exit 1
    done
  )
}

_mdm_prereq_uname() {
  /usr/bin/uname "$@"
}

_mdm_prereq_sysctl() {
  /usr/sbin/sysctl "$@"
}

_mdm_current_darwin_arch() {
  local arm64 machine
  [[ "$(_mdm_prereq_uname -s 2>/dev/null)" == "Darwin" ]] || return 1
  # Intel macOS does not expose hw.optional.arm64.  -i turns that expected
  # unknown OID into an empty value, while the hardware bit remains stable
  # across native and Rosetta-translated processes on Apple Silicon.
  arm64="$(_mdm_prereq_sysctl -in hw.optional.arm64 2>/dev/null)" || return 1
  machine="$(_mdm_prereq_uname -m 2>/dev/null)" || return 1
  case "$arm64:$machine" in
    1:arm64|1:x86_64) printf '%s' arm64 ;;
    0:x86_64|:x86_64) printf '%s' x64 ;;
    *) return 1 ;;
  esac
}

_mdm_select_biome_artifact() {
  local arch="$1"
  case "$arch" in
    arm64)
      _MDM_SELECTED_ARTIFACT_URL="$_MDM_BIOME_ARM64_URL"
      _MDM_SELECTED_ARCHIVE_SHA256="$_MDM_BIOME_ARM64_ARCHIVE_SHA256"
      _MDM_SELECTED_BINARY_SHA256="$_MDM_BIOME_ARM64_BINARY_SHA256"
      _MDM_SELECTED_PACKAGE_SHA256="$_MDM_BIOME_ARM64_PACKAGE_SHA256"
      ;;
    x64)
      _MDM_SELECTED_ARTIFACT_URL="$_MDM_BIOME_X64_URL"
      _MDM_SELECTED_ARCHIVE_SHA256="$_MDM_BIOME_X64_ARCHIVE_SHA256"
      _MDM_SELECTED_BINARY_SHA256="$_MDM_BIOME_X64_BINARY_SHA256"
      _MDM_SELECTED_PACKAGE_SHA256="$_MDM_BIOME_X64_PACKAGE_SHA256"
      ;;
    *) return 1 ;;
  esac
}

_mdm_select_node_runtime_artifact() {
  local arch="$1"
  case "$arch" in
    arm64)
      _MDM_SELECTED_NODE_SOURCE_URL="$_MDM_NODE_ARM64_SOURCE_URL"
      _MDM_SELECTED_NODE_SOURCE_SHA256="$_MDM_NODE_ARM64_SOURCE_SHA256"
      _MDM_SELECTED_NODE_CONTENT_SHA256="$_MDM_NODE_ARM64_CONTENT_SHA256"
      ;;
    x64)
      _MDM_SELECTED_NODE_SOURCE_URL="$_MDM_NODE_X64_SOURCE_URL"
      _MDM_SELECTED_NODE_SOURCE_SHA256="$_MDM_NODE_X64_SOURCE_SHA256"
      _MDM_SELECTED_NODE_CONTENT_SHA256="$_MDM_NODE_X64_CONTENT_SHA256"
      ;;
    *) return 1 ;;
  esac
}

# Canonicalize the official runtime inventory exactly as the privileged MDM
# installer does: UTF-8 byte-sorted path/type/mode records plus regular-file
# bytes or symlink targets. The local provenance marker is intentionally
# excluded because it is issued after extracting the pinned official archive.
_mdm_private_node_content_sha256() { # <runtime-root> <trusted-node> [uid] [gid]
  local root="$1" node="$2" expected_uid="${3:-0}" expected_gid="${4:-0}"
  [[ "$root" == /* && "$node" == "$root/bin/node" \
    && "$expected_uid" =~ ^[0-9]+$ && "$expected_gid" =~ ^[0-9]+$ ]] \
    || return 1
  /usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$node" -e '
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const [root, provenance, uidText, gidText] = process.argv.slice(1);
const expectedUid = BigInt(uidText);
const expectedGid = BigInt(gidText);
const records = [];
let count = 0;
let total = 0n;

function identity(value) {
  return [value.dev, value.ino, value.mode, value.nlink, value.size,
    value.mtimeNs, value.ctimeNs].join(":");
}

function namesAt(value) {
  return fs.readdirSync(value, { encoding: "buffer" })
    .sort(Buffer.compare)
    .map((raw) => {
      const name = raw.toString("utf8");
      if (!Buffer.from(name, "utf8").equals(raw)) {
        throw new Error("non-UTF-8 runtime pathname");
      }
      return { name, raw };
    });
}

function visit(value, relative) {
  const before = fs.lstatSync(value, { bigint: true });
  count += 1;
  if (count > 100000 || before.uid !== expectedUid
      || before.gid !== expectedGid) {
    throw new Error("untrusted runtime metadata");
  }
  const modeValue = before.mode & 0o7777n;
  const mode = Number(modeValue).toString(8).padStart(4, "0");
  const base = { mode, path: relative };
  if (before.isDirectory()) {
    if ((modeValue & 0o022n) !== 0n) throw new Error("writable directory");
    records.push({ kind: "dir", mode: base.mode, path: base.path });
    const names = namesAt(value);
    for (const entry of names) {
      if (!relative && entry.name === provenance) continue;
      visit(path.join(value, entry.name),
        relative ? `${relative}/${entry.name}` : entry.name);
    }
    const afterNames = namesAt(value);
    if (afterNames.length !== names.length
        || afterNames.some((entry, index) => !entry.raw.equals(names[index].raw))) {
      throw new Error("runtime inventory changed");
    }
  } else if (before.isFile()) {
    if ((modeValue & 0o022n) !== 0n || before.size > 536870912n) {
      throw new Error("unsafe runtime file");
    }
    const descriptor = fs.openSync(value,
      fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const digest = crypto.createHash("sha256");
    let size = 0n;
    try {
      const opened = fs.fstatSync(descriptor, { bigint: true });
      if (opened.dev !== before.dev || opened.ino !== before.ino
          || opened.mode !== before.mode || opened.nlink !== before.nlink) {
        throw new Error("runtime file changed before read");
      }
      const buffer = Buffer.allocUnsafe(1024 * 1024);
      for (;;) {
        const length = fs.readSync(descriptor, buffer, 0, buffer.length, null);
        if (length === 0) break;
        digest.update(buffer.subarray(0, length));
        size += BigInt(length);
        total += BigInt(length);
        if (size > 536870912n || total > 2147483648n) {
          throw new Error("runtime content too large");
        }
      }
    } finally {
      fs.closeSync(descriptor);
    }
    if (size !== before.size) throw new Error("runtime file size changed");
    records.push({ kind: "file", mode: base.mode, path: base.path,
      sha256: digest.digest("hex"), size: Number(size) });
  } else if (before.isSymbolicLink()) {
    const raw = fs.readlinkSync(value, { encoding: "buffer" });
    const target = raw.toString("utf8");
    if (!Buffer.from(target, "utf8").equals(raw)) {
      throw new Error("non-UTF-8 runtime symlink");
    }
    records.push({ kind: "symlink", mode: "0777", path: base.path, target });
  } else {
    throw new Error("unsupported runtime entry");
  }
  const after = fs.lstatSync(value, { bigint: true });
  if (identity(before) !== identity(after)) {
    throw new Error("runtime entry changed");
  }
}

visit(root, "");
records.sort((left, right) => Buffer.compare(
  Buffer.from(left.path, "utf8"), Buffer.from(right.path, "utf8")));
const canonical = (JSON.stringify(records) + "\n").replace(
  /[\u007f-\uffff]/g,
  (value) => `\\u${value.charCodeAt(0).toString(16).padStart(4, "0")}`);
process.stdout.write(crypto.createHash("sha256").update(canonical, "ascii")
  .digest("hex"));
' "$root" "$_MDM_NODE_PROVENANCE_FILE" "$expected_uid" "$expected_gid" \
    2>/dev/null
}

_mdm_private_node_provenance_valid() { # <runtime-root> <arch>
  local root="$1" arch="$2" marker expected
  _mdm_select_node_runtime_artifact "$arch" || return 1
  marker="$root/$_MDM_NODE_PROVENANCE_FILE"
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  _prereq_file_has_one_link "$marker" || return 1
  _prereq_root_owned_not_writable "$marker" || return 1
  _prereq_mode_is "$marker" 444 || return 1
  expected="$(printf \
    'schema=1\nversion=v%s\narch=%s\nurl=%s\nsha256=%s' \
    "$_MDM_NODE_VERSION" "$arch" "$_MDM_SELECTED_NODE_SOURCE_URL" \
    "$_MDM_SELECTED_NODE_SOURCE_SHA256")" || return 1
  _prereq_exact_text_file "$marker" "$expected"
}

_mdm_resolve_private_node_toolchain() {
  _MDM_PREREQ_NODE=""
  _MDM_PREREQ_NPM=""
  KIT_MDM_NODE_RUNTIME_ROOT=""
  KIT_MDM_NODE_PATH=""
  KIT_MDM_NPM_PATH=""
  export KIT_MDM_NODE_RUNTIME_ROOT KIT_MDM_NODE_PATH KIT_MDM_NPM_PATH

  local arch root node npm npm_target npm_json dir output metadata version
  local process_arch content content_after
  arch="$(_mdm_current_darwin_arch)" || return 1
  _mdm_select_node_runtime_artifact "$arch" || return 1
  root="/Library/Application Support/ClaudeCodeStarterKit/runtime/node-v${_MDM_NODE_VERSION}-darwin-$arch"
  node="$root/bin/node"
  npm="$root/bin/npm"
  npm_target="$root/lib/node_modules/npm/bin/npm-cli.js"
  npm_json="$root/lib/node_modules/npm/package.json"

  for dir in / /Library "/Library/Application Support"; do
    _prereq_canonical_real_dir "$dir" || return 1
    _prereq_root_owned_not_writable "$dir" || return 1
    _prereq_mode_is "$dir" 755 || return 1
    _prereq_path_acl_safe "$dir" || return 1
  done
  for dir in "/Library/Application Support/ClaudeCodeStarterKit" \
    "/Library/Application Support/ClaudeCodeStarterKit/runtime" \
    "$root" "$root/bin" "$root/lib" "$root/lib/node_modules" \
    "$root/lib/node_modules/npm" "$root/lib/node_modules/npm/bin"; do
    _prereq_canonical_real_dir "$dir" || return 1
    _prereq_root_owned_not_writable "$dir" || return 1
    [[ "$(_prereq_stat_gid "$dir")" == 0 ]] || return 1
    _prereq_mode_is "$dir" 755 || return 1
    _prereq_path_acl_safe "$dir" || return 1
  done
  [[ -f "$node" && ! -L "$node" && -x "$node" ]] || return 1
  [[ -f "$npm_target" && ! -L "$npm_target" ]] || return 1
  [[ -f "$npm_json" && ! -L "$npm_json" ]] || return 1
  _prereq_file_has_one_link "$node" || return 1
  _prereq_file_has_one_link "$npm_target" || return 1
  _prereq_file_has_one_link "$npm_json" || return 1
  _prereq_root_owned_not_writable "$node" || return 1
  _prereq_root_owned_not_writable "$npm_target" || return 1
  _prereq_root_owned_not_writable "$npm_json" || return 1
  _prereq_symlink_value_exact "$npm" \
    '../lib/node_modules/npm/bin/npm-cli.js' || return 1
  [[ "$(_prereq_canonical_file "$npm")" == "$npm_target" ]] || return 1
  _prereq_tree_acl_safe "$root" || return 1

  _mdm_private_node_signature_trusted "$node" || return 1
  _mdm_private_node_provenance_valid "$root" "$arch" || return 1
  content="$(_mdm_private_node_content_sha256 "$root" "$node")" || return 1
  [[ "$content" == "$_MDM_SELECTED_NODE_CONTENT_SHA256" ]] || return 1
  output="$(/usr/bin/env -i HOME="$HOME" \
    PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" LC_ALL=C \
    "$node" --version 2>/dev/null)" || return 1
  [[ "$output" == "v$_MDM_NODE_VERSION" ]] || return 1
  process_arch="$(/usr/bin/env -i HOME="$HOME" \
    PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" LC_ALL=C \
    "$node" -p process.arch 2>/dev/null)" || return 1
  [[ "$process_arch" == "$arch" ]] || return 1
  metadata="$(/usr/bin/env -i HOME="$HOME" \
    PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" LC_ALL=C \
    "$node" -e '
    const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (p.name !== "npm" || typeof p.version !== "string") process.exit(1);
    process.stdout.write(p.version);
  ' "$npm_json" 2>/dev/null)" || return 1
  [[ "$metadata" == "$_MDM_NODE_NPM_VERSION" ]] || return 1
  version="$(/usr/bin/env -i HOME="$HOME" \
    PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" LC_ALL=C \
    "$npm" --version 2>/dev/null)" || return 1
  _prereq_cli_version_matches "$version" "$_MDM_NODE_NPM_VERSION" || return 1
  content_after="$(_mdm_private_node_content_sha256 "$root" "$node")" \
    || return 1
  [[ "$content_after" == "$content" ]] || return 1
  _prereq_tree_acl_safe "$root" || return 1

  _MDM_PREREQ_NODE="$node"
  _MDM_PREREQ_NPM="$npm"
  KIT_MDM_NODE_RUNTIME_ROOT="$root"
  KIT_MDM_NODE_PATH="$node"
  KIT_MDM_NPM_PATH="$npm"
  export KIT_MDM_NODE_RUNTIME_ROOT KIT_MDM_NODE_PATH KIT_MDM_NPM_PATH
}

_mdm_prereq_codesign() {
  /usr/bin/codesign "$@"
}

_mdm_private_node_signature_trusted() {
  local node="$1" requirement details
  requirement='=identifier "node" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "HX7739G8FX"'
  _mdm_prereq_codesign --verify --strict -R "$requirement" -- "$node" \
    >/dev/null 2>&1 || return 1
  details="$(_mdm_prereq_codesign -dv --verbose=4 -- "$node" 2>&1)" \
    || return 1
  printf '%s\n' "$details" | /usr/bin/grep -qx 'Identifier=node' \
    && printf '%s\n' "$details" | /usr/bin/grep -qx \
      'TeamIdentifier=HX7739G8FX' \
    && printf '%s\n' "$details" | /usr/bin/grep -qx \
      'Authority=Developer ID Application: Node.js Foundation (HX7739G8FX)' \
    && printf '%s\n' "$details" | /usr/bin/grep -qx \
      'Authority=Developer ID Certification Authority' \
    && printf '%s\n' "$details" | /usr/bin/grep -qx 'Authority=Apple Root CA'
}

_mdm_prepare_user_local_base() {
  local dir
  _prereq_canonical_real_dir "$HOME" || return 1
  for dir in "$HOME/.local" "$HOME/.local/bin" "$HOME/.local/lib" \
    "$HOME/.local/lib/claude-code-starter-kit"; do
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
      /bin/mkdir "$dir" || return 1
    fi
    _prereq_canonical_real_dir "$dir" || return 1
  done
}

_mdm_prepare_component_parent() {
  local component="$1" dir
  _mdm_prepare_user_local_base || return 1
  dir="$HOME/.local/lib/claude-code-starter-kit/$component"
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then
    /bin/mkdir "$dir" || return 1
  fi
  _prereq_canonical_real_dir "$dir"
}

_mdm_validate_private_node_activation() {
  local link="$HOME/.local/bin/node"
  _prereq_canonical_real_dir "$HOME/.local/bin" || return 1
  [[ -n "$_MDM_PREREQ_NODE" ]] || return 1
  _prereq_symlink_value_exact "$link" "$_MDM_PREREQ_NODE" || return 1
  [[ "$(_prereq_canonical_file "$link")" == "$_MDM_PREREQ_NODE" ]]
}

_mdm_download_pinned_artifact() {
  local url="$1" expected_sha="$2" destination="$3" proxy
  local -a clean_env
  _prereq_mdm_managed || return 1
  _prereq_mdm_fail_mode && return 1
  [[ "$url" == https://registry.npmjs.org/* \
    && "$expected_sha" =~ ^[0-9a-f]{64}$ \
    && ! -e "$destination" && ! -L "$destination" ]] || return 1
  clean_env=(/usr/bin/env -i "HOME=$HOME" "LC_ALL=C" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin")
  for proxy in HTTPS_PROXY NO_PROXY https_proxy no_proxy; do
    [[ -n "${!proxy:-}" ]] && clean_env+=("$proxy=${!proxy}")
  done
  if ! printf '%s\n' \
    "url = \"$url\"" \
    'fail' 'location' 'silent' 'show-error' \
    'proto = "=https"' 'proto-redir = "=https"' \
    | "${clean_env[@]}" /usr/bin/curl --config - > "$destination"; then
    /bin/rm -f "$destination" 2>/dev/null || true
    return 1
  fi
  if [[ "$(_prereq_sha256_file "$destination")" != "$expected_sha" ]]; then
    /bin/rm -f "$destination" 2>/dev/null || true
    return 1
  fi
}

_mdm_extract_pinned_regular_member() {
  local archive="$1" member="$2" destination="$3" names verbose
  [[ "$member" =~ ^package/[A-Za-z0-9._/-]+$ \
    && ! "$member" =~ (^|/)\.\.(/|$) \
    && ! -e "$destination" && ! -L "$destination" ]] || return 1
  names="$(/usr/bin/tar -tzf "$archive" "$member" 2>/dev/null)" || return 1
  [[ "$names" == "$member" ]] || return 1
  verbose="$(LC_ALL=C /usr/bin/tar -tvzf "$archive" "$member" 2>/dev/null)" \
    || return 1
  [[ "${verbose:0:1}" == "-" && "$verbose" != *$'\n'* ]] || return 1
  /usr/bin/tar -xOzf "$archive" "$member" > "$destination" 2>/dev/null \
    || { /bin/rm -f "$destination" 2>/dev/null || true; return 1; }
  [[ -f "$destination" && ! -L "$destination" ]] || return 1
}

_mdm_atomic_replace_component_leaf() {
  local candidate="$1" destination="$2" replacement_kind="${3:-component}"
  local parent _rc=0 _output=""
  _MDM_COMPONENT_PRESERVE_TOKEN=""
  parent="${destination%/*}"
  case "$replacement_kind" in
    component|link|link-preserve-dir) : ;;
    *) return 1 ;;
  esac
  _prereq_canonical_real_dir "$parent" || return 1
  [[ -x /usr/bin/python3 \
    && "$candidate" == "$parent/"* \
    && "${candidate#"$parent/"}" != */* \
    && "$destination" == "$parent/"* \
    && "${destination#"$parent/"}" != */* \
    && "$candidate" != "$destination" ]] || return 1

  # The candidate is created in the destination directory, so an atomic
  # renameat swap can publish it without ever making the fixed leaf absent.
  # All decisions and cleanup stay bound to one O_NOFOLLOW parent descriptor;
  # a post-rename identity mismatch is rolled back before any old content is
  # removed.  This also avoids the old `.starter-kit-old.*` crash residue.
  _output="$(/usr/bin/env -i HOME="$HOME" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /usr/bin/python3 -I -B - "$candidate" "$destination" \
      "$replacement_kind" <<'PY'
import ctypes
import errno
import os
import stat
import sys

candidate_path, destination_path, replacement_kind = sys.argv[1:]
parent_path = os.path.dirname(destination_path)
candidate_parent = os.path.dirname(candidate_path)
candidate_name = os.path.basename(candidate_path)
destination_name = os.path.basename(destination_path)

if (not parent_path or candidate_parent != parent_path
        or not candidate_name or not destination_name
        or "/" in candidate_name or "/" in destination_name
        or candidate_name in (".", "..")
        or destination_name in (".", "..")
        or candidate_name == destination_name):
    raise SystemExit(1)

directory_flags = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                   | getattr(os, "O_CLOEXEC", 0))
parent = os.open(parent_path, directory_flags)
published = False
publication_verified = False
cleanup_started = False
candidate_before = None
destination_before = None
exchange_before = None
destination_after = None
candidate_after = None


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_nlink)


def stable_identity(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode),
            value.st_uid, value.st_gid)


def at(name):
    return os.stat(name, dir_fd=parent, follow_symlinks=False)


def supported(value):
    return (stat.S_ISDIR(value.st_mode) or stat.S_ISREG(value.st_mode)
            or stat.S_ISLNK(value.st_mode))


def serialized(value):
    return ":".join(str(part) for part in identity(value))


def entry_kind(value):
    if value is None:
        return "none"
    if stat.S_ISDIR(value.st_mode):
        return "directory"
    if stat.S_ISREG(value.st_mode):
        return "file"
    if stat.S_ISLNK(value.st_mode):
        return "link"
    raise ValueError("unsupported preserved entry")


def rename_atomic(source, destination, operation):
    libc = ctypes.CDLL(None, use_errno=True)
    source_value = os.fsencode(source)
    destination_value = os.fsencode(destination)
    if sys.platform == "darwin":
        call = libc.renameatx_np
        call.argtypes = [ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        call.restype = ctypes.c_int
        flags = 0x00000004 if operation == "create" else 0x00000002
    elif sys.platform.startswith("linux"):
        call = libc.renameat2
        call.argtypes = [ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        call.restype = ctypes.c_int
        flags = 0x00000001 if operation == "create" else 0x00000002
    else:
        raise OSError(errno.ENOTSUP, "atomic rename is unavailable")
    ctypes.set_errno(0)
    if call(parent, source_value, parent, destination_value, flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error or errno.EIO, "atomic rename failed")


removed = 0


def remove_bound(parent_fd, name, expected, depth=0):
    global removed
    if depth > 128 or removed > 100000:
        raise ValueError("old component tree exceeds cleanup bounds")
    current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if stable_identity(current) != stable_identity(expected):
        raise ValueError("old component identity changed")
    if not stat.S_ISDIR(current.st_mode):
        os.unlink(name, dir_fd=parent_fd)
        removed += 1
        return
    descriptor = os.open(name, directory_flags, dir_fd=parent_fd)
    try:
        opened = os.fstat(descriptor)
        if stable_identity(opened) != stable_identity(expected):
            raise ValueError("old component directory changed")
        for child in os.listdir(descriptor):
            if child in (".", ".."):
                raise ValueError("invalid component entry")
            child_value = os.stat(child, dir_fd=descriptor,
                                  follow_symlinks=False)
            if not supported(child_value):
                raise ValueError("unsupported old component entry")
            remove_bound(descriptor, child, child_value, depth + 1)
        if os.listdir(descriptor):
            raise ValueError("old component directory changed during cleanup")
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if stable_identity(current) != stable_identity(opened):
            raise ValueError("old component root changed during cleanup")
    finally:
        os.close(descriptor)
    os.rmdir(name, dir_fd=parent_fd)
    removed += 1


def unlink_candidate_if_exact(expected):
    # Callers must never perform a pathname-only cleanup after this helper
    # returns.  A concurrently replaced candidate belongs to the replacer and
    # is deliberately left untouched.  Directory stages are also retained on
    # failure because their contents cannot be identity-bound cheaply.
    if expected is None or stat.S_ISDIR(expected.st_mode):
        return
    try:
        current = at(candidate_name)
    except FileNotFoundError:
        return
    if identity(current) == identity(expected):
        os.unlink(candidate_name, dir_fd=parent)
        os.fsync(parent)


def rollback_published():
    """Reverse only the exact publication still present at both bound names."""
    global published
    if not published:
        return False
    try:
        current_destination = at(destination_name)
    except FileNotFoundError:
        return False
    current_candidate = None
    try:
        current_candidate = at(candidate_name)
    except FileNotFoundError:
        pass
    if (stable_identity(os.fstat(parent)) != stable_identity(parent_before)
            or identity(current_destination) != identity(candidate_before)):
        return False

    # exchange_before is re-captured immediately before the syscall. It binds
    # the inode actually exchanged even when the fixed destination changed
    # after the first validation. A later replacement at either name fails
    # these identity checks and is never moved or deleted.
    expected_old = exchange_before
    if destination_before is None:
        if expected_old is not None or current_candidate is not None:
            return False
        rename_atomic(destination_name, candidate_name, "create")
    else:
        if (expected_old is None or current_candidate is None
                or identity(current_candidate) != identity(expected_old)):
            return False
        rename_atomic(candidate_name, destination_name, "swap")
    os.fsync(parent)

    restored_candidate = at(candidate_name)
    if identity(restored_candidate) != identity(candidate_before):
        raise ValueError("publication rollback candidate mismatch")
    if destination_before is None:
        try:
            at(destination_name)
        except FileNotFoundError:
            pass
        else:
            raise ValueError("publication rollback left destination")
    elif identity(at(destination_name)) != identity(expected_old):
        raise ValueError("publication rollback destination mismatch")
    published = False
    return True


try:
    parent_before = os.fstat(parent)
    candidate_before = at(candidate_name)
    if (not supported(candidate_before)
            or candidate_before.st_uid != os.geteuid()
            or (not stat.S_ISDIR(candidate_before.st_mode)
                and candidate_before.st_nlink != 1)):
        raise ValueError("unsafe component candidate")
    if (replacement_kind in ("link", "link-preserve-dir")
            and not stat.S_ISLNK(candidate_before.st_mode)):
        raise ValueError("link publication requires a symlink candidate")
    try:
        destination_before = at(destination_name)
    except FileNotFoundError:
        destination_before = None
    if destination_before is not None:
        if (not supported(destination_before)
                or destination_before.st_uid != os.geteuid()
                or (not stat.S_ISDIR(destination_before.st_mode)
                    and destination_before.st_nlink != 1)):
            raise ValueError("unsafe existing component")
        if (replacement_kind == "link"
                and stat.S_ISDIR(destination_before.st_mode)):
            raise ValueError("refusing to replace a directory with a link")
        if (replacement_kind == "link-preserve-dir"
                and stat.S_ISDIR(destination_before.st_mode)
                and stat.S_IMODE(destination_before.st_mode) & 0o022):
            raise ValueError("refusing writable activation directory")

    operation = "create" if destination_before is None else "swap"
    # Bind the exact object that the atomic syscall will exchange. This closes
    # the first-validation-to-rename type race and also gives every exception
    # after rename enough identity evidence for a safe inverse operation.
    if destination_before is None:
        try:
            exchange_before = at(destination_name)
        except FileNotFoundError:
            exchange_before = None
        if exchange_before is not None:
            raise ValueError("component destination appeared before create")
    else:
        exchange_before = at(destination_name)
        if (not supported(exchange_before)
                or exchange_before.st_uid != os.geteuid()
                or (not stat.S_ISDIR(exchange_before.st_mode)
                    and exchange_before.st_nlink != 1)
                or (stat.S_ISDIR(exchange_before.st_mode)
                    and stat.S_IMODE(exchange_before.st_mode) & 0o022)):
            raise ValueError("unsafe component at exchange time")
    rename_atomic(candidate_name, destination_name, operation)
    published = True
    os.fsync(parent)
    destination_after = at(destination_name)
    try:
        candidate_after = at(candidate_name)
    except FileNotFoundError:
        pass
    valid = (identity(destination_after) == identity(candidate_before)
             and stable_identity(os.fstat(parent))
             == stable_identity(parent_before))
    if destination_before is None:
        valid = valid and candidate_after is None
    else:
        valid = (valid and candidate_after is not None
                 and identity(candidate_after) == identity(destination_before))
    if not valid:
        rollback_published()
        raise ValueError("component publish identity mismatch")

    if replacement_kind == "link-preserve-dir":
        old_identity = "-" if destination_before is None \
            else serialized(destination_before)
        sys.stdout.write("|".join((
            entry_kind(destination_before),
            serialized(parent_before),
            serialized(destination_after),
            old_identity,
        )))
        publication_verified = True
    elif destination_before is not None:
        publication_verified = True
        cleanup_started = True
        remove_bound(parent, candidate_name, destination_before)
        os.fsync(parent)
    else:
        publication_verified = True
except (AttributeError, OSError, ValueError):
    if published and not cleanup_started:
        try:
            rollback_published()
        except (OSError, ValueError):
            pass
    if not published:
        try:
            unlink_candidate_if_exact(candidate_before)
        except (OSError, ValueError):
            pass
    # Once bound cleanup of an old component tree starts, reversing the swap
    # could restore a partially removed tree. Keep a verified publication and
    # its random residue as the only safe outcome in that narrow case.
    if published and publication_verified and cleanup_started:
        raise SystemExit(0)
    raise SystemExit(1)
finally:
    os.close(parent)
PY
)" || _rc=$?
  [[ "$_rc" -eq 0 ]] || return "$_rc"
  if [[ "$replacement_kind" == link-preserve-dir ]]; then
    [[ -n "$_output" && ! "$_output" =~ [[:space:][:cntrl:]] ]] || return 1
    _MDM_COMPONENT_PRESERVE_TOKEN="$_output"
  else
    [[ -z "$_output" ]] || return 1
  fi
}

_mdm_rollback_preserved_component_leaf() {
  local preserved="$1" destination="$2" token="$3" parent _rc=0
  parent="${destination%/*}"
  _prereq_canonical_real_dir "$parent" || return 1
  [[ -x /usr/bin/python3 \
    && "$preserved" == "$parent/"* \
    && "${preserved#"$parent/"}" != */* \
    && "$destination" == "$parent/"* \
    && "${destination#"$parent/"}" != */* \
    && "$preserved" != "$destination" \
    && -n "$token" && ! "$token" =~ [[:space:][:cntrl:]] ]] || return 1

  /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /usr/bin/python3 -I -B - "$preserved" "$destination" "$token" <<'PY' \
      || _rc=$?
import ctypes
import errno
import os
import stat
import sys

preserved_path, destination_path, token = sys.argv[1:]
parent_path = os.path.dirname(destination_path)
if os.path.dirname(preserved_path) != parent_path:
    raise SystemExit(1)
preserved_name = os.path.basename(preserved_path)
destination_name = os.path.basename(destination_path)
if (not preserved_name or not destination_name
        or preserved_name in (".", "..") or destination_name in (".", "..")
        or "/" in preserved_name or "/" in destination_name
        or preserved_name == destination_name):
    raise SystemExit(1)


def parse_identity(text):
    parts = text.split(":")
    if len(parts) != 6 or any(not part.isdigit() for part in parts):
        raise ValueError("invalid identity token")
    return tuple(int(part) for part in parts)


parts = token.split("|")
if len(parts) != 4 or parts[0] not in ("none", "directory", "file", "link"):
    raise SystemExit(1)
old_kind = parts[0]
try:
    expected_parent = parse_identity(parts[1])
    expected_published = parse_identity(parts[2])
    expected_old = None if parts[3] == "-" else parse_identity(parts[3])
except ValueError:
    raise SystemExit(1)
if (old_kind == "none") != (expected_old is None):
    raise SystemExit(1)

directory_flags = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                   | getattr(os, "O_CLOEXEC", 0))
parent = os.open(parent_path, directory_flags)


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_nlink)


def stable_parent_identity(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode),
            value.st_uid, value.st_gid)


expected_parent_stable = (expected_parent[0], expected_parent[1],
                          stat.S_IFMT(expected_parent[2]),
                          expected_parent[3], expected_parent[4])


def at(name):
    return os.stat(name, dir_fd=parent, follow_symlinks=False)


def rename_atomic(source, destination, operation):
    libc = ctypes.CDLL(None, use_errno=True)
    source_value = os.fsencode(source)
    destination_value = os.fsencode(destination)
    if sys.platform == "darwin":
        call = libc.renameatx_np
        call.argtypes = [ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        call.restype = ctypes.c_int
        flags = 0x00000004 if operation == "create" else 0x00000002
    elif sys.platform.startswith("linux"):
        call = libc.renameat2
        call.argtypes = [ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        call.restype = ctypes.c_int
        flags = 0x00000001 if operation == "create" else 0x00000002
    else:
        raise OSError(errno.ENOTSUP, "atomic rename is unavailable")
    ctypes.set_errno(0)
    if call(parent, source_value, parent, destination_value, flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error or errno.EIO, "atomic rename failed")


try:
    if stable_parent_identity(os.fstat(parent)) != expected_parent_stable:
        raise ValueError("preserved parent identity changed")
    destination_before = at(destination_name)
    if identity(destination_before) != expected_published:
        raise ValueError("published activation identity changed")
    if old_kind == "none":
        try:
            at(preserved_name)
        except FileNotFoundError:
            pass
        else:
            raise ValueError("preserved name was claimed")
        rename_atomic(destination_name, preserved_name, "create")
    else:
        preserved_before = at(preserved_name)
        if identity(preserved_before) != expected_old:
            raise ValueError("preserved activation identity changed")
        rename_atomic(preserved_name, destination_name, "swap")
    # The inverse rename is the rollback commit point. Once the old state is
    # back at destination, no later fsync/stat/cleanup failure may publish the
    # already-rejected activation again.
    os.fsync(parent)

    candidate_after = at(preserved_name)
    if identity(candidate_after) != expected_published:
        raise ValueError("rollback candidate identity mismatch")
    if old_kind == "none":
        try:
            at(destination_name)
        except FileNotFoundError:
            pass
        else:
            raise ValueError("rollback did not restore absence")
    elif identity(at(destination_name)) != expected_old:
        raise ValueError("rollback destination identity mismatch")
    if identity(os.fstat(parent)) != expected_parent:
        raise ValueError("rollback parent identity changed")
    # The original destination state is now restored. A cleanup failure for
    # our published symlink must not re-publish it over that restored state.
    os.unlink(preserved_name, dir_fd=parent)
    os.fsync(parent)
except (AttributeError, OSError, ValueError):
    raise SystemExit(1)
finally:
    os.close(parent)
PY
  [[ "$_rc" -eq 0 ]]
}

_mdm_finalize_preserved_component_leaf() {
  local preserved="$1" destination="$2" token="$3" parent _rc=0
  parent="${destination%/*}"
  _prereq_canonical_real_dir "$parent" || return 1
  [[ -x /usr/bin/python3 \
    && "$preserved" == "$parent/"* \
    && "${preserved#"$parent/"}" != */* \
    && "$destination" == "$parent/"* \
    && "${destination#"$parent/"}" != */* \
    && "$preserved" != "$destination" \
    && -n "$token" && ! "$token" =~ [[:space:][:cntrl:]] ]] || return 1

  /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /usr/bin/python3 -I -B - "$preserved" "$destination" "$token" <<'PY' \
      || _rc=$?
import os
import stat
import sys

preserved_path, destination_path, token = sys.argv[1:]
parent_path = os.path.dirname(destination_path)
if os.path.dirname(preserved_path) != parent_path:
    raise SystemExit(1)
preserved_name = os.path.basename(preserved_path)
destination_name = os.path.basename(destination_path)
if (not preserved_name or not destination_name
        or preserved_name in (".", "..") or destination_name in (".", "..")
        or "/" in preserved_name or "/" in destination_name
        or preserved_name == destination_name):
    raise SystemExit(1)


def parse_identity(text):
    parts = text.split(":")
    if len(parts) != 6 or any(not part.isdigit() for part in parts):
        raise ValueError("invalid identity token")
    return tuple(int(part) for part in parts)


parts = token.split("|")
if len(parts) != 4 or parts[0] not in ("none", "directory", "file", "link"):
    raise SystemExit(1)
old_kind = parts[0]
try:
    expected_parent = parse_identity(parts[1])
    expected_published = parse_identity(parts[2])
    expected_old = None if parts[3] == "-" else parse_identity(parts[3])
except ValueError:
    raise SystemExit(1)
if (old_kind == "none") != (expected_old is None):
    raise SystemExit(1)

directory_flags = (os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                   | getattr(os, "O_CLOEXEC", 0))
parent = os.open(parent_path, directory_flags)


def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_nlink)


def stable_parent_identity(value):
    return (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode),
            value.st_uid, value.st_gid)


expected_parent_stable = (expected_parent[0], expected_parent[1],
                          stat.S_IFMT(expected_parent[2]),
                          expected_parent[3], expected_parent[4])


def at(name):
    return os.stat(name, dir_fd=parent, follow_symlinks=False)


def kind(value):
    if stat.S_ISDIR(value.st_mode):
        return "directory"
    if stat.S_ISREG(value.st_mode):
        return "file"
    if stat.S_ISLNK(value.st_mode):
        return "link"
    raise ValueError("unsupported preserved entry")


try:
    if stable_parent_identity(os.fstat(parent)) != expected_parent_stable:
        raise ValueError("preserved parent identity changed")
    if identity(at(destination_name)) != expected_published:
        raise ValueError("published activation identity changed")
    if old_kind == "none":
        try:
            at(preserved_name)
        except FileNotFoundError:
            pass
        else:
            raise ValueError("preserved name was claimed")
    else:
        preserved_before = at(preserved_name)
        if (identity(preserved_before) != expected_old
                or kind(preserved_before) != old_kind):
            raise ValueError("preserved activation identity changed")
        if old_kind in ("file", "link"):
            # The old leaf was validated as a single-link, replaceable object.
            # Delete only that token-bound inode through the opened parent;
            # real dependency directories are deliberately retained forever.
            os.unlink(preserved_name, dir_fd=parent)
            os.fsync(parent)
            try:
                at(preserved_name)
            except FileNotFoundError:
                pass
            else:
                raise ValueError("finalized name was reclaimed")
    if (stable_parent_identity(os.fstat(parent)) != expected_parent_stable
            or identity(at(destination_name)) != expected_published):
        raise ValueError("activation changed during finalize")
except (AttributeError, OSError, ValueError):
    raise SystemExit(1)
finally:
    os.close(parent)
PY
  [[ "$_rc" -eq 0 ]]
}

_mdm_component_link_destination_safe() { # <name>
  local name="$1" bin_dir="$HOME/.local/bin" destination
  [[ "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
  _prereq_canonical_real_dir "$bin_dir" || return 1
  destination="$bin_dir/$name"
  [[ ! -d "$destination" || -L "$destination" ]]
}

_mdm_install_component_link() {
  local name="$1" relative_target="$2" bin_dir="$HOME/.local/bin"
  local temp
  _mdm_component_link_destination_safe "$name" || return 1
  temp="$(/usr/bin/mktemp "$bin_dir/.${name}.XXXXXX")" || return 1
  /bin/rm -f "$temp" || return 1
  /bin/ln -s "$relative_target" "$temp" || return 1
  # The helper owns candidate cleanup through its bound parent descriptor.
  # Never unlink this random pathname after a failure: another same-UID process
  # may have replaced it after the helper released the descriptor.
  _mdm_atomic_replace_component_leaf "$temp" "$bin_dir/$name" link
}

_mdm_validate_biome_tree_at() {
  local root="$1" arch="$2" output
  _mdm_select_biome_artifact "$arch" || return 1
  _prereq_canonical_real_dir "$root" || return 1
  _prereq_dir_has_exact_entries "$root" biome package.json || return 1
  [[ -f "$root/biome" && ! -L "$root/biome" && -x "$root/biome" \
    && -f "$root/package.json" && ! -L "$root/package.json" ]] || return 1
  _prereq_file_has_one_link "$root/biome" || return 1
  _prereq_file_has_one_link "$root/package.json" || return 1
  _prereq_mode_is "$root/biome" 755 || return 1
  _prereq_mode_is "$root/package.json" 644 || return 1
  [[ "$(_prereq_sha256_file "$root/biome")" \
    == "$_MDM_SELECTED_BINARY_SHA256" ]] || return 1
  [[ "$(_prereq_sha256_file "$root/package.json")" \
    == "$_MDM_SELECTED_PACKAGE_SHA256" ]] || return 1
  output="$(/usr/bin/env -i HOME="$HOME" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$root/biome" --version 2>/dev/null)" || return 1
  _prereq_cli_version_matches "$output" "$_MDM_BIOME_VERSION"
}

_mdm_expected_safety_wrapper() {
  local node="$1" script="$2"
  printf '#!/bin/bash\nunset NODE_OPTIONS NODE_PATH\nexec %q %q "$@"\n' \
    "$node" "$script"
}

_mdm_validate_safety_tree_at() {
  local root="$1" node="$2" execute_wrapper="${3:-true}"
  local wrapper="$root/bin/cc-safety-net" js="$root/dist/bin/cc-safety-net.js"
  local expected_wrapper output
  _prereq_canonical_real_dir "$root" || return 1
  _prereq_dir_has_exact_entries "$root" bin dist package.json || return 1
  _prereq_canonical_real_dir "$root/bin" || return 1
  _prereq_dir_has_exact_entries "$root/bin" cc-safety-net || return 1
  _prereq_canonical_real_dir "$root/dist" || return 1
  _prereq_dir_has_exact_entries "$root/dist" bin || return 1
  _prereq_canonical_real_dir "$root/dist/bin" || return 1
  _prereq_dir_has_exact_entries "$root/dist/bin" cc-safety-net.js || return 1
  [[ -f "$wrapper" && ! -L "$wrapper" && -x "$wrapper" \
    && -f "$js" && ! -L "$js" \
    && -f "$root/package.json" && ! -L "$root/package.json" ]] || return 1
  _prereq_file_has_one_link "$wrapper" || return 1
  _prereq_file_has_one_link "$js" || return 1
  _prereq_file_has_one_link "$root/package.json" || return 1
  _prereq_mode_is "$wrapper" 755 || return 1
  _prereq_mode_is "$js" 644 || return 1
  _prereq_mode_is "$root/package.json" 644 || return 1
  [[ "$(_prereq_sha256_file "$js")" == "$_MDM_CC_SAFETY_NET_JS_SHA256" ]] \
    || return 1
  [[ "$(_prereq_sha256_file "$root/package.json")" \
    == "$_MDM_CC_SAFETY_NET_PACKAGE_SHA256" ]] || return 1
  expected_wrapper="$(_mdm_expected_safety_wrapper "$node" \
    "$HOME/.local/lib/claude-code-starter-kit/cc-safety-net/${_MDM_CC_SAFETY_NET_VERSION}/dist/bin/cc-safety-net.js")" \
    || return 1
  _prereq_exact_text_file "$wrapper" "$expected_wrapper" || return 1
  [[ "$execute_wrapper" == true ]] || return 0
  output="$(/usr/bin/env -i HOME="$HOME" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    "$wrapper" --version 2>/dev/null)" || return 1
  _prereq_cli_version_matches "$output" "$_MDM_CC_SAFETY_NET_VERSION"
}

check_mdm_biome_baseline() {
  KIT_MDM_BIOME_COMPONENT_ROOT=""
  KIT_MDM_BIOME_COMMAND_PATH=""
  export KIT_MDM_BIOME_COMPONENT_ROOT KIT_MDM_BIOME_COMMAND_PATH
  _prereq_mdm_managed || return 1
  local arch root link target
  arch="$(_mdm_current_darwin_arch)" || return 1
  root="$HOME/.local/lib/claude-code-starter-kit/biome/${_MDM_BIOME_VERSION}"
  link="$HOME/.local/bin/biome"
  target="$root/biome"
  _mdm_validate_biome_tree_at "$root" "$arch" || return 1
  _prereq_symlink_value_exact "$link" \
    "../lib/claude-code-starter-kit/biome/${_MDM_BIOME_VERSION}/biome" \
    || return 1
  [[ "$(_prereq_canonical_file "$link")" == "$target" ]] || return 1
  KIT_MDM_BIOME_COMPONENT_ROOT="$root"
  KIT_MDM_BIOME_COMMAND_PATH="$target"
  export KIT_MDM_BIOME_COMPONENT_ROOT KIT_MDM_BIOME_COMMAND_PATH
}

check_mdm_cc_safety_net_baseline() {
  KIT_MDM_CC_SAFETY_NET_COMPONENT_ROOT=""
  KIT_MDM_CC_SAFETY_NET_COMMAND_PATH=""
  export KIT_MDM_CC_SAFETY_NET_COMPONENT_ROOT \
    KIT_MDM_CC_SAFETY_NET_COMMAND_PATH
  _prereq_mdm_managed || return 1
  _mdm_resolve_private_node_toolchain || return 1
  local root link target
  root="$HOME/.local/lib/claude-code-starter-kit/cc-safety-net/${_MDM_CC_SAFETY_NET_VERSION}"
  link="$HOME/.local/bin/cc-safety-net"
  target="$root/bin/cc-safety-net"
  _mdm_validate_safety_tree_at "$root" "$_MDM_PREREQ_NODE" true || return 1
  _prereq_symlink_value_exact "$link" \
    "../lib/claude-code-starter-kit/cc-safety-net/${_MDM_CC_SAFETY_NET_VERSION}/bin/cc-safety-net" \
    || return 1
  [[ "$(_prereq_canonical_file "$link")" == "$target" ]] || return 1
  KIT_MDM_CC_SAFETY_NET_COMPONENT_ROOT="$root"
  KIT_MDM_CC_SAFETY_NET_COMMAND_PATH="$target"
  export KIT_MDM_CC_SAFETY_NET_COMPONENT_ROOT \
    KIT_MDM_CC_SAFETY_NET_COMMAND_PATH
}

install_mdm_biome() {
  _prereq_mdm_managed || return 1
  _prereq_mdm_mode_valid || return 1
  _prereq_mdm_fail_mode && return 1
  local arch parent root stage archive
  _mdm_prepare_user_local_base || return 1
  _mdm_component_link_destination_safe biome || return 1
  arch="$(_mdm_current_darwin_arch)" || return 1
  _mdm_select_biome_artifact "$arch" || return 1
  _mdm_prepare_component_parent biome || return 1
  parent="$HOME/.local/lib/claude-code-starter-kit/biome"
  root="$parent/${_MDM_BIOME_VERSION}"
  stage="$(/usr/bin/mktemp -d "$parent/.biome-stage.XXXXXX")" || return 1
  /bin/chmod 700 "$stage" || { /bin/rm -rf "$stage"; return 1; }
  archive="$stage/artifact.tgz"
  if ! _mdm_download_pinned_artifact "$_MDM_SELECTED_ARTIFACT_URL" \
      "$_MDM_SELECTED_ARCHIVE_SHA256" "$archive" \
    || ! _mdm_extract_pinned_regular_member "$archive" package/biome \
      "$stage/biome" \
    || ! _mdm_extract_pinned_regular_member "$archive" package/package.json \
      "$stage/package.json"; then
    /bin/rm -rf "$stage" 2>/dev/null || true
    return 1
  fi
  /bin/rm -f "$archive" || { /bin/rm -rf "$stage"; return 1; }
  /bin/chmod 755 "$stage/biome" || { /bin/rm -rf "$stage"; return 1; }
  /bin/chmod 644 "$stage/package.json" || { /bin/rm -rf "$stage"; return 1; }
  _mdm_validate_biome_tree_at "$stage" "$arch" \
    || { /bin/rm -rf "$stage"; return 1; }
  # A failed atomic helper may deliberately retain an uncertain stage. Do not
  # perform pathname-only cleanup after it releases its bound parent fd.
  _mdm_atomic_replace_component_leaf "$stage" "$root" || return 1
  _mdm_install_component_link biome \
    "../lib/claude-code-starter-kit/biome/${_MDM_BIOME_VERSION}/biome" \
    || return 1
  check_mdm_biome_baseline
}

install_mdm_cc_safety_net() {
  _prereq_mdm_managed || return 1
  _prereq_mdm_mode_valid || return 1
  _prereq_mdm_fail_mode && return 1
  _mdm_resolve_private_node_toolchain || return 1
  local parent root stage archive final_js
  _mdm_prepare_user_local_base || return 1
  _mdm_component_link_destination_safe cc-safety-net || return 1
  _mdm_prepare_component_parent cc-safety-net || return 1
  parent="$HOME/.local/lib/claude-code-starter-kit/cc-safety-net"
  root="$parent/${_MDM_CC_SAFETY_NET_VERSION}"
  stage="$(/usr/bin/mktemp -d "$parent/.safety-stage.XXXXXX")" || return 1
  /bin/chmod 700 "$stage" || { /bin/rm -rf "$stage"; return 1; }
  /bin/mkdir "$stage/bin" "$stage/dist" || { /bin/rm -rf "$stage"; return 1; }
  /bin/mkdir "$stage/dist/bin" || { /bin/rm -rf "$stage"; return 1; }
  /bin/chmod 700 "$stage/bin" "$stage/dist" "$stage/dist/bin" \
    || { /bin/rm -rf "$stage"; return 1; }
  archive="$stage/artifact.tgz"
  if ! _mdm_download_pinned_artifact "$_MDM_CC_SAFETY_NET_URL" \
      "$_MDM_CC_SAFETY_NET_ARCHIVE_SHA256" "$archive" \
    || ! _mdm_extract_pinned_regular_member "$archive" \
      package/dist/bin/cc-safety-net.js "$stage/dist/bin/cc-safety-net.js" \
    || ! _mdm_extract_pinned_regular_member "$archive" package/package.json \
      "$stage/package.json"; then
    /bin/rm -rf "$stage" 2>/dev/null || true
    return 1
  fi
  /bin/rm -f "$archive" || { /bin/rm -rf "$stage"; return 1; }
  /bin/chmod 644 "$stage/dist/bin/cc-safety-net.js" "$stage/package.json" \
    || { /bin/rm -rf "$stage"; return 1; }
  final_js="$root/dist/bin/cc-safety-net.js"
  _mdm_expected_safety_wrapper "$_MDM_PREREQ_NODE" "$final_js" \
    > "$stage/bin/cc-safety-net" \
    || { /bin/rm -rf "$stage"; return 1; }
  /bin/chmod 755 "$stage/bin/cc-safety-net" \
    || { /bin/rm -rf "$stage"; return 1; }
  _mdm_validate_safety_tree_at "$stage" "$_MDM_PREREQ_NODE" false \
    || { /bin/rm -rf "$stage"; return 1; }
  _mdm_atomic_replace_component_leaf "$stage" "$root" || return 1
  _mdm_install_component_link cc-safety-net \
    "../lib/claude-code-starter-kit/cc-safety-net/${_MDM_CC_SAFETY_NET_VERSION}/bin/cc-safety-net" \
    || return 1
  check_mdm_cc_safety_net_baseline
}

check_biome() {
  if _prereq_mdm_managed; then
    _prereq_mdm_mode_valid || return 1
    if _prereq_mdm_fail_mode; then
      check_mdm_biome_baseline
    else
      install_mdm_biome
    fi
    return $?
  fi
  if command -v biome &>/dev/null; then
    ok "biome $(biome --version 2>/dev/null | head -1)"
    return 0
  fi

  info "Installing Biome..."

  if _brew_is_usable 2>/dev/null; then
    if brew install biome 2>/dev/null && command -v biome &>/dev/null; then
      ok "biome installed via Homebrew"
      return 0
    fi
  fi

  if _npm_global_install biome @biomejs/biome; then
    ok "biome installed via npm"
    return 0
  fi

  warn "Failed to install Biome automatically."
  if [[ "$(uname -s)" == "Darwin" ]]; then
    warn "  Or: brew install biome"
  fi
  warn "  Or: npm install -g @biomejs/biome"
  return 1
}

check_cc_safety_net() {
  if _prereq_mdm_managed; then
    _prereq_mdm_mode_valid || return 1
    if _prereq_mdm_fail_mode; then
      check_mdm_cc_safety_net_baseline
    else
      install_mdm_cc_safety_net
    fi
    return $?
  fi
  if command -v cc-safety-net &>/dev/null; then
    ok "cc-safety-net $(cc-safety-net --version 2>/dev/null | head -1)"
    return 0
  fi

  info "Installing cc-safety-net..."

  if _npm_global_install cc-safety-net cc-safety-net --ignore-scripts --no-audit --no-fund; then
    ok "cc-safety-net installed via npm"
    return 0
  fi

  warn "Failed to install cc-safety-net automatically."
  warn "  The safety-net hook cannot block destructive commands until it is installed."
  warn "  Install manually: npm install -g --ignore-scripts cc-safety-net"
  return 1
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Bash 4+ detection and re-exec
# ---------------------------------------------------------------------------

_is_bash4_candidate() {
  local candidate="$1"
  [[ -x "$candidate" ]] || return 1

  local ver
  ver="$("$candidate" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo "0")"
  [[ "$ver" =~ ^[0-9]+$ ]] && [[ "$ver" -ge 4 ]]
}

# _detect_bash4 - Find a Bash 4+ binary on the system
# Returns the path via stdout. Returns 1 if none found.
_detect_bash4() {
  # Check current shell first
  if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
    printf '%s' "$BASH"
    return 0
  fi

  # Search trusted common locations first.
  local candidate
  for candidate in \
    /opt/homebrew/bin/bash \
    /usr/local/bin/bash \
    /bin/bash \
    /usr/bin/bash; do
    if [[ -x "$candidate" ]]; then
      if _is_bash4_candidate "$candidate"; then
        printf '%s' "$candidate"
        return 0
      fi
    fi
  done

  return 1
}

_install_bash4() {
  _prereq_mdm_mode_valid || return 1
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    warn "Dry-run: Bash 4+ is missing; skipping automatic Bash install"
    return 1
  fi

  if _prereq_mdm_fail_mode; then
    warn "MDM prerequisite mode is fail; will not install Bash 4+"
    return 1
  fi

  info "Installing Bash 4+..."
  if _pkg_install bash; then
    return 0
  fi
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

  if _install_bash4 && new_bash="$(_detect_bash4)"; then
    info "Found Bash 4+ at: $new_bash"
    info "Re-executing setup.sh under Bash 4+..."
    exec "$new_bash" "$_SETUP_SCRIPT_PATH" "${_SETUP_ORIG_ARGS[@]+"${_SETUP_ORIG_ARGS[@]}"}"
    error "Failed to re-exec under $new_bash"
    return 1
  fi

  return 1
}

# ---------------------------------------------------------------------------
# _get_shell_rc_file - Determine the user's shell RC file
#
# Outputs the path to stdout. Handles MSYS (bash_profile), zsh, bash.
# ---------------------------------------------------------------------------
_get_shell_rc_file() {
  if is_msys; then
    printf '%s' "$HOME/.bash_profile"
  else
    case "${SHELL:-/bin/bash}" in
      */zsh)  printf '%s' "$HOME/.zshrc" ;;
      */bash)
        if is_macos; then
          printf '%s' "$HOME/.bash_profile"
        else
          printf '%s' "$HOME/.bashrc"
        fi
        ;;
      *)      printf '%s' "$HOME/.profile" ;;
    esac
  fi
}

_get_shell_rc_files() {
  local primary
  primary="$(_get_shell_rc_file)" || return 1
  if is_macos && [[ "${SHELL:-/bin/bash}" == */bash ]] && _bash_profile_sources_bashrc "$primary"; then
    printf '%s\n' "$HOME/.bashrc"
    return 0
  fi

  printf '%s\n' "$primary"
  if is_macos && [[ "${SHELL:-/bin/bash}" == */bash ]] && [[ "$primary" != "$HOME/.bashrc" ]]; then
    printf '%s\n' "$HOME/.bashrc"
  fi
}

_bash_profile_sources_bashrc() {
  local bash_profile="$1"
  [[ -f "$bash_profile" ]] || return 1
  grep -Ev '^[[:space:]]*#' "$bash_profile" 2>/dev/null \
    | grep -Eq '(^|[[:space:];])(\.|source)[[:space:]]+["'\'']?((~|\$HOME|\$\{HOME\})/)?\.bashrc["'\'']?'
}

# ---------------------------------------------------------------------------
# _add_to_path_now_and_persist - Add a directory to PATH immediately + persist
#
# Usage: _add_to_path_now_and_persist <dir> [comment]
#
# 1. Immediate: export PATH="<dir>:$PATH" (current session)
# 2. Persist: append to shell RC file if not already present
# ---------------------------------------------------------------------------
_add_to_path_now_and_persist() {
  local dir="$1"
  local comment="${2:-Claude Code CLI}"

  # Immediate export for current session
  case ":${PATH}:" in
    *":${dir}:"*) ;;  # already in PATH
    *) export PATH="${dir}:${PATH}" ;;
  esac

  # Persist to shell startup files. macOS bash writes both login and
  # non-login files so Ghostty/login shells and plain bash both work.
  local rc_file rc_files
  rc_files="$(_get_shell_rc_files)" || return 1
  while IFS= read -r rc_file; do
    [[ -n "$rc_file" ]] || continue
    [[ -f "$rc_file" ]] || touch "$rc_file" || return 1

    if ! grep -Fq "$dir" "$rc_file" 2>/dev/null; then
      printf '\n# %s\nexport PATH="%s:$PATH"\n' "$comment" "$dir" \
        >> "$rc_file" || return 1
    fi
  done <<< "$rc_files"
}

# Main entry point
# ---------------------------------------------------------------------------

# Run all prerequisite checks. Returns non-zero on critical failure.
check_prerequisites() {
  section "必要なツールを確認中 / Checking prerequisites"
  _prereq_mdm_mode_valid || return 1

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
  check_node     || failed=1
  check_tmux     || failed=1
  check_dos2unix || failed=1
  check_gh       || failed=1

  if [[ "$failed" -ne 0 ]]; then
    error "一部の必須ツールをインストールできませんでした。手動でインストールして再実行してください。"
    error "Some required dependencies could not be installed. Please install them manually and re-run."
    return 1
  fi

  ok "必要なツールはすべて揃っています / All prerequisites satisfied"
  return 0
}
