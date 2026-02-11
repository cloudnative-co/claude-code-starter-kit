#!/bin/bash
# lib/ghostty.sh - Ghostty terminal emulator installation and configuration
# Requires: lib/colors.sh and lib/detect.sh to be sourced first
set -euo pipefail

# ---------------------------------------------------------------------------
# Config path detection
# ---------------------------------------------------------------------------
_ghostty_config_dir() {
  case "$(uname -s)" in
    Darwin) printf '%s' "$HOME/Library/Application Support/com.mitchellh.ghostty" ;;
    *)      printf '%s' "$HOME/.config/ghostty" ;;
  esac
}

# ---------------------------------------------------------------------------
# Ensure Homebrew is available (find in PATH or standard locations)
# ---------------------------------------------------------------------------
_ghostty_ensure_brew() {
  command -v brew &>/dev/null && return 0

  # Try standard Homebrew paths (may not be in PATH yet)
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  command -v brew &>/dev/null && return 0

  # Not installed - try to install (macOS only)
  if [[ "$(uname -s)" == "Darwin" ]]; then
    info "Homebrew not found. Installing Homebrew..."
    if NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1; then
      if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
    fi
  fi

  command -v brew &>/dev/null
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
  if [[ -d "/Applications/Ghostty.app" ]] || command -v ghostty &>/dev/null; then
    ok "$STR_GHOSTTY_ALREADY_INSTALLED"
    return 0
  fi
  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "$STR_GHOSTTY_SKIP_PLATFORM"
    return 0
  fi
  if ! _ghostty_ensure_brew; then
    warn "Homebrew is not available. Cannot install Ghostty."
    info "  Install manually: https://ghostty.org/"
    return 0
  fi
  info "Installing Ghostty..."
  if brew install --cask ghostty; then
    ok "Ghostty installed"
  else
    warn "Failed to install Ghostty. Install manually: https://ghostty.org/"
  fi
}

# ---------------------------------------------------------------------------
# Install HackGen NF font
# ---------------------------------------------------------------------------
install_hackgen_font() {
  if ! command -v brew &>/dev/null; then
    warn "Homebrew is not available. Cannot install HackGen NF font."
    info "  Install manually: https://github.com/yuru7/HackGen"
    return 0
  fi
  if brew list --cask font-hackgen-nerd &>/dev/null; then
    ok "$STR_GHOSTTY_FONT_ALREADY"
    return 0
  fi
  info "Installing HackGen NF font..."
  if brew install --cask font-hackgen-nerd; then
    ok "HackGen NF font installed"
  else
    warn "Failed to install HackGen NF font. Install manually: https://github.com/yuru7/HackGen"
  fi
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
  local template_file="${1:-}"
  install_ghostty
  install_hackgen_font
  if [[ -n "$template_file" && -f "$template_file" ]]; then
    deploy_ghostty_config "$template_file"
  fi
}
