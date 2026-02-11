#!/bin/bash
# lib/colors.sh - Color output helpers for terminal messages
# Works on macOS and Linux. Falls back to plain text if terminal lacks color support.
set -euo pipefail

# ---------------------------------------------------------------------------
# Color codes (disabled when stdout is not a terminal or TERM is dumb)
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m' # No Color / reset
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  BOLD=''
  NC=''
fi

# ---------------------------------------------------------------------------
# Output functions
# ---------------------------------------------------------------------------

# Informational message (blue)
info() {
  printf "${BLUE}[INFO]${NC} %s\n" "$*"
}

# Success message (green)
ok() {
  printf "${GREEN}[  OK]${NC} %s\n" "$*"
}

# Warning message (yellow) - prints to stderr
warn() {
  printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2
}

# Error message (red) - prints to stderr
error() {
  printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

# Section header with a visual separator
section() {
  printf "\n${BOLD}── %s ──${NC}\n\n" "$*"
}
