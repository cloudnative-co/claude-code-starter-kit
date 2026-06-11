#!/bin/bash
# lib/ghostty.sh - Ghostty terminal emulator installation and configuration (macOS only)
#
# Requires: lib/colors.sh, lib/detect.sh, lib/prerequisites.sh (_brew_is_usable),
#           lib/fonts.sh (install_hackgen_nf)
# Sets globals: GHOSTTY_INCOMPLETE[]
# Exports: setup_ghostty()
# Dry-run: guarded (setup.sh logs EXTERNAL, does not call setup_ghostty)
set -euo pipefail

# Track incomplete installations for final summary (array for safe iteration)
GHOSTTY_INCOMPLETE=()

# ---------------------------------------------------------------------------
# Config path detection
# ---------------------------------------------------------------------------
_ghostty_config_dir() {
  printf '%s' "$HOME/Library/Application Support/com.mitchellh.ghostty"
}

# ---------------------------------------------------------------------------
# Backup existing config
# ---------------------------------------------------------------------------
_backup_ghostty_config() {
  local config_dir config_file
  config_dir="$(_ghostty_config_dir)"
  config_file="$config_dir/config"
  if [[ -f "$config_file" ]]; then
    local ts backup
    ts="$(date +%Y%m%d%H%M%S)"
    backup="${config_file}.backup.${ts}"
    cp -a "$config_file" "$backup"
    ok "$STR_GHOSTTY_CONFIG_BACKED_UP $backup"
  fi
}

# ---------------------------------------------------------------------------
# Install Ghostty
# ---------------------------------------------------------------------------
install_ghostty() {
  if [[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]; then
    # Remove quarantine attribute if still present (e.g., previous install without this fix)
    xattr -d com.apple.quarantine /Applications/Ghostty.app 2>/dev/null || true
    ok "$STR_GHOSTTY_ALREADY_INSTALLED"
    return 0
  fi

  _ensure_homebrew
  if ! _brew_is_usable 2>/dev/null; then
    warn "Homebrew is not available. Cannot install Ghostty."
    info "  Install manually: https://ghostty.org/"
    return 1
  fi
  info "Installing Ghostty..."
  brew install --cask ghostty 2>/dev/null || true
  # brew may report success without installing if the cask is registered
  # but the app was deleted. Reinstall to restore the actual .app bundle.
  if [[ ! -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]; then
    info "  App not found after install, reinstalling..."
    brew reinstall --cask ghostty || true
  fi
  if [[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]; then
    xattr -d com.apple.quarantine /Applications/Ghostty.app 2>/dev/null || true
    ok "Ghostty installed"
    return 0
  fi
  warn "Failed to install Ghostty. Install manually: https://ghostty.org/"
  return 1
}

# ---------------------------------------------------------------------------
# Deploy Ghostty config
# ---------------------------------------------------------------------------
deploy_ghostty_config() {
  local template_file="$1"
  local config_dir config_file
  config_dir="$(_ghostty_config_dir)"
  config_file="$config_dir/config"

  mkdir -p "$config_dir"
  _backup_ghostty_config

  cp -a "$template_file" "$config_file"

  ok "$STR_GHOSTTY_CONFIG_DEPLOYED: $config_file"
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
setup_ghostty() {
  # Ghostty is macOS only
  if [[ "$(uname -s)" != "Darwin" ]]; then
    return 0
  fi

  local template_file="${1:-}"

  install_ghostty       || GHOSTTY_INCOMPLETE+=("Ghostty")
  install_hackgen_nf    || GHOSTTY_INCOMPLETE+=("HackGen-NF")

  if [[ -n "$template_file" && -f "$template_file" ]]; then
    deploy_ghostty_config "$template_file"
  fi
}
