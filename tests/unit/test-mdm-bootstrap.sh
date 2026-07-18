#!/bin/bash
# tests/unit/test-mdm-bootstrap.sh - Single-file clean launcher and root parser.

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

(
  export MDM_EUID_OVERRIDE=0 TMPDIR=/Users/attacker/tmp
  _mdm_is_darwin() { return 0; }
  [[ "$(_mdm_safe_tmpdir)" == "/private/tmp" ]] \
    && pass "mdm-bootstrap: macOS root は user TMPDIR を使わない" \
    || fail "mdm-bootstrap: macOS root temporary directory is unsafe"
)
(
  export MDM_EUID_OVERRIDE=0 TMPDIR=/Users/attacker/tmp
  _mdm_is_darwin() { return 1; }
  [[ "$(_mdm_safe_tmpdir)" == "/tmp" ]] \
    && pass "mdm-bootstrap: Linux root は /private/tmp に依存しない" \
    || fail "mdm-bootstrap: Linux root temporary directory is unsafe"
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

if [[ "$(_mdm_stat_owner "$_conf")" == "$(/usr/bin/id -un)" ]]; then
  pass "mdm-bootstrap: config owner stat adapter は実所有者を返す"
else
  fail "mdm-bootstrap: config owner stat adapter が実所有者と不一致"
fi

for _owner_case in file directory; do
  (
    unset MDM_CONFIG_SKIP_OWNER_CHECK
    _mdm_stat_owner() {
      if [[ "$_owner_case" == file && "$1" == "$_conf" ]] \
        || [[ "$_owner_case" == directory && "$1" == "$_tmpd" ]]; then
        printf 'nobody'
      else
        printf 'root'
      fi
    }
    _owner_rc=0
    _mdm_root_config_apply "$_conf" >/dev/null 2>&1 || _owner_rc=$?
    [[ "$_owner_rc" -eq "$MDM_EXIT_CONFIG" ]] \
      && pass "mdm-bootstrap: non-root owner の管理設定 $_owner_case を拒否" \
      || fail "mdm-bootstrap: non-root owner の管理設定 $_owner_case を許可 (rc=$_owner_rc)"
  )
done

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

if [[ "$(/usr/bin/uname -s)" == Darwin && "$(/usr/bin/id -u)" -ne 0 ]]; then
  printf 'UNKNOWN_ROOT_KEY=true\n' > "$_tmpd/override-config.conf"
  chmod 600 "$_tmpd/override-config.conf"
  _rc=0
  MDM_SOURCE_ONLY=1 MDM_EUID_OVERRIDE=0 MDM_CONFIG_SKIP_OWNER_CHECK=1 \
    MDM_CONFIG_PATH_OVERRIDE="$_tmpd/override-config.conf" \
    MDM_DSCL_UID_OVERRIDE=501 MDM_CLT_PRESENT_OVERRIDE=1 \
    KIT_MDM_DRY_RUN=true "$PROJECT_DIR/mdm/install-mdm.sh" \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq "$MDM_EXIT_CONTEXT" ]]; then
    pass "mdm-bootstrap: production entrypoint は MDM override 群を破棄"
  else
    fail "mdm-bootstrap: production override isolation が不正 (rc=$_rc)"
  fi
else
  skip "mdm-bootstrap: production override isolation" "Darwin non-root contract"
fi

rm -rf "$_tmpd"
