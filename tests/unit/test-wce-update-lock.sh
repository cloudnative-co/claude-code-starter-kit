#!/bin/bash
# tests/unit/test-wce-update-lock.sh - Shared WCE writer-lock regressions

# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/prerequisites.sh
source "$PROJECT_DIR/lib/prerequisites.sh"
# shellcheck source=lib/snapshot.sh
source "$PROJECT_DIR/lib/snapshot.sh"
# shellcheck source=lib/update.sh
source "$PROJECT_DIR/lib/update.sh"
# shellcheck source=lib/deploy.sh
source "$PROJECT_DIR/lib/deploy.sh"

if ! declare -F is_true >/dev/null 2>&1; then
  is_true() {
    case "${1:-}" in true|TRUE|1|yes|YES|on|ON) return 0 ;; esac
    return 1
  }
fi

_wul_tmp="$(mktemp -d)"
_SETUP_TMP_FILES=()

_wul_restore_fn() { # <function> <saved declaration>
  local fn="$1" saved="$2"
  if [[ -n "$saved" ]]; then
    eval "$saved"
  else
    unset -f "$fn"
  fi
}

# Existing special lock leaves must fail immediately without being opened.
_wul_shapes="$_wul_tmp/shapes"
mkdir -p "$_wul_shapes/logs"
mkfifo "$_wul_shapes/logs/.update.lock"
export -f _wce_runtime_update_lock_acquire
_wul_fifo_rc=0
_run_with_timeout 2 bash -c \
  '_wce_runtime_update_lock_acquire "$1" lock_token' \
  _ "$_wul_shapes" >/dev/null 2>&1 || _wul_fifo_rc=$?
if [[ "$_wul_fifo_rc" -ne 0 && -p "$_wul_shapes/logs/.update.lock" ]]; then
  pass "WCE lock: FIFO contention fails closed without blocking"
else
  fail "WCE lock: FIFO leaf was opened, replaced, or accepted"
fi
rm -f "$_wul_shapes/logs/.update.lock"
printf 'regular\n' > "$_wul_shapes/logs/.update.lock"
_wul_regular_rc=0
_wce_runtime_update_lock_acquire "$_wul_shapes" _wul_token \
  || _wul_regular_rc=$?
if [[ "$_wul_regular_rc" -ne 0 ]] \
  && grep -qx regular "$_wul_shapes/logs/.update.lock"; then
  pass "WCE lock: regular-file lock residue is retained"
else
  fail "WCE lock: regular-file lock residue was opened or replaced"
fi
rm -f "$_wul_shapes/logs/.update.lock"
ln -s "$_wul_tmp/foreign" "$_wul_shapes/logs/.update.lock"
_wul_symlink_rc=0
_wce_runtime_update_lock_acquire "$_wul_shapes" _wul_token \
  || _wul_symlink_rc=$?
if [[ "$_wul_symlink_rc" -ne 0 \
  && -L "$_wul_shapes/logs/.update.lock" ]]; then
  pass "WCE lock: symlink lock residue is retained"
else
  fail "WCE lock: symlink lock residue was followed or replaced"
fi
rm -f "$_wul_shapes/logs/.update.lock"

# Ownership is the exact token plus one LF; prefixes and extra bytes fail.
_wul_token=""
_wce_runtime_update_lock_acquire "$_wul_shapes" _wul_token
printf '%s\nextra\n' "$_wul_token" \
  > "$_wul_shapes/logs/.update.lock/owner"
_wul_exact_rc=0
_wce_runtime_update_lock_release "$_wul_shapes" "$_wul_token" \
  || _wul_exact_rc=$?
if [[ "$_wul_exact_rc" -ne 0 ]] \
  && grep -qx extra "$_wul_shapes/logs/.update.lock/owner"; then
  pass "WCE lock: a second owner line is rejected and retained"
else
  fail "WCE lock: a token prefix was accepted as ownership"
fi
printf '%s\n\0' "$_wul_token" \
  > "$_wul_shapes/logs/.update.lock/owner"
_wul_nul_rc=0
_wce_runtime_update_lock_release "$_wul_shapes" "$_wul_token" \
  || _wul_nul_rc=$?
if [[ "$_wul_nul_rc" -ne 0 ]] \
  && [[ "$(LC_ALL=C wc -c < "$_wul_shapes/logs/.update.lock/owner" \
    | tr -d '[:space:]')" -eq "$((${#_wul_token} + 2))" ]]; then
  pass "WCE lock: a trailing NUL is rejected and retained"
else
  fail "WCE lock: non-text owner bytes were accepted"
fi
rm -rf "$_wul_shapes/logs/.update.lock"

# Replace the canonical directory after the first owner check. The release
# must quarantine, detect the foreign inode/token, and restore it unchanged.
_wul_race="$_wul_tmp/foreign-replacement"
mkdir -p "$_wul_race"
_wul_race_token=""
_wce_runtime_update_lock_acquire "$_wul_race" _wul_race_token
_wul_race_lock="$_wul_race/logs/.update.lock"
_wul_race_quarantine="${_wul_race_lock}.release-${_wul_race_token}"
_wul_mv_saved="$(declare -f mv 2>/dev/null || true)"
_wul_mv_injected=false
mv() {
  if [[ "$_wul_mv_injected" != true && "$1" == "$_wul_race_lock" ]]; then
    _wul_mv_injected=true
    command rm -rf "$_wul_race_lock"
    command mkdir "$_wul_race_lock"
    printf 'foreign-owner\n' > "$_wul_race_lock/owner"
  fi
  command mv "$@"
}
_wul_race_rc=0
_wce_runtime_update_lock_release "$_wul_race" "$_wul_race_token" \
  || _wul_race_rc=$?
_wul_restore_fn mv "$_wul_mv_saved"
if [[ "$_wul_race_rc" -ne 0 ]] \
  && grep -qx foreign-owner "$_wul_race_lock/owner" \
  && [[ ! -e "$_wul_race_quarantine" \
    && ! -L "$_wul_race_quarantine" ]]; then
  pass "WCE lock: read-to-rename foreign replacement is restored"
else
  fail "WCE lock: release deleted or stranded a foreign replacement"
fi
rm -rf "$_wul_race_lock" "$_wul_race_quarantine"

# Reentry is bound to both the canonical skill path and the holder BASHPID.
_wul_reentry="$_wul_tmp/reentry"
mkdir -p "$_wul_reentry"
_wul_reentry_result="$_wul_tmp/reentry.result"
_wul_inner_callback() { :; }
_wul_outer_callback() {
  local direct_rc=0 child_rc=0 alias_path="$1/./"
  _wce_with_runtime_update_lock "$alias_path" _wul_inner_callback \
    || direct_rc=$?
  ( _wce_with_runtime_update_lock "$1" _wul_inner_callback ) \
    || child_rc=$?
  printf '%s:%s\n' "$direct_rc" "$child_rc" > "$2"
}
_wul_reentry_rc=0
_wce_with_runtime_update_lock "$_wul_reentry" \
  _wul_outer_callback "$_wul_reentry" "$_wul_reentry_result" \
  || _wul_reentry_rc=$?
if [[ "$_wul_reentry_rc" -eq 0 \
  && "$(< "$_wul_reentry_result")" == 0:75 \
  && ! -e "$_wul_reentry/logs/.update.lock" ]]; then
  pass "WCE lock: reentry requires the canonical path and holder BASHPID"
else
  fail "WCE lock: an inherited bearer token bypassed exclusion"
fi

# Acquisition is also a critical section: TERM immediately after the atomic
# mkdir waits for owner publication, then cleanup releases the owned lock.
_wul_acquire_signal="$_wul_tmp/acquire-signal"
mkdir -p "$_wul_acquire_signal"
_wul_mkdir_saved="$(declare -f mkdir 2>/dev/null || true)"
_wul_acquire_signal_sent=false
mkdir() {
  command mkdir "$@" || return 1
  case "${*: -1}" in
    */logs/.update.lock)
      if [[ "$_wul_acquire_signal_sent" != true ]]; then
        _wul_acquire_signal_sent=true
        kill -TERM "$_WCE_RUNTIME_ACQUIRE_WAITER_PID"
      fi
      ;;
  esac
}
_wul_acquire_signal_rc=0
_wce_with_runtime_update_lock "$_wul_acquire_signal" _wul_inner_callback \
  >/dev/null 2>&1 || _wul_acquire_signal_rc=$?
_wul_restore_fn mkdir "$_wul_mkdir_saved"
if [[ "$_wul_acquire_signal_rc" -eq 143 ]] \
  && [[ ! -e "$_wul_acquire_signal/logs/.update.lock" ]] \
  && ! compgen -G \
    "$_wul_acquire_signal/logs/.update.lock.release-*" >/dev/null; then
  pass "WCE lock: TERM during acquisition publishes then releases ownership"
else
  fail "WCE lock: TERM during acquisition leaked partial lock state"
fi

# A signal delivered from inside the release critical section is recorded,
# release finishes in a signal-ignoring child, and status 143 is preserved.
_wul_signal="$_wul_tmp/release-signal"
mkdir -p "$_wul_signal"
_wul_mv_saved="$(declare -f mv 2>/dev/null || true)"
_wul_signal_sent=false
mv() {
  command mv "$@" || return 1
  if [[ "$_wul_signal_sent" != true ]]; then
    _wul_signal_sent=true
    kill -TERM "$_WCE_RUNTIME_RELEASE_WAITER_PID"
  fi
}
_wul_signal_rc=0
_wce_with_runtime_update_lock "$_wul_signal" _wul_inner_callback \
  >/dev/null 2>&1 || _wul_signal_rc=$?
_wul_restore_fn mv "$_wul_mv_saved"
if [[ "$_wul_signal_rc" -eq 143 ]] \
  && [[ ! -e "$_wul_signal/logs/.update.lock" ]] \
  && ! compgen -G "$_wul_signal/logs/.update.lock.release-*" >/dev/null; then
  pass "WCE lock: TERM waits for release and preserves signal status"
else
  fail "WCE lock: TERM interrupted release or changed its status"
fi

# Production run_update must acquire before any WCE live/snapshot tail work.
_wul_update_project="$_wul_tmp/update/project"
_wul_update_home="$_wul_tmp/update/home/.claude"
_wul_update_snapshot="$_wul_update_home/.starter-kit-snapshot"
mkdir -p "$_wul_update_project/skills/web-content-extraction" \
  "$_wul_update_home/skills/web-content-extraction/logs/.update.lock" \
  "$_wul_update_snapshot/skills/web-content-extraction"
printf 'live-before\n' \
  > "$_wul_update_home/skills/web-content-extraction/SKILL.md"
printf 'snapshot-before\n' \
  > "$_wul_update_snapshot/skills/web-content-extraction/SKILL.md"
printf 'foreign-updater\n' \
  > "$_wul_update_home/skills/web-content-extraction/logs/.update.lock/owner"
_wul_phase_settings_saved="$(declare -f _update_phase_settings)"
_wul_phase_claude_saved="$(declare -f _update_phase_claude_md)"
_wul_tail_saved="$(declare -f _update_tail_with_wce_lock)"
_wul_major_saved="$(declare -f _check_major_upgrade)"
_update_phase_settings() { :; }
_update_phase_claude_md() { :; }
_check_major_upgrade() { :; }
_update_tail_with_wce_lock() {
  printf 'live-after\n' \
    > "$2/skills/web-content-extraction/SKILL.md"
  printf 'snapshot-after\n' \
    > "$3/skills/web-content-extraction/SKILL.md"
}
INSTALL_SKILLS=true KIT_MDM_MANAGED=false DRY_RUN=false
_RESET_MERGE_PREFS=false
# shellcheck disable=SC2034 # consumed indirectly by sourced run_update
STR_UPDATE_TITLE="Update"
_wul_update_rc=0
run_update "$_wul_update_project" "$_wul_update_home" \
  >/dev/null 2>&1 || _wul_update_rc=$?
eval "$_wul_phase_settings_saved"
eval "$_wul_phase_claude_saved"
eval "$_wul_tail_saved"
eval "$_wul_major_saved"
if [[ "$_wul_update_rc" -eq 75 ]] \
  && grep -qx live-before \
    "$_wul_update_home/skills/web-content-extraction/SKILL.md" \
  && grep -qx snapshot-before \
    "$_wul_update_snapshot/skills/web-content-extraction/SKILL.md" \
  && grep -qx foreign-updater \
    "$_wul_update_home/skills/web-content-extraction/logs/.update.lock/owner"; then
  pass "WCE update: lock contention preserves live and snapshot bytes"
else
  fail "WCE update: contention exposed a partial subtree transaction"
fi

# Fresh/full and merge-aware deployment must contend before backup or any live
# or snapshot write. Exercise both branch selectors with the same production
# setup_deploy entrypoint.
_wul_check_fresh_contention() { # <full|merge>
  local mode="$1"
  local case_root="$_wul_tmp/fresh-contention-$mode"
  local case_home="$case_root/home"
  local case_skill="$case_home/.claude/skills/web-content-extraction"
  local case_snapshot="$case_home/.claude/.starter-kit-snapshot/skills/web-content-extraction"
  local case_backup="$case_home/.claude.backup.KEEP"
  local case_rc=0 backup_count
  mkdir -p "$case_skill/logs/.update.lock" "$case_snapshot" "$case_backup"
  printf 'live-before\n' > "$case_skill/SKILL.md"
  printf 'snapshot-before\n' > "$case_snapshot/SKILL.md"
  printf 'backup-before\n' > "$case_backup/marker"
  printf 'foreign-updater\n' > "$case_skill/logs/.update.lock/owner"
  printf '{}\n' > "$case_home/.claude/settings.json"
  if [[ "$mode" == full ]]; then
    printf '{}\n' > "$case_home/.claude/.starter-kit-manifest.json"
  fi
  cp "$case_skill/SKILL.md" "$case_root/live.saved"
  cp "$case_snapshot/SKILL.md" "$case_root/snapshot.saved"
  cp "$case_backup/marker" "$case_root/backup.saved"

  (
    HOME="$case_home"
    # shellcheck source=setup.sh
    source "$PROJECT_DIR/setup.sh"
    UPDATE_MODE=false DRY_RUN=false KIT_MDM_MANAGED=false
    INSTALL_AGENTS=true INSTALL_RULES=true INSTALL_COMMANDS=true
    INSTALL_SKILLS=true WIZARD_NONINTERACTIVE=true
    unset KIT_MDM_OUTER_TRANSACTION KIT_MDM_OUTER_TRANSACTION_BACKUP
    section() { :; }
    warn_existing_claude_reconfigure() { :; }
    setup_deploy
  ) >/dev/null 2>&1 || case_rc=$?
  backup_count="$(find "$case_home" -maxdepth 1 \
    -name '.claude.backup.*' -print | wc -l | tr -d '[:space:]')"
  if [[ "$case_rc" -eq 75 && "$backup_count" == 1 ]] \
    && cmp -s "$case_skill/SKILL.md" "$case_root/live.saved" \
    && cmp -s "$case_snapshot/SKILL.md" "$case_root/snapshot.saved" \
    && cmp -s "$case_backup/marker" "$case_root/backup.saved" \
    && grep -qx foreign-updater "$case_skill/logs/.update.lock/owner"; then
    pass "WCE fresh $mode: contention preserves live, snapshot, and backup bytes"
  else
    fail "WCE fresh $mode: contention reached a deployment mutation"
  fi
}
_wul_check_fresh_contention full
_wul_check_fresh_contention merge

# A successful full re-setup holds one token from backup through skills copy,
# snapshot publication, and npm activation. Its recovery copy must not retain
# the transaction's lock or lock-created logs directory.
_wul_fresh_success="$_wul_tmp/fresh-success"
_wul_fresh_success_home="$_wul_fresh_success/home"
_wul_fresh_success_skill="$_wul_fresh_success_home/.claude/skills/web-content-extraction"
_wul_fresh_trace="$_wul_fresh_success/trace"
_wul_fresh_state="$_wul_fresh_success/state"
mkdir -p "$_wul_fresh_success_skill"
printf 'pre-transaction\n' > "$_wul_fresh_success_skill/SKILL.md"
printf '{}\n' > "$_wul_fresh_success_home/.claude/settings.json"
printf '{}\n' > "$_wul_fresh_success_home/.claude/.starter-kit-manifest.json"
_wul_fresh_success_rc=0
(
  HOME="$_wul_fresh_success_home"
  # shellcheck source=setup.sh
  source "$PROJECT_DIR/setup.sh"
  UPDATE_MODE=false DRY_RUN=false KIT_MDM_MANAGED=false
  INSTALL_AGENTS=true INSTALL_RULES=true INSTALL_COMMANDS=true
  INSTALL_SKILLS=true WIZARD_NONINTERACTIVE=true
  unset KIT_MDM_OUTER_TRANSACTION KIT_MDM_OUTER_TRANSACTION_BACKUP
  _wul_record_locked_phase() {
    _wce_runtime_update_lock_owner_matches \
      "$CLAUDE_DIR/skills/web-content-extraction" \
      "$_WCE_RUNTIME_LOCK_TOKEN" || return 1
    printf '%s\n' "$1" >> "$_wul_fresh_trace"
  }
  section() { :; }
  warn_existing_claude_reconfigure() { :; }
  ensure_dirs() { _wul_record_locked_phase ensure; }
  copy_if_enabled() {
    _wul_record_locked_phase "copy-$(basename "$3")"
  }
  build_claude_md() { _wul_record_locked_phase claude-md; }
  _build_settings_managed_file() { _wul_record_locked_phase settings; }
  deploy_hook_scripts() { _wul_record_locked_phase hooks; }
  reconcile_fresh_wce_package_pair() { _wul_record_locked_phase pair; }
  _mdm_reconcile_absent_managed_files() { _wul_record_locked_phase retired; }
  write_managed_snapshot() { _wul_record_locked_phase snapshot; }
  refresh_fresh_wce_snapshot_pair() { _wul_record_locked_phase baseline; }
  maybe_install_web_content_deps() { _wul_record_locked_phase npm; }
  ok() { :; }
  setup_deploy
  printf '%s\0%s\0' "$_BACKUP_PATH" "$_BACKUP_TIMESTAMP" \
    > "$_wul_fresh_state"
) >/dev/null 2>&1 || _wul_fresh_success_rc=$?
_wul_fresh_backup=""
IFS= read -r -d '' _wul_fresh_backup < "$_wul_fresh_state" || true
if [[ "$_wul_fresh_success_rc" -eq 0 && -d "$_wul_fresh_backup" ]] \
  && grep -qx copy-skills "$_wul_fresh_trace" \
  && grep -qx snapshot "$_wul_fresh_trace" \
  && grep -qx baseline "$_wul_fresh_trace" \
  && grep -qx npm "$_wul_fresh_trace" \
  && grep -qx pre-transaction \
    "$_wul_fresh_backup/skills/web-content-extraction/SKILL.md" \
  && [[ ! -e "$_wul_fresh_backup/skills/web-content-extraction/logs" ]] \
  && [[ ! -e "$_wul_fresh_success_skill/logs/.update.lock" ]]; then
  pass "WCE fresh: one lock covers backup, copy, snapshot, and npm without backup residue"
else
  fail "WCE fresh: lock boundary or backup scrubbing is incomplete"
fi

# A normal minimal fresh install has neither a live nor snapshotted WCE tree.
# With skills disabled it must stay a no-op for WCE and complete successfully.
_wul_no_skills="$_wul_tmp/fresh-no-skills"
_wul_no_skills_rc=0
(
  HOME="$_wul_no_skills/home"
  # shellcheck source=setup.sh
  source "$PROJECT_DIR/setup.sh"
  UPDATE_MODE=false DRY_RUN=false KIT_MDM_MANAGED=false
  INSTALL_AGENTS=false INSTALL_RULES=false INSTALL_COMMANDS=false
  INSTALL_SKILLS=false WIZARD_NONINTERACTIVE=true
  unset KIT_MDM_OUTER_TRANSACTION KIT_MDM_OUTER_TRANSACTION_BACKUP
  section() { :; }
  warn_existing_claude_reconfigure() { :; }
  ensure_dirs() { :; }
  copy_if_enabled() { :; }
  build_claude_md() { :; }
  _build_settings_managed_file() { :; }
  deploy_hook_scripts() { :; }
  _mdm_reconcile_absent_managed_files() { :; }
  write_managed_snapshot() { :; }
  ok() { :; }
  setup_deploy
) >/dev/null 2>&1 || _wul_no_skills_rc=$?
if [[ "$_wul_no_skills_rc" -eq 0 \
  && ! -e "$_wul_no_skills/home/.claude/skills/web-content-extraction" ]]; then
  pass "WCE fresh disabled: an absent skill remains a successful no-op"
else
  fail "WCE fresh disabled: absent WCE caused deployment failure or creation"
fi

# Acquiring the lock creates a WCE/logs scaffold. When skills was originally
# empty, that scaffold must not trigger an interactive existing-directory path.
_wul_scaffold="$_wul_tmp/fresh-lock-scaffold"
_wul_scaffold_home="$_wul_scaffold/home"
mkdir -p "$_wul_scaffold_home/.claude"
printf '{}\n' > "$_wul_scaffold_home/.claude/settings.json"
printf 's\n' > "$_wul_scaffold/reply"
_wul_scaffold_rc=0
(
  HOME="$_wul_scaffold_home"
  # shellcheck source=setup.sh
  source "$PROJECT_DIR/setup.sh"
  UPDATE_MODE=false DRY_RUN=false KIT_MDM_MANAGED=false
  INSTALL_AGENTS=false INSTALL_RULES=false INSTALL_COMMANDS=false
  INSTALL_SKILLS=true WIZARD_NONINTERACTIVE=true
  _MERGE_INTERACTIVE=true _TTY_INPUT="$_wul_scaffold/reply"
  unset KIT_MDM_OUTER_TRANSACTION KIT_MDM_OUTER_TRANSACTION_BACKUP
  section() { :; }
  warn_existing_claude_reconfigure() { :; }
  backup_existing() { :; }
  ensure_dirs() { :; }
  _offer_dryrun_preview() { :; }
  _copy_distribution_tree() { printf '%s\n' "$3" > "$_wul_scaffold/mode"; }
  _build_claude_md_safe() { :; }
  _build_settings_safe() { :; }
  deploy_hook_scripts() { :; }
  reconcile_fresh_wce_package_pair() { :; }
  _mdm_reconcile_absent_managed_files() { :; }
  write_managed_snapshot() { :; }
  refresh_fresh_wce_snapshot_pair() { :; }
  maybe_install_web_content_deps() { :; }
  info() { :; }
  warn() { :; }
  ok() { :; }
  STR_DRYRUN_OFFER_EXISTING=dry-run
  STR_EXISTING_CLAUDE_MERGE_NOTE=merge
  STR_FRESH_DIR_EXISTS=exists
  STR_FRESH_DIR_PROMPT=prompt
  STR_FRESH_SKIPPED=skipped
  STR_FRESH_NEW_ONLY=new
  setup_deploy
  [[ "${#_FRESH_SKIPPED_FILES[@]}" -eq 0 ]]
) >/dev/null 2>&1 || _wul_scaffold_rc=$?
if [[ "$_wul_scaffold_rc" -eq 0 \
  && "$(< "$_wul_scaffold/mode")" == overwrite \
  && ! -e "$_wul_scaffold_home/.claude/skills/web-content-extraction/logs/.update.lock" ]]; then
  pass "WCE fresh merge: lock-only scaffold does not trigger an existing-skills prompt"
else
  fail "WCE fresh merge: lock scaffold changed the directory merge decision"
fi

# Choosing [S]kip for an existing skills tree means no WCE side effect,
# including npm ci. The skipped-path state must survive the lock subshell.
_wul_skip="$_wul_tmp/fresh-skip"
_wul_skip_home="$_wul_skip/home"
_wul_skip_skill="$_wul_skip_home/.claude/skills/web-content-extraction"
mkdir -p "$_wul_skip_skill"
printf '{}\n' > "$_wul_skip_home/.claude/settings.json"
cp "$PROJECT_DIR/skills/web-content-extraction/package.json" \
  "$_wul_skip_skill/package.json"
printf 's\n' > "$_wul_skip/reply"
_wul_skip_rc=0
(
  HOME="$_wul_skip_home"
  # shellcheck source=setup.sh
  source "$PROJECT_DIR/setup.sh"
  UPDATE_MODE=false DRY_RUN=false KIT_MDM_MANAGED=false
  INSTALL_AGENTS=false INSTALL_RULES=false INSTALL_COMMANDS=false
  INSTALL_SKILLS=true WIZARD_NONINTERACTIVE=true
  _MERGE_INTERACTIVE=true _TTY_INPUT="$_wul_skip/reply"
  unset KIT_MDM_OUTER_TRANSACTION KIT_MDM_OUTER_TRANSACTION_BACKUP
  unset WCE_SKIP_NPM_INSTALL
  section() { :; }
  warn_existing_claude_reconfigure() { :; }
  backup_existing() { :; }
  ensure_dirs() { :; }
  _offer_dryrun_preview() { :; }
  _build_claude_md_safe() { :; }
  _build_settings_safe() { :; }
  deploy_hook_scripts() { :; }
  _mdm_reconcile_absent_managed_files() { :; }
  write_managed_snapshot() { :; }
  node() { :; }
  npm() { : > "$_wul_skip/npm-called"; }
  info() { :; }
  warn() { :; }
  ok() { :; }
  STR_DRYRUN_OFFER_EXISTING=dry-run
  STR_EXISTING_CLAUDE_MERGE_NOTE=merge
  STR_FRESH_DIR_EXISTS=exists
  STR_FRESH_DIR_PROMPT=prompt
  STR_FRESH_SKIPPED=skipped
  STR_FRESH_NEW_ONLY=new
  setup_deploy
  [[ "${#_FRESH_SKIPPED_FILES[@]}" -eq 1 \
    && "${_FRESH_SKIPPED_FILES[0]}" == "$CLAUDE_DIR/skills" ]]
) >/dev/null 2>&1 || _wul_skip_rc=$?
if [[ "$_wul_skip_rc" -eq 0 && ! -e "$_wul_skip/npm-called" \
  && ! -e "$_wul_skip_skill/logs/.update.lock" ]]; then
  pass "WCE fresh skip: preserving skills also suppresses npm activation"
else
  fail "WCE fresh skip: npm or lock state ignored the preserved skills choice"
fi

# Generic fresh copy must omit both package leaves; the pair helper then repairs
# a one-sided install with one rollback-protected transaction.
_wul_fresh_partial="$_wul_tmp/fresh-partial"
_wul_fresh_partial_home="$_wul_fresh_partial/home/.claude"
_wul_fresh_partial_skill="$_wul_fresh_partial_home/skills/web-content-extraction"
mkdir -p "$_wul_fresh_partial_skill"
printf '{"dependencies":{"defuddle":"partial"}}\n' \
  > "$_wul_fresh_partial_skill/package.json"
_copy_distribution_tree "$PROJECT_DIR/skills" \
  "$_wul_fresh_partial_home/skills" overwrite true
_wul_partial_copy_ok=false
if grep -q 'partial' "$_wul_fresh_partial_skill/package.json" \
  && [[ ! -e "$_wul_fresh_partial_skill/package-lock.json" ]]; then
  _wul_partial_copy_ok=true
fi
(
  CLAUDE_DIR="$_wul_fresh_partial_home"
  INSTALL_SKILLS=true KIT_MDM_MANAGED=false DRY_RUN=false
  _FRESH_SKIPPED_FILES=()
  reconcile_fresh_wce_package_pair
) >/dev/null 2>&1 || _wul_fresh_partial_rc=$?
if [[ "${_wul_fresh_partial_rc:-0}" -eq 0 \
  && "$_wul_partial_copy_ok" == true ]] \
  && cmp -s "$_wul_fresh_partial_skill/package.json" \
    "$PROJECT_DIR/skills/web-content-extraction/package.json" \
  && cmp -s "$_wul_fresh_partial_skill/package-lock.json" \
    "$PROJECT_DIR/skills/web-content-extraction/package-lock.json" \
  && _wce_package_pair_is_valid \
    "$_wul_fresh_partial_skill/package.json" \
    "$_wul_fresh_partial_skill/package-lock.json"; then
  pass "WCE fresh pair: one-sided state is repaired atomically from kit"
else
  fail "WCE fresh pair: generic copy or pair transaction left a split contract"
fi

# A coherent runtime pair survives fresh re-setup, while its new baseline is
# exactly the kit pair. A subsequent update must therefore retain runtime state.
_wul_fresh_runtime="$_wul_tmp/fresh-runtime-baseline"
_wul_fresh_runtime_project="$_wul_fresh_runtime/project"
_wul_fresh_runtime_home="$_wul_fresh_runtime/home/.claude"
_wul_fresh_runtime_skill="$_wul_fresh_runtime_home/skills/web-content-extraction"
_wul_fresh_runtime_snapshot="$_wul_fresh_runtime_home/.starter-kit-snapshot/skills/web-content-extraction"
_wul_fresh_runtime_kit="$_wul_fresh_runtime_project/skills/web-content-extraction"
mkdir -p "$_wul_fresh_runtime_skill" "$_wul_fresh_runtime_snapshot" \
  "$_wul_fresh_runtime_kit"
printf '{"scripts":{"test":"kit"},"dependencies":{"a":"1.0.0"}}\n' \
  > "$_wul_fresh_runtime_kit/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"scripts":{"test":"kit"},"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' \
  > "$_wul_fresh_runtime_kit/package-lock.json"
printf '{"scripts":{"test":"old"},"dependencies":{"a":"9.0.0"}}\n' \
  > "$_wul_fresh_runtime_skill/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"scripts":{"test":"old"},"dependencies":{"a":"9.0.0"}},"node_modules/a":{"version":"9.0.0"}}}\n' \
  > "$_wul_fresh_runtime_skill/package-lock.json"
_wul_fresh_runtime_rc=0
(
  PROJECT_DIR="$_wul_fresh_runtime_project"
  CLAUDE_DIR="$_wul_fresh_runtime_home"
  INSTALL_SKILLS=true KIT_MDM_MANAGED=false DRY_RUN=false
  _FRESH_SKIPPED_FILES=()
  reconcile_fresh_wce_package_pair
  _wul_write_fresh_snapshot() {
    local _WCE_FRESH_KIT_PAIR_BASELINE=true
    write_managed_snapshot
  }
  _wul_write_fresh_snapshot
  [[ ! -e "$CLAUDE_DIR/.starter-kit-snapshot/skills/web-content-extraction/package.json" \
    && ! -e "$CLAUDE_DIR/.starter-kit-snapshot/skills/web-content-extraction/package-lock.json" ]]
  refresh_fresh_wce_snapshot_pair
  _update_auto_managed_wce_package_pair \
    "$CLAUDE_DIR/skills/web-content-extraction" \
    "$CLAUDE_DIR/.starter-kit-snapshot/skills/web-content-extraction" \
    "$PROJECT_DIR/skills/web-content-extraction" || [[ "$?" -eq 1 ]]
) >/dev/null 2>&1 || _wul_fresh_runtime_rc=$?
if [[ "$_wul_fresh_runtime_rc" -eq 0 ]] \
  && [[ "$(jq -r '.dependencies.a' \
    "$_wul_fresh_runtime_skill/package.json")" == 9.0.0 ]] \
  && [[ "$(jq -r '.packages["node_modules/a"].version' \
    "$_wul_fresh_runtime_skill/package-lock.json")" == 9.0.0 ]] \
  && [[ "$(jq -r '.scripts.test' \
    "$_wul_fresh_runtime_skill/package.json")" == kit ]] \
  && cmp -s "$_wul_fresh_runtime_snapshot/package.json" \
    "$_wul_fresh_runtime_kit/package.json" \
  && cmp -s "$_wul_fresh_runtime_snapshot/package-lock.json" \
    "$_wul_fresh_runtime_kit/package-lock.json" \
  && [[ ! -e "$_wul_fresh_runtime_skill/logs/.update.lock" ]]; then
  pass "WCE fresh baseline: runtime pair survives fresh and the next update"
else
  fail "WCE fresh baseline: runtime state was promoted to baseline or rolled back"
fi

# A disabled, pre-existing WCE tree is not newly adopted by fresh setup. The
# generic snapshot omits its runtime pair and the baseline refresher stays off.
_wul_disabled_owned="$_wul_tmp/fresh-disabled-user-owned"
_wul_disabled_home="$_wul_disabled_owned/home/.claude"
_wul_disabled_skill="$_wul_disabled_home/skills/web-content-extraction"
_wul_disabled_snapshot="$_wul_disabled_home/.starter-kit-snapshot/skills/web-content-extraction"
mkdir -p "$_wul_disabled_skill"
cp "$PROJECT_DIR/skills/web-content-extraction/package.json" \
  "$PROJECT_DIR/skills/web-content-extraction/package-lock.json" \
  "$_wul_disabled_skill/"
cp "$_wul_disabled_skill/package.json" "$_wul_disabled_owned/package.saved"
cp "$_wul_disabled_skill/package-lock.json" "$_wul_disabled_owned/lock.saved"
_wul_disabled_rc=0
(
  CLAUDE_DIR="$_wul_disabled_home"
  INSTALL_SKILLS=false KIT_MDM_MANAGED=false DRY_RUN=false
  _FRESH_SKIPPED_FILES=()
  _wul_disabled_snapshot_body() {
    local _WCE_FRESH_KIT_PAIR_BASELINE=true
    write_managed_snapshot
    refresh_fresh_wce_snapshot_pair
  }
  _wce_with_runtime_update_lock "$_wul_disabled_skill" \
    _wul_disabled_snapshot_body
) >/dev/null 2>&1 || _wul_disabled_rc=$?
if [[ "$_wul_disabled_rc" -eq 0 ]] \
  && cmp -s "$_wul_disabled_skill/package.json" \
    "$_wul_disabled_owned/package.saved" \
  && cmp -s "$_wul_disabled_skill/package-lock.json" \
    "$_wul_disabled_owned/lock.saved" \
  && [[ ! -e "$_wul_disabled_snapshot/package.json" \
    && ! -e "$_wul_disabled_snapshot/package-lock.json" \
    && ! -e "$_wul_disabled_skill/logs/.update.lock" ]]; then
  pass "WCE fresh disabled: user-owned package pair is not adopted as baseline"
else
  fail "WCE fresh disabled: package pair was changed or re-added to snapshot"
fi

# Metadata-only current drift is kit-owned. With no runtime graph change, a
# new kit dependency version must win instead of preserving stale bytes.
_wul_pair="$_wul_tmp/pair-runtime-ownership"
mkdir -p "$_wul_pair/current" "$_wul_pair/snapshot" "$_wul_pair/new"
printf '{"scripts":{"test":"kit-old"},"dependencies":{"a":"1.0.0"}}\n' \
  > "$_wul_pair/snapshot/package.json"
printf '{"scripts":{"test":"local"},"dependencies":{"a":"1.0.0"}}\n' \
  > "$_wul_pair/current/package.json"
printf '{"scripts":{"test":"kit-new"},"dependencies":{"a":"2.0.0"}}\n' \
  > "$_wul_pair/new/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"scripts":{"test":"kit-old"},"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' \
  > "$_wul_pair/snapshot/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"scripts":{"test":"local"},"dependencies":{"a":"1.0.0"}},"node_modules/a":{"version":"1.0.0"}}}\n' \
  > "$_wul_pair/current/package-lock.json"
printf '{"lockfileVersion":3,"packages":{"":{"scripts":{"test":"kit-new"},"dependencies":{"a":"2.0.0"}},"node_modules/a":{"version":"2.0.0"}}}\n' \
  > "$_wul_pair/new/package-lock.json"
_wul_pair_rc=0
_update_auto_managed_wce_package_pair \
  "$_wul_pair/current" "$_wul_pair/snapshot" "$_wul_pair/new" \
  >/dev/null 2>&1 || _wul_pair_rc=$?
if [[ "$_wul_pair_rc" -eq 0 ]] \
  && cmp -s "$_wul_pair/current/package.json" "$_wul_pair/new/package.json" \
  && cmp -s "$_wul_pair/current/package-lock.json" \
    "$_wul_pair/new/package-lock.json"; then
  pass "WCE package pair: metadata-only drift adopts new kit versions"
else
  fail "WCE package pair: metadata drift masked a kit dependency update"
fi

# A valid but stale baseline still needs phase 5 even when live already equals
# the newly staged pair. Return 0 to record both files as managed refreshes.
cp "$_wul_pair/new/package.json" "$_wul_pair/current/package.json"
cp "$_wul_pair/new/package-lock.json" "$_wul_pair/current/package-lock.json"
_wul_stale_rc=0
_update_auto_managed_wce_package_pair \
  "$_wul_pair/current" "$_wul_pair/snapshot" "$_wul_pair/new" \
  >/dev/null 2>&1 || _wul_stale_rc=$?
if [[ "$_wul_stale_rc" -eq 0 ]]; then
  pass "WCE package pair: staged no-op reports stale snapshot refresh"
else
  fail "WCE package pair: staged no-op left a stale valid baseline"
fi

rm -rf "$_wul_tmp"
