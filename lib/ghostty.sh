#!/bin/bash
# lib/ghostty.sh - Ghostty terminal emulator installation and configuration
# Requires: lib/colors.sh and lib/detect.sh to be sourced first
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

# ---------------------------------------------------------------------------
# Ensure Homebrew is available (find in PATH or standard locations)
# ---------------------------------------------------------------------------
_ghostty_ensure_brew() {
  # _brew_is_usable is defined in lib/prerequisites.sh (sourced earlier)
  _brew_is_usable 2>/dev/null && return 0

  # Try standard Homebrew paths (may not be in PATH yet)
  if ! command -v brew &>/dev/null; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
  _brew_is_usable 2>/dev/null && return 0

  # Not installed or not usable (installed by another user) — try to install
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      warn "Homebrew found but not writable by current user"
    fi
    info "Installing Homebrew..."
    if NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
      if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
  fi

  _brew_is_usable 2>/dev/null
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

  local uname_s
  uname_s="$(uname -s)"

  case "$uname_s" in
    Darwin)
      if ! _ghostty_ensure_brew; then
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

# ---------------------------------------------------------------------------
# Install HackGen NF font
# ---------------------------------------------------------------------------
install_hackgen_font() {
  local uname_s
  uname_s="$(uname -s)"

  case "$uname_s" in
    Darwin)
      # Already installed via brew?
      if _brew_is_usable 2>/dev/null && brew list --cask font-hackgen-nerd &>/dev/null 2>&1; then
        ok "$STR_GHOSTTY_FONT_ALREADY"
        return 0
      fi
      # Already installed via direct download?
      # shellcheck disable=SC2086
      if ls "$HOME/Library/Fonts"/HackGen*NF*.ttf &>/dev/null 2>&1; then
        ok "$STR_GHOSTTY_FONT_ALREADY"
        return 0
      fi
      info "Installing HackGen NF font..."
      # Try brew first, fall back to direct download
      if _ghostty_ensure_brew && brew install --cask font-hackgen-nerd 2>/dev/null; then
        ok "HackGen NF font installed"
        return 0
      fi
      info "  brew failed, downloading directly..."
      local hackgen_url="https://github.com/yuru7/HackGen/releases/download/v2.10.0/HackGen_NF_v2.10.0.zip"
      local tmp_dir
      tmp_dir="$(mktemp -d)"
      mkdir -p "$HOME/Library/Fonts"
      if curl -fsSL "$hackgen_url" -o "$tmp_dir/HackGen_NF.zip" \
         && unzip -qo "$tmp_dir/HackGen_NF.zip" -d "$tmp_dir"; then
        find "$tmp_dir" -name "*.ttf" -exec cp {} "$HOME/Library/Fonts/" \;
        rm -rf "$tmp_dir"
        ok "HackGen NF font installed"
        return 0
      fi
      rm -rf "$tmp_dir"
      warn "Failed to install HackGen NF font."
      info "  Install manually: https://github.com/yuru7/HackGen"
      return 1
      ;;
    MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*)
      warn "Automatic font installation is not supported on Windows."
      info "  Download HackGen NF: https://github.com/yuru7/HackGen/releases"
      info "  Double-click the .ttf files to install."
      return 1
      ;;
    *)
      warn "Cannot install HackGen NF font on this platform."
      info "  Install manually: https://github.com/yuru7/HackGen"
      return 1
      ;;
  esac
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
  install_hackgen_font  || GHOSTTY_INCOMPLETE+=("HackGen-NF")

  if [[ -n "$template_file" && -f "$template_file" ]]; then
    deploy_ghostty_config "$template_file"
  fi
}
