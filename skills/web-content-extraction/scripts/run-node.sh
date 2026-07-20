#!/bin/bash
set -euo pipefail

_ccsk_wce_arch() {
  local hardware_arm64=""
  if [[ -x /usr/sbin/sysctl ]]; then
    hardware_arm64="$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)"
  fi
  case "$hardware_arm64" in
    1) printf 'arm64'; return 0 ;;
    0) printf 'x64'; return 0 ;;
  esac
  case "$(/usr/bin/uname -m)" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|amd64) printf 'x64' ;;
    *) return 1 ;;
  esac
}

_ccsk_wce_managed_marker() {
  local receipt="$1" runtime_root="$2" node_link="$3" target=""

  # The runtime tree is shared by every local account, so its presence alone
  # cannot make this user managed.  A root-issued per-user receipt is the
  # authority; the exact per-user activation remains a marker if that receipt
  # is temporarily unavailable and must still fail closed when malformed.
  [[ -e "$receipt" || -L "$receipt" ]] && return 0
  [[ -L "$node_link" ]] || return 1
  target="$(/usr/bin/readlink "$node_link" 2>/dev/null)" || return 1
  case "$target" in
    "$runtime_root/node-v24.18.0-darwin-arm64/bin/node"|\
      "$runtime_root/node-v24.18.0-darwin-x64/bin/node") return 0 ;;
    *) return 1 ;;
  esac
}

_ccsk_wce_run() {
  local managed="$1" runtime_root="$2" node_link="$3"
  local expected_node="$4" self_path="$5" fallback=""
  shift 5

  if [[ "$managed" == true ]]; then
    [[ -n "$expected_node" && -L "$node_link" && -x "$node_link" ]] \
      || return 1
    [[ "$(/usr/bin/readlink "$node_link" 2>/dev/null)" == "$expected_node" ]] \
      || return 1
    [[ -f "$expected_node" && ! -L "$expected_node" \
      && -x "$expected_node" ]] || return 1
    unset NODE_OPTIONS NODE_PATH
    exec "$expected_node" "$@"
  fi

  fallback="$(command -v node 2>/dev/null)" || return 1
  [[ -n "$fallback" ]] || return 1
  if [[ "$fallback" == "$self_path" || "$fallback" -ef "$self_path" ]]; then
    return 1
  fi
  exec "$fallback" "$@"
}

_ccsk_wce_main() {
  local managed_root runtime_root node_link receipt current_user
  local managed=false expected_node="" arch
  managed_root="/Library/Application Support/ClaudeCodeStarterKit"
  runtime_root="$managed_root/runtime"
  node_link="$HOME/.local/bin/node"
  current_user="$(/usr/bin/id -un 2>/dev/null)" || return 1
  case "$current_user" in ""|*/*) return 1 ;; esac
  receipt="$managed_root/receipt-$current_user.json"
  if _ccsk_wce_managed_marker "$receipt" "$runtime_root" "$node_link"; then
    managed=true
    arch="$(_ccsk_wce_arch)" || return 1
    expected_node="$runtime_root/node-v24.18.0-darwin-$arch/bin/node"
  fi
  _ccsk_wce_run "$managed" "$runtime_root" "$node_link" \
    "$expected_node" "${BASH_SOURCE[0]}" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _ccsk_wce_main "$@"
fi
