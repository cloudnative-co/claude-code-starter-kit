#!/bin/bash
# tests/unit/test-mdm-bootstrap.sh - Single-file clean launcher and root parser.

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

(
  export MDM_EUID_OVERRIDE=0 TMPDIR=/Users/attacker/tmp
  [[ "$(_mdm_safe_tmpdir)" == "/private/tmp" ]] \
    && pass "mdm-bootstrap: root は user TMPDIR を使わない" \
    || fail "mdm-bootstrap: root temporary directory is unsafe"
)
(
  export MDM_EUID_OVERRIDE=501 TMPDIR=/custom/tmp
  [[ "$(_mdm_safe_tmpdir)" == "/custom/tmp" ]] \
    && pass "mdm-bootstrap: source-only non-root override is testable" \
    || fail "mdm-bootstrap: source-only override failed"
)

if head -1 "$PROJECT_DIR/mdm/install-mdm.sh" | grep -q '^#!/bin/bash -p$' \
  && grep -q '/usr/bin/env -i' "$PROJECT_DIR/mdm/install-mdm.sh" \
  && grep -q -- '--noprofile --norc -p' "$PROJECT_DIR/mdm/install-mdm.sh" \
  && ! grep -q -- '--mdm-clean-launch' "$PROJECT_DIR/mdm/install-mdm.sh"; then
  pass "mdm-bootstrap: privileged shebang から clean Bash へ再実行"
else
  fail "mdm-bootstrap: clean privileged launcher contract is missing"
fi

if ! grep -qE 'source[[:space:]]+/dev/fd|source[[:space:]].*lib-mdm-config' \
    "$PROJECT_DIR/mdm/install-mdm.sh" \
  && ! grep -q '_mdm_bootstrap_and_reexec' "$PROJECT_DIR/mdm/install-mdm.sh" \
  && grep -q '_mdm_root_config_apply' "$PROJECT_DIR/mdm/install-mdm.sh"; then
  pass "mdm-bootstrap: root launcher は adjacent/checkout code を source しない"
else
  fail "mdm-bootstrap: root code-loading boundary regressed"
fi

_tmpd="$(mktemp -d)"
_conf="$_tmpd/mdm-config.conf"
chmod 700 "$_tmpd"
cat >"$_conf" <<'CONF'
PROFILE="standard"
LANGUAGE="ja"
KIT_MDM_GIT_REF="main"
KIT_MDM_INSTALL_HOMEBREW="false"
HTTP_PROXY="https://proxy.example:8443"
CONF
chmod 600 "$_conf"

(
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  export PROFILE=full GIT_EXEC_PATH=/tmp/attacker BASH_ENV=/tmp/attacker-env
  _rc=0
  _mdm_root_config_apply "$_conf" 'PROFILE=minimal' || _rc=$?
  if [[ "$_rc" -eq 0 && "$PROFILE" == "minimal" && "$LANGUAGE" == "ja" \
    && "$KIT_MDM_GIT_REF" == "main" && "$KIT_MDM_INSTALL_HOMEBREW" == "false" \
    && "$HTTP_PROXY" == "https://proxy.example:8443" ]]; then
    pass "mdm-bootstrap: CLI > root config、継承 PROFILE は破棄"
  else
    fail "mdm-bootstrap: root config precedence failed (rc=$_rc profile=${PROFILE:-})"
  fi
)

(
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _rc=0
  _mdm_root_config_apply "$_conf" 'UNKNOWN_KEY=value' >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq "$MDM_EXIT_CONFIG" ]] \
    && pass "mdm-bootstrap: unknown CLI key は fail-closed" \
    || fail "mdm-bootstrap: unknown CLI key was accepted (rc=$_rc)"
)

(
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _rc=0
  _mdm_root_config_apply "$_conf" 'KIT_MDM_GIT_REF=--upload-pack=evil' >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq "$MDM_EXIT_CONFIG" ]] \
    && pass "mdm-bootstrap: option-like Git ref を拒否" \
    || fail "mdm-bootstrap: unsafe Git ref was accepted (rc=$_rc)"
)

(
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _rc=0
  _mdm_root_config_apply "$_conf" $'NO_PROXY=localhost\nBASH_ENV=/tmp/x' >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq "$MDM_EXIT_CONFIG" ]] \
    && pass "mdm-bootstrap: control-character config argv を拒否" \
    || fail "mdm-bootstrap: control-character value was accepted (rc=$_rc)"
)

for _mode in 20 30 020 030; do
  if _mdm_boot_mode_is_safe "$_mode"; then
    fail "mdm-bootstrap: writable mode $_mode を安全扱い"
  else
    pass "mdm-bootstrap: writable mode $_mode を拒否"
  fi
done

_canary="$_tmpd/bash-env-ran"
cat >"$_tmpd/bash-env" <<EOF
printf x > "$_canary"
EOF
_rc=0
BASH_ENV="$_tmpd/bash-env" "$PROJECT_DIR/mdm/install-mdm.sh" \
  UNKNOWN_KEY=value >/dev/null 2>&1 || _rc=$?
if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
  _expected_rc="$MDM_EXIT_CONFIG"
else
  _expected_rc="$MDM_EXIT_OS"
fi
if [[ ! -e "$_canary" && "$_rc" -eq "$_expected_rc" ]]; then
  pass "mdm-bootstrap: direct launcher は BASH_ENV を起動前に無効化"
else
  fail "mdm-bootstrap: BASH_ENV executed or launcher exit changed (rc=$_rc expected=$_expected_rc)"
fi

rm -rf "$_tmpd"
