#!/bin/bash
# install.sh - One-liner bootstrap for Claude Code Starter Kit
# Usage: curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash
# Or:    curl -fsSL <url>/install.sh -o /tmp/install.sh && bash /tmp/install.sh
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
_safe_install_dir() {
  local dir="$1"
  case "$dir" in
    /|/bin|/etc|/usr|/var|/tmp|/home|/root)
      return 1 ;;
  esac
  [[ "$dir" == "$HOME" ]] && return 1
  return 0
}

if ! _safe_install_dir "$INSTALL_DIR"; then
  error "Refusing to use INSTALL_DIR='$INSTALL_DIR' (dangerous path)"
  exit 1
fi

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
    info "Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || {
      warn "Could not fast-forward. Re-cloning..."
      rm -rf "$INSTALL_DIR"
      git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    }
    ok "Updated"
  else
    info "Cloning Claude Code Starter Kit..."
    if [[ -d "$INSTALL_DIR" ]]; then
      warn "Directory $INSTALL_DIR exists but is not a git repo. Removing..."
      rm -rf "$INSTALL_DIR"
    fi
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    ok "Cloned to $INSTALL_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
printf "\n${BOLD}Claude Code Starter Kit - Bootstrap${NC}\n\n"

check_required
clone_or_update

chmod +x "$INSTALL_DIR/setup.sh"
chmod +x "$INSTALL_DIR/uninstall.sh" 2>/dev/null || true

info "Starting interactive setup..."
# When run via 'curl | bash', stdin is the pipe, not the terminal.
# Redirect stdin from /dev/tty so the interactive wizard can read input.
exec bash "$INSTALL_DIR/setup.sh" "$@" </dev/tty
