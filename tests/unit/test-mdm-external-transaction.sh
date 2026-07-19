#!/bin/bash
# tests/unit/test-mdm-external-transaction.sh - exact external-state transaction
# MDM_TEST_TIMEOUT_SECONDS=900
# shellcheck disable=SC2034

if ! declare -F pass >/dev/null 2>&1 \
  || ! declare -F fail >/dev/null 2>&1 \
  || [[ -z "${PROJECT_DIR:-}" ]]; then
  printf 'test-mdm-external-transaction.sh must use run-mdm-tests.sh\n' >&2
  exit 2
fi

# shellcheck source=mdm/install-mdm.sh
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

if [[ -z "${MDM_TEST_TMP_ROOT:-}" || ! -d "$MDM_TEST_TMP_ROOT" \
  || -L "$MDM_TEST_TMP_ROOT" ]]; then
  printf 'runner-owned MDM_TEST_TMP_ROOT is required\n' >&2
  exit 2
fi

_ext_python="${MDM_SYSTEM_PYTHON_OVERRIDE:-}"
_ext_user="$(/usr/bin/id -un)"
_ext_uid="$(/usr/bin/id -u)"
[[ "$_ext_python" == /* && -x "$_ext_python" && ! -L "$_ext_python" \
  && "$_ext_uid" =~ ^[0-9]+$ ]] || exit 2

# These tests exercise the real embedded state machines. Only the account
# transition is adapted because the process already runs as the target user.
_mdm_system_python() { printf '%s' "$_ext_python"; }
_mdm_target_system_python() { printf '%s' "$_ext_python"; }
_mdm_exec_as_user() {
  local _uid="$1" _user="$2" _home="$3"
  shift 3
  [[ "$_uid" == "$_ext_uid" && "$_user" == "$_ext_user" ]] || return 1
  /usr/bin/env -i HOME="$_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LC_ALL=C "$@"
}
_mdm_arm_transient_cleanup() { :; }

_ext_fixture_init() { # <label> <component...>
  local _label="$1"
  shift
  _ext_root="$(mktemp -d "$MDM_TEST_TMP_ROOT/external-${_label}.XXXXXX")"
  _ext_root="$(builtin cd -P "$_ext_root" && printf '%s' "$PWD")"
  _ext_home="$_ext_root/home"
  _ext_auth="$_ext_root/authority"
  /bin/mkdir -p "$_ext_home" "$_ext_auth"
  /bin/chmod 700 "$_ext_root" "$_ext_home" "$_ext_auth"
  _MDM_TEST_MODE=1
  MDM_TIMEOUT_OVERRIDE_SECONDS=60
  MDM_AUTH_TMPDIR_OVERRIDE="$_ext_auth"
  MDM_AUTH_OWNER_UID_OVERRIDE="$_ext_uid"
  MDM_EXTERNAL_CARRIER_ANCESTOR_OVERRIDE="$_ext_root"
  unset MDM_EXTERNAL_APPLY_SIGNAL_AFTER_OVERRIDE
  KIT_MDM_PREREQ_MODE=auto
  MDM_REQUIRED_COMPONENTS=("$@")
  _MDM_TRANSACTION_STATE=active
  _MDM_TRANSACTION_USER="$_ext_user"
  _MDM_TRANSACTION_HOME="$_ext_home"
  _MDM_TRANSACTION_UID="$_ext_uid"
  _MDM_EXTERNAL_TRANSACTION_STATE=idle
  _MDM_EXTERNAL_TRANSACTION_JOURNAL=""
  _MDM_EXTERNAL_TRANSACTION_JOURNAL_IDENTITY=""
  _MDM_EXTERNAL_INVENTORY_TMP=""
  _MDM_EXTERNAL_INVENTORY_TMP_IDENTITY=""
  _MDM_EXTERNAL_COMMIT_CARRIER=""
  _MDM_EXTERNAL_COMMIT_CARRIER_IDENTITY=""
  _MDM_EXTERNAL_COMMIT_ANCESTOR=""
  _MDM_EXTERNAL_COMMIT_ANCESTOR_IDENTITY=""
  MDM_EXTERNAL_TRANSACTION_PATHS=()
}

_ext_write_old() {
  /bin/mkdir -p "$_ext_home/.local/bin" \
    "$_ext_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6"
  printf 'old-node\n' > "$_ext_home/.local/bin/node"
  /bin/ln -s /old/cc-safety-net "$_ext_home/.local/bin/cc-safety-net"
  printf 'old-tree\n' > \
    "$_ext_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/payload"
}

_ext_write_new() {
  /bin/mkdir -p "$_ext_home/.local/bin" \
    "$_ext_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6" \
    "$_ext_home/Library/Application Support/com.mitchellh.ghostty"
  printf 'new-node\n' > "$_ext_home/.local/bin/node"
  /bin/ln -s /new/cc-safety-net "$_ext_home/.local/bin/cc-safety-net"
  printf 'new-tree\n' > \
    "$_ext_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/payload"
  printf 'new-config\n' > \
    "$_ext_home/Library/Application Support/com.mitchellh.ghostty/config"
}

_ext_residue_count() {
  /usr/bin/find "$_ext_root" \
    \( -name '*.claude-kit-mdm-old.*' \
      -o -name '.claude-kit-mdm-external-carrier.*' \) \
    -print | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]'
}

(
  _ext_fixture_init inventory node_runtime safety_net ghostty
  _auto="$(_mdm_external_transaction_paths "$_ext_home" "$_ext_uid")"
  KIT_MDM_PREREQ_MODE=fail
  _fail="$(_mdm_external_transaction_paths "$_ext_home" "$_ext_uid")"
  if [[ "$_auto" == $'.local/bin/node\n.local/bin/cc-safety-net\n.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6\nLibrary/Application Support/com.mitchellh.ghostty/config' \
    && "$_fail" == $'.local/bin/node\nLibrary/Application Support/com.mitchellh.ghostty/config' ]]; then
    pass "external transaction: auto/fail inventories contain exact leaves"
  else
    fail "external transaction: exact inventory drifted"
  fi
  /bin/rm -rf "$_ext_root"
)

(
  if [[ "$(/usr/bin/uname -s 2>/dev/null || true)" != Darwin ]]; then
    skip "external transaction: macOS deny-only parent ACL" \
      "Darwin ACL APIs are unavailable"
  else
    _deny_ok=false
    _allow_ok=false
    _ext_fixture_init darwin-deny-acl ghostty
    _ghostty_parent="$_ext_home/Library/Application Support/com.mitchellh.ghostty"
    /bin/mkdir -p "$_ghostty_parent"
    printf 'old-config\n' > "$_ghostty_parent/config"
    /bin/chmod +a 'group:everyone deny delete' "$_ext_home/Library"
    if _mdm_external_transaction_prepare \
        "$_ext_user" "$_ext_home" "$_ext_uid" \
      && printf 'new-config\n' > "$_ghostty_parent/config" \
      && _mdm_external_transaction_ready \
      && _mdm_external_transaction_abort \
      && [[ "$(sed -n '1p' "$_ghostty_parent/config")" == old-config \
        && "$(_ext_residue_count)" == 0 ]]; then
      _deny_ok=true
    fi
    /bin/chmod -RN "$_ext_home/Library" 2>/dev/null || true
    /bin/rm -rf "$_ext_root"

    _ext_fixture_init darwin-allow-acl ghostty
    _ghostty_parent="$_ext_home/Library/Application Support/com.mitchellh.ghostty"
    /bin/mkdir -p "$_ghostty_parent"
    printf 'old-config\n' > "$_ghostty_parent/config"
    /bin/chmod +a 'group:everyone allow write' "$_ext_home/Library"
    if ! _mdm_external_transaction_prepare \
        "$_ext_user" "$_ext_home" "$_ext_uid" \
      && [[ "$(sed -n '1p' "$_ghostty_parent/config")" == old-config \
        && -z "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" \
        && -z "$_MDM_EXTERNAL_COMMIT_CARRIER" \
        && "$(_ext_residue_count)" == 0 ]]; then
      _allow_ok=true
    fi
    /bin/chmod -RN "$_ext_home/Library" 2>/dev/null || true
    /bin/rm -rf "$_ext_root"
    if [[ "$_deny_ok" == true && "$_allow_ok" == true ]]; then
      pass "external transaction: macOS parent ACL permits deny-only and rejects allow"
    else
      fail "external transaction: macOS parent ACL classification is unsafe"
    fi
  fi
)

(
  _ext_fixture_init abort node_runtime safety_net ghostty
  _ext_write_old
  if _mdm_external_transaction_prepare "$_ext_user" "$_ext_home" "$_ext_uid" \
    && _ext_write_new \
    && _mdm_external_transaction_ready \
    && _mdm_external_transaction_abort \
    && [[ "$(sed -n '1p' "$_ext_home/.local/bin/node")" == old-node \
      && "$(/usr/bin/readlink "$_ext_home/.local/bin/cc-safety-net")" \
        == /old/cc-safety-net \
      && "$(sed -n '1p' \
        "$_ext_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/payload")" \
        == old-tree \
      && ! -e "$_ext_home/Library/Application Support/com.mitchellh.ghostty/config" \
      && "$(_ext_residue_count)" == 0 \
      && -z "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" \
      && -z "$_MDM_EXTERNAL_COMMIT_CARRIER" ]]; then
    _failed_count="$(/usr/bin/find "$_ext_home" \
      -name '*.claude-kit-mdm-failed.*' -print \
      | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
    if [[ "$_failed_count" -ge 4 ]]; then
      pass "external transaction: abort restores link/file/tree/absence and preserves failed state"
    else
      fail "external transaction: abort lost quarantined candidate state"
    fi
  else
    fail "external transaction: full abort lifecycle failed"
  fi
  /bin/rm -rf "$_ext_root"
)

(
  _ext_fixture_init commit node_runtime safety_net ghostty
  _ext_write_old
  if _mdm_external_transaction_prepare "$_ext_user" "$_ext_home" "$_ext_uid" \
    && _ext_write_new \
    && _mdm_external_transaction_ready \
    && _mdm_external_transaction_commit \
    && [[ "$(sed -n '1p' "$_ext_home/.local/bin/node")" == new-node \
      && "$(/usr/bin/readlink "$_ext_home/.local/bin/cc-safety-net")" \
        == /new/cc-safety-net \
      && "$(sed -n '1p' \
        "$_ext_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6/payload")" \
        == new-tree \
      && "$(_ext_residue_count)" == 0 \
      && "$_MDM_EXTERNAL_TRANSACTION_STATE" == committed \
      && -z "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" ]]; then
    pass "external transaction: commit retains candidate and removes bound backups"
  else
    fail "external transaction: full commit lifecycle failed"
  fi
  /bin/rm -rf "$_ext_root"
)

(
  _ext_fixture_init claude claude_cli
  /bin/mkdir -p "$_ext_home/.local/bin" \
    "$_ext_home/.local/share/claude/versions/A"
  printf 'old-cli\n' > "$_ext_home/.local/share/claude/versions/A/payload"
  /bin/ln -s "$_ext_home/.local/share/claude/versions/A" \
    "$_ext_home/.local/bin/claude"
  if _mdm_external_transaction_prepare "$_ext_user" "$_ext_home" "$_ext_uid"; then
    /bin/mkdir -p "$_ext_home/.local/share/claude/versions/B"
    printf 'inactive-new-cli\n' > \
      "$_ext_home/.local/share/claude/versions/B/payload"
    /bin/ln -s "$_ext_home/.local/share/claude/versions/B" \
      "$_ext_home/.local/bin/claude"
    if _mdm_external_transaction_ready \
      && _mdm_external_transaction_abort \
      && [[ "$(/usr/bin/readlink "$_ext_home/.local/bin/claude")" \
          == "$_ext_home/.local/share/claude/versions/A" \
        && "$(sed -n '1p' \
          "$_ext_home/.local/share/claude/versions/A/payload")" == old-cli \
        && "$(sed -n '1p' \
          "$_ext_home/.local/share/claude/versions/B/payload")" \
          == inactive-new-cli ]]; then
      pass "external transaction: frozen Claude A target restores while inactive B cache survives"
    else
      fail "external transaction: Claude A-to-B rollback failed"
    fi
  else
    fail "external transaction: Claude frozen inventory prepare failed"
  fi
  /bin/rm -rf "$_ext_root"
)

(
  _ext_fixture_init correlation claude_cli
  /bin/mkdir -p "$_ext_home/.local/bin" \
    "$_ext_home/.local/share/claude/versions/A" \
    "$_ext_home/.local/share/claude/versions/B"
  /bin/ln -s "$_ext_home/.local/share/claude/versions/A" \
    "$_ext_home/.local/bin/claude"
  if _mdm_external_transaction_collect_paths "$_ext_home" "$_ext_uid"; then
    /bin/rm -f "$_ext_home/.local/bin/claude"
    /bin/ln -s "$_ext_home/.local/share/claude/versions/B" \
      "$_ext_home/.local/bin/claude"
    if ! _mdm_external_transaction_invoke plan "$_ext_user" "$_ext_home" \
      "$_ext_uid" "" "${MDM_EXTERNAL_TRANSACTION_PATHS[@]}" \
      > "$_ext_root/drift-plan"; then
      pass "external transaction: collector-to-plan Claude target drift is rejected"
    else
      fail "external transaction: Claude target drift reached mutation planning"
    fi
  else
    fail "external transaction: Claude correlation fixture collection failed"
  fi
  /bin/rm -rf "$_ext_root"
)

(
  _ext_fixture_init producer node_runtime
  _mdm_external_transaction_paths() {
    printf '%s\n' '.local/bin/node'
    return 71
  }
  if ! _mdm_external_transaction_collect_paths "$_ext_home" "$_ext_uid" \
    && [[ "${#MDM_EXTERNAL_TRANSACTION_PATHS[@]}" -eq 0 \
      && -z "$_MDM_EXTERNAL_INVENTORY_TMP" ]]; then
    pass "external transaction: partial producer output with nonzero status is rejected"
  else
    fail "external transaction: producer status was lost"
  fi
  /bin/rm -rf "$_ext_root"
)

(
  _ext_fixture_init hardlink node_runtime
  /bin/mkdir -p "$_ext_home/.local/bin"
  printf 'old-node\n' > "$_ext_home/.local/bin/node"
  /bin/ln "$_ext_home/.local/bin/node" "$_ext_home/.local/bin/node-peer"
  if ! _mdm_external_transaction_prepare "$_ext_user" "$_ext_home" "$_ext_uid" \
    && [[ "$(sed -n '1p' "$_ext_home/.local/bin/node")" == old-node \
      && -z "$_MDM_EXTERNAL_TRANSACTION_JOURNAL" \
      && -z "$_MDM_EXTERNAL_COMMIT_CARRIER" ]]; then
    pass "external transaction: hard-linked managed leaf fails before mutation"
  else
    fail "external transaction: hard-linked leaf was accepted or mutated"
  fi
  /bin/rm -rf "$_ext_root"
)

(
  _ext_fixture_init retry node_runtime safety_net ghostty
  _ext_write_old
  if _mdm_external_transaction_prepare "$_ext_user" "$_ext_home" "$_ext_uid" \
    && _ext_write_new \
    && _mdm_external_transaction_ready; then
    printf 'collision\n' > "$_MDM_EXTERNAL_COMMIT_CARRIER/unexpected"
    _first_rc=0
    _mdm_external_transaction_commit || _first_rc=$?
    /bin/rm -f "$_MDM_EXTERNAL_COMMIT_CARRIER/unexpected"
    if [[ "$_first_rc" -ne 0 \
      && "$_MDM_EXTERNAL_TRANSACTION_STATE" == cleanup ]] \
      && _mdm_external_transaction_commit \
      && [[ "$_MDM_EXTERNAL_TRANSACTION_STATE" == committed \
        && "$(sed -n '1p' "$_ext_home/.local/bin/node")" == new-node \
        && "$(_ext_residue_count)" == 0 ]]; then
      pass "external transaction: carrier collision preserves backups and commit_retry converges"
    else
      fail "external transaction: carrier cleanup retry did not converge"
    fi
  else
    fail "external transaction: retry fixture preparation failed"
  fi
  /bin/rm -rf "$_ext_root"
)

(
  _external_calls=0
  _mdm_external_transaction_commit() {
    _external_calls=$((_external_calls + 1))
    [[ "$_external_calls" -gt 1 ]]
  }
  _mdm_cleanup_persistent_stage() { return 0; }
  _mdm_managed_parent_modes_commit() { return 0; }
  _mdm_transaction_cleanup_root_snapshots() { return 0; }
  _mdm_claude_transaction_marker_path() { printf '%s' /nonexistent; }
  _MDM_TRANSACTION_STATE=active
  _MDM_PERSISTENT_TRANSACTION_STATE=created
  _MDM_CLAUDE_TRANSACTION_STATE=created
  _MDM_CLAUDE_LIVE=""
  _first_rc=0
  _mdm_transaction_commit || _first_rc=$?
  if [[ "$_first_rc" -ne 0 \
    && "$_MDM_TRANSACTION_STATE" == commit_cleanup ]] \
    && _mdm_transaction_commit \
    && [[ "$_MDM_TRANSACTION_STATE" == committed \
      && "$_external_calls" -eq 2 ]]; then
    pass "external transaction: outer commit finalizes only after cleanup retry"
  else
    fail "external transaction: outer commit finalized before cleanup"
  fi
)

(
  _commit_calls=0
  _abort_calls=0
  _mdm_transaction_commit() {
    _commit_calls=$((_commit_calls + 1))
    _MDM_TRANSACTION_STATE=committed
  }
  _mdm_transaction_abort() { _abort_calls=$((_abort_calls + 1)); }
  _mdm_launcher_cleanup_snapshots() { :; }
  _mdm_cleanup_expected_inflight() { :; }
  _mdm_stop_active_timeout_supervisor() { :; }
  _mdm_stop_active_drop_supervisor() { :; }
  _mdm_stop_active_bound_snapshot() { :; }
  _mdm_receipt_discard_prepared() { :; }
  _mdm_external_inventory_discard() { :; }
  _mdm_managed_parent_check_discard() { :; }
  _mdm_cleanup_prereq_artifacts() { :; }
  _mdm_cleanup_auth_entry_list() { :; }
  _mdm_cleanup_dryrun_checkout() { :; }
  _mdm_cleanup_persistent_stage() { :; }
  _mdm_cleanup_auth_checkout() { :; }
  _mdm_cleanup_expected_dir() { :; }
  _mdm_cleanup_prior_inventory() { :; }
  _mdm_cleanup_renderer_snapshot() { :; }
  _mdm_cleanup_system_python_workspace() { :; }
  _mdm_clear_failure_rollback_runtime() { :; }
  _mdm_release_run_lock() { :; }
  _MDM_TRANSACTION_STATE=commit_cleanup
  _mdm_cleanup_transient_checkouts
  if [[ "$_commit_calls" -eq 1 && "$_abort_calls" -eq 0 \
    && "$_MDM_TRANSACTION_STATE" == committed ]]; then
    pass "external transaction: EXIT cleanup retries commit and never rolls back published state"
  else
    fail "external transaction: EXIT cleanup selected rollback after publication"
  fi
)

for _signal_case in HUP INT TERM; do
  _ext_fixture_init "signal-${_signal_case}" node_runtime safety_net
  _ext_write_old
  MDM_EXTERNAL_APPLY_SIGNAL_AFTER_OVERRIDE="${_signal_case}:1"
  _signal_rc=0
  (
    _mdm_arm_transient_cleanup() {
      trap '_mdm_external_transaction_abort >/dev/null 2>&1 || true' EXIT
      trap '_mdm_external_transaction_abort >/dev/null 2>&1 || true; exit 129' HUP
      trap '_mdm_external_transaction_abort >/dev/null 2>&1 || true; exit 130' INT
      trap '_mdm_external_transaction_abort >/dev/null 2>&1 || true; exit 143' TERM
    }
    _mdm_external_transaction_prepare "$_ext_user" "$_ext_home" "$_ext_uid"
  ) || _signal_rc=$?
  case "$_signal_case" in HUP) _expected_rc=129 ;; INT) _expected_rc=130 ;; TERM) _expected_rc=143 ;; esac
  _signal_residue="$(/usr/bin/find "$_ext_root" \
    \( -name '*.claude-kit-mdm-old.*' \
      -o -name '.claude-kit-mdm-external-carrier.*' \
      -o -name 'claude-kit-mdm-external.*' \) -print \
    | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')"
  if [[ "$_signal_rc" -eq "$_expected_rc" \
    && "$(sed -n '1p' "$_ext_home/.local/bin/node")" == old-node \
    && "$_signal_residue" == 0 ]]; then
    pass "external transaction: $_signal_case after rename restores old state and exits $_expected_rc"
  else
    fail "external transaction: $_signal_case rollback contract failed"
  fi
  /bin/rm -rf "$_ext_root"
done

mdm_test_reached_end
