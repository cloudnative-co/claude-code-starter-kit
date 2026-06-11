#!/bin/bash
# tests/unit/test-install-bootstrap.sh - Bootstrap installer regression tests

{
  test_name="install: shell scripts are forced to LF checkouts"
  if grep -q '^\*\.sh text eol=lf$' "$PROJECT_DIR/.gitattributes" \
    && grep -q '^\*\.bash text eol=lf$' "$PROJECT_DIR/.gitattributes" \
    && grep -q '^\*\.conf text eol=lf$' "$PROJECT_DIR/.gitattributes"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install: reclone fallback clones to temp before replacing target"
  if grep -q '_clone_to_temp_and_swap "$INSTALL_DIR"' "$PROJECT_DIR/install.sh" \
    && grep -q 'mktemp -d "$parent/.claude-starter-kit.clone.XXXXXX"' "$PROJECT_DIR/install.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install: _clone_to_temp_and_swap keeps target intact when clone fails"
  _ib_tmp="$(mktemp -d)"
  _ib_target="$_ib_tmp/kits/claude-code-starter-kit"
  mkdir -p "$_ib_target" "$_ib_tmp/bin"
  printf 'keep me\n' > "$_ib_target/existing.txt"

  # Fake git: clone always fails
  cat > "$_ib_tmp/bin/git" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$_ib_tmp/bin/git"

  # Source install.sh in a subshell so its set -euo pipefail / globals do not
  # leak into the shared test process. Results are passed back via files.
  _ib_rc=0
  (
    export PATH="$_ib_tmp/bin:$PATH"
    export HOME="$_ib_tmp/home"
    export STARTER_KIT_DIR="$_ib_tmp/home/.claude-starter-kit"
    # shellcheck source=install.sh
    source "$PROJECT_DIR/install.sh"
    _swap_rc=0
    _clone_to_temp_and_swap "$_ib_target" >/dev/null 2>&1 || _swap_rc=$?
    printf '%s' "$_swap_rc" > "$_ib_tmp/swap_rc"
  ) || _ib_rc=$?

  _ib_swap_rc="$(cat "$_ib_tmp/swap_rc" 2>/dev/null || printf 'missing')"
  _ib_leftover="$(find "$_ib_tmp/kits" -maxdepth 1 -name '.claude-starter-kit.clone.*' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$_ib_rc" -eq 0 ]] \
    && [[ "$_ib_swap_rc" != "missing" ]] \
    && [[ "$_ib_swap_rc" != "0" ]] \
    && [[ -f "$_ib_target/existing.txt" ]] \
    && grep -q 'keep me' "$_ib_target/existing.txt" \
    && [[ "$_ib_leftover" -eq 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}

{
  test_name="install: _clone_to_temp_and_swap replaces target after successful clone"
  _ib_tmp="$(mktemp -d)"
  _ib_target="$_ib_tmp/kits/claude-code-starter-kit"
  mkdir -p "$_ib_target" "$_ib_tmp/bin"
  printf 'stale content\n' > "$_ib_target/old-file.txt"

  # Fake git: clone creates the destination repo with a marker file
  cat > "$_ib_tmp/bin/git" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "clone" ]]; then
  _dest="${!#}"
  mkdir -p "$_dest"
  printf 'fresh clone\n' > "$_dest/NEW_REPO_MARKER"
  exit 0
fi
exit 0
EOF
  chmod +x "$_ib_tmp/bin/git"

  _ib_rc=0
  (
    export PATH="$_ib_tmp/bin:$PATH"
    export HOME="$_ib_tmp/home"
    export STARTER_KIT_DIR="$_ib_tmp/home/.claude-starter-kit"
    # shellcheck source=install.sh
    source "$PROJECT_DIR/install.sh"
    _swap_rc=0
    _clone_to_temp_and_swap "$_ib_target" >/dev/null 2>&1 || _swap_rc=$?
    printf '%s' "$_swap_rc" > "$_ib_tmp/swap_rc"
  ) || _ib_rc=$?

  _ib_swap_rc="$(cat "$_ib_tmp/swap_rc" 2>/dev/null || printf 'missing')"
  _ib_leftover="$(find "$_ib_tmp/kits" -maxdepth 1 -name '.claude-starter-kit.clone.*' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$_ib_rc" -eq 0 ]] \
    && [[ "$_ib_swap_rc" == "0" ]] \
    && [[ -f "$_ib_target/NEW_REPO_MARKER" ]] \
    && [[ ! -e "$_ib_target/old-file.txt" ]] \
    && [[ "$_ib_leftover" -eq 0 ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}

{
  test_name="install: install.sh can be sourced without running main"
  _out="$(HOME="/Users/tester" STARTER_KIT_DIR="/Users/tester/.claude-starter-kit" bash -c 'source "$1"; type _safe_install_dir >/dev/null; printf ok' _ "$PROJECT_DIR/install.sh" 2>&1)"
  if [[ "$_out" == "ok" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install: _safe_install_dir rejects dangerous paths"
  if HOME="/Users/tester" STARTER_KIT_DIR="/Users/tester/.claude-starter-kit" bash -c '
    source "$1"
    _safe_install_dir "$HOME/.claude-starter-kit"
    ! _safe_install_dir "$HOME"
    ! _safe_install_dir "/"
    ! _safe_install_dir "/usr/local/share/claude"
    ! _safe_install_dir "/tmp/claude"
  ' _ "$PROJECT_DIR/install.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install: update and NONINTERACTIVE handling are testable in main"
  if grep -q 'install_main()' "$PROJECT_DIR/install.sh" \
    && grep -q '_setup_args+=("--non-interactive")' "$PROJECT_DIR/install.sh" \
    && grep -q '_setup_args+=("--update")' "$PROJECT_DIR/install.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install.ps1: embedded bootstrap uses safe clone swap"
  clone_calls="$(grep -c '_clone_to_temp_and_swap "$INSTALL_DIR"' "$PROJECT_DIR/install.ps1" || true)"
  if [[ "$clone_calls" -ge 4 ]] \
    && ! grep -q 'git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"' "$PROJECT_DIR/install.ps1"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install.ps1: embedded safety guards stay visible to CI"
  safe_guard_count="$(grep -c '^_safe_install_dir()' "$PROJECT_DIR/install.ps1" || true)"
  if [[ "$safe_guard_count" -eq 2 ]] \
    && grep -q '^_safe_install_dir()' "$PROJECT_DIR/install.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install.ps1: delegates Node.js installation to prerequisites"
  if ! grep -q 'setup_20.x' "$PROJECT_DIR/install.ps1" \
    && ! grep -q 'setup_.*\\.x.*nodejs' "$PROJECT_DIR/install.ps1"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="uninstall: runtime cleanup is manifest driven"
  if grep -q 'cleanup_paths_json()' "$PROJECT_DIR/lib/deploy.sh" \
    && grep -q 'cleanup_paths: $cleanup_paths' "$PROJECT_DIR/lib/deploy.sh" \
    && grep -q '_json_cleanup_paths "$MANIFEST"' "$PROJECT_DIR/uninstall.sh" \
    && grep -q '_cleanup_paths_seen' "$PROJECT_DIR/uninstall.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="uninstall: starter kit repository cleanup is offered"
  if grep -q 'Also remove starter kit repository' "$PROJECT_DIR/uninstall.sh" \
    && grep -q 'Remove manually if desired' "$PROJECT_DIR/uninstall.sh" \
    && grep -q '_safe_install_dir "$KIT_INSTALL_DIR"' "$PROJECT_DIR/uninstall.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ---------------------------------------------------------------------------
# Embedded-copy sync checks
#
# _safe_install_dir exists in 4 copies (install.sh, install.ps1 WSL here-string,
# install.ps1 Git Bash here-string, uninstall.sh) and _clone_to_temp_and_swap
# in 3 copies (install.sh, install.ps1 x2). These tests extract each function
# body and compare them after normalization (strip leading whitespace, drop
# blank/comment lines) so a change to one copy without the others fails CI.
# ---------------------------------------------------------------------------

# Extract the Nth occurrence (1-based) of a top-level function body from a file.
_ib_extract_fn() {
  # Usage: _ib_extract_fn <file> <function-name> [occurrence]
  awk -v fn="$2" -v want="${3:-1}" '
    !inside && $0 ~ ("^" fn "\\(\\)") { count++; if (count == want) inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$1" | tr -d '\r'
}

# Normalize a function body: strip leading whitespace, drop comments/blanks.
_ib_normalize_fn() {
  sed -e 's/^[[:space:]]*//' -e '/^#/d' -e '/^$/d'
}

{
  test_name="sync: _safe_install_dir identical across install.sh / install.ps1 (x2) / uninstall.sh"
  _ib_ref="$(_ib_extract_fn "$PROJECT_DIR/install.sh" _safe_install_dir 1 | _ib_normalize_fn)"
  _ib_ps1_wsl="$(_ib_extract_fn "$PROJECT_DIR/install.ps1" _safe_install_dir 1 | _ib_normalize_fn)"
  _ib_ps1_gitbash="$(_ib_extract_fn "$PROJECT_DIR/install.ps1" _safe_install_dir 2 | _ib_normalize_fn)"
  _ib_uninstall="$(_ib_extract_fn "$PROJECT_DIR/uninstall.sh" _safe_install_dir 1 | _ib_normalize_fn)"
  # Sanity: extraction must capture a complete, meaningful body
  if [[ "$_ib_ref" == *'depth'* ]] && [[ "$_ib_ref" == *'return 0'* ]] && [[ "$_ib_ref" == *$'\n}' ]] \
    && [[ "$_ib_ref" == "$_ib_ps1_wsl" ]] \
    && [[ "$_ib_ref" == "$_ib_ps1_gitbash" ]] \
    && [[ "$_ib_ref" == "$_ib_uninstall" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="sync: _clone_to_temp_and_swap identical across install.sh / install.ps1 (x2)"
  _ib_ref="$(_ib_extract_fn "$PROJECT_DIR/install.sh" _clone_to_temp_and_swap 1 | _ib_normalize_fn)"
  _ib_ps1_wsl="$(_ib_extract_fn "$PROJECT_DIR/install.ps1" _clone_to_temp_and_swap 1 | _ib_normalize_fn)"
  _ib_ps1_gitbash="$(_ib_extract_fn "$PROJECT_DIR/install.ps1" _clone_to_temp_and_swap 2 | _ib_normalize_fn)"
  if [[ "$_ib_ref" == *'mktemp -d'* ]] && [[ "$_ib_ref" == *'return 1'* ]] && [[ "$_ib_ref" == *$'\n}' ]] \
    && [[ "$_ib_ref" == "$_ib_ps1_wsl" ]] \
    && [[ "$_ib_ref" == "$_ib_ps1_gitbash" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="install: _safe_install_dir rejects trailing-slash and relative bypasses"
  if HOME="/Users/tester" STARTER_KIT_DIR="/Users/tester/.claude-starter-kit" bash -c '
    source "$1"
    _safe_install_dir "$HOME/.claude-starter-kit"
    _safe_install_dir "$HOME/.claude-starter-kit/"
    ! _safe_install_dir "$HOME//"
    ! _safe_install_dir "$HOME/"
    ! _safe_install_dir "/usr//"
    ! _safe_install_dir "relative/path/with/depth"
    ! _safe_install_dir ""
  ' _ "$PROJECT_DIR/install.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ---------------------------------------------------------------------------
# _resolve_setup_args behavior (update auto-detection + NONINTERACTIVE)
# ---------------------------------------------------------------------------

# Run _resolve_setup_args in a clean subshell with a controlled HOME.
# Usage: _ib_resolve_args <home> <noninteractive-env> [setup-args...]
# Prints "<update_mode>|<is_noninteractive>|<final args>"
_ib_resolve_args() {
  local _ib_home="$1" _ib_ni="$2"
  shift 2
  HOME="$_ib_home" STARTER_KIT_DIR="$_ib_home/.claude-starter-kit" NONINTERACTIVE="$_ib_ni" \
    bash -c '
      source "$1"
      shift
      _resolve_setup_args "$@" >/dev/null
      printf "%s|%s|%s" "$_update_mode" "$_is_noninteractive" "${_setup_args[*]-}"
    ' _ "$PROJECT_DIR/install.sh" "$@" 2>/dev/null
}

{
  test_name="install: _resolve_setup_args passes args through without manifest"
  _ib_tmp="$(mktemp -d)"
  mkdir -p "$_ib_tmp/home"
  _ib_out="$(_ib_resolve_args "$_ib_tmp/home" "")" || _ib_out="ERROR"
  _ib_out2="$(_ib_resolve_args "$_ib_tmp/home" "" --profile=full)" || _ib_out2="ERROR"
  if [[ "$_ib_out" == "false|false|" ]] \
    && [[ "$_ib_out2" == "false|false|--profile=full" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}

{
  test_name="install: _resolve_setup_args auto-adds --update when manifest v2 + snapshot exist"
  _ib_tmp="$(mktemp -d)"
  mkdir -p "$_ib_tmp/home/.claude/.starter-kit-snapshot"
  printf '{"version": "2", "files": []}\n' > "$_ib_tmp/home/.claude/.starter-kit-manifest.json"
  _ib_out="$(_ib_resolve_args "$_ib_tmp/home" "")" || _ib_out="ERROR"
  if [[ "$_ib_out" == "true|true|--update" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}

{
  test_name="install: _resolve_setup_args does not duplicate an explicit --update"
  _ib_tmp="$(mktemp -d)"
  mkdir -p "$_ib_tmp/home/.claude/.starter-kit-snapshot"
  printf '{"version": "2", "files": []}\n' > "$_ib_tmp/home/.claude/.starter-kit-manifest.json"
  _ib_out="$(_ib_resolve_args "$_ib_tmp/home" "" --update)" || _ib_out="ERROR"
  if [[ "$_ib_out" == "true|true|--update" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}

{
  test_name="install: _resolve_setup_args treats legacy manifest (no snapshot) as migration update"
  _ib_tmp="$(mktemp -d)"
  mkdir -p "$_ib_tmp/home/.claude"
  printf '{"files": []}\n' > "$_ib_tmp/home/.claude/.starter-kit-manifest.json"
  _ib_out="$(_ib_resolve_args "$_ib_tmp/home" "")" || _ib_out="ERROR"
  if [[ "$_ib_out" == "true|true|--update" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}

{
  test_name="install: _resolve_setup_args honors NONINTERACTIVE env without duplicating the flag"
  _ib_tmp="$(mktemp -d)"
  mkdir -p "$_ib_tmp/home"
  _ib_out="$(_ib_resolve_args "$_ib_tmp/home" "1")" || _ib_out="ERROR"
  _ib_out2="$(_ib_resolve_args "$_ib_tmp/home" "1" --non-interactive)" || _ib_out2="ERROR"
  if [[ "$_ib_out" == "false|true|--non-interactive" ]] \
    && [[ "$_ib_out2" == "false|true|--non-interactive" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}

{
  test_name="install: _resolve_setup_args combines NONINTERACTIVE env and manifest update"
  _ib_tmp="$(mktemp -d)"
  mkdir -p "$_ib_tmp/home/.claude/.starter-kit-snapshot"
  printf '{"version": "2", "files": []}\n' > "$_ib_tmp/home/.claude/.starter-kit-manifest.json"
  _ib_out="$(_ib_resolve_args "$_ib_tmp/home" "1")" || _ib_out="ERROR"
  if [[ "$_ib_out" == "true|true|--non-interactive --update" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}

{
  test_name="install: install_main auto-detects update mode end-to-end (fake git, no network)"
  # NOTE: system mktemp dirs (/tmp, /var/folders) are rejected by
  # _safe_install_dir's deny list, so the fake HOME lives under the repo.
  _ib_tmp="$(mktemp -d "$PROJECT_DIR/tests/.tmp-install-e2e.XXXXXX")"
  mkdir -p "$_ib_tmp/bin" "$_ib_tmp/home/.claude/.starter-kit-snapshot"
  printf '{"version": "2", "files": []}\n' > "$_ib_tmp/home/.claude/.starter-kit-manifest.json"

  # Fake git: "clone" creates a repo containing a stub setup.sh that records
  # its arguments; every other subcommand succeeds silently.
  cat > "$_ib_tmp/bin/git" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "clone" ]]; then
  _dest="${!#}"
  mkdir -p "$_dest"
  cat > "$_dest/setup.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$ARGS_OUT"
STUB
  exit 0
fi
exit 0
EOF
  chmod +x "$_ib_tmp/bin/git"

  _ib_rc=0
  (
    export PATH="$_ib_tmp/bin:$PATH"
    export HOME="$_ib_tmp/home"
    export STARTER_KIT_DIR="$_ib_tmp/home/.claude-starter-kit"
    export NONINTERACTIVE=1
    export ARGS_OUT="$_ib_tmp/setup-args"
    bash "$PROJECT_DIR/install.sh" >/dev/null 2>&1
  ) || _ib_rc=$?

  _ib_args="$(cat "$_ib_tmp/setup-args" 2>/dev/null || printf 'missing')"
  if [[ "$_ib_rc" -eq 0 ]] \
    && [[ -f "$_ib_tmp/home/.claude-starter-kit/setup.sh" ]] \
    && [[ "$_ib_args" == $'--non-interactive\n--update' ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
  rm -rf "$_ib_tmp"
}
