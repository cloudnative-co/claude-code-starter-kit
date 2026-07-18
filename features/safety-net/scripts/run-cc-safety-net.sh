#!/bin/bash
set -euo pipefail

_ccsk_safety_hw_arm64() {
  [[ -x /usr/sbin/sysctl ]] || return 1
  /usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null
}

_ccsk_safety_machine_arch() {
  /usr/bin/uname -m
}

_ccsk_safety_arch() {
  local hardware_arm64=""
  hardware_arm64="$(_ccsk_safety_hw_arm64 2>/dev/null || true)"
  case "$hardware_arm64" in
    1) printf 'arm64'; return 0 ;;
    0) printf 'x64'; return 0 ;;
  esac
  case "$(_ccsk_safety_machine_arch)" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|amd64) printf 'x64' ;;
    *) return 1 ;;
  esac
}

_ccsk_safety_runtime_base() {
  printf '%s' "/Library/Application Support/ClaudeCodeStarterKit/runtime"
}

_ccsk_safety_component_root() {
  printf '%s' "$HOME/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6"
}

_ccsk_safety_receipt_path() {
  local current_user
  current_user="$(/usr/bin/id -un 2>/dev/null)" || return 1
  [[ ${#current_user} -ge 1 && ${#current_user} -le 32 \
    && "$current_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*([.@][A-Za-z0-9_-]+)*$ ]] \
    || return 1
  printf '%s' "/Library/Application Support/ClaudeCodeStarterKit/receipt-$current_user.json"
}

_ccsk_safety_user_is_managed() {
  local receipt="$1" component_root="$2"
  [[ -e "$receipt" || -L "$receipt" \
    || -e "$component_root" || -L "$component_root" ]]
}

_ccsk_safety_real_dir_exact() {
  local path="$1" canonical
  [[ "$path" == /* && -d "$path" && ! -L "$path" ]] || return 1
  canonical="$(builtin cd -P -- "$path" 2>/dev/null && printf '%s' "$PWD")" \
    || return 1
  [[ "$canonical" == "$path" ]]
}

_ccsk_safety_real_file_exact() {
  local path="$1" parent canonical
  [[ "$path" == /* && -f "$path" && ! -L "$path" ]] || return 1
  parent="${path%/*}"
  canonical="$(builtin cd -P -- "$parent" 2>/dev/null \
    && printf '%s/%s' "$PWD" "${path##*/}")" || return 1
  [[ "$canonical" == "$path" ]]
}

_ccsk_safety_expected_cli_sha256() {
  printf '%s' "1ffbfafabf2fe4fc9b6bf64a8088ca3a96c2714cf8fd8afd5b1b326582c982d4"
}

_ccsk_safety_snapshot_cli() {
  local cli="$1" expected_sha
  expected_sha="$(_ccsk_safety_expected_cli_sha256)" || return 1
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ \
    && -x /usr/bin/python3 && ! -L /usr/bin/python3 ]] || return 1
  /usr/bin/env -i HOME="${HOME:-/}" LC_ALL=C \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /usr/bin/python3 -I -B - "$cli" "$expected_sha" 2>/dev/null <<'PY'
import hashlib
import os
import stat
import sys
import tempfile

source, expected = sys.argv[1:]
limit = 64 * 1024 * 1024
temp_dir = None
snapshot = None

def identity(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_uid, value.st_gid, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns)

def remove_private():
    if snapshot is not None:
        try:
            os.unlink(snapshot)
        except FileNotFoundError:
            pass
    if temp_dir is not None:
        try:
            os.rmdir(temp_dir)
        except FileNotFoundError:
            pass

try:
    if (not os.path.isabs(source) or os.path.normpath(source) != source
            or os.path.realpath(source) != source):
        raise ValueError("non-canonical source")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(source, flags)
    try:
        before = os.fstat(descriptor)
        mode = stat.S_IMODE(before.st_mode)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or before.st_uid != os.geteuid() or mode & 0o022
                or before.st_size <= 0 or before.st_size > limit):
            raise ValueError("unsafe source")
        chunks = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise ValueError("short read")
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        if identity(before) != identity(after):
            raise ValueError("source changed")
    finally:
        os.close(descriptor)
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("source hash mismatch")

    temp_base = "/private/tmp" if sys.platform == "darwin" else "/tmp"
    base = os.lstat(temp_base)
    base_mode = stat.S_IMODE(base.st_mode)
    if (not stat.S_ISDIR(base.st_mode) or base.st_uid != 0
            or (base_mode & 0o022 and not base_mode & stat.S_ISVTX)):
        raise ValueError("unsafe temp base")
    temp_dir = tempfile.mkdtemp(prefix="ccsk-safety.", dir=temp_base)
    os.chmod(temp_dir, 0o700)
    directory = os.lstat(temp_dir)
    if (not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.geteuid()
            or stat.S_IMODE(directory.st_mode) != 0o700):
        raise ValueError("unsafe snapshot directory")

    snapshot = os.path.join(temp_dir, "cc-safety-net.mjs")
    output_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    output_flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    output = os.open(snapshot, output_flags, 0o400)
    try:
        view = memoryview(data)
        while view:
            written = os.write(output, view)
            if written <= 0:
                raise OSError("short write")
            view = view[written:]
        os.fchmod(output, 0o400)
        os.fsync(output)
    finally:
        os.close(output)
    final = os.lstat(snapshot)
    if (not stat.S_ISREG(final.st_mode) or final.st_nlink != 1
            or final.st_uid != os.geteuid()
            or stat.S_IMODE(final.st_mode) != 0o400
            or final.st_size != len(data)):
        raise ValueError("unsafe snapshot")
    directory_fd = os.open(temp_dir, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    print(snapshot)
except (OSError, ValueError):
    remove_private()
    sys.exit(1)
PY
}

_ccsk_safety_cleanup_snapshot() {
  local snapshot="$1" directory
  directory="${snapshot%/*}"
  /bin/rm -f "$snapshot" 2>/dev/null || return 1
  /bin/rmdir "$directory" 2>/dev/null || return 1
}

_ccsk_safety_execute_snapshot() (
  local node="$1" snapshot="$2"
  shift 2
  trap '_ccsk_safety_cleanup_snapshot "$snapshot" >/dev/null 2>&1 || true' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  unset NODE_OPTIONS NODE_PATH
  "$node" "$snapshot" "$@"
)

_ccsk_safety_run() {
  local managed="$1" node="$2" cli="$3" component_root="$4"
  local runtime_base="$5" self_path="$6" fallback="" snapshot=""
  shift 6

  if [[ "$managed" == true ]]; then
    _ccsk_safety_real_dir_exact "$runtime_base" || return 1
    _ccsk_safety_real_dir_exact "$component_root" || return 1
    _ccsk_safety_real_file_exact "$node" && [[ -x "$node" ]] || return 1
    _ccsk_safety_real_file_exact "$cli" || return 1
    snapshot="$(_ccsk_safety_snapshot_cli "$cli")" || return 1
    _ccsk_safety_execute_snapshot "$node" "$snapshot" "$@"
    return $?
  fi
  [[ "$managed" == false ]] || return 1

  # Normal installs retain the historical PATH lookup.  The deployed wrapper
  # has a different name, and the inode check also rejects a PATH symlink back
  # to this wrapper so a malformed installation cannot recurse indefinitely.
  fallback="$(command -v cc-safety-net 2>/dev/null)" || return 1
  [[ -n "$fallback" ]] || return 1
  if [[ "$fallback" == "$self_path" || "$fallback" -ef "$self_path" ]]; then
    return 1
  fi
  exec "$fallback" "$@"
}

_ccsk_safety_main() {
  local arch="" runtime_base node="" component_root cli receipt managed=false
  runtime_base="$(_ccsk_safety_runtime_base)" || return 1
  component_root="$(_ccsk_safety_component_root)" || return 1
  # An account name outside the MDM issuer's allowlist is necessarily
  # non-managed, but ordinary Linux/WSL installs must still reach PATH.
  receipt="$(_ccsk_safety_receipt_path 2>/dev/null || true)"
  cli="$component_root/dist/bin/cc-safety-net.js"
  if _ccsk_safety_user_is_managed "$receipt" "$component_root"; then
    managed=true
    arch="$(_ccsk_safety_arch)" || return 1
    node="$runtime_base/node-v24.18.0-darwin-$arch/bin/node"
  fi
  _ccsk_safety_run "$managed" "$node" "$cli" "$component_root" \
    "$runtime_base" "${BASH_SOURCE[0]}" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _ccsk_safety_main "$@"
fi
