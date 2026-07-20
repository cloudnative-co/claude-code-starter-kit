#!/bin/bash
set -euo pipefail

_ccsk_biome_receipt_path() {
  local current_user
  current_user="$(/usr/bin/id -un 2>/dev/null)" || return 1
  [[ ${#current_user} -ge 1 && ${#current_user} -le 32 \
    && "$current_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*([.@][A-Za-z0-9_-]+)*$ ]] \
    || return 1
  printf '%s' "/Library/Application Support/ClaudeCodeStarterKit/receipt-$current_user.json"
}

_ccsk_biome_real_file_exact() {
  local path="$1" parent canonical
  [[ "$path" == /* && -f "$path" && ! -L "$path" && -x "$path" ]] || return 1
  parent="${path%/*}"
  canonical="$(builtin cd -P -- "$parent" 2>/dev/null \
    && printf '%s/%s' "$PWD" "${path##*/}")" || return 1
  [[ "$canonical" == "$path" ]]
}

_ccsk_biome_arch() {
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

_ccsk_biome_expected_sha256() {
  case "$(_ccsk_biome_arch)" in
    arm64) printf '%s' '1250bb41a0409cf6c3133fc47819237eb61251624297f87158d2bed3ec123c3c' ;;
    x64) printf '%s' 'b3dfae5422dbd86272bb8ed40afec66670ea7754531d8fbcbae7e445e5430387' ;;
    *) return 1 ;;
  esac
}

_ccsk_biome_sha256() {
  local path="$1"
  if [[ -x /usr/bin/shasum ]]; then
    /usr/bin/shasum -a 256 "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
  elif [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
  elif [[ -x /bin/sha256sum ]]; then
    /bin/sha256sum "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
  else
    return 1
  fi
}

_ccsk_biome_metadata_is_safe() {
  local path="$1" uid links mode expected_uid
  expected_uid="$(/usr/bin/id -u 2>/dev/null)" || return 1
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]]; then
    uid="$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" || return 1
    links="$(/usr/bin/stat -f '%l' "$path" 2>/dev/null)" || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null)" || return 1
  else
    uid="$(/usr/bin/stat -c '%u' "$path" 2>/dev/null)" || return 1
    links="$(/usr/bin/stat -c '%h' "$path" 2>/dev/null)" || return 1
    mode="$(/usr/bin/stat -c '%a' "$path" 2>/dev/null)" || return 1
  fi
  [[ "$uid" == "$expected_uid" && "$links" == 1 && "$mode" == 755 ]]
}

_ccsk_biome_command() {
  local component_root managed receipt=""
  component_root="$HOME/.local/lib/claude-code-starter-kit/biome/2.5.4"
  managed="$component_root/biome"
  receipt="$(_ccsk_biome_receipt_path 2>/dev/null || true)"

  # The system runtime belongs to every local account.  Only this user's root
  # receipt or per-user component marks a managed install.  Once marked, a
  # partial/corrupt component must never fall through to an unrelated PATH
  # binary; formatting remains best-effort and simply becomes a no-op.
  if [[ ( -n "$receipt" && ( -e "$receipt" || -L "$receipt" ) ) \
    || -e "$component_root" || -L "$component_root" ]]; then
    _ccsk_biome_real_file_exact "$managed" || return 1
    _ccsk_biome_metadata_is_safe "$managed" || return 1
    [[ "$(_ccsk_biome_sha256 "$managed")" \
      == "$(_ccsk_biome_expected_sha256)" ]] || return 1
    printf '%s' "$managed"
    return 0
  fi
  command -v biome 2>/dev/null
}

_ccsk_biome_main() {
  local input file_path biome_command
  input="$(/bin/cat)"
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

  biome_command="$(_ccsk_biome_command 2>/dev/null || true)"
  if [[ "$file_path" =~ \.(ts|tsx|js|jsx)$ ]] \
    && [[ -f "$file_path" ]] \
    && [[ -n "$biome_command" ]]; then
    "$biome_command" check --write "$file_path" 2>&1 \
      | /usr/bin/head -5 >&2 || true
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _ccsk_biome_main "$@"
fi
