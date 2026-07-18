#!/bin/bash
# lib/ghostty.sh - Ghostty terminal emulator installation and configuration (macOS only)
#
# Requires: lib/colors.sh, lib/detect.sh, lib/prerequisites.sh (_brew_is_usable),
#           lib/fonts.sh (install_hackgen_nf)
# Sets globals: GHOSTTY_INCOMPLETE[]
# Exports: setup_ghostty(), ghostty_mdm_is_trusted(), install_ghostty_mdm()
# Dry-run: guarded (setup.sh logs EXTERNAL, does not call setup_ghostty)
set -euo pipefail

# Track incomplete installations for final summary (array for safe iteration)
GHOSTTY_INCOMPLETE=()

_ghostty_mdm_managed() {
  case "$(printf '%s' "${KIT_MDM_MANAGED:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

_ghostty_mdm_mode() {
  case "${KIT_MDM_PREREQ_MODE:-auto}" in
    auto|fail) printf '%s' "${KIT_MDM_PREREQ_MODE:-auto}" ;;
    *) return 1 ;;
  esac
}

_ghostty_app_path() {
  printf '%s' /Applications/Ghostty.app
}

_ghostty_codesign_requirement() {
  printf '%s' '=identifier "com.mitchellh.ghostty" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "24VZTF6M5V"'
}

_ghostty_codesign() {
  /usr/bin/codesign "$@"
}

_ghostty_signature_trusted() {
  local app_path="$1" requirement
  requirement="$(_ghostty_codesign_requirement)" || return 1
  _ghostty_codesign --verify --deep --strict -R "$requirement" \
    -- "$app_path" >/dev/null 2>&1
}

_ghostty_quarantine_absent() {
  ! /usr/bin/xattr -p com.apple.quarantine "$1" >/dev/null 2>&1
}

# Verify the actual main executable and evaluate the publisher identity as a
# code requirement. Display-only Authority/TeamIdentifier strings are never a
# trust decision.
ghostty_mdm_is_trusted() {
  local app_path="${1:-$(_ghostty_app_path)}" binary
  [[ "$app_path" == /* && ! "$app_path" =~ [[:cntrl:]] ]] || return 1
  binary="$app_path/Contents/MacOS/ghostty"
  [[ -d "$app_path" && ! -L "$app_path" \
    && -d "$app_path/Contents" && ! -L "$app_path/Contents" \
    && -d "$app_path/Contents/MacOS" && ! -L "$app_path/Contents/MacOS" \
    && -f "$binary" && ! -L "$binary" && -x "$binary" ]] || return 1
  _ghostty_signature_trusted "$app_path"
}

install_ghostty_mdm() {
  local app_path mode
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || return 1
  app_path="$(_ghostty_app_path)" || return 1
  mode="$(_ghostty_mdm_mode)" || return 1

  if ghostty_mdm_is_trusted "$app_path"; then
    if [[ "$mode" == "auto" ]]; then
      /usr/bin/xattr -d com.apple.quarantine "$app_path" 2>/dev/null || true
    fi
    if ! _ghostty_quarantine_absent "$app_path"; then
      warn "Ghostty still has the Gatekeeper quarantine attribute; the MDM preinstall must clear it."
      return 1
    fi
    ok "$STR_GHOSTTY_ALREADY_INSTALLED"
    return 0
  fi
  # setup.sh runs as the bound target user. A standard managed account cannot
  # non-interactively place a cask in /Applications, and Homebrew must not be
  # run as root. MDM therefore treats Ghostty as a separately preinstalled
  # baseline in both prerequisite modes and only configures it after signature
  # validation. This avoids a hidden password prompt in zero-touch deployment.
  warn "Ghostty must be preinstalled by MDM at $app_path with a trusted Developer ID signature (mode=$mode)."
  return 1
}

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
  if _ghostty_mdm_managed; then
    install_ghostty_mdm
    return
  fi
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
  if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    return 0
  fi

  local template_file="${1:-}"

  if _ghostty_mdm_managed; then
    if ! install_ghostty; then
      GHOSTTY_INCOMPLETE+=("Ghostty")
      return 1
    fi
    # In managed mode fonts are a separate required component. Installing a
    # font as an unattested Ghostty side effect would make the receipt lie.
    if [[ -n "$template_file" && -f "$template_file" ]]; then
      deploy_ghostty_config "$template_file" || return 1
    fi
    return 0
  fi

  install_ghostty       || GHOSTTY_INCOMPLETE+=("Ghostty")
  install_hackgen_nf    || GHOSTTY_INCOMPLETE+=("HackGen-NF")

  if [[ -n "$template_file" && -f "$template_file" ]]; then
    deploy_ghostty_config "$template_file"
  fi
}
