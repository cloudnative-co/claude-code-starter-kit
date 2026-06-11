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
    && grep -q 'mktemp -d "$parent/.claude-starter-kit.clone.XXXXXX"' "$PROJECT_DIR/install.sh" \
    && ! grep -q 'git -C "$INSTALL_DIR" pull --ff-only.*rm -rf "$INSTALL_DIR"' "$PROJECT_DIR/install.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
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
