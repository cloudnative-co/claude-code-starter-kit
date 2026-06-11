#!/bin/bash
# install.sh - One-liner bootstrap for Claude Code Starter Kit
#
# Interactive (wizard):
#   curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash
#
# Non-interactive (standard profile, all default plugins):
#   curl -fsSL <url>/install.sh | bash -s -- --non-interactive
#   NONINTERACTIVE=1 bash -c "$(curl -fsSL <url>/install.sh)"
#
# Options (passed through to setup.sh):
#   --non-interactive       Skip wizard, use standard profile defaults
#   --profile=<name>        Profile: minimal, standard (default), full
#   --language=<code>       Language: en (default), ja
#   --plugins=<csv>         Override plugin selection (name or name@marketplace)
set -euo pipefail

REPO_URL="https://github.com/cloudnative-co/claude-code-starter-kit.git"
INSTALL_DIR="${STARTER_KIT_DIR:-$HOME/.claude-starter-kit}"

# ---------------------------------------------------------------------------
# Colors (inline since lib/ isn't available yet)
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[  OK]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Safety guard: prevent rm -rf on dangerous paths
# ---------------------------------------------------------------------------
# NOTE: This function is copied into install.ps1 (WSL + Git Bash here-strings)
# and uninstall.sh. Keep all 4 copies functionally identical — CI compares the
# normalized function bodies (tests/unit/test-install-bootstrap.sh).
_safe_install_dir() {
  # Normalize: strip ALL trailing slashes (so "$HOME//" cannot bypass checks)
  local dir="$1"
  while [[ "$dir" == */ ]]; do
    dir="${dir%/}"
  done
  [[ -z "$dir" ]] && return 1
  # Require an absolute path
  [[ "$dir" != /* ]] && return 1
  # Block $HOME itself
  [[ "$dir" == "$HOME" || "$dir" == "${HOME%/}" ]] && return 1
  # Block system directories and their subtrees
  case "$dir" in
    /|/bin|/bin/*|/sbin|/sbin/*|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/tmp|/tmp/*)
      return 1 ;;
    /home|/root|/opt|/Applications|/Applications/*|/Library|/Library/*)
      return 1 ;;
    /System|/System/*|/dev|/dev/*|/proc|/proc/*)
      return 1 ;;
  esac
  # Require at least 3 path components (e.g. /home/user/dir)
  local depth
  depth="$(printf '%s' "$dir" | tr -cd '/' | wc -c | tr -d ' ')"
  [[ "$depth" -lt 3 ]] && return 1
  return 0
}

_clone_to_temp_and_swap() {
  local target="$1"
  local parent
  parent="$(dirname "$target")"
  mkdir -p "$parent"

  # 過去の中断実行が残した一時 clone ディレクトリを掃除（自己修復）
  rm -rf "$parent"/.claude-starter-kit.clone.* 2>/dev/null || true

  local tmp_dir
  tmp_dir="$(mktemp -d "$parent/.claude-starter-kit.clone.XXXXXX")"
  if git clone --depth 1 "$REPO_URL" "$tmp_dir/repo"; then
    rm -rf "$target"
    mv "$tmp_dir/repo" "$target"
    rm -rf "$tmp_dir"
    return 0
  fi

  rm -rf "$tmp_dir"
  return 1
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
_ensure_xcode_clt() {
  # On macOS, /usr/bin/git exists as a shim even without Xcode CLT.
  # "command -v git" succeeds but "git" triggers the CLT install dialog and blocks.
  # Detect via xcode-select -p (returns non-zero when CLT is missing).
  xcode-select -p &>/dev/null && return 0

  info "Xcode Command Line Tools not found. Installing..."
  xcode-select --install 2>/dev/null || true

  info "Waiting for Xcode CLT installation to complete..."
  info "(Please follow the dialog to install)"

  local elapsed=0
  local timeout=600  # 10 minutes
  while ! xcode-select -p &>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ $elapsed -ge $timeout ]]; then
      error "Timed out waiting for Xcode CLT installation."
      error "Please install manually: xcode-select --install"
      exit 1
    fi
  done

  ok "Xcode Command Line Tools installed"
}

check_required() {
  local missing=()
  command -v curl &>/dev/null || missing+=("curl")

  if [[ "$(uname -s)" == "Darwin" ]]; then
    _ensure_xcode_clt
  elif ! git --version &>/dev/null; then
    missing+=("git")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
    error "Please install them and try again."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Clone or update
# ---------------------------------------------------------------------------
clone_or_update() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    # Dirty check: abort if local changes exist (prevent git pull conflicts)
    if [[ -n "$(git -C "$INSTALL_DIR" status --porcelain 2>/dev/null)" ]]; then
      error "Local changes detected in $INSTALL_DIR"
      info "  Run: cd $INSTALL_DIR && git stash -u"
      info "  Then re-run this installer."
      exit 1
    fi
    info "Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || {
      warn "Could not fast-forward. Re-cloning..."
      _clone_to_temp_and_swap "$INSTALL_DIR"
    }
    ok "Updated"
  else
    info "Cloning Claude Code Starter Kit..."
    if [[ -d "$INSTALL_DIR" ]]; then
      warn "Directory $INSTALL_DIR exists but is not a git repo. Replacing after clone succeeds..."
    fi
    _clone_to_temp_and_swap "$INSTALL_DIR"
    ok "Cloned to $INSTALL_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Resolve the final setup.sh argument list (pure logic, testable offline):
#   - NONINTERACTIVE env var handling (same convention as Homebrew)
#   - Auto-detect update mode via manifest (~/.claude/.starter-kit-manifest.json)
# Sets globals: _setup_args[], _update_mode, _is_noninteractive
# ---------------------------------------------------------------------------
_resolve_setup_args() {
  _setup_args=("$@")
  _update_mode=false
  _is_noninteractive=false
  local _arg

  # Support NONINTERACTIVE env var (same convention as Homebrew)
  if [[ -n "${NONINTERACTIVE:-}" ]]; then
    local _has_ni=false
    for _arg in "${_setup_args[@]+"${_setup_args[@]}"}"; do
      [[ "$_arg" == "--non-interactive" ]] && _has_ni=true
    done
    if [[ "$_has_ni" == "false" ]]; then
      _setup_args+=("--non-interactive")
    fi
  fi

  # Auto-detect update mode via manifest
  local _manifest="$HOME/.claude/.starter-kit-manifest.json"
  local _snapshot_dir="$HOME/.claude/.starter-kit-snapshot"

  if [[ -f "$_manifest" ]]; then
    local _manifest_version=""
    if command -v jq &>/dev/null; then
      _manifest_version="$(jq -r '.version // "1"' "$_manifest" 2>/dev/null || echo "1")"
    fi

    _update_mode=true
    if [[ "$_manifest_version" == "2" ]] && [[ -d "$_snapshot_dir" ]]; then
      info "Existing installation detected (manifest v2). Running update mode."
    else
      info "Existing starter-kit installation detected without a usable snapshot."
      info "Bootstrapping a snapshot from the current ~/.claude state, then running migration update."
    fi

    local _has_update=false
    for _arg in "${_setup_args[@]+"${_setup_args[@]}"}"; do
      [[ "$_arg" == "--update" ]] && _has_update=true
    done
    if [[ "$_has_update" == "false" ]]; then
      _setup_args+=("--update")
    fi
  fi

  # Non-interactive when --non-interactive or --update is requested
  for _arg in "${_setup_args[@]+"${_setup_args[@]}"}"; do
    [[ "$_arg" == "--non-interactive" || "$_arg" == "--update" ]] && _is_noninteractive=true
  done
  return 0
}

install_main() {
printf "\n${BOLD}Claude Code Starter Kit - Bootstrap${NC}\n\n"

if ! _safe_install_dir "$INSTALL_DIR"; then
  error "Refusing to use INSTALL_DIR='$INSTALL_DIR' (dangerous path)"
  exit 1
fi

check_required
clone_or_update

chmod +x "$INSTALL_DIR/setup.sh"
chmod +x "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true

_resolve_setup_args "$@"

if [[ "$_is_noninteractive" == "true" ]]; then
  if [[ "$_update_mode" == "true" ]]; then
    info "Starting update..."
  else
    info "Starting non-interactive setup (standard profile)..."
  fi
  exec bash "$INSTALL_DIR/setup.sh" ${_setup_args[@]+"${_setup_args[@]}"}
else
  info "Starting interactive setup..."
  # When run via 'curl | bash', stdin is the pipe, not the terminal.
  # Redirect stdin from /dev/tty so the interactive wizard can read input.
  exec bash "$INSTALL_DIR/setup.sh" ${_setup_args[@]+"${_setup_args[@]}"} </dev/tty
fi
}

# curl|bash / bash -c では BASH_SOURCE[0] が unset のため、set -u 下で
# ${BASH_SOURCE[0]} を直接参照すると即死してワンライナーインストールが壊れる。
# unset（パイプ実行）または $0 一致（ファイル実行）で main を呼び、source 時のみスキップ。
if [[ "${BASH_SOURCE[0]:-}" == "" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  install_main "$@"
fi
