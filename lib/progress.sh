#!/bin/bash
# lib/progress.sh - Lightweight progress helpers for update/dry-run flows
#
# Requires: lib/colors.sh
# Uses globals: DRY_RUN, _QUIET_OUTPUT
# Exports: _progress_step(), _progress_tick(), _progress_summary()
set -euo pipefail

_progress_label() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '%s' "Preview"
  else
    printf '%s' "Step"
  fi
}

_progress_step() {
  local current="$1"
  local total="$2"
  local label="$3"
  info "$(_progress_label) ${current}/${total}: ${label}"
}

_progress_tick() {
  local label="$1"
  local current="$2"
  local total="$3"
  info "  ${label}: ${current}/${total}"
}

_progress_summary() {
  local label="$1"
  local message="$2"
  info "  ${label}: ${message}"
}
