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
  case "$(uname -s)" in
    Darwin) printf '%s' "$HOME/Library/Application Support/com.mitchellh.ghostty" ;;
    MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*)
      if [[ -n "${APPDATA:-}" ]]; then
        printf '%s' "$(cygpath -u "$APPDATA")/Ghostty"
      else
        printf '%s' "$HOME/.config/ghostty"
      fi
      ;;
    *)      printf '%s' "$HOME/.config/ghostty" ;;
  esac
}

# _ghostty_ensure_brew removed in v0.30.0 — use _ensure_homebrew from prerequisites.sh

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

  local uname_s
  uname_s="$(uname -s)"

  case "$uname_s" in
    Darwin)
      if ! _ensure_homebrew; then
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
        # Remove macOS quarantine attribute to prevent Gatekeeper block on first launch
        xattr -d com.apple.quarantine /Applications/Ghostty.app 2>/dev/null || true
        ok "Ghostty installed"
        return 0
      else
        warn "Failed to install Ghostty. Install manually: https://ghostty.org/"
        return 1
      fi
      ;;
    MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*)
      if command -v winget.exe &>/dev/null; then
        info "Installing Ghostty via winget..."
        if winget.exe install --id=com.mitchellh.ghostty --accept-package-agreements --accept-source-agreements 2>/dev/null; then
          ok "Ghostty installed"
          return 0
        else
          warn "Failed to install Ghostty via winget."
          info "  Install manually: https://ghostty.org/download"
          return 1
        fi
      else
        warn "winget not available. Cannot install Ghostty."
        info "  Install manually: https://ghostty.org/download"
        return 1
      fi
      ;;
    *)
      warn "$STR_GHOSTTY_SKIP_PLATFORM"
      return 1
      ;;
  esac
}

# install_hackgen_font removed in v0.22.2 — now uses install_hackgen_nf from lib/fonts.sh

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

  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*)
      # Strip macOS-specific settings (macos-*)
      grep -v '^macos-' "$template_file" > "$config_file"
      ;;
    *)
      cp -a "$template_file" "$config_file"
      ;;
  esac

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
