#!/bin/bash
# tests/unit/test-mdm-purpose.sh - PR 150 purpose-level acceptance coverage.
# MDM_TEST_TIMEOUT_SECONDS=1800

if ! declare -F pass >/dev/null 2>&1 \
  || ! declare -F fail >/dev/null 2>&1 \
  || [[ -z "${PROJECT_DIR:-}" ]]; then
  printf 'test-mdm-purpose.sh must be run through tests/run-mdm-tests.sh\n' >&2
  exit 2
fi

# This suite deliberately crosses the local Git checkout and authoritative
# user-phase boundary.  Network, macOS account lookup, and package installers
# remain fixtures so the same acceptance contract runs on Linux CI.
# shellcheck source=mdm/install-mdm.sh
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

if [[ -z "${MDM_TEST_TMP_ROOT:-}" || ! -d "$MDM_TEST_TMP_ROOT" \
  || -L "$MDM_TEST_TMP_ROOT" ]]; then
  printf 'test-mdm-purpose.sh requires the runner-owned MDM_TEST_TMP_ROOT\n' >&2
  exit 2
fi
_purpose_python_cmd="$(command -v python3)"
_purpose_runner_user="$(/usr/bin/id -un)"
_purpose_runner_uid="$(/usr/bin/id -u)"
_purpose_runner_gid="$(/usr/bin/id -g)"
_purpose_runner_tmp_mode=""
if [[ "$_purpose_runner_uid" -eq 0 ]]; then
  _purpose_runner_tmp_physical="$(builtin cd -P -- "$MDM_TEST_TMP_ROOT" \
    2>/dev/null && printf '%s' "$PWD" || true)"
  _purpose_runner_tmp_uid="$(_mdm_stat_uid \
    "$MDM_TEST_TMP_ROOT" 2>/dev/null || true)"
  _purpose_runner_tmp_mode="$(_mdm_mode_normalize \
    "$(_mdm_stat_mode "$MDM_TEST_TMP_ROOT" 2>/dev/null || true)" \
    2>/dev/null || true)"
  if [[ "$MDM_TEST_TMP_ROOT" != /* \
    || "$_purpose_runner_tmp_physical" != "$MDM_TEST_TMP_ROOT" \
    || "$_purpose_runner_tmp_uid" != 0 ]] \
    || ! _mdm_mode_is_safe "$_purpose_runner_tmp_mode" \
    || _mdm_has_extended_acl "$MDM_TEST_TMP_ROOT"; then
    printf 'test-mdm-purpose.sh requires a canonical root-owned safe tmp root\n' >&2
    exit 2
  fi
fi
_purpose_tmp="$(mktemp -d "$MDM_TEST_TMP_ROOT/mdm-purpose.XXXXXX")"
_purpose_tmp="$(builtin cd -P "$_purpose_tmp" && printf '%s' "$PWD")"
_purpose_repo="$_purpose_tmp/repo"
_purpose_user_repo="$_purpose_repo"
_purpose_home="$_purpose_tmp/home"
_purpose_auth="$_purpose_tmp/authority"
_purpose_tmp_mode_guard_pid=""
_purpose_user="$_purpose_runner_user"
_purpose_uid="$_purpose_runner_uid"
_purpose_gid="$_purpose_runner_gid"
if [[ "$_purpose_runner_uid" -eq 0 ]]; then
  _purpose_user_record="$("$_purpose_python_cmd" -I -B - <<'PY'
import pwd

invalid_shells = {"", "/bin/false", "/usr/bin/false",
                  "/sbin/nologin", "/usr/sbin/nologin"}
users = [entry for entry in pwd.getpwall()
         if 501 <= entry.pw_uid <= 60000
         and entry.pw_shell not in invalid_shells]
if users:
    selected = min(users, key=lambda entry: entry.pw_uid)
    print(f"{selected.pw_name}\t{selected.pw_uid}\t{selected.pw_gid}")
PY
)"
  IFS=$'\t' read -r _purpose_user _purpose_uid _purpose_gid \
    <<< "$_purpose_user_record"
  _purpose_bound_uid="$(/usr/bin/id -u "$_purpose_user" 2>/dev/null || true)"
  _purpose_bound_gid="$(/usr/bin/id -g "$_purpose_user" 2>/dev/null || true)"
  if [[ -z "$_purpose_user" || ! "$_purpose_uid" =~ ^[0-9]+$ \
    || "$_purpose_uid" -lt 501 || "$_purpose_uid" -gt 60000 \
    || ! "$_purpose_gid" =~ ^[0-9]+$ \
    || "$_purpose_bound_uid" != "$_purpose_uid" \
    || "$_purpose_bound_gid" != "$_purpose_gid" ]]; then
    printf 'test-mdm-purpose.sh requires an eligible target persona under root\n' >&2
    exit 2
  fi
fi
_purpose_generated_uid=11111111-2222-3333-4444-555555555555
mkdir -p "$_purpose_repo" "$_purpose_home" "$_purpose_auth"
chmod 700 "$_purpose_home" "$_purpose_auth"
_purpose_restore_runner_tmp_mode() {
  [[ "$_purpose_runner_uid" -eq 0 ]] || return 0
  /bin/chmod "$_purpose_runner_tmp_mode" "$MDM_TEST_TMP_ROOT"
}
_purpose_mode_guard_alive() {
  local _ppid _stat
  _ppid="$(LC_ALL=C /bin/ps -o ppid= \
    -p "$_purpose_tmp_mode_guard_pid" 2>/dev/null \
    | /usr/bin/tr -d '[:space:]')"
  _stat="$(LC_ALL=C /bin/ps -o stat= \
    -p "$_purpose_tmp_mode_guard_pid" 2>/dev/null \
    | /usr/bin/tr -d '[:space:]')"
  [[ "$_ppid" == "$$" && -n "$_stat" && "$_stat" != Z* ]]
}
_purpose_stop_mode_guard() {
  local _rc=0
  if ! /bin/mkdir "$_purpose_guard_stop" 2>/dev/null; then
    _rc=1
  elif ! wait "$_purpose_tmp_mode_guard_pid" 2>/dev/null; then
    _rc=1
  fi
  _purpose_restore_runner_tmp_mode || _rc=1
  [[ "$(_mdm_mode_normalize \
    "$(_mdm_stat_mode "$MDM_TEST_TMP_ROOT" 2>/dev/null || true)" \
    2>/dev/null || true)" == "$_purpose_runner_tmp_mode" ]] || _rc=1
  return "$_rc"
}
if [[ "$_purpose_runner_uid" -eq 0 ]]; then
  _purpose_guard_ready="$_purpose_tmp/.mode-guard-ready"
  _purpose_guard_stop="$_purpose_tmp/.mode-guard-stop"
  /bin/sh -c '
    set -u
    mode="$1" root="$2" expected_parent="$3" ready="$4" stop="$5"
    restore_mode() {
      /bin/chmod "$mode" "$root" 2>/dev/null || true
    }
    trap restore_mode 0
    trap "exit 0" 1 2 15
    /bin/mkdir "$ready" || exit 1
    while [ ! -d "$stop" ]; do
      current_parent="$(LC_ALL=C /bin/ps -o ppid= -p "$$" 2>/dev/null \
        | /usr/bin/tr -d "[:space:]")"
      [ "$current_parent" = "$expected_parent" ] || exit 0
      /bin/sleep 1
    done
  ' purpose-mode-guard "$_purpose_runner_tmp_mode" "$MDM_TEST_TMP_ROOT" \
    "$$" "$_purpose_guard_ready" "$_purpose_guard_stop" &
  _purpose_tmp_mode_guard_pid="$!"
  _purpose_guard_ready_count=0
  while [[ ! -d "$_purpose_guard_ready" \
    && "$_purpose_guard_ready_count" -lt 500 ]]; do
    /bin/sleep 0.01
    _purpose_guard_ready_count=$((_purpose_guard_ready_count + 1))
  done
  if [[ ! -d "$_purpose_guard_ready" ]]; then
    _purpose_stop_mode_guard || true
    printf 'test-mdm-purpose.sh could not arm the tmp mode guard\n' >&2
    exit 2
  fi
  /bin/rmdir "$_purpose_guard_ready"
  chmod go+x "$MDM_TEST_TMP_ROOT"
  if ! _purpose_mode_guard_alive; then
    _purpose_stop_mode_guard || true
    printf 'test-mdm-purpose.sh tmp mode guard exited before handoff\n' >&2
    exit 2
  fi
  if ! /usr/bin/sudo -n -u "#$_purpose_uid" \
    /bin/test -x "$MDM_TEST_TMP_ROOT"; then
    _purpose_stop_mode_guard || true
    printf 'test-mdm-purpose.sh target cannot traverse the runner tmp root\n' >&2
    exit 2
  fi
  chmod 711 "$_purpose_tmp"
  chmod 711 "$_purpose_auth"
  chown "$_purpose_uid:$_purpose_gid" "$_purpose_home"
fi

/usr/bin/git -C "$_purpose_repo" init -q
cat > "$_purpose_repo/setup.sh" <<'SETUP'
#!/bin/bash
set -euo pipefail

version="$(/bin/cat "$(/usr/bin/dirname "$0")/fixture-version")"
state_dir="$HOME/.mdm-purpose-state"
current="$state_dir/current"
next="$state_dir/.next"
desired="${KIT_MDM_GIT_REF}|${PROFILE}|${LANGUAGE}|${ENABLE_STATUSLINE}|${KIT_MDM_INSTALL_CLAUDE_CLI}|${version}"
/bin/mkdir -p "$state_dir"
generation=0
if [[ -f "$current" ]]; then
  IFS= read -r previous < "$current" || true
  if [[ "$previous" == "$desired" ]]; then
    exit 0
  fi
  if [[ -f "$state_dir/generation" ]]; then
    IFS= read -r generation < "$state_dir/generation" || generation=0
  fi
fi
generation=$((generation + 1))
printf '%s\n' "$desired" > "$next"
if [[ -f "$HOME/.mdm-purpose-fail-once" ]]; then
  /bin/rm -f "$HOME/.mdm-purpose-fail-once" "$next"
  exit 86
fi
/bin/mv -f "$next" "$current"
printf '%s\n' "$generation" > "$state_dir/generation"
SETUP
chmod +x "$_purpose_repo/setup.sh"

_purpose_commit() {
  local _version="$1"
  printf '%s\n' "$_version" > "$_purpose_repo/fixture-version"
  /usr/bin/git -C "$_purpose_repo" add setup.sh fixture-version
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_purpose_repo" commit -q -m "fixture $_version"
  /usr/bin/git -C "$_purpose_repo" rev-parse HEAD
}

_purpose_sha_a="$(_purpose_commit A)"
_purpose_sha_b="$(_purpose_commit B)"
_purpose_sha_c="$(_purpose_commit C)"
if [[ "$_purpose_runner_uid" -eq 0 ]]; then
  _purpose_user_repo="$_purpose_tmp/user-repo"
  /bin/cp -R "$_purpose_repo" "$_purpose_user_repo"
  chown -R "$_purpose_uid:$_purpose_gid" "$_purpose_user_repo"
fi

_purpose_python="$("$_purpose_python_cmd" -c \
  'import os, sys; print(os.path.realpath(sys.executable))')"
MDM_SYSTEM_PYTHON_OVERRIDE="$_purpose_python"
export MDM_SYSTEM_PYTHON_OVERRIDE
# The product entry point is macOS-only, while this source-only purpose suite
# also runs in Linux CI. Normalize GNU uname's arm64 spelling through the
# existing test seam without widening the production platform contract.
unset MDM_NODE_ARCH_OVERRIDE
_purpose_node_arch="$(_mdm_node_runtime_arch 2>/dev/null || true)"
if [[ -z "$_purpose_node_arch" ]]; then
  case "$(/usr/bin/uname -m 2>/dev/null || true)" in
    aarch64) _purpose_node_arch=arm64 ;;
  esac
fi

# Keep the production checkout, fixed-SHA, clean-env, and setup argv flow.
# Only OS/root-only facilities are replaced by deterministic local adapters.
_mdm_exec_as_user() {
  local _uid="$1" _user="$2" _home="$3" _item
  shift 3
  mdm_build_drop_argv "$_uid" "$_user" "$_home" "$@" || return 1
  if [[ "$_purpose_runner_uid" -eq 0 ]]; then
    for _item in "${!MDM_DROP_ARGV[@]}"; do
      [[ "${MDM_DROP_ARGV[$_item]}" == "$_purpose_repo" ]] \
        && MDM_DROP_ARGV[$_item]="$_purpose_user_repo"
    done
  fi
  if [[ "$_purpose_runner_uid" -eq 0 ]]; then
    (builtin cd -P "$_home" \
      && /usr/bin/sudo -n -u "#$_uid" -H /bin/sh -c \
        'umask 077; exec "$@"' sh "${MDM_DROP_ARGV[@]}")
  else
    "${MDM_DROP_ARGV[@]}"
  fi
}
_mdm_system_python() { printf '%s' "$_purpose_python"; }
_mdm_capture_prior_inventory() { return 0; }
_mdm_prepare_expected_state() {
  local _input="$_purpose_tmp/fixture-policy"
  printf '%s|%s|%s|%s\n' "$PROFILE" "$LANGUAGE" \
    "$ENABLE_STATUSLINE" "$KIT_MDM_INSTALL_CLAUDE_CLI" > "$_input"
  MDM_RCPT_POLICY_SHA256="$(_mdm_sha256_file "$_input")" || return 1
  [[ "${KIT_MDM_EXPECTED_POLICY_SHA256:-}" == "$MDM_RCPT_POLICY_SHA256" ]] \
    || return "$MDM_EXIT_CONFIG"
  KIT_MDM_POLICY_SHA256="$MDM_RCPT_POLICY_SHA256"
  export KIT_MDM_POLICY_SHA256
}
_mdm_load_expected_required_components() {
  if [[ "$KIT_MDM_INSTALL_CLAUDE_CLI" == true ]]; then
    # Read indirectly by the production component/postcondition helpers.
    # shellcheck disable=SC2034
    MDM_REQUIRED_COMPONENTS=(claude_cli kit)
    export MDM_RCPT_REQUIRED_COMPONENTS='["claude_cli","kit"]'
  else
    # shellcheck disable=SC2034
    MDM_REQUIRED_COMPONENTS=(kit)
    export MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'
  fi
}
_mdm_cli_present_for_home() { return 0; }

_purpose_run() { # <sha> <profile> <language> <statusline> <cli-required>
  local _policy_input="$_purpose_tmp/fixture-policy"
  export MDM_AUTH_TMPDIR_OVERRIDE="$_purpose_auth"
  export MDM_AUTH_OWNER_UID_OVERRIDE="$_purpose_runner_uid"
  export MDM_AUTH_PRIVACY_UID_OVERRIDE=99999
  export MDM_AUTH_READONLY_OWNER_TEST=1
  export MDM_KIT_REPO_URL_OVERRIDE="$_purpose_repo"
  export KIT_MDM_GIT_REF="$1"
  export PROFILE="$2"
  export LANGUAGE="$3"
  export ENABLE_STATUSLINE="$4"
  export KIT_MDM_INSTALL_CLAUDE_CLI="$5"
  export KIT_MDM_DRY_RUN=false
  printf '%s|%s|%s|%s\n' "$PROFILE" "$LANGUAGE" \
    "$ENABLE_STATUSLINE" "$KIT_MDM_INSTALL_CLAUDE_CLI" > "$_policy_input"
  KIT_MDM_EXPECTED_POLICY_SHA256="$(_mdm_sha256_file "$_policy_input")"
  export KIT_MDM_EXPECTED_POLICY_SHA256
  unset KIT_MDM_INSTALL_DIR
  _mdm_run_user_phase 0 "$_purpose_user" "$_purpose_home" "$_purpose_uid"
}

_purpose_state() { /bin/cat "$_purpose_home/.mdm-purpose-state/current"; }
_purpose_generation() { /bin/cat "$_purpose_home/.mdm-purpose-state/generation"; }
_purpose_target_git() {
  if [[ "$_purpose_runner_uid" -eq 0 ]]; then
    /usr/bin/sudo -n -u "#$_purpose_uid" -H /usr/bin/git "$@"
  else
    /usr/bin/git "$@"
  fi
}
_purpose_target_worktree_clean() { # <repo>
  if [[ "$_purpose_runner_uid" -eq 0 ]]; then
    local _MDM_GIT_DROP_UID="$_purpose_uid"
    local _MDM_GIT_DROP_USER="$_purpose_user"
    local _MDM_GIT_DROP_HOME="$_purpose_home"
    _mdm_persistent_worktree_clean "$1"
  else
    _mdm_persistent_worktree_clean "$1"
  fi
}
_purpose_head() {
  _purpose_target_git -C "$_purpose_home/.claude-starter-kit" rev-parse HEAD
}
_purpose_policy_sha() { # <profile> <language> <statusline> <cli-required>
  local _base _output _hash
  _base="$(mktemp -d "$_purpose_tmp/policy.XXXXXX")" || return 1
  _output="$_base/rendered"
  "$_purpose_python" "$PROJECT_DIR/mdm/render-expected.py" \
    --checkout "$PROJECT_DIR" --output "$_output" \
    --profile "$1" --language "$2" --editor none \
    --claude-cli-required "$4" --logical-home /Users/purpose \
    --override "ENABLE_STATUSLINE=$3" >/dev/null 2>&1 || {
      /bin/rm -rf "$_base"
      return 1
    }
  _hash="$("$(command -v jq)" -r '.policy_sha256 // empty' \
    "$_output/manifest.json")"
  /bin/rm -rf "$_base"
  [[ "$_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$_hash"
}
_purpose_write_receipt() { # <profile> <language> <policy-sha>
  export MDM_RCPT_KIT_VERSION=0.73.0
  export MDM_RCPT_GIT_REF="$_purpose_sha_c"
  export MDM_RCPT_RESOLVED_SHA="$_purpose_sha_c"
  export MDM_RCPT_INSTALL_DIR="$_purpose_home/.claude-starter-kit"
  export MDM_RCPT_PROFILE="$1"
  export MDM_RCPT_LANGUAGE="$2"
  export MDM_RCPT_POLICY_SHA256="$3"
  export MDM_RCPT_MANIFEST_PATH="$_purpose_home/.claude/.starter-kit-manifest.json"
  export MDM_RCPT_MANIFEST_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export MDM_RCPT_DEPLOYMENT_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  export MDM_RCPT_COMPONENT_MANIFEST_PATH="$_purpose_receipts/components-${_purpose_generated_uid}.json"
  printf '{"component":"kit"}\n' > "$MDM_RCPT_COMPONENT_MANIFEST_PATH"
  chmod 600 "$MDM_RCPT_COMPONENT_MANIFEST_PATH"
  MDM_RCPT_COMPONENT_MANIFEST_SHA256="$(_mdm_sha256_file \
    "$MDM_RCPT_COMPONENT_MANIFEST_PATH")" || return 1
  export MDM_RCPT_COMPONENT_MANIFEST_SHA256
  export MDM_RCPT_TARGET_USER="$_purpose_user"
  export MDM_RCPT_TARGET_UID="$_purpose_uid"
  export MDM_RCPT_TARGET_GENERATED_UID="$_purpose_generated_uid"
  export MDM_RCPT_PARTIAL='[]'
  export MDM_RCPT_TIMESTAMP=2026-07-18T00:00:00Z
  export MDM_RCPT_LOG_PATH="$_purpose_tmp/install.log"
  MDM_EUID_OVERRIDE="$_purpose_uid" mdm_receipt_write \
    "$_purpose_receipts/receipt-$_purpose_user.json" success 0
}
_purpose_detect() { # <commit> <policy-sha>
  PROJECT_DIR="$PROJECT_DIR" PURPOSE_JQ="$(command -v jq)" \
    PURPOSE_RECEIPTS="$_purpose_receipts" PURPOSE_USER="$_purpose_user" \
    PURPOSE_HOME="$_purpose_home" PURPOSE_UID="$_purpose_uid" \
    PURPOSE_GENERATED_UID="$_purpose_generated_uid" \
    PURPOSE_COMMIT="$1" PURPOSE_POLICY="$2" \
    "$BASH" --noprofile --norc -c '
      MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/detect-mdm.sh"
      mdm_detect() {
        local receipt="$1" user="$2" commit="${3:-}" policy="${4:-}"
        [[ "$($PURPOSE_JQ -r .schema_version "$receipt")" == 3 ]] || return 1
        [[ "$($PURPOSE_JQ -r .result "$receipt")" == success ]] || return 1
        [[ "$($PURPOSE_JQ -r .target_user "$receipt")" == "$user" ]] || return 1
        [[ -z "$commit" \
          || "$($PURPOSE_JQ -r .resolved_sha "$receipt")" == "$commit" ]] \
          || return 1
        [[ -z "$policy" \
          || "$($PURPOSE_JQ -r .policy_sha256 "$receipt")" == "$policy" ]] \
          || return 1
        _MDM_DETECT_VERIFIED_KIT_VERSION=0.73.0
      }
      export MDM_RECEIPT_DIR_OVERRIDE="$PURPOSE_RECEIPTS"
      export MDM_DETECT_CANONICAL_USER_OVERRIDE="$PURPOSE_USER"
      export MDM_DETECT_EXPECTED_UID_OVERRIDE="$PURPOSE_UID"
      export MDM_DETECT_GENERATED_UID_OVERRIDE="$PURPOSE_GENERATED_UID"
      export MDM_DETECT_HOME_OVERRIDE="$PURPOSE_HOME"
      export MDM_EUID_OVERRIDE=0
      mdm_detect_main --user "$PURPOSE_USER" \
        --expected-commit "$PURPOSE_COMMIT" \
        --expected-policy-sha256 "$PURPOSE_POLICY"
    ' >/dev/null 2>&1
}

_purpose_rc=0
_purpose_run "$_purpose_sha_a" standard en true false \
  >/dev/null 2>&1 || _purpose_rc=$?
if [[ "$_purpose_rc" -eq 0 \
  && "$(_purpose_state)" == "$_purpose_sha_a|standard|en|true|false|A" \
  && "$(_purpose_generation)" == 1 \
  && "$(_purpose_head)" == "$_purpose_sha_a" ]]; then
  pass "mdm-purpose: fixed-SHA zero-touch fresh install が期待状態へ収束"
else
  fail "mdm-purpose: fresh install の目的を満たさない (rc=$_purpose_rc)"
fi

_purpose_rc=0
_purpose_run "$_purpose_sha_a" standard en true false \
  >/dev/null 2>&1 || _purpose_rc=$?
if [[ "$_purpose_rc" -eq 0 && "$(_purpose_generation)" == 1 \
  && "$(_purpose_head)" == "$_purpose_sha_a" ]]; then
  pass "mdm-purpose: 同一入力の再実行は idempotent"
else
  fail "mdm-purpose: 同一入力の再実行で state が変化"
fi

_purpose_rc=0
_purpose_run "$_purpose_sha_b" standard en true false \
  >/dev/null 2>&1 || _purpose_rc=$?
if [[ "$_purpose_rc" -eq 0 \
  && "$(_purpose_state)" == "$_purpose_sha_b|standard|en|true|false|B" \
  && "$(_purpose_generation)" == 2 \
  && "$(_purpose_head)" == "$_purpose_sha_b" ]]; then
  pass "mdm-purpose: 新しい fixed SHA への MDM update が収束"
else
  fail "mdm-purpose: fixed-SHA update の目的を満たさない (rc=$_purpose_rc)"
fi

: > "$_purpose_home/.mdm-purpose-fail-once"
_purpose_before_failure="$(_purpose_state)"
_purpose_rc=0
_purpose_run "$_purpose_sha_c" full ja false true \
  >/dev/null 2>&1 || _purpose_rc=$?
if [[ "$_purpose_rc" -ne 0 \
  && "$(_purpose_state)" == "$_purpose_before_failure" \
  && "$(_purpose_generation)" == 2 ]]; then
  pass "mdm-purpose: setup 失敗時は旧 deployed state を保持"
else
  fail "mdm-purpose: setup 失敗が旧 deployed state を破壊"
fi
_mdm_cleanup_auth_entry_list >/dev/null 2>&1 || true
_mdm_cleanup_auth_checkout >/dev/null 2>&1 || true

_purpose_rc=0
_purpose_run "$_purpose_sha_c" full ja false true \
  >/dev/null 2>&1 || _purpose_rc=$?
if [[ "$_purpose_rc" -eq 0 \
  && "$(_purpose_state)" == "$_purpose_sha_c|full|ja|false|true|C" \
  && "$(_purpose_generation)" == 3 \
  && "$(_purpose_head)" == "$_purpose_sha_c" ]]; then
  pass "mdm-purpose: 同一 fixed SHA の再試行で自動復旧"
else
  fail "mdm-purpose: 失敗後の再試行で収束しない (rc=$_purpose_rc)"
fi

# The detector's desired-state identity covers configuration changes even
# when the deployed commit stays fixed.  A mismatch must schedule remediation,
# and the same top-level detector must become compliant after convergence.
_purpose_receipts="$_purpose_tmp/receipts"
mkdir -p "$_purpose_receipts"
_purpose_policy_current="$(_purpose_policy_sha full ja false true)"
_purpose_write_receipt full ja "$_purpose_policy_current"
_purpose_detect_rc=0
_purpose_detect "$_purpose_sha_c" "$_purpose_policy_current" \
  || _purpose_detect_rc=$?
if [[ "$_purpose_detect_rc" -eq 0 ]]; then
  pass "mdm-purpose: fixed SHAとpolicy一致をtop-level detectorがcompliant判定"
else
  fail "mdm-purpose: 一致するMDM policyをcompliant判定できない (rc=$_purpose_detect_rc)"
fi

_purpose_policy_drift_ok=true
for _purpose_policy_changed in \
  "$(_purpose_policy_sha standard ja false true)" \
  "$(_purpose_policy_sha full en false true)" \
  "$(_purpose_policy_sha full ja true true)" \
  "$(_purpose_policy_sha full ja false false)"; do
  _purpose_detect_rc=0
  _purpose_detect "$_purpose_sha_c" "$_purpose_policy_changed" \
    || _purpose_detect_rc=$?
  [[ "$_purpose_detect_rc" -eq 1 ]] || _purpose_policy_drift_ok=false
done
if [[ "$_purpose_policy_drift_ok" == true ]]; then
  pass "mdm-purpose: profile/language/feature/CLI方針変更をnon-compliant判定"
else
  fail "mdm-purpose: 同一SHAのMDM policy driftを検知できない"
fi

_purpose_policy_next="$(_purpose_policy_sha standard en true false)"
_purpose_rc=0
_purpose_run "$_purpose_sha_c" standard en true false \
  >/dev/null 2>&1 || _purpose_rc=$?
_purpose_write_receipt standard en "$_purpose_policy_next"
_purpose_detect_rc=0
_purpose_detect "$_purpose_sha_c" "$_purpose_policy_next" \
  || _purpose_detect_rc=$?
if [[ "$_purpose_rc" -eq 0 && "$_purpose_detect_rc" -eq 0 \
  && "$(_purpose_state)" == "$_purpose_sha_c|standard|en|true|false|C" \
  && "$(_purpose_generation)" == 4 ]]; then
  pass "mdm-purpose: policy drift検知後のremediationでcompliantへ再収束"
else
  fail "mdm-purpose: policy driftをremediationして再収束できない"
fi

# MDM-only controls must not become ambient switches for the normal setup.
# Exercise the real orchestration function in an isolated shell and replace
# only the network installer with a marker write.
_purpose_cli_probe() { # <managed-value|__unset__> <cli-policy> <marker>
  PROJECT_DIR="$PROJECT_DIR" \
    PURPOSE_MANAGED="$1" PURPOSE_CLI_POLICY="$2" PURPOSE_MARKER="$3" \
    "$BASH" --noprofile --norc -c '
      source "$PROJECT_DIR/setup.sh"
      source "$PROJECT_DIR/lib/prerequisites.sh"
      set +u
      info() { :; }
      ok() { :; }
      warn() { :; }
      if [[ "$PURPOSE_MANAGED" == __unset__ ]]; then
        unset KIT_MDM_MANAGED
      else
        export KIT_MDM_MANAGED="$PURPOSE_MANAGED"
      fi
      unset KIT_MDM_PREREQ_MODE KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI
      export KIT_MDM_INSTALL_CLAUDE_CLI="$PURPOSE_CLI_POLICY"
      _need_claude_cli_install() { return 0; }
      _mdm_prepare_native_claude_cli_reinstall() { :; }
      _install_claude_cli() { : > "$PURPOSE_MARKER"; }
      _mdm_native_claude_cli_present() { return 0; }
      _add_to_path_now_and_persist() { :; }
      install_claude_cli_if_needed quiet >/dev/null 2>&1
    '
}

_purpose_nonmdm_unset="$_purpose_tmp/nonmdm-unset"
_purpose_nonmdm_false="$_purpose_tmp/nonmdm-false"
_purpose_mdm_false="$_purpose_tmp/mdm-false"
_purpose_mdm_invalid="$_purpose_tmp/mdm-invalid"
_purpose_cli_probe __unset__ false "$_purpose_nonmdm_unset"
_purpose_cli_probe false false "$_purpose_nonmdm_false"
_purpose_cli_probe true false "$_purpose_mdm_false"
_purpose_cli_probe true garbage "$_purpose_mdm_invalid"
if [[ -f "$_purpose_nonmdm_unset" && -f "$_purpose_nonmdm_false" \
  && ! -e "$_purpose_mdm_false" && -f "$_purpose_mdm_invalid" ]]; then
  pass "mdm-purpose: MDM専用CLI方針は非MDM setupの挙動を変えない"
else
  fail "mdm-purpose: MDM専用CLI方針が非MDM setupへ漏出"
fi

# One purpose-level smoke test keeps the production state contracts connected
# end to end: current tracked product code -> fixed-SHA authoritative checkout
# -> real renderer/setup/postcondition/history/receipt -> real detector.
_purpose_full_repo="$_purpose_tmp/full-repo"
_purpose_full_user_repo="$_purpose_full_repo"
_purpose_full_patch="$_purpose_tmp/full-working-tree.patch"
_purpose_full_home="$_purpose_tmp/full-home"
_purpose_full_auth="$_purpose_tmp/full-authority"
_purpose_full_trust="$_purpose_tmp/full-trust"
_purpose_full_receipts="$_purpose_full_trust/ClaudeCodeStarterKit"
_purpose_full_detect_tmp="$_purpose_tmp/full-detect-tmp"
_purpose_full_renderer="$_purpose_tmp/trusted-render-expected.py"
_purpose_full_reference="$_purpose_tmp/full-policy-reference"
_purpose_standard_reference="$_purpose_tmp/standard-policy-reference"
_purpose_full_tool_bin="$_purpose_tmp/full-tool-bin"
mkdir -p "$_purpose_full_home" "$_purpose_full_auth" \
  "$_purpose_full_receipts" "$_purpose_full_detect_tmp" \
  "$_purpose_full_tool_bin"
chmod 700 "$_purpose_full_home" "$_purpose_full_auth" \
  "$_purpose_full_trust" "$_purpose_full_detect_tmp" \
  "$_purpose_full_tool_bin"
chmod 755 "$_purpose_full_receipts"
if [[ "$_purpose_runner_uid" -eq 0 ]]; then
  chown "$_purpose_uid:$_purpose_gid" "$_purpose_full_home"
  chmod 711 "$_purpose_full_auth"
  chmod 755 "$_purpose_full_tool_bin"
fi

# The real setup path must remain in prerequisite fail mode, but hosted CI
# images are not required to preinstall tmux or gh. Supply only those OS tools
# through the target-user execution adapter so the test remains offline and
# still exercises the production prerequisite, setup, and postcondition flow.
cat > "$_purpose_full_tool_bin/tmux" <<'TMUX'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "-V" ]; then
  printf '%s\n' 'tmux purpose-fixture'
  exit 0
fi
exit 64
TMUX
cat > "$_purpose_full_tool_bin/gh" <<'GH'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  printf '%s\n' 'gh version purpose-fixture'
  exit 0
fi
exit 64
GH
if [[ "$_purpose_runner_uid" -eq 0 ]]; then
  chmod 555 "$_purpose_full_tool_bin/tmux" "$_purpose_full_tool_bin/gh"
else
  chmod 500 "$_purpose_full_tool_bin/tmux" "$_purpose_full_tool_bin/gh"
fi

/usr/bin/git clone --quiet --no-local "$PROJECT_DIR" "$_purpose_full_repo"
/usr/bin/git -C "$PROJECT_DIR" diff --binary HEAD -- . \
  > "$_purpose_full_patch"
if [[ -s "$_purpose_full_patch" ]]; then
  /usr/bin/git -C "$_purpose_full_repo" apply --binary "$_purpose_full_patch"
fi
while IFS= read -r -d '' _purpose_untracked; do
  case "$_purpose_untracked" in
    ''|/*|../*|*/../*|*/..) continue ;;
  esac
  mkdir -p "$_purpose_full_repo/$(/usr/bin/dirname "$_purpose_untracked")"
  /bin/cp "$PROJECT_DIR/$_purpose_untracked" \
    "$_purpose_full_repo/$_purpose_untracked"
done < <(/usr/bin/git -C "$PROJECT_DIR" ls-files --others \
  --exclude-standard -z)
/usr/bin/git -C "$_purpose_full_repo" add -A
GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
  /usr/bin/git -C "$_purpose_full_repo" commit --quiet --allow-empty \
    -m 'fixture purpose state'
_purpose_full_sha="$(/usr/bin/git -C "$_purpose_full_repo" rev-parse HEAD)"
_purpose_sync_full_user_repo() {
  _purpose_full_user_repo="$_purpose_full_repo"
  if [[ "$_purpose_runner_uid" -eq 0 ]]; then
    _purpose_full_user_repo="$_purpose_tmp/full-user-repo-$_purpose_full_sha"
    /bin/cp -R "$_purpose_full_repo" "$_purpose_full_user_repo" || return 1
    chown -R "$_purpose_uid:$_purpose_gid" "$_purpose_full_user_repo"
  fi
}
_purpose_sync_full_user_repo
/bin/cp "$_purpose_full_repo/mdm/render-expected.py" "$_purpose_full_renderer"
chmod 500 "$_purpose_full_renderer"
"$_purpose_python" -I -B "$_purpose_full_renderer" \
  --checkout "$_purpose_full_repo" --output "$_purpose_full_reference" \
  --profile minimal --language en --editor vscode \
  --logical-home "$_purpose_full_home" --claude-cli-required false \
  --override ENABLE_AUTO_UPDATE=false \
  --override ENABLE_WEB_CONTENT_UPDATE=false \
  --override ENABLE_STATUSLINE=false \
  --override ENABLE_CODEX_PLUGIN=false >/dev/null 2>&1
_purpose_full_reference_policy="$("$(command -v jq)" -r \
  '.policy_sha256 // empty' "$_purpose_full_reference/manifest.json")"
_purpose_full_reference_editor="$("$(command -v jq)" -r \
  '.editor_choice // empty' "$_purpose_full_reference/policy.json")"
_purpose_full_expected_policy="$_purpose_full_reference_policy"

"$_purpose_python" -I -B "$_purpose_full_renderer" \
  --checkout "$_purpose_full_repo" --output "$_purpose_standard_reference" \
  --profile standard --language en --editor vscode \
  --logical-home "$_purpose_full_home" \
  --claude-cli-required false >/dev/null 2>&1

# Exercise the real root coordinator and expected-component loader while
# replacing only network, privileged filesystem, and target-user execution
# boundaries. Runtime leaf adapters preserve the production auto/fail/dry-run
# branching, and the setup adapter verifies the one-shot WCE carrier argv.
_purpose_composite_run() { # <name> <manifest-dir> <profile> <mode> <dry-run> <wce>
  local _name="$1" _manifest="$2" _profile="$3" _mode="$4" _dry="$5" _wce="$6"
  local _case_root="$_purpose_tmp/composite-$_name"
  mkdir -p "$_case_root/auth" "$_case_root/home" \
    "$_case_root/state/node/bin" "$_case_root/state/wce"
  PROJECT_DIR="$PROJECT_DIR" PURPOSE_CASE_ROOT="$_case_root" \
    PURPOSE_MANIFEST="$_manifest" PURPOSE_PROFILE="$_profile" \
    PURPOSE_MODE="$_mode" PURPOSE_DRY="$_dry" PURPOSE_WCE="$_wce" \
    PURPOSE_USER="$_purpose_user" PURPOSE_UID="$_purpose_uid" \
    PURPOSE_SHA="$_purpose_full_sha" PURPOSE_PYTHON="$_purpose_python" \
    "$BASH" --noprofile --norc -c '
      set -euo pipefail
      MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
      event_log="$PURPOSE_CASE_ROOT/events"
      state="$PURPOSE_CASE_ROOT/state"
      if [[ "$PURPOSE_MODE" == fail || "$PURPOSE_DRY" == true ]]; then
        printf "node\n" > "$state/node/ready"
        printf "node-active\n" > "$state/node-active"
        printf "wce\n" > "$state/wce/ready"
        printf "wce-active\n" > "$state/wce-active"
      fi
      runtime_snapshot() {
        local leaf
        for leaf in node/ready node-active wce/ready wce-active; do
          if [[ -f "$state/$leaf" ]]; then
            printf "%s:%s\n" "$leaf" "$(_mdm_sha256_file "$state/$leaf")"
          else
            printf "%s:missing\n" "$leaf"
          fi
        done
      }
      before="$(runtime_snapshot)"

      _mdm_prepare_authoritative_checkout() {
        _MDM_AUTH_CHECKOUT="$PURPOSE_CASE_ROOT/auth"
        MDM_RCPT_RESOLVED_SHA="$1"
      }
      _mdm_repo_url() { printf "%s" "$PURPOSE_CASE_ROOT/repo"; }
      _mdm_capture_prior_inventory() { return 0; }
      _mdm_prepare_expected_state() {
        _MDM_EXPECTED_OUTPUT="$PURPOSE_MANIFEST"
        KIT_MDM_POLICY_SHA256="$KIT_MDM_EXPECTED_POLICY_SHA256"
        MDM_RCPT_POLICY_SHA256="$KIT_MDM_POLICY_SHA256"
        export KIT_MDM_POLICY_SHA256
      }
      _mdm_worktree_content_digest() {
        printf "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      }
      _mdm_rebuild_persistent_checkout() { return 0; }
      _mdm_persistent_dir_identity() { printf "1:2:d"; }
      _mdm_persistent_checkout_matches_identity() { return 0; }
      _mdm_persistent_worktree_clean() { return 0; }
      _mdm_detached_head_matches() { return 0; }
      _mdm_artifact_digest() {
        printf "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      }
      _mdm_auth_tree_trusted() { return 0; }
      _mdm_auth_expected_uid() { printf "0"; }
      _mdm_cleanup_auth_entry_list() { return 0; }
      _mdm_cleanup_auth_checkout() { return 0; }

      _mdm_node_runtime_path() { printf "%s" "$state/node"; }
      _mdm_node_runtime_bin() { printf "%s" "$state/node/bin"; }
      _mdm_node_runtime_trusted() {
        [[ "$1" == "$state/node" && -f "$state/node/ready" ]] || return 1
        printf "node-trusted\n" >> "$event_log"
      }
      _mdm_node_runtime_rebuild() {
        printf "node-ensure\n" >> "$event_log"
        printf "node\n" > "$state/node/ready"
      }
      _mdm_node_runtime_bind_activation() {
        printf "node-bind\n" >> "$event_log"
        printf "node-active\n" > "$state/node-active"
      }
      _mdm_node_runtime_activation_valid() {
        [[ -f "$state/node-active" ]] || return 1
        printf "node-activation\n" >> "$event_log"
      }
      _mdm_wce_runtime_source_hashes() {
        printf -v "$1" "%s" dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
        printf -v "$2" "%s" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
      }
      _mdm_wce_runtime_path() { printf "%s" "$state/wce"; }
      _mdm_wce_runtime_trusted() {
        [[ "$1" == "$state/wce" && -f "$state/wce/ready" ]] || return 1
        _MDM_WCE_RUNTIME_DIGEST=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
        printf "wce-trusted\n" >> "$event_log"
      }
      _mdm_wce_runtime_rebuild() {
        printf "wce-ensure\n" >> "$event_log"
        printf "wce\n" > "$state/wce/ready"
      }
      _mdm_wce_runtime_activation_valid() {
        [[ -f "$state/wce-active" ]] || return 1
        printf "wce-activation\n" >> "$event_log"
      }
      _mdm_wce_runtime_validate_dryrun() {
        local user="$1" home="$2" uid="$3" target
        target="$(_mdm_wce_runtime_path)" || return 1
        _MDM_WCE_RUNTIME_DIGEST=""
        _mdm_wce_runtime_trusted "$target" || return 1
        _MDM_WCE_VERIFIED_BUNDLE="$target"
        _MDM_EXPECTED_WCE_COMPONENT_SHA256="$_MDM_WCE_RUNTIME_DIGEST"
        _mdm_wce_runtime_activation_valid "$user" "$home" "$uid" "$target"
      }
      _mdm_exec_as_user() {
        local uid="$1" user="$2" home="$3" item carrier=0 dry_arg=0
        local cli_policy=0 native_cli=0
        shift 3
        mdm_build_drop_argv "$uid" "$user" "$home" "$@" || return 1
        for item in "${MDM_DROP_ARGV[@]}"; do
          [[ "$item" == "KIT_MDM_WCE_RUNTIME_BUNDLE=$state/wce" ]] \
            && carrier=$((carrier + 1))
          [[ "$item" == --dry-run ]] && dry_arg=1
          [[ "$item" == KIT_MDM_INSTALL_CLAUDE_CLI=false ]] \
            && cli_policy=$((cli_policy + 1))
          [[ "$item" == KIT_MDM_REQUIRE_NATIVE_CLAUDE_CLI=true ]] \
            && native_cli=$((native_cli + 1))
        done
        [[ "$cli_policy" -eq 1 && "$native_cli" -eq 0 ]]
        if [[ "$PURPOSE_WCE" == true ]]; then
          [[ "${_MDM_WCE_CARRIER_ACTIVE:-false}" == true && "$carrier" -eq 1 ]]
          printf "setup-carrier\n" >> "$event_log"
          if [[ "$PURPOSE_MODE" == auto && "$PURPOSE_DRY" == false ]]; then
            printf "wce-active\n" > "$state/wce-active"
          else
            [[ -f "$state/wce-active" ]]
          fi
        else
          [[ "${_MDM_WCE_CARRIER_ACTIVE:-false}" == false && "$carrier" -eq 0 ]]
          printf "setup-plain\n" >> "$event_log"
        fi
        if [[ "$PURPOSE_DRY" == true ]]; then
          [[ "$dry_arg" -eq 1 ]]
        else
          [[ "$dry_arg" -eq 0 ]]
        fi
      }

      export _MDM_TEST_MODE=1 MDM_EUID_OVERRIDE=0
      export PROFILE="$PURPOSE_PROFILE" LANGUAGE=en EDITOR_CHOICE=vscode
      export KIT_MDM_GIT_REF="$PURPOSE_SHA"
      export KIT_MDM_EXPECTED_POLICY_SHA256="$(_mdm_json_get \
        "$PURPOSE_MANIFEST/manifest.json" policy_sha256)"
      export KIT_MDM_INSTALL_CLAUDE_CLI=false KIT_MDM_INSTALL_HOMEBREW=false
      export KIT_MDM_PREREQ_MODE="$PURPOSE_MODE" KIT_MDM_DRY_RUN="$PURPOSE_DRY"
      _MDM_TARGET_GENERATED_UID=11111111-2222-3333-4444-555555555555
      _MDM_TARGET_SHELL=/bin/bash
      _mdm_run_root_user_phase "$PURPOSE_USER" \
        "$PURPOSE_CASE_ROOT/home" "$PURPOSE_UID"
      after="$(runtime_snapshot)"

      if [[ "$PURPOSE_PROFILE" == standard ]]; then
        [[ "${MDM_REQUIRED_COMPONENTS[*]}" \
          == "kit node_runtime safety_net web_content_runtime" ]]
        [[ "$MDM_RCPT_REQUIRED_COMPONENTS" \
          == "[\"kit\",\"node_runtime\",\"safety_net\",\"web_content_runtime\"]" ]]
        [[ "$KIT_MDM_REQUIRE_NODE_RUNTIME" == true ]]
      else
        [[ "${MDM_REQUIRED_COMPONENTS[*]}" == kit ]]
        [[ "$MDM_RCPT_REQUIRED_COMPONENTS" == "[\"kit\"]" ]]
        [[ "$KIT_MDM_REQUIRE_NODE_RUNTIME" == false ]]
      fi
      if [[ "$PURPOSE_MODE" == fail || "$PURPOSE_DRY" == true \
        || "$PURPOSE_PROFILE" == minimal ]]; then
        [[ "$after" == "$before" ]]
        ! /usr/bin/grep -Eq "^(node-ensure|node-bind|wce-ensure)$" "$event_log"
      fi
      if [[ "$PURPOSE_PROFILE" == minimal ]]; then
        [[ "$(/bin/cat "$event_log")" == setup-plain ]]
      elif [[ "$PURPOSE_MODE" == auto && "$PURPOSE_DRY" == false ]]; then
        [[ -f "$state/node/ready" && -f "$state/node-active" \
          && -f "$state/wce/ready" && -f "$state/wce-active" ]]
        node_pos="$(/usr/bin/awk "\$0 == \"node-ensure\" { print NR; exit }" "$event_log")"
        wce_pos="$(/usr/bin/awk "\$0 == \"wce-ensure\" { print NR; exit }" "$event_log")"
        setup_pos="$(/usr/bin/awk "\$0 == \"setup-carrier\" { print NR; exit }" "$event_log")"
        post_trust="$(/usr/bin/awk "\$0 == \"wce-trusted\" { n=NR } END { print n+0 }" "$event_log")"
        post_activation="$(/usr/bin/awk "\$0 == \"wce-activation\" { n=NR } END { print n+0 }" "$event_log")"
        [[ "$node_pos" -lt "$wce_pos" && "$wce_pos" -lt "$setup_pos" \
          && "$setup_pos" -lt "$post_trust" \
          && "$post_trust" -lt "$post_activation" ]]
      else
        /usr/bin/grep -qx setup-carrier "$event_log" \
          || /usr/bin/grep -q "^setup-carrier$" "$event_log"
      fi
    '
}

_purpose_composite_case() { # <name> <manifest-dir> <profile> <mode> <dry> <wce>
  local _name="$1" _out="$_purpose_tmp/composite-$1.out" _rc=0
  shift
  _purpose_composite_run "$_name" "$@" > "$_out" 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]]; then
    pass "mdm-purpose: root composite $_name"
  else
    tail -30 "$_out" >&2 || true
    fail "mdm-purpose: root composite $_name が不成立 (rc=$_rc)"
  fi
}

_purpose_composite_case standard-auto "$_purpose_standard_reference" \
  standard auto false true
_purpose_composite_case standard-fail "$_purpose_standard_reference" \
  standard fail false true
_purpose_composite_case standard-dry-run "$_purpose_standard_reference" \
  standard auto true true
_purpose_composite_case minimal-no-wce "$_purpose_full_reference" \
  minimal auto false false

_purpose_full_prior_record="$_purpose_tmp/full-prior-handoff"
_purpose_full_install() {
  local _rc=0 _prior_expected=false _prior_path=""
  if [[ "$_purpose_runner_uid" -eq 0 \
    && -f "$_purpose_full_receipts/managed-history-$_purpose_generated_uid.json" ]]; then
    _prior_expected=true
  fi
  : > "$_purpose_full_prior_record"
  PROJECT_DIR="$PROJECT_DIR" PURPOSE_REPO="$_purpose_full_repo" \
    PURPOSE_USER_REPO="$_purpose_full_user_repo" \
    PURPOSE_HOME="$_purpose_full_home" PURPOSE_AUTH="$_purpose_full_auth" \
    PURPOSE_RECEIPTS="$_purpose_full_receipts" \
    PURPOSE_RENDERER="$_purpose_full_renderer" PURPOSE_SHA="$_purpose_full_sha" \
    PURPOSE_POLICY="$_purpose_full_expected_policy" \
    PURPOSE_USER="$_purpose_user" PURPOSE_UID="$_purpose_uid" \
    PURPOSE_RUNNER_UID="$_purpose_runner_uid" \
    PURPOSE_GENERATED_UID="$_purpose_generated_uid" \
    PURPOSE_PYTHON="$_purpose_python" PURPOSE_TOOL_BIN="$_purpose_full_tool_bin" \
    PURPOSE_PRIOR_RECORD="$_purpose_full_prior_record" \
    PURPOSE_NODE_ARCH="$_purpose_node_arch" \
    PURPOSE_FAIL_AFTER_DEPLOY="${PURPOSE_FAIL_AFTER_DEPLOY:-false}" \
    "$BASH" --noprofile --norc -c '
      set -euo pipefail
      MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
      if [[ "$PURPOSE_RUNNER_UID" -eq 0 ]]; then
        # The user-side inventory parser accepts only the production handoff
        # locations. Keep all other root test temporaries contained, while
        # letting the production cleanup track this one cross-UID handoff.
        _mdm_safe_tmpdir() {
          if [[ "${FUNCNAME[1]:-}" == _mdm_capture_prior_inventory ]]; then
            case "$(/usr/bin/uname -s)" in
              Darwin) printf "%s" /private/tmp ;;
              *) printf "%s" /tmp ;;
            esac
          else
            printf "%s" "$MDM_TEST_TMP_ROOT"
          fi
        }
      fi
      # A non-root CI runner cannot create root-owned authority fixtures. Root
      # execution keeps every production owner check live.
      if [[ "$PURPOSE_RUNNER_UID" -ne 0 ]]; then
        _MDM_PASSTHROUGH_KEYS="$_MDM_PASSTHROUGH_KEYS MDM_PRIOR_INVENTORY_SKIP_OWNER_CHECK"
      fi
      _mdm_exec_as_user() {
        local uid="$1" user="$2" home="$3" item path_count=0
        shift 3
        mdm_build_drop_argv "$uid" "$user" "$home" "$@" || return 1
        for item in "${!MDM_DROP_ARGV[@]}"; do
          case "${MDM_DROP_ARGV[$item]}" in
            PATH=*)
              path_count=$((path_count + 1))
              MDM_DROP_ARGV[$item]="PATH=$PURPOSE_TOOL_BIN:${MDM_DROP_ARGV[$item]#PATH=}"
              ;;
          esac
          if [[ "$PURPOSE_RUNNER_UID" -eq 0 \
            && "${MDM_DROP_ARGV[$item]}" == "$PURPOSE_REPO" ]]; then
            MDM_DROP_ARGV[$item]="$PURPOSE_USER_REPO"
          fi
        done
        [[ "$path_count" -eq 1 ]] || return 1
        if [[ "$PURPOSE_RUNNER_UID" -eq 0 ]]; then
          (builtin cd -P "$home" \
            && /usr/bin/sudo -n -u "#$uid" -H /bin/sh -c \
              "umask 077; exec \"\$@\"" sh "${MDM_DROP_ARGV[@]}")
        else
          (builtin cd -P "$home" && "${MDM_DROP_ARGV[@]}")
        fi
      }
      export MDM_KIT_REPO_URL_OVERRIDE="$PURPOSE_REPO"
      export MDM_AUTH_TMPDIR_OVERRIDE="$PURPOSE_AUTH"
      export MDM_AUTH_OWNER_UID_OVERRIDE="$PURPOSE_RUNNER_UID"
      export MDM_AUTH_PRIVACY_UID_OVERRIDE=99999
      export MDM_AUTH_READONLY_OWNER_TEST=1
      export MDM_SYSTEM_PYTHON_OVERRIDE="$PURPOSE_PYTHON"
      export MDM_NODE_ARCH_OVERRIDE="$PURPOSE_NODE_ARCH"
      export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$PURPOSE_RECEIPTS"
      case "$(/usr/bin/uname -s)" in
        Darwin) export TMPDIR=/private/tmp ;;
        *) export TMPDIR=/tmp ;;
      esac
      export MDM_DSCL_UID_OVERRIDE="$PURPOSE_UID"
      export MDM_DSCL_HOME_OVERRIDE="$PURPOSE_HOME"
      export MDM_SEARCH_UID_OVERRIDE="$PURPOSE_UID"
      export MDM_CANONICAL_USER_OVERRIDE="$PURPOSE_USER"
      export MDM_DSCL_GENERATED_UID_OVERRIDE="$PURPOSE_GENERATED_UID"
      export MDM_SEARCH_GENERATED_UID_OVERRIDE="$PURPOSE_GENERATED_UID"
      if [[ "$PURPOSE_RUNNER_UID" -ne 0 ]]; then
        export MDM_CONFIG_SKIP_OWNER_CHECK=1 MDM_LOG_SKIP_OWNER_CHECK=1
        export MDM_PRIOR_INVENTORY_SKIP_OWNER_CHECK=1
      else
        unset MDM_CONFIG_SKIP_OWNER_CHECK MDM_LOG_SKIP_OWNER_CHECK
        unset MDM_PRIOR_INVENTORY_SKIP_OWNER_CHECK
      fi
      export PROFILE=minimal LANGUAGE=en EDITOR_CHOICE=vscode
      export KIT_MDM_GIT_REF="$PURPOSE_SHA"
      export KIT_MDM_EXPECTED_POLICY_SHA256="$PURPOSE_POLICY"
      export KIT_MDM_INSTALL_CLAUDE_CLI=false KIT_MDM_DRY_RUN=false
      export KIT_MDM_PREREQ_MODE=fail KIT_MDM_INSTALL_HOMEBREW=false
      export ENABLE_AUTO_UPDATE=false ENABLE_WEB_CONTENT_UPDATE=false
      export ENABLE_STATUSLINE=false ENABLE_CODEX_PLUGIN=false
      _MDM_EXPECTED_RENDERER="$PURPOSE_RENDERER"
      _MDM_TARGET_GENERATED_UID="$PURPOSE_GENERATED_UID"
      _MDM_TARGET_SHELL=/bin/zsh
      _mdm_transaction_begin "$PURPOSE_USER" "$PURPOSE_HOME" \
        "$PURPOSE_UID" "$PURPOSE_GENERATED_UID"
      _mdm_run_user_phase 0 "$PURPOSE_USER" "$PURPOSE_HOME" "$PURPOSE_UID"
      if [[ "$PURPOSE_RUNNER_UID" -eq 0 \
        && -n "${_MDM_PRIOR_INVENTORY:-}" ]]; then
        printf "%s\n" "$_MDM_PRIOR_INVENTORY" > "$PURPOSE_PRIOR_RECORD"
      fi
      MDM_RCPT_TARGET_USER="$PURPOSE_USER"
      MDM_RCPT_TARGET_UID="$PURPOSE_UID"
      MDM_RCPT_TARGET_GENERATED_UID="$PURPOSE_GENERATED_UID"
      _mdm_capture_postcondition "$PURPOSE_HOME" "$PURPOSE_UID"
      _mdm_attest_components "$PURPOSE_USER" "$PURPOSE_HOME" \
        "$PURPOSE_UID" "$PURPOSE_GENERATED_UID"
      _mdm_persist_managed_history "$PURPOSE_USER" "$PURPOSE_HOME" \
        "$PURPOSE_UID" "$PURPOSE_GENERATED_UID"
      if [[ "$PURPOSE_FAIL_AFTER_DEPLOY" == true ]]; then
        MDM_EUID_OVERRIDE="$PURPOSE_UID" \
          _mdm_finish "$PURPOSE_USER" "$PURPOSE_HOME" failure 30
      fi
      _mdm_revalidate_success_state "$PURPOSE_USER" "$PURPOSE_HOME" \
        "$PURPOSE_UID" "$PURPOSE_GENERATED_UID"
      MDM_EUID_OVERRIDE="$PURPOSE_UID" \
        _mdm_finish "$PURPOSE_USER" "$PURPOSE_HOME" success 0
    ' || _rc=$?
  if [[ "$_purpose_runner_uid" -eq 0 ]]; then
    IFS= read -r _prior_path < "$_purpose_full_prior_record" || true
    if [[ "$_prior_expected" == true ]]; then
      case "$_prior_path" in
        /private/tmp/claude-kit-mdm-prior.??????|/tmp/claude-kit-mdm-prior.??????) ;;
        *) return 1 ;;
      esac
      [[ ! -e "$_prior_path" && ! -L "$_prior_path" ]] || return 1
    elif [[ -n "$_prior_path" ]]; then
      return 1
    fi
  fi
  return "$_rc"
}

_purpose_full_detect() { # <policy-sha>
  PROJECT_DIR="$PROJECT_DIR" PURPOSE_RECEIPTS="$_purpose_full_receipts" \
    PURPOSE_TRUST="$_purpose_full_trust" PURPOSE_HOME="$_purpose_full_home" \
    PURPOSE_TMP="$_purpose_full_detect_tmp" PURPOSE_USER="$_purpose_user" \
    PURPOSE_UID="$_purpose_uid" PURPOSE_GENERATED_UID="$_purpose_generated_uid" \
    PURPOSE_SHA="$_purpose_full_sha" PURPOSE_POLICY="$1" \
    PURPOSE_PYTHON="$_purpose_python" \
    PURPOSE_RUNNER_USER="$_purpose_runner_user" \
    "$BASH" --noprofile --norc -c '
      MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/detect-mdm.sh"
      export MDM_RECEIPT_DIR_OVERRIDE="$PURPOSE_RECEIPTS"
      export MDM_DETECT_TRUST_BASE_OVERRIDE="$PURPOSE_TRUST"
      export MDM_DETECT_EXPECTED_OWNER_OVERRIDE="$PURPOSE_RUNNER_USER"
      export MDM_DETECT_CANONICAL_USER_OVERRIDE="$PURPOSE_USER"
      export MDM_DETECT_HOME_OVERRIDE="$PURPOSE_HOME"
      export MDM_DETECT_EXPECTED_UID_OVERRIDE="$PURPOSE_UID"
      export MDM_DETECT_GENERATED_UID_OVERRIDE="$PURPOSE_GENERATED_UID"
      export MDM_DETECT_TMP_BASE_OVERRIDE="$PURPOSE_TMP"
      export MDM_DETECT_PYTHON_OVERRIDE="$PURPOSE_PYTHON"
      export MDM_EUID_OVERRIDE=0
      mdm_detect_main --user "$PURPOSE_USER" \
        --expected-commit "$PURPOSE_SHA" \
        --expected-policy-sha256 "$PURPOSE_POLICY"
    '
}

_purpose_full_receipt="$_purpose_full_receipts/receipt-$_purpose_user.json"
_purpose_full_component_contract() { # <policy-sha>
  local _policy="$1" _path _expected_path _declared_hash _actual_hash
  _expected_path="$_purpose_full_receipts/components-$_purpose_generated_uid.json"
  _path="$("$(command -v jq)" -r '.component_manifest_path // empty' \
    "$_purpose_full_receipt" 2>/dev/null || true)"
  _declared_hash="$("$(command -v jq)" -r \
    '.component_manifest_sha256 // empty' "$_purpose_full_receipt" \
    2>/dev/null || true)"
  _actual_hash="$(_mdm_sha256_file "$_path" 2>/dev/null || true)"
  [[ "$_path" == "$_expected_path" && "$_declared_hash" == "$_actual_hash" \
    && "$_actual_hash" =~ ^[0-9a-f]{64}$ ]] || return 10
  "$(command -v jq)" -e --arg user "$_purpose_user" \
    --arg uid "$_purpose_uid" --arg guid "$_purpose_generated_uid" \
    --arg policy "$_policy" --arg componentPath "$_expected_path" '
      .schema_version == 3
      and .target_user == $user
      and (.target_uid | tostring) == $uid
      and .target_generated_uid == $guid
      and .policy_sha256 == $policy
      and .component_manifest_path == $componentPath
      and .required_components == ["kit"]
    ' "$_purpose_full_receipt" >/dev/null || return 11
  "$(command -v jq)" -e --arg user "$_purpose_user" \
    --arg uid "$_purpose_uid" --arg guid "$_purpose_generated_uid" \
    --arg policy "$_policy" \
    --arg kit "$_purpose_full_home/.claude-starter-kit" '
      .schema_version == 1
      and .target_user == $user
      and (.target_uid | tostring) == $uid
      and .target_generated_uid == $guid
      and .policy_sha256 == $policy
      and (.entries | length) == 1
      and .entries[0].component == "kit"
      and .entries[0].path == $kit
      and .entries[0].kind == "tree"
      and (.entries[0].sha256 | test("^[0-9a-f]{64}$"))
    ' "$_path" >/dev/null || return 12
}

_purpose_full_rc=0
_purpose_full_install > "$_purpose_tmp/full-install.out" 2>&1 \
  || _purpose_full_rc=$?
_purpose_full_policy="$("$(command -v jq)" -r '.policy_sha256 // empty' \
  "$_purpose_full_receipt" 2>/dev/null || true)"
_purpose_full_detect_rc=0
_purpose_full_detect "$_purpose_full_policy" \
  > "$_purpose_tmp/full-detect.out" 2>&1 || _purpose_full_detect_rc=$?
_purpose_full_component_rc=0
_purpose_full_component_contract "$_purpose_full_policy" \
  || _purpose_full_component_rc=$?
if [[ "$_purpose_full_rc" -eq 0 && "$_purpose_full_detect_rc" -eq 0 \
  && "$_purpose_full_policy" =~ ^[0-9a-f]{64}$ \
  && "$_purpose_full_policy" == "$_purpose_full_reference_policy" \
  && "$_purpose_full_reference_editor" == vscode \
  && "$_purpose_full_component_rc" -eq 0 ]] \
  && /usr/bin/grep -q 'tmux purpose-fixture' \
    "$_purpose_tmp/full-install.out" \
  && [[ "$(_purpose_target_git -C \
    "$_purpose_full_home/.claude-starter-kit" rev-parse HEAD)" \
    == "$_purpose_full_sha" ]]; then
  pass "mdm-purpose: 実zero-touch配備からreceipt検知までend-to-endで収束"
else
  tail -20 "$_purpose_tmp/full-install.out" >&2 || true
  tail -20 "$_purpose_tmp/full-detect.out" >&2 || true
  fail "mdm-purpose: 実zero-touch配備の目的契約が不成立 (install=$_purpose_full_rc detect=$_purpose_full_detect_rc component=$_purpose_full_component_rc)"
fi

# Prove idempotence through the same production setup path, not through the
# smaller fixture above.  Transaction paths and timestamps are intentionally
# regenerated, so compare the stable state projection and also prove that the
# sole retained backup is the exact pre-run live generation.
_purpose_idem_live="$_purpose_full_home/.claude"
_purpose_idem_checkout="$_purpose_full_home/.claude-starter-kit"
_purpose_idem_manifest="$_purpose_idem_live/.starter-kit-manifest.json"
_purpose_idem_history="$_purpose_full_receipts/managed-history-$_purpose_generated_uid.json"
_purpose_idem_receipt_before="$_purpose_tmp/idempotent-receipt-before.json"
_purpose_idem_receipt_after="$_purpose_tmp/idempotent-receipt-after.json"
_purpose_idem_manifest_before="$_purpose_tmp/idempotent-manifest-before.json"
_purpose_idem_manifest_after="$_purpose_tmp/idempotent-manifest-after.json"
_purpose_idem_history_before="$_purpose_tmp/idempotent-history-before.json"
_purpose_idem_ready=true
"$(command -v jq)" -S \
  'del(.timestamp, .log_path, .manifest_sha256, .component_manifest_sha256)' \
  "$_purpose_full_receipt" > "$_purpose_idem_receipt_before" \
  || _purpose_idem_ready=false
"$(command -v jq)" -S 'del(.timestamp)' "$_purpose_idem_manifest" \
  > "$_purpose_idem_manifest_before" || _purpose_idem_ready=false
/bin/cp -p "$_purpose_idem_history" "$_purpose_idem_history_before" \
  || _purpose_idem_ready=false
_purpose_idem_live_id="$(_mdm_persistent_dir_identity \
  "$_purpose_idem_live" 2>/dev/null || true)"
_purpose_idem_live_digest="$(_mdm_artifact_digest tree \
  "$_purpose_idem_live" "$_purpose_uid" 2>/dev/null || true)"
_purpose_idem_worktree_digest="$(_mdm_worktree_content_digest \
  "$_purpose_idem_checkout" retained 2>/dev/null || true)"
_purpose_idem_deployment="$(_mdm_json_get "$_purpose_full_receipt" \
  deployment_sha256 2>/dev/null || true)"
_purpose_idem_claude_sha="$(_mdm_sha256_file \
  "$_purpose_idem_live/CLAUDE.md" 2>/dev/null || true)"
_purpose_idem_claude_mode="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_idem_live/CLAUDE.md" \
    2>/dev/null || true)" 2>/dev/null || true)"
if [[ ! "$_purpose_idem_live_id" =~ ^[^:]+:[^:]+:.+ \
  || ! "$_purpose_idem_live_digest" =~ ^[0-9a-f]{64}$ \
  || ! "$_purpose_idem_worktree_digest" =~ ^[0-9a-f]{64}$ \
  || ! "$_purpose_idem_deployment" =~ ^[0-9a-f]{64}$ \
  || ! "$_purpose_idem_claude_sha" =~ ^[0-9a-f]{64}$ \
  || ! "$_purpose_idem_claude_mode" =~ ^0[0-7]{3}$ ]]; then
  _purpose_idem_ready=false
fi

_purpose_idem_install_rc=125
if [[ "$_purpose_idem_ready" == true ]]; then
  _purpose_idem_install_rc=0
  _purpose_full_install > "$_purpose_tmp/full-idempotent.out" 2>&1 \
    || _purpose_idem_install_rc=$?
fi
_purpose_idem_policy="$(_mdm_json_get "$_purpose_full_receipt" \
  policy_sha256 2>/dev/null || true)"
_purpose_idem_detect_rc=0
_purpose_full_detect "$_purpose_idem_policy" \
  > "$_purpose_tmp/full-idempotent-detect.out" 2>&1 \
  || _purpose_idem_detect_rc=$?
_purpose_idem_component_rc=0
_purpose_full_component_contract "$_purpose_idem_policy" \
  || _purpose_idem_component_rc=$?
"$(command -v jq)" -S \
  'del(.timestamp, .log_path, .manifest_sha256, .component_manifest_sha256)' \
  "$_purpose_full_receipt" > "$_purpose_idem_receipt_after" \
  || _purpose_idem_ready=false
"$(command -v jq)" -S 'del(.timestamp)' "$_purpose_idem_manifest" \
  > "$_purpose_idem_manifest_after" || _purpose_idem_ready=false

_purpose_idem_backup=""
_purpose_idem_backup_count=0
while IFS= read -r _purpose_idem_candidate; do
  [[ -n "$_purpose_idem_candidate" ]] || continue
  _purpose_idem_backup_count=$((_purpose_idem_backup_count + 1))
  _purpose_idem_backup="$_purpose_idem_candidate"
done < <(/usr/bin/find "$_purpose_full_home" -maxdepth 1 -type d \
  -name '.claude.mdm-backup.*' -print)
_purpose_idem_marker=""
if [[ -f "$_purpose_idem_live/.starter-kit-last-backup" \
  && ! -L "$_purpose_idem_live/.starter-kit-last-backup" ]]; then
  IFS= read -r _purpose_idem_marker \
    < "$_purpose_idem_live/.starter-kit-last-backup" || true
fi
_purpose_idem_backup_id="$(_mdm_persistent_dir_identity \
  "$_purpose_idem_backup" 2>/dev/null || true)"
_purpose_idem_backup_digest="$(_mdm_artifact_digest tree \
  "$_purpose_idem_backup" "$_purpose_uid" 2>/dev/null || true)"
_purpose_idem_head="$(_purpose_target_git -C "$_purpose_idem_checkout" \
  rev-parse HEAD 2>/dev/null || true)"
_purpose_idem_status=dirty
_purpose_target_worktree_clean "$_purpose_idem_checkout" \
  && _purpose_idem_status=clean
_purpose_idem_residue=false
if /usr/bin/find "$_purpose_full_home" -maxdepth 1 \
    \( -name '.claude.mdm-failed.*' \
      -o -name '.claude-starter-kit.mdm-stage.*' \
      -o -name '.claude-starter-kit.mdm-failed.*' \) \
    -print -quit | /usr/bin/grep -q . \
  || /usr/bin/find "$_purpose_full_auth" -maxdepth 1 \
    -name 'claude-kit-mdm-parent-modes.*' -print -quit \
    | /usr/bin/grep -q . \
  || [[ -e "$_purpose_idem_live/.claude-starter-kit-mdm-transaction" \
    || -L "$_purpose_idem_live/.claude-starter-kit-mdm-transaction" ]]; then
  _purpose_idem_residue=true
fi

if [[ "$_purpose_idem_ready" == true \
  && "$_purpose_idem_install_rc" -eq 0 \
  && "$_purpose_idem_detect_rc" -eq 0 \
  && "$_purpose_idem_component_rc" -eq 0 \
  && "$_purpose_idem_policy" == "$_purpose_full_policy" \
  && "$_purpose_idem_head" == "$_purpose_full_sha" \
  && "$_purpose_idem_status" == clean \
  && "$(_mdm_worktree_content_digest "$_purpose_idem_checkout" retained \
    2>/dev/null || true)" == "$_purpose_idem_worktree_digest" \
  && "$(_mdm_json_get "$_purpose_full_receipt" deployment_sha256 \
    2>/dev/null || true)" == "$_purpose_idem_deployment" \
  && "$(_mdm_sha256_file "$_purpose_idem_live/CLAUDE.md" \
    2>/dev/null || true)" == "$_purpose_idem_claude_sha" \
  && "$(_mdm_mode_normalize \
    "$(_mdm_stat_mode "$_purpose_idem_live/CLAUDE.md" \
      2>/dev/null || true)" 2>/dev/null || true)" \
    == "$_purpose_idem_claude_mode" ]] \
  && /usr/bin/cmp -s "$_purpose_idem_receipt_before" \
    "$_purpose_idem_receipt_after" \
  && /usr/bin/cmp -s "$_purpose_idem_manifest_before" \
    "$_purpose_idem_manifest_after" \
  && /usr/bin/cmp -s "$_purpose_idem_history_before" \
    "$_purpose_idem_history" \
  && [[ "$_purpose_idem_backup_count" -eq 1 \
  && "$_purpose_idem_marker" == "$_purpose_idem_backup" \
  && "$_purpose_idem_backup_id" == "$_purpose_idem_live_id" \
  && "$_purpose_idem_backup_digest" == "$_purpose_idem_live_digest" \
  && "$_purpose_idem_residue" == false ]]; then
  pass "mdm-purpose: 実setup同一入力再実行はsemantic driftなく収束し最新1世代backupを保持"
else
  tail -30 "$_purpose_tmp/full-idempotent.out" >&2 || true
  tail -20 "$_purpose_tmp/full-idempotent-detect.out" >&2 || true
  fail "mdm-purpose: 実setup同一入力再実行の冪等契約が不成立 (prepared=$_purpose_idem_ready install=$_purpose_idem_install_rc detect=$_purpose_idem_detect_rc component=$_purpose_idem_component_rc backups=$_purpose_idem_backup_count residue=$_purpose_idem_residue)"
fi

_purpose_full_tampered="$_purpose_full_home/.claude-starter-kit/README.md"
chmod u+w "$_purpose_full_tampered"
printf '\n# purpose-level managed component tamper\n' >> "$_purpose_full_tampered"
_purpose_full_tamper_detect_rc=0
_purpose_full_detect "$_purpose_full_policy" \
  > "$_purpose_tmp/full-detect-tampered.out" 2>&1 \
  || _purpose_full_tamper_detect_rc=$?
_purpose_full_remediate_rc=0
_purpose_full_install > "$_purpose_tmp/full-remediate.out" 2>&1 \
  || _purpose_full_remediate_rc=$?
_purpose_full_remediated_policy="$("$(command -v jq)" -r \
  '.policy_sha256 // empty' "$_purpose_full_receipt" 2>/dev/null || true)"
_purpose_full_recheck_rc=0
_purpose_full_detect "$_purpose_full_remediated_policy" \
  > "$_purpose_tmp/full-detect-remediated.out" 2>&1 \
  || _purpose_full_recheck_rc=$?
_purpose_full_remediated_component_rc=0
_purpose_full_component_contract "$_purpose_full_remediated_policy" \
  || _purpose_full_remediated_component_rc=$?
if [[ "$_purpose_full_tamper_detect_rc" -eq 1 \
  && "$_purpose_full_remediate_rc" -eq 0 \
  && "$_purpose_full_recheck_rc" -eq 0 \
  && "$_purpose_full_remediated_policy" == "$_purpose_full_reference_policy" \
  && "$_purpose_full_remediated_component_rc" -eq 0 ]] \
  && /usr/bin/cmp -s "$_purpose_full_tampered" \
    "$_purpose_full_repo/README.md"; then
  pass "mdm-purpose: component改変を検知し同一SHA remediationで再準拠"
else
  tail -20 "$_purpose_tmp/full-detect-tampered.out" >&2 || true
  tail -20 "$_purpose_tmp/full-remediate.out" >&2 || true
  tail -20 "$_purpose_tmp/full-detect-remediated.out" >&2 || true
  fail "mdm-purpose: component改変後の再収束に失敗 (detect=$_purpose_full_tamper_detect_rc remediate=$_purpose_full_remediate_rc recheck=$_purpose_full_recheck_rc component=$_purpose_full_remediated_component_rc)"
fi

# Managed-file parent metadata is part of the deployed-state contract even
# when every managed byte and file mode is unchanged.  Exercise the same real
# fixed-SHA install/detect chain while retaining user-owned rule content.
_purpose_parent_live="$_purpose_full_home/.claude/rules"
_purpose_parent_snapshot="$_purpose_full_home/.claude/.starter-kit-snapshot/rules"
_purpose_parent_live_file="$_purpose_parent_live/agents.md"
_purpose_parent_snapshot_file="$_purpose_parent_snapshot/agents.md"
_purpose_parent_user_file="$_purpose_parent_live/user-purpose-parent-mode.md"
_purpose_parent_user_dir="$_purpose_parent_live/user-purpose-parent-mode"
_purpose_parent_user_nested="$_purpose_parent_user_dir/notes.md"
printf 'purpose user rule\n' > "$_purpose_parent_user_file"
mkdir "$_purpose_parent_user_dir"
printf 'purpose nested user rule\n' > "$_purpose_parent_user_nested"
chmod 600 "$_purpose_parent_user_file" "$_purpose_parent_user_nested"
chmod 700 "$_purpose_parent_user_dir"
if [[ "$_purpose_runner_uid" -eq 0 ]]; then
  chown "$_purpose_uid:$_purpose_gid" \
    "$_purpose_parent_user_file" "$_purpose_parent_user_dir" \
    "$_purpose_parent_user_nested"
fi

_purpose_parent_live_copy="$_purpose_tmp/parent-live-managed.before"
_purpose_parent_snapshot_copy="$_purpose_tmp/parent-snapshot-managed.before"
_purpose_parent_user_copy="$_purpose_tmp/parent-user.before"
_purpose_parent_user_nested_copy="$_purpose_tmp/parent-user-nested.before"
/bin/cp -p "$_purpose_parent_live_file" "$_purpose_parent_live_copy"
/bin/cp -p "$_purpose_parent_snapshot_file" "$_purpose_parent_snapshot_copy"
/bin/cp -p "$_purpose_parent_user_file" "$_purpose_parent_user_copy"
/bin/cp -p "$_purpose_parent_user_nested" \
  "$_purpose_parent_user_nested_copy"
_purpose_parent_live_mode="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_live")")"
_purpose_parent_snapshot_mode="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_snapshot")")"
_purpose_parent_live_file_mode="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_live_file")")"
_purpose_parent_snapshot_file_mode="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_snapshot_file")")"
_purpose_parent_user_mode="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_user_file")")"
_purpose_parent_user_dir_mode="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_user_dir")")"
_purpose_parent_user_nested_mode="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_user_nested")")"
_purpose_parent_fixture_ok=false
if [[ -d "$_purpose_parent_live" && ! -L "$_purpose_parent_live" \
  && -d "$_purpose_parent_snapshot" && ! -L "$_purpose_parent_snapshot" \
  && "$(_mdm_stat_uid "$_purpose_parent_live")" == "$_purpose_uid" \
  && "$(_mdm_stat_uid "$_purpose_parent_snapshot")" == "$_purpose_uid" \
  && "$(_mdm_stat_uid "$_purpose_parent_user_file")" == "$_purpose_uid" \
  && "$(_mdm_stat_uid "$_purpose_parent_user_dir")" == "$_purpose_uid" \
  && "$(_mdm_stat_uid "$_purpose_parent_user_nested")" == "$_purpose_uid" ]] \
  && ! _mdm_has_extended_acl "$_purpose_parent_live" \
  && ! _mdm_has_extended_acl "$_purpose_parent_snapshot"; then
  _purpose_parent_fixture_ok=true
fi

# The production root-private mutator also covers 000. Purpose tests run as the
# target UID without privilege, so use owner-readable 0500 for the real flow.
chmod 0500 "$_purpose_parent_live"
chmod 0777 "$_purpose_parent_snapshot"
_purpose_parent_drift_detect_rc=0
_purpose_full_detect "$_purpose_full_reference_policy" \
  > "$_purpose_tmp/full-detect-parent-drift.out" 2>&1 \
  || _purpose_parent_drift_detect_rc=$?
_purpose_parent_remediate_rc=0
_purpose_full_install > "$_purpose_tmp/full-remediate-parent-drift.out" 2>&1 \
  || _purpose_parent_remediate_rc=$?
_purpose_parent_recheck_rc=0
_purpose_full_detect "$_purpose_full_reference_policy" \
  > "$_purpose_tmp/full-detect-parent-remediated.out" 2>&1 \
  || _purpose_parent_recheck_rc=$?
_purpose_parent_component_rc=0
_purpose_full_component_contract "$_purpose_full_reference_policy" \
  || _purpose_parent_component_rc=$?
_purpose_parent_live_mode_after="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_live" 2>/dev/null || true)" \
  2>/dev/null || true)"
_purpose_parent_snapshot_mode_after="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_parent_snapshot" 2>/dev/null || true)" \
  2>/dev/null || true)"

# Restore traversal only after observing the remediation postcondition so a
# failed implementation does not strand the remaining transaction fixture.
[[ "$_purpose_parent_live_mode_after" == "$_purpose_parent_live_mode" ]] \
  || chmod "$_purpose_parent_live_mode" "$_purpose_parent_live" 2>/dev/null || true
[[ "$_purpose_parent_snapshot_mode_after" == "$_purpose_parent_snapshot_mode" ]] \
  || chmod "$_purpose_parent_snapshot_mode" "$_purpose_parent_snapshot" \
    2>/dev/null || true

_purpose_parent_preserved=false
if /usr/bin/cmp -s "$_purpose_parent_live_copy" \
    "$_purpose_parent_live_file" \
  && /usr/bin/cmp -s "$_purpose_parent_snapshot_copy" \
    "$_purpose_parent_snapshot_file" \
  && /usr/bin/cmp -s "$_purpose_parent_user_copy" \
    "$_purpose_parent_user_file" \
  && /usr/bin/cmp -s "$_purpose_parent_user_nested_copy" \
    "$_purpose_parent_user_nested" \
  && [[ -d "$_purpose_parent_user_dir" && ! -L "$_purpose_parent_user_dir" \
    && "$(_mdm_stat_uid "$_purpose_parent_user_file")" == "$_purpose_uid" \
    && "$(_mdm_stat_uid "$_purpose_parent_user_dir")" == "$_purpose_uid" \
    && "$(_mdm_stat_uid "$_purpose_parent_user_nested")" == "$_purpose_uid" \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_purpose_parent_live_file")")" \
      == "$_purpose_parent_live_file_mode" \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_purpose_parent_snapshot_file")")" \
      == "$_purpose_parent_snapshot_file_mode" \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_purpose_parent_user_file")")" \
      == "$_purpose_parent_user_mode" \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_purpose_parent_user_dir")")" \
      == "$_purpose_parent_user_dir_mode" \
    && "$(_mdm_mode_normalize \
      "$(_mdm_stat_mode "$_purpose_parent_user_nested")")" \
      == "$_purpose_parent_user_nested_mode" ]]; then
  _purpose_parent_preserved=true
fi
if [[ "$_purpose_parent_fixture_ok" == true \
  && "$_purpose_parent_drift_detect_rc" -eq 1 \
  && "$_purpose_parent_remediate_rc" -eq 0 \
  && "$_purpose_parent_recheck_rc" -eq 0 \
  && "$_purpose_parent_component_rc" -eq 0 \
  && "$_purpose_parent_live_mode_after" == "$_purpose_parent_live_mode" \
  && "$_purpose_parent_snapshot_mode_after" \
    == "$_purpose_parent_snapshot_mode" \
  && "$_purpose_parent_preserved" == true ]]; then
  pass "mdm-purpose: managed parent mode driftを同一SHAで修復しuser state保持"
else
  tail -20 "$_purpose_tmp/full-detect-parent-drift.out" >&2 || true
  tail -30 "$_purpose_tmp/full-remediate-parent-drift.out" >&2 || true
  tail -20 "$_purpose_tmp/full-detect-parent-remediated.out" >&2 || true
  fail "mdm-purpose: managed parent mode remediation契約が不成立 (fixture=$_purpose_parent_fixture_ok detect=$_purpose_parent_drift_detect_rc remediate=$_purpose_parent_remediate_rc recheck=$_purpose_parent_recheck_rc component=$_purpose_parent_component_rc preserved=$_purpose_parent_preserved live-mode=$_purpose_parent_live_mode_after snapshot-mode=$_purpose_parent_snapshot_mode_after)"
  _purpose_full_install > "$_purpose_tmp/full-parent-recovery.out" 2>&1 || true
fi

# A second fixed-SHA generation fails only after setup, component attestation,
# and root history persistence.  The outer transaction must restore generation
# A across user/root artifacts, preserve rejected B candidates, and converge on
# the next retry.
_purpose_txn_claude="$_purpose_full_home/.claude"
_purpose_txn_persistent="$_purpose_full_home/.claude-starter-kit"
_purpose_txn_history="$_purpose_full_receipts/managed-history-$_purpose_generated_uid.json"
_purpose_txn_component="$_purpose_full_receipts/components-$_purpose_generated_uid.json"
_purpose_txn_parent_live="$_purpose_txn_claude/rules"
_purpose_txn_parent_snapshot="$_purpose_txn_claude/.starter-kit-snapshot/rules"
_purpose_txn_old_claude_id="$(_mdm_persistent_dir_identity \
  "$_purpose_txn_claude")"
_purpose_txn_old_claude_digest="$(_mdm_artifact_digest tree \
  "$_purpose_txn_claude" "$_purpose_uid")"
_purpose_txn_old_persistent_id="$(_mdm_persistent_dir_identity \
  "$_purpose_txn_persistent")"
_purpose_txn_old_persistent_digest="$(_mdm_artifact_digest tree \
  "$_purpose_txn_persistent" "$_purpose_uid")"
_purpose_txn_old_head="$(_purpose_target_git -C "$_purpose_txn_persistent" \
  rev-parse HEAD)"
chmod 0500 "$_purpose_txn_parent_live"
chmod 0777 "$_purpose_txn_parent_snapshot"
_purpose_txn_parent_live_original="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_txn_parent_live")")"
_purpose_txn_parent_snapshot_original="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_txn_parent_snapshot")")"
_purpose_txn_history_before="$_purpose_tmp/transaction-history-before"
_purpose_txn_component_before="$_purpose_tmp/transaction-component-before"
/bin/cp -p "$_purpose_txn_history" "$_purpose_txn_history_before"
/bin/cp -p "$_purpose_txn_component" "$_purpose_txn_component_before"
_purpose_txn_marker="$_purpose_txn_claude/.starter-kit-last-backup"
_purpose_txn_marker_state=absent
_purpose_txn_marker_before="$_purpose_tmp/transaction-marker-before"
if [[ -f "$_purpose_txn_marker" && ! -L "$_purpose_txn_marker" ]]; then
  _purpose_txn_marker_state=present
  /bin/cp -p "$_purpose_txn_marker" "$_purpose_txn_marker_before"
fi

printf 'transaction generation B\n' \
  > "$_purpose_full_repo/transaction-generation"
/usr/bin/git -C "$_purpose_full_repo" add transaction-generation
GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
  /usr/bin/git -C "$_purpose_full_repo" commit --quiet \
    -m 'fixture transaction generation B'
_purpose_full_sha="$(/usr/bin/git -C "$_purpose_full_repo" rev-parse HEAD)"
_purpose_sync_full_user_repo
_purpose_txn_reference="$_purpose_tmp/transaction-policy-reference"
"$_purpose_python" -I -B "$_purpose_full_renderer" \
  --checkout "$_purpose_full_repo" --output "$_purpose_txn_reference" \
  --profile minimal --language en --editor vscode \
  --logical-home "$_purpose_full_home" --claude-cli-required false \
  --override ENABLE_AUTO_UPDATE=false \
  --override ENABLE_WEB_CONTENT_UPDATE=false \
  --override ENABLE_STATUSLINE=false \
  --override ENABLE_CODEX_PLUGIN=false >/dev/null 2>&1
_purpose_full_expected_policy="$("$(command -v jq)" -r \
  '.policy_sha256 // empty' "$_purpose_txn_reference/manifest.json")"

_purpose_txn_fail_rc=0
PURPOSE_FAIL_AFTER_DEPLOY=true \
  _purpose_full_install > "$_purpose_tmp/transaction-fail.out" 2>&1 \
  || _purpose_txn_fail_rc=$?
_purpose_txn_failed_claude="$(/usr/bin/find "$_purpose_full_home" -maxdepth 1 \
  -type d -name '.claude.mdm-failed.*' -print -quit)"
_purpose_txn_failed_persistent="$(/usr/bin/find "$_purpose_full_home" -maxdepth 1 \
  -type d -name '.claude-starter-kit.mdm-failed.*' -print -quit)"
_purpose_txn_failure_detect_rc=0
_purpose_full_detect "$_purpose_full_remediated_policy" \
  > "$_purpose_tmp/transaction-failure-detect.out" 2>&1 \
  || _purpose_txn_failure_detect_rc=$?
_purpose_txn_marker_restored=false
if [[ "$_purpose_txn_marker_state" == present ]]; then
  /usr/bin/cmp -s "$_purpose_txn_marker_before" "$_purpose_txn_marker" \
    && _purpose_txn_marker_restored=true
elif [[ ! -e "$_purpose_txn_marker" && ! -L "$_purpose_txn_marker" ]]; then
  _purpose_txn_marker_restored=true
fi
_purpose_txn_history_restored=false
/usr/bin/cmp -s "$_purpose_txn_history_before" "$_purpose_txn_history" \
  && _purpose_txn_history_restored=true
_purpose_txn_component_restored=false
/usr/bin/cmp -s "$_purpose_txn_component_before" "$_purpose_txn_component" \
  && _purpose_txn_component_restored=true
_purpose_txn_persistent_head="$(_purpose_target_git -C \
  "$_purpose_txn_persistent" rev-parse HEAD 2>/dev/null || true)"
_purpose_txn_failed_persistent_head="$(_purpose_target_git -C \
  "$_purpose_txn_failed_persistent" rev-parse HEAD 2>/dev/null || true)"
_purpose_txn_receipt_result="$("$(command -v jq)" -r \
  '.result // empty' "$_purpose_full_receipt" 2>/dev/null || true)"
_purpose_txn_parent_live_after_failure="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_txn_parent_live" 2>/dev/null || true)" \
  2>/dev/null || true)"
_purpose_txn_parent_snapshot_after_failure="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_txn_parent_snapshot" 2>/dev/null || true)" \
  2>/dev/null || true)"
_purpose_txn_parent_journal_after_failure=false
if /usr/bin/find "$_purpose_full_auth" -maxdepth 1 \
  -name 'claude-kit-mdm-parent-modes.*' -print -quit \
  | /usr/bin/grep -q .; then
  _purpose_txn_parent_journal_after_failure=true
fi
chmod 0700 "$_purpose_txn_parent_live" "$_purpose_txn_parent_snapshot"
_purpose_txn_claude_digest_after_failure="$(_mdm_artifact_digest tree \
  "$_purpose_txn_claude" "$_purpose_uid")"
chmod "$_purpose_txn_parent_live_original" "$_purpose_txn_parent_live"
chmod "$_purpose_txn_parent_snapshot_original" \
  "$_purpose_txn_parent_snapshot"
if [[ "$_purpose_txn_fail_rc" -eq "$MDM_EXIT_SETUP" \
  && "$_purpose_txn_failure_detect_rc" -eq 1 \
  && "$(_mdm_persistent_dir_identity "$_purpose_txn_claude")" \
    == "$_purpose_txn_old_claude_id" \
  && "$_purpose_txn_claude_digest_after_failure" \
    == "$_purpose_txn_old_claude_digest" \
  && "$(_mdm_persistent_dir_identity "$_purpose_txn_persistent")" \
    == "$_purpose_txn_old_persistent_id" \
  && "$(_mdm_artifact_digest tree \
    "$_purpose_txn_persistent" "$_purpose_uid")" \
    == "$_purpose_txn_old_persistent_digest" \
  && "$_purpose_txn_persistent_head" == "$_purpose_txn_old_head" \
  && "$_purpose_txn_marker_restored" == true \
  && "$_purpose_txn_history_restored" == true \
  && "$_purpose_txn_component_restored" == true \
  && "$_purpose_txn_parent_live_after_failure" \
    == "$_purpose_txn_parent_live_original" \
  && "$_purpose_txn_parent_snapshot_after_failure" \
    == "$_purpose_txn_parent_snapshot_original" \
  && "$_purpose_txn_parent_journal_after_failure" == false \
  && -d "$_purpose_txn_failed_claude" \
  && -d "$_purpose_txn_failed_persistent" \
  && "$_purpose_txn_failed_persistent_head" == "$_purpose_full_sha" \
  && "$_purpose_txn_receipt_result" == failure ]]; then
  pass "mdm-purpose: generation B 後段失敗は A 全stateを復元し failed candidates保持"
else
  tail -30 "$_purpose_tmp/transaction-fail.out" >&2 || true
  tail -20 "$_purpose_tmp/transaction-failure-detect.out" >&2 || true
  fail "mdm-purpose: generation B outer rollback 契約が不成立 (install=$_purpose_txn_fail_rc detect=$_purpose_txn_failure_detect_rc)"
fi

_purpose_txn_retry_rc=0
_purpose_full_install > "$_purpose_tmp/transaction-retry.out" 2>&1 \
  || _purpose_txn_retry_rc=$?
_purpose_txn_retry_policy="$("$(command -v jq)" -r \
  '.policy_sha256 // empty' "$_purpose_full_receipt" 2>/dev/null || true)"
_purpose_txn_retry_detect_rc=0
_purpose_full_detect "$_purpose_txn_retry_policy" \
  > "$_purpose_tmp/transaction-retry-detect.out" 2>&1 \
  || _purpose_txn_retry_detect_rc=$?
_purpose_txn_retry_component_rc=0
_purpose_full_component_contract "$_purpose_txn_retry_policy" \
  || _purpose_txn_retry_component_rc=$?
_purpose_txn_retry_persistent_head="$(_purpose_target_git -C \
  "$_purpose_txn_persistent" rev-parse HEAD 2>/dev/null || true)"
_purpose_txn_retry_receipt_result="$("$(command -v jq)" -r \
  '.result // empty' "$_purpose_full_receipt" 2>/dev/null || true)"
_purpose_txn_parent_live_after_retry="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_txn_parent_live" 2>/dev/null || true)" \
  2>/dev/null || true)"
_purpose_txn_parent_snapshot_after_retry="$(_mdm_mode_normalize \
  "$(_mdm_stat_mode "$_purpose_txn_parent_snapshot" 2>/dev/null || true)" \
  2>/dev/null || true)"
_purpose_txn_parent_journal_after_retry=false
if /usr/bin/find "$_purpose_full_auth" -maxdepth 1 \
  -name 'claude-kit-mdm-parent-modes.*' -print -quit \
  | /usr/bin/grep -q .; then
  _purpose_txn_parent_journal_after_retry=true
fi
if [[ "$_purpose_txn_retry_rc" -eq 0 \
  && "$_purpose_txn_retry_detect_rc" -eq 0 \
  && "$_purpose_txn_retry_component_rc" -eq 0 \
  && "$_purpose_txn_retry_persistent_head" == "$_purpose_full_sha" \
  && "$_purpose_txn_parent_live_after_retry" == 0700 \
  && "$_purpose_txn_parent_snapshot_after_retry" == 0700 \
  && "$_purpose_txn_parent_journal_after_retry" == false \
  && -d "$_purpose_txn_failed_claude" \
  && -d "$_purpose_txn_failed_persistent" \
  && "$_purpose_txn_retry_receipt_result" == success ]]; then
  pass "mdm-purpose: failed generation B の次回 remediation は準拠へ収束"
else
  tail -30 "$_purpose_tmp/transaction-retry.out" >&2 || true
  tail -20 "$_purpose_tmp/transaction-retry-detect.out" >&2 || true
  fail "mdm-purpose: generation B retry収束に失敗 (install=$_purpose_txn_retry_rc detect=$_purpose_txn_retry_detect_rc component=$_purpose_txn_retry_component_rc)"
fi

_mdm_cleanup_transient_checkouts >/dev/null 2>&1 || true
if [[ "$_purpose_runner_uid" -eq 0 ]]; then
  if ! _purpose_stop_mode_guard; then
    printf 'test-mdm-purpose.sh tmp mode guard did not restore the root\n' >&2
    exit 2
  fi
fi
rm -rf "$_purpose_tmp"

mdm_test_reached_end
