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
# The child attempt is expected to lose; its contention report is not asserted.
_wce_with_runtime_update_lock "$_wul_reentry" \
  _wul_outer_callback "$_wul_reentry" "$_wul_reentry_result" \
  2>/dev/null || _wul_reentry_rc=$?
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
  > "$_wul_tmp/update-contention.out" 2>&1 || _wul_update_rc=$?
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
# Exit 75 at this point used to be completely silent. It must name the lock and
# say that settings.json / CLAUDE.md were already processed by this run.
if grep -Fq \
    "$_wul_update_home/skills/web-content-extraction/logs/.update.lock" \
    "$_wul_tmp/update-contention.out" \
  && grep -q 'settings\.json' "$_wul_tmp/update-contention.out"; then
  pass "WCE update: tail contention names the lock and the partial state"
else
  fail "WCE update: tail contention exited 75 without a diagnosis"
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
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  UPDATE_MODE=false DRY_RUN=false KIT_MDM_MANAGED=false
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  INSTALL_AGENTS=false INSTALL_RULES=false INSTALL_COMMANDS=false
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
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
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  STR_DRYRUN_OFFER_EXISTING=dry-run
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  STR_EXISTING_CLAUDE_MERGE_NOTE=merge
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  STR_FRESH_DIR_EXISTS=exists
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  STR_FRESH_DIR_PROMPT=prompt
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  STR_FRESH_SKIPPED=skipped
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
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
  # shellcheck disable=SC2034 # consumed indirectly by snapshot helpers
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

# ---------------------------------------------------------------------------
# Diagnosis, pre-write preflight, and bounded recovery of an abandoned lock.
#
# A dependency updater killed while holding the lock used to leave it forever:
# every later update wrote settings.json / CLAUDE.md and a full backup, then
# exited 75 without a word. The low-level acquire must still refuse every
# existing lock; only the preflight may recover one, and only when its owner
# is a recognized token whose process is provably gone and the lock is old.
# ---------------------------------------------------------------------------
_wul_uuid="33613976-dc7b-422d-aa54-8c4cb5ab84fb"
_wul_uuid_other="0f0e0d0c-0b0a-4908-8706-050403020100"

_wul_dead_pid() { # prints the PID of a process that has already exited
  local pid
  sh -c 'exit 0' &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s' "$pid"
}

_wul_make_lock() { # <skill-dir> <owner-line> [old]
  mkdir -p "$1/logs/.update.lock"
  printf '%s\n' "$2" > "$1/logs/.update.lock/owner"
  if [[ "${3:-}" == old ]]; then
    touch -t 200001010000 "$1/logs/.update.lock/owner"
  fi
}

_wul_lock_state() { # <skill-dir>
  (
    _WCE_LOCK_STATE=""
    _wce_runtime_update_lock_inspect "$1" >/dev/null 2>&1
    printf '%s' "$_WCE_LOCK_STATE"
  ) 2>/dev/null || true
}

_wul_lock_residue() { # <skill-dir>: true while reclaim scaffolding remains
  compgen -G "$1/logs/.update.lock.*" >/dev/null
}

_wul_preflight() { # <skill-dir> <output-file> [wait-seconds] [msys|mdm]
  local rc=0
  (
    _WCE_RUNTIME_LOCK_WAIT_SECONDS="${3:-0}"
    KIT_MDM_MANAGED=false
    case "${4:-}" in
      msys) is_msys() { return 0; } ;;
      mdm) KIT_MDM_MANAGED=true ;;
    esac
    _wce_runtime_update_lock_preflight "$1"
  ) > "$2" 2>&1 || rc=$?
  printf '%s' "$rc"
}

sleep 120 >/dev/null 2>&1 &
_wul_live_pid=$!
_wul_dead="$(_wul_dead_pid)"
_wul_dead_other="$(_wul_dead_pid)"

# --- Classification: free / busy / stale / unknown ---------------------------
_wul_inspect="$_wul_tmp/inspect"
mkdir -p "$_wul_inspect/free"
_wul_make_lock "$_wul_inspect/node-live" "$_wul_live_pid:$_wul_uuid"
_wul_make_lock "$_wul_inspect/node-dead" "$_wul_dead:$_wul_uuid"
_wul_make_lock "$_wul_inspect/kit-live" \
  "starter-kit-update-$_wul_live_pid-1-1700000000"
_wul_make_lock "$_wul_inspect/kit-dead" \
  "starter-kit-update-$_wul_dead-1-1700000000"
# PID 1 always exists but belongs to another user: `kill -0` fails for it
# exactly as it does for a missing PID, so it must not be classified as gone.
_wul_make_lock "$_wul_inspect/pid1" "1:$_wul_uuid"
_wul_make_lock "$_wul_inspect/foreign" foreign-updater
_wul_make_lock "$_wul_inspect/zero-pid" "0:$_wul_uuid"
_wul_make_lock "$_wul_inspect/uppercase-uuid" \
  "$_wul_dead:33613976-DC7B-422D-AA54-8C4CB5AB84FB"
mkdir -p "$_wul_inspect/empty/logs/.update.lock"
_wul_make_lock "$_wul_inspect/two-lines" "$_wul_dead:$_wul_uuid"
printf 'second-line\n' >> "$_wul_inspect/two-lines/logs/.update.lock/owner"
mkdir -p "$_wul_inspect/no-newline/logs/.update.lock"
printf '%s' "$_wul_dead:$_wul_uuid" \
  > "$_wul_inspect/no-newline/logs/.update.lock/owner"
mkdir -p "$_wul_inspect/oversized/logs/.update.lock"
printf '%0129d\n' 0 > "$_wul_inspect/oversized/logs/.update.lock/owner"
_wul_make_lock "$_wul_inspect/extra-entry" "$_wul_dead:$_wul_uuid"
: > "$_wul_inspect/extra-entry/logs/.update.lock/npm-in-flight"
mkdir -p "$_wul_inspect/symlink-lock/logs" "$_wul_inspect/symlink-target"
printf '%s\n' "$_wul_dead:$_wul_uuid" > "$_wul_inspect/symlink-target/owner"
ln -s "$_wul_inspect/symlink-target" \
  "$_wul_inspect/symlink-lock/logs/.update.lock"
mkdir -p "$_wul_inspect/symlink-owner/logs/.update.lock"
ln -s "$_wul_inspect/symlink-target/owner" \
  "$_wul_inspect/symlink-owner/logs/.update.lock/owner"
mkdir -p "$_wul_inspect/regular-file/logs"
printf '%s\n' "$_wul_dead:$_wul_uuid" \
  > "$_wul_inspect/regular-file/logs/.update.lock"
mkdir -p "$_wul_inspect/symlink-logs" "$_wul_inspect/symlink-logs-target"
ln -s "$_wul_inspect/symlink-logs-target" "$_wul_inspect/symlink-logs/logs"

_wul_states=""
for _wul_case in free node-live node-dead kit-live kit-dead pid1 foreign \
  zero-pid uppercase-uuid empty two-lines no-newline oversized extra-entry \
  symlink-lock symlink-owner regular-file symlink-logs; do
  _wul_states+="$_wul_case=$(_wul_lock_state "$_wul_inspect/$_wul_case") "
done
_wul_states_expected="free=free node-live=busy node-dead=stale kit-live=busy"
_wul_states_expected+=" kit-dead=stale pid1=busy foreign=unknown"
_wul_states_expected+=" zero-pid=unknown uppercase-uuid=unknown empty=unknown"
_wul_states_expected+=" two-lines=unknown no-newline=unknown oversized=unknown"
_wul_states_expected+=" extra-entry=unknown symlink-lock=unusable"
_wul_states_expected+=" symlink-owner=unknown regular-file=unusable"
_wul_states_expected+=" symlink-logs=unusable "
if [[ "$_wul_states" == "$_wul_states_expected" ]]; then
  pass "WCE lock inspect: only a recognized owner with a missing PID is stale"
else
  echo "  expected: $_wul_states_expected" >&2
  echo "  got:      $_wul_states" >&2
  fail "WCE lock inspect: a lock shape or owner was misclassified"
fi

# A symlinked or non-directory path holds no lock. The diagnosis must name
# that path and must not offer `rm -f <lock>/owner && rmdir <lock>`: through a
# symlinked lock, that command would delete the link target's owner file.
_wul_unusable_ok=true
for _wul_case in symlink-lock symlink-logs regular-file; do
  _wul_unusable_out="$_wul_tmp/unusable-$_wul_case.out"
  _wul_unusable_rc="$(_wul_preflight "$_wul_inspect/$_wul_case" \
    "$_wul_unusable_out")"
  case "$_wul_case" in
    symlink-lock|regular-file)
      _wul_unusable_path="$_wul_inspect/$_wul_case/logs/.update.lock" ;;
    symlink-logs)
      _wul_unusable_path="$_wul_inspect/$_wul_case/logs" ;;
  esac
  [[ "$_wul_unusable_rc" == 75 ]] || _wul_unusable_ok=false
  grep -Fq "$_wul_unusable_path" "$_wul_unusable_out" || _wul_unusable_ok=false
  if grep -Eq 'rm -f .*(&&|;) *rmdir' "$_wul_unusable_out"; then
    _wul_unusable_ok=false
  fi
  if [[ "$_wul_unusable_ok" != true ]]; then
    echo "  case=$_wul_case rc=$_wul_unusable_rc" >&2
    sed 's/^/    | /' "$_wul_unusable_out" >&2 || true
    break
  fi
done
if [[ "$_wul_unusable_ok" == true ]] \
  && [[ -L "$_wul_inspect/symlink-lock/logs/.update.lock" ]] \
  && grep -qx "$_wul_dead:$_wul_uuid" "$_wul_inspect/symlink-target/owner"; then
  pass "WCE preflight: a symlink or non-directory path is named, with no lock removal offered"
else
  fail "WCE preflight: an unusable path was reported as a held lock, or a removal command was offered"
fi

# --- Preflight recovers a provably abandoned, old lock ------------------------
for _wul_case in node kit; do
  _wul_reclaim="$_wul_tmp/reclaim-$_wul_case"
  if [[ "$_wul_case" == node ]]; then
    _wul_make_lock "$_wul_reclaim" "$_wul_dead:$_wul_uuid" old
  else
    _wul_make_lock "$_wul_reclaim" \
      "starter-kit-update-$_wul_dead-1-1700000000" old
  fi
  _wul_reclaim_rc="$(_wul_preflight "$_wul_reclaim" "$_wul_reclaim.out")"
  if [[ "$_wul_reclaim_rc" == 0 ]] \
    && [[ ! -e "$_wul_reclaim/logs/.update.lock" \
      && ! -L "$_wul_reclaim/logs/.update.lock" ]] \
    && ! _wul_lock_residue "$_wul_reclaim" \
    && grep -Fq "$_wul_dead" "$_wul_reclaim.out"; then
    pass "WCE preflight: an old $_wul_case lock whose owner is gone is recovered"
  else
    echo "  rc=$_wul_reclaim_rc" >&2
    sed 's/^/    | /' "$_wul_reclaim.out" >&2 || true
    fail "WCE preflight: an abandoned $_wul_case lock was not recovered cleanly"
  fi
done

# --- Preflight refuses everything else, byte for byte -------------------------
_wul_check_blocked() { # <case> <skill-dir> <mode> [needle...]
  local name="$1" dir="$2" mode="$3" needle ok=true rc
  local out="$_wul_tmp/blocked-$1.out" saved="$_wul_tmp/blocked-$1.owner"
  shift 3
  cp -p "$dir/logs/.update.lock/owner" "$saved"
  rc="$(_wul_preflight "$dir" "$out" 0 "$mode")"
  [[ "$rc" == 75 ]] || ok=false
  cmp -s "$dir/logs/.update.lock/owner" "$saved" || ok=false
  [[ ! "$dir/logs/.update.lock/owner" -nt "$saved" ]] || ok=false
  grep -Fq "$dir/logs/.update.lock" "$out" || ok=false
  for needle in "$@"; do
    grep -Fq -- "$needle" "$out" || ok=false
  done
  compgen -G "$dir/logs/.update.lock.stale-*" >/dev/null && ok=false
  if [[ "$ok" == true ]]; then
    pass "WCE preflight: $name stops with a diagnosis and is left untouched"
  else
    echo "  rc=$rc" >&2
    sed 's/^/    | /' "$out" >&2 || true
    fail "WCE preflight: $name was reclaimed, changed, or reported silently"
  fi
}

_wul_make_lock "$_wul_tmp/blocked-recent" "$_wul_dead:$_wul_uuid"
_wul_check_blocked "a recently abandoned lock" "$_wul_tmp/blocked-recent" "" \
  "$_wul_dead" rmdir

# The age threshold is 60 minutes (_WCE_RUNTIME_LOCK_STALE_MINUTES). Bind it
# from both sides: 59 minutes is kept, 61 minutes is recovered. BSD find
# rounds the age up and GNU find truncates it, so both sides stay a full
# minute away from the threshold.
_wul_touch_minutes_ago() { # <file> <minutes>
  local stamp=""
  stamp="$(date -v "-$2M" '+%Y%m%d%H%M.%S' 2>/dev/null)" \
    || stamp="$(date -d "$2 minutes ago" '+%Y%m%d%H%M.%S' 2>/dev/null)" \
    || return 1
  touch -t "$stamp" "$1"
}
_wul_make_lock "$_wul_tmp/blocked-59min" "$_wul_dead:$_wul_uuid"
if _wul_touch_minutes_ago "$_wul_tmp/blocked-59min/logs/.update.lock/owner" 59; then
  _wul_check_blocked "an abandoned lock 59 minutes old" \
    "$_wul_tmp/blocked-59min" "" "$_wul_dead" rmdir
else
  fail "WCE preflight: could not set a 59-minute-old owner mtime"
fi
_wul_edge="$_wul_tmp/reclaim-61min"
_wul_make_lock "$_wul_edge" "$_wul_dead:$_wul_uuid"
_wul_edge_rc=1
if _wul_touch_minutes_ago "$_wul_edge/logs/.update.lock/owner" 61; then
  _wul_edge_rc="$(_wul_preflight "$_wul_edge" "$_wul_edge.out")"
fi
if [[ "$_wul_edge_rc" == 0 ]] \
  && [[ ! -e "$_wul_edge/logs/.update.lock" ]] \
  && ! _wul_lock_residue "$_wul_edge" \
  && grep -Fq "$_wul_dead" "$_wul_edge.out"; then
  pass "WCE preflight: an abandoned lock 61 minutes old is recovered"
else
  echo "  rc=$_wul_edge_rc" >&2
  sed 's/^/    | /' "$_wul_edge.out" >&2 || true
  fail "WCE preflight: an abandoned lock just past the 60-minute threshold was kept"
fi

_wul_make_lock "$_wul_tmp/blocked-foreign" foreign-updater old
_wul_check_blocked "an unverifiable owner" "$_wul_tmp/blocked-foreign" "" \
  foreign-updater rmdir

_wul_make_lock "$_wul_tmp/blocked-live" "$_wul_live_pid:$_wul_uuid" old
_wul_check_blocked "a running owner" "$_wul_tmp/blocked-live" "" \
  "$_wul_live_pid"

_wul_make_lock "$_wul_tmp/blocked-pid1" "1:$_wul_uuid" old
_wul_check_blocked "a PID that cannot be signalled" "$_wul_tmp/blocked-pid1" ""

_wul_make_lock "$_wul_tmp/blocked-msys" "$_wul_dead:$_wul_uuid" old
_wul_check_blocked "a lock on MSYS" "$_wul_tmp/blocked-msys" msys rmdir

_wul_make_lock "$_wul_tmp/blocked-mdm" "$_wul_dead:$_wul_uuid" old
_wul_check_blocked "a lock under MDM" "$_wul_tmp/blocked-mdm" mdm

_wul_make_lock "$_wul_tmp/blocked-mutex" "$_wul_dead:$_wul_uuid" old
mkdir "$_wul_tmp/blocked-mutex/logs/.update.lock.reclaim"
_wul_check_blocked "a lock with a leftover reclaim mutex" \
  "$_wul_tmp/blocked-mutex" "" ".update.lock.reclaim"
if [[ -d "$_wul_tmp/blocked-mutex/logs/.update.lock.reclaim" ]]; then
  pass "WCE preflight: a reclaim mutex it does not own is never removed"
else
  fail "WCE preflight: a foreign reclaim mutex was removed"
fi

# Acquisition fails while the reclaim mutex exists (see the reclaimer: only
# then can it be sure no writer completed an acquisition after it took the
# mutex). A mutex left by a killed reclaimer therefore blocks the lock even
# with the canonical name free. It also outlasts the withdrawal wait, which
# does not prove the reclaimer dead, so the attempt leaves its own lock in
# place rather than renaming anything.
_wul_mutex_acq="$_wul_tmp/mutex-only-acquire"
mkdir -p "$_wul_mutex_acq/logs/.update.lock.reclaim"
_wul_mutex_acq_rc=0
_wce_with_runtime_update_lock "$_wul_mutex_acq" true \
  >/dev/null 2> "$_wul_mutex_acq.err" || _wul_mutex_acq_rc=$?
if [[ "$_wul_mutex_acq_rc" -eq 75 ]] \
  && [[ -d "$_wul_mutex_acq/logs/.update.lock.reclaim" ]] \
  && grep -Eqx 'starter-kit-update-[0-9]+-[0-9]+-[0-9]+' \
    "$_wul_mutex_acq/logs/.update.lock/owner" \
  && [[ "$(command ls -A "$_wul_mutex_acq/logs" | LC_ALL=C sort | tr '\n' ' ')" \
    == ".update.lock .update.lock.reclaim " ]] \
  && grep -Fq ".update.lock.reclaim" "$_wul_mutex_acq.err"; then
  pass "WCE lock: acquisition backs off while a reclaim mutex exists"
else
  echo "  rc=$_wul_mutex_acq_rc" >&2
  sed 's/^/    | /' "$_wul_mutex_acq.err" >&2 || true
  fail "WCE lock: a lock was taken beside a reclaim mutex, or the mutex was not named"
fi

# The preflight runs before any acquisition and must report a leftover mutex
# instead of passing a run through to a later 75 after the backup.
_wul_mutex_only="$_wul_tmp/mutex-only"
mkdir -p "$_wul_mutex_only/logs/.update.lock.reclaim"
_wul_mutex_only_pre_rc="$(_wul_preflight "$_wul_mutex_only" "$_wul_mutex_only.out")"
if [[ "$_wul_mutex_only_pre_rc" == 75 ]] \
  && grep -Fq ".update.lock.reclaim" "$_wul_mutex_only.out" \
  && ! grep -Eq 'rm -f .*(&&|;) *rmdir' "$_wul_mutex_only.out" \
  && [[ -d "$_wul_mutex_only/logs/.update.lock.reclaim" ]]; then
  pass "WCE preflight: a leftover reclaim mutex with no lock is reported, not passed"
else
  echo "  rc=$_wul_mutex_only_pre_rc" >&2
  sed 's/^/    | /' "$_wul_mutex_only.out" >&2 || true
  fail "WCE preflight: a leftover reclaim mutex was passed through or misreported"
fi

# A whole recovery can run between the owner write and the mutex check: the
# reclaimer moves this lock aside, cannot put it back because writer B took
# the canonical name, and releases the mutex. The mutex check then passes, so
# acquisition must still fail on the canonical owner (B's), and must leave
# both B's lock and the displaced directory alone.
_wul_displaced="$_wul_tmp/acquire-displaced"
_wul_displaced_lock="$_wul_displaced/logs/.update.lock"
mkdir -p "$_wul_displaced/logs"
_wul_displaced_rc=0
(
  printf() {
    builtin printf "$@"
    if [[ "${1:-}" == '%s\n' && "${2:-}" == starter-kit-update-* \
      && ! -e "$_wul_displaced/injected" ]]; then
      : > "$_wul_displaced/injected"
      command mv "$_wul_displaced_lock" "$_wul_displaced_lock.stale-test"
      command mkdir "$_wul_displaced_lock"
      builtin printf 'writer-b\n' > "$_wul_displaced_lock/owner"
    fi
  }
  _wul_displaced_token=""
  _wce_runtime_update_lock_acquire "$_wul_displaced" _wul_displaced_token \
    || exit 1
  [[ -z "$_wul_displaced_token" ]] || exit 2
  exit 0
) >/dev/null 2>&1 || _wul_displaced_rc=$?
if [[ "$_wul_displaced_rc" -eq 1 && -e "$_wul_displaced/injected" ]] \
  && grep -qx writer-b "$_wul_displaced_lock/owner" \
  && grep -Eqx 'starter-kit-update-[0-9]+-[0-9]+-[0-9]+' \
    "$_wul_displaced_lock.stale-test/owner"; then
  pass "WCE lock: acquisition fails when a recovery displaced it before the mutex check"
else
  echo "  rc=$_wul_displaced_rc" >&2
  fail "WCE lock: a displaced acquisition succeeded or disturbed the canonical owner"
fi

# The mutex check sees the recovery, but before the withdrawal runs the
# recovery moves this lock aside and writer B takes the canonical name. The
# withdrawal must check the token and leave B's lock in place.
_wul_withdraw="$_wul_tmp/acquire-withdraw"
_wul_withdraw_lock="$_wul_withdraw/logs/.update.lock"
mkdir -p "$_wul_withdraw/logs"
_wul_withdraw_rc=0
(
  printf() {
    builtin printf "$@"
    if [[ "${1:-}" == '%s\n' && "${2:-}" == starter-kit-update-* \
      && ! -e "$_wul_withdraw/injected" ]]; then
      : > "$_wul_withdraw/injected"
      command mkdir "$_wul_withdraw_lock.reclaim"
      command mv "$_wul_withdraw_lock" "$_wul_withdraw_lock.stale-test"
      command mkdir "$_wul_withdraw_lock"
      builtin printf 'writer-b\n' > "$_wul_withdraw_lock/owner"
    fi
  }
  _wul_withdraw_token=""
  _wce_runtime_update_lock_acquire "$_wul_withdraw" _wul_withdraw_token \
    || exit 1
  exit 0
) >/dev/null 2>&1 || _wul_withdraw_rc=$?
if [[ "$_wul_withdraw_rc" -eq 1 && -e "$_wul_withdraw/injected" ]] \
  && grep -qx writer-b "$_wul_withdraw_lock/owner" \
  && [[ "$(command ls -A "$_wul_withdraw_lock")" == owner ]] \
  && grep -Eqx 'starter-kit-update-[0-9]+-[0-9]+-[0-9]+' \
    "$_wul_withdraw_lock.stale-test/owner"; then
  pass "WCE lock: withdrawing beside a reclaim mutex never removes another writer's lock"
else
  echo "  rc=$_wul_withdraw_rc" >&2
  fail "WCE lock: withdrawing beside a reclaim mutex removed another writer's lock"
fi

# The reclaimer is still active when the mutex check runs. A withdrawal that
# checked its owner and renamed at once could have this lock moved aside
# between the two steps; writer B then takes the canonical name after the
# mutex is released, the rename moves B's lock, and writer C takes the free
# name. The withdrawal must wait for the mutex, then find B and rename nothing.
_wul_wwait="$_wul_tmp/acquire-withdraw-wait"
_wul_wwait_lock="$_wul_wwait/logs/.update.lock"
mkdir -p "$_wul_wwait/logs"
_wul_wwait_rc=0
(
  _wul_wwait_recover() { # reclaimer moves this lock aside, finishes; B acquires
    [[ ! -e "$_wul_wwait/recovered" ]] || return 0
    : > "$_wul_wwait/recovered"
    command mv "$_wul_wwait_lock" "$_wul_wwait_lock.stale-test"
    command rmdir "$_wul_wwait_lock.reclaim"
    command mkdir "$_wul_wwait_lock"
    builtin printf 'writer-b\n' > "$_wul_wwait_lock/owner"
  }
  printf() {
    builtin printf "$@"
    if [[ "${1:-}" == '%s\n' && "${2:-}" == starter-kit-update-* \
      && ! -e "$_wul_wwait/injected" ]]; then
      : > "$_wul_wwait/injected"
      command mkdir "$_wul_wwait_lock.reclaim"
    fi
  }
  sleep() { _wul_wwait_recover; }
  mv() {
    local mv_rc=0
    if [[ "${1:-}" == "$_wul_wwait_lock" \
      && "${2:-}" == "$_wul_wwait_lock".release-* ]]; then
      _wul_wwait_recover
      command mv "$@" || mv_rc=$?
      command mkdir "$_wul_wwait_lock" 2>/dev/null \
        && builtin printf 'writer-c\n' > "$_wul_wwait_lock/owner"
      return "$mv_rc"
    fi
    command mv "$@"
  }
  _wul_wwait_token=""
  _wce_runtime_update_lock_acquire "$_wul_wwait" _wul_wwait_token \
    || exit 1
  exit 0
) >/dev/null 2>&1 || _wul_wwait_rc=$?
if [[ "$_wul_wwait_rc" -eq 1 && -e "$_wul_wwait/recovered" ]] \
  && grep -qx writer-b "$_wul_wwait_lock/owner" \
  && [[ "$(command ls -A "$_wul_wwait_lock")" == owner ]] \
  && grep -Eqx 'starter-kit-update-[0-9]+-[0-9]+-[0-9]+' \
    "$_wul_wwait_lock.stale-test/owner" \
  && [[ "$(command ls -A "$_wul_wwait/logs" | LC_ALL=C sort | tr '\n' ' ')" \
    == ".update.lock .update.lock.stale-test " ]]; then
  pass "WCE lock: withdrawal waits for the reclaimer before renaming anything"
else
  echo "  rc=$_wul_wwait_rc" >&2
  command ls -A "$_wul_wwait/logs" | sed 's/^/    | /' >&2 || true
  fail "WCE lock: withdrawal renamed while a reclaimer could still move locks"
fi

# The token names the process that holds the lock. A parent killed on its own
# leaves that subshell running, and a token naming the parent would make the
# live writer look abandoned (stale) and therefore reclaimable.
_wul_holder="$_wul_tmp/holder-pid"
mkdir -p "$_wul_holder"
_wul_holder_cb() {
  builtin printf '%s\n' "$BASHPID" > "$_wul_holder/holder"
  _wce_runtime_update_lock_inspect "$_wul_holder"
  builtin printf '%s\n' "$_WCE_LOCK_OWNER_PID" > "$_wul_holder/token-pid"
}
_wul_holder_rc=0
_wce_with_runtime_update_lock "$_wul_holder" _wul_holder_cb \
  >/dev/null 2>&1 || _wul_holder_rc=$?
if [[ "$_wul_holder_rc" -eq 0 && -s "$_wul_holder/holder" ]] \
  && [[ "$(cat "$_wul_holder/token-pid")" == "$(cat "$_wul_holder/holder")" ]] \
  && [[ "$(cat "$_wul_holder/holder")" != "$$" ]]; then
  pass "WCE lock: the owner token names the lock-holding process, not the parent"
else
  echo "  rc=$_wul_holder_rc holder=$(cat "$_wul_holder/holder" 2>/dev/null) token=$(cat "$_wul_holder/token-pid" 2>/dev/null) parent=$$" >&2
  fail "WCE lock: the owner token names a process other than the lock holder"
fi

# A mutex that outlasts the withdrawal wait does not prove the reclaimer dead;
# it may be stalled between its own read and rename. The token-checked release
# is not atomic either, so withdrawing now could move a successor's lock. The
# acquisition must fail and leave its own lock and the mutex untouched.
_wul_wstall="$_wul_tmp/acquire-withdraw-stalled"
_wul_wstall_lock="$_wul_wstall/logs/.update.lock"
mkdir -p "$_wul_wstall/logs"
_wul_wstall_rc=0
(
  printf() {
    builtin printf "$@"
    if [[ "${1:-}" == '%s\n' && "${2:-}" == starter-kit-update-* \
      && ! -e "$_wul_wstall/injected" ]]; then
      : > "$_wul_wstall/injected"
      command mkdir "$_wul_wstall_lock.reclaim"
    fi
  }
  sleep() { :; }
  mv() {
    builtin printf '%s\n' "$*" >> "$_wul_wstall/mv-calls"
    command mv "$@"
  }
  _wul_wstall_token=""
  _wce_runtime_update_lock_acquire "$_wul_wstall" _wul_wstall_token \
    || exit 1
  exit 0
) >/dev/null 2>&1 || _wul_wstall_rc=$?
if [[ "$_wul_wstall_rc" -eq 1 && -e "$_wul_wstall/injected" ]] \
  && [[ ! -e "$_wul_wstall/mv-calls" ]] \
  && [[ -d "$_wul_wstall_lock.reclaim" ]] \
  && grep -Eqx 'starter-kit-update-[0-9]+-[0-9]+-[0-9]+' \
    "$_wul_wstall_lock/owner" \
  && [[ "$(command ls -A "$_wul_wstall/logs" | LC_ALL=C sort | tr '\n' ' ')" \
    == ".update.lock .update.lock.reclaim " ]]; then
  pass "WCE lock: a mutex outlasting the wait fails without renaming anything"
else
  echo "  rc=$_wul_wstall_rc" >&2
  command ls -A "$_wul_wstall/logs" | sed 's/^/    | /' >&2 || true
  fail "WCE lock: withdrew while a stalled reclaimer could still move locks"
fi

# Between the mkdir and the owner write a reclaimer can move this directory
# aside and writer B can take the canonical name. The owner write must not
# truncate B's owner (noclobber, like 'wx' in update-deps.mjs); otherwise both
# writers pass their final token check and hold the lock at once.
_wul_clob="$_wul_tmp/acquire-owner-noclobber"
_wul_clob_lock="$_wul_clob/logs/.update.lock"
mkdir -p "$_wul_clob/logs"
_wul_clob_rc=0
(
  mkdir() {
    command mkdir "$@" || return
    if [[ "${!#}" == "$_wul_clob_lock" ]]; then
      # This directory is swapped for writer B's completed lock.
      builtin printf 'writer-b\n' > "$_wul_clob_lock/owner"
    fi
  }
  _wul_clob_token=""
  _wce_runtime_update_lock_acquire "$_wul_clob" _wul_clob_token \
    || exit 1
  exit 0
) >/dev/null 2>&1 || _wul_clob_rc=$?
if [[ "$_wul_clob_rc" -eq 1 ]] \
  && grep -qx writer-b "$_wul_clob_lock/owner" \
  && [[ "$(command ls -A "$_wul_clob_lock")" == owner ]]; then
  pass "WCE lock: the owner write never overwrites another writer's owner"
else
  echo "  rc=$_wul_clob_rc owner=$(cat "$_wul_clob_lock/owner" 2>/dev/null)" >&2
  fail "WCE lock: the owner write replaced another writer's owner"
fi

# --- A stale observation never authorizes removing a successor ----------------
_wul_observed="$_wul_tmp/reclaim-observed"
_wul_make_lock "$_wul_observed" "$_wul_dead_other:$_wul_uuid_other" old
cp -p "$_wul_observed/logs/.update.lock/owner" "$_wul_observed.owner"
_wul_observed_rc=0
(
  # The mismatch must be caught under the mutex, before any rename: moving a
  # successor's lock aside, even briefly, would let a third writer in.
  mv() {
    : > "$_wul_observed.mv-called"
    command mv "$@"
  }
  _wce_runtime_update_lock_reclaim_stale \
    "$_wul_observed" "$_wul_dead:$_wul_uuid"
) >/dev/null 2>&1 || _wul_observed_rc=$?
if [[ "$_wul_observed_rc" -ne 0 && "$_wul_observed_rc" -ne 127 ]] \
  && [[ ! -e "$_wul_observed.mv-called" ]] \
  && cmp -s "$_wul_observed/logs/.update.lock/owner" "$_wul_observed.owner" \
  && ! _wul_lock_residue "$_wul_observed"; then
  pass "WCE reclaim: a different owner than the one observed is not removed"
else
  fail "WCE reclaim: an outdated observation removed a successor lock"
fi

# Replace the canonical directory between the mutex-held recheck and the
# rename. The quarantined inode no longer carries the observed owner, so it
# must be put back and the mutex released.
_wul_swap="$_wul_tmp/reclaim-swap"
_wul_swap_lock="$_wul_swap/logs/.update.lock"
_wul_make_lock "$_wul_swap" "$_wul_dead:$_wul_uuid" old
_wul_swap_rc=0
(
  mv() {
    if [[ "$1" == "$_wul_swap_lock" && ! -e "$_wul_swap/injected" ]]; then
      : > "$_wul_swap/injected"
      command rm -rf "$_wul_swap_lock"
      command mkdir "$_wul_swap_lock"
      printf 'successor-owner\n' > "$_wul_swap_lock/owner"
    fi
    command mv "$@"
  }
  _WCE_RUNTIME_LOCK_WAIT_SECONDS=0
  KIT_MDM_MANAGED=false
  _wce_runtime_update_lock_preflight "$_wul_swap"
) > "$_wul_swap.out" 2>&1 || _wul_swap_rc=$?
if [[ "$_wul_swap_rc" -eq 75 && -e "$_wul_swap/injected" ]] \
  && grep -qx successor-owner "$_wul_swap_lock/owner" \
  && ! _wul_lock_residue "$_wul_swap"; then
  pass "WCE reclaim: a read-to-rename successor is restored, not deleted"
else
  echo "  rc=$_wul_swap_rc" >&2
  sed 's/^/    | /' "$_wul_swap.out" >&2 || true
  fail "WCE reclaim: a successor lock was deleted or stranded in quarantine"
fi

# Same replacement, but a third writer takes the canonical name before the
# successor can be put back. The restore claims the name with mkdir; when
# that fails it must leave the successor in quarantine and say where, never
# move it into the third writer's lock directory.
_wul_third="$_wul_tmp/reclaim-third"
_wul_third_lock="$_wul_third/logs/.update.lock"
_wul_make_lock "$_wul_third" "$_wul_dead:$_wul_uuid" old
_wul_third_rc=0
(
  mv() {
    if [[ "$1" == "$_wul_third_lock" && ! -e "$_wul_third/injected" ]]; then
      : > "$_wul_third/injected"
      command rm -rf "$_wul_third_lock"
      command mkdir "$_wul_third_lock"
      printf 'successor-owner\n' > "$_wul_third_lock/owner"
    fi
    command mv "$@"
  }
  mkdir() {
    # The restore's claim of the canonical name loses to a third writer.
    if [[ "${*: -1}" == "$_wul_third_lock" && ! -e "$_wul_third/third" ]]; then
      : > "$_wul_third/third"
      command mkdir "$_wul_third_lock"
      printf 'third-owner\n' > "$_wul_third_lock/owner"
      return 1
    fi
    command mkdir "$@"
  }
  _WCE_RUNTIME_LOCK_WAIT_SECONDS=0
  KIT_MDM_MANAGED=false
  # shellcheck disable=SC2034 # consumed indirectly by the sourced helper
  STR_WCE_LOCK_QUARANTINE_LEFT="quarantine-left-marker"
  _wce_runtime_update_lock_preflight "$_wul_third"
) > "$_wul_third.out" 2>&1 || _wul_third_rc=$?
_wul_third_quarantine="$(compgen -G "$_wul_third/logs/.update.lock.stale-*" || true)"
if [[ "$_wul_third_rc" -eq 75 && -e "$_wul_third/third" ]] \
  && grep -qx third-owner "$_wul_third_lock/owner" \
  && [[ -n "$_wul_third_quarantine" ]] \
  && grep -qx successor-owner "$_wul_third_quarantine/owner" \
  && [[ -z "$(find "$_wul_third_lock" -mindepth 1 -type d -print 2>/dev/null)" ]] \
  && [[ ! -e "$_wul_third/logs/.update.lock.reclaim" ]] \
  && grep -Fq quarantine-left-marker "$_wul_third.out" \
  && grep -Fq "$_wul_third_quarantine" "$_wul_third.out"; then
  pass "WCE reclaim: a successor that cannot be put back is kept aside and named"
else
  echo "  rc=$_wul_third_rc quarantine=$_wul_third_quarantine" >&2
  sed 's/^/    | /' "$_wul_third.out" >&2 || true
  fail "WCE reclaim: a successor was moved into a third writer's lock or lost silently"
fi

# The release runs in a child of the lock holder. If only the holder is killed
# (its PID is in the token) while the child is stalled between its owner check
# and its rename, the lock is stale; once old enough a reclaimer removes it,
# writer A takes the name, the resumed rename moves A's lock, and writer B
# takes the free name: A and B both run. The release must hold the reclaim
# mutex from the owner check to the rename, so the reclaimer cannot act then.
_wul_rel="$_wul_tmp/release-vs-reclaim"
_wul_rel_lock="$_wul_rel/logs/.update.lock"
_wul_rel_token="starter-kit-update-$_wul_dead-1-1"
_wul_make_lock "$_wul_rel" "$_wul_rel_token" old
_wul_rel_rc=0
(
  mv() {
    if [[ "${1:-}" == "$_wul_rel_lock" \
      && "${2:-}" == "$_wul_rel_lock".release-* \
      && ! -e "$_wul_rel/injected" ]]; then
      : > "$_wul_rel/injected"
      # The stalled window: a reclaimer runs, then writer A tries to acquire.
      if _wce_runtime_update_lock_reclaim_stale_locked \
          "$_wul_rel" "$_wul_rel_token"; then
        : > "$_wul_rel/reclaimed"
      fi
      if command mkdir "$_wul_rel_lock" 2>/dev/null; then
        builtin printf 'writer-a\n' > "$_wul_rel_lock/owner"
        : > "$_wul_rel/a-acquired"
      fi
      command mv "$@" || return
      # Writer B takes the name the rename freed.
      if command mkdir "$_wul_rel_lock" 2>/dev/null; then
        builtin printf 'writer-b\n' > "$_wul_rel_lock/owner"
      fi
      return 0
    fi
    command mv "$@"
  }
  KIT_MDM_MANAGED=false
  _wce_runtime_update_lock_release "$_wul_rel" "$_wul_rel_token"
) > "$_wul_rel.out" 2>&1 || _wul_rel_rc=$?
if [[ "$_wul_rel_rc" -eq 0 && -e "$_wul_rel/injected" ]] \
  && [[ ! -e "$_wul_rel/reclaimed" && ! -e "$_wul_rel/a-acquired" ]] \
  && grep -qx writer-b "$_wul_rel_lock/owner" \
  && [[ "$(command ls -A "$_wul_rel/logs")" == .update.lock ]]; then
  pass "WCE lock: a release holds the reclaim mutex from owner check to rename"
else
  echo "  rc=$_wul_rel_rc" >&2
  command ls -A "$_wul_rel" "$_wul_rel/logs" | sed 's/^/    | /' >&2 || true
  sed 's/^/    | /' "$_wul_rel.out" >&2 || true
  fail "WCE lock: a reclaim during a stalled release let two writers hold the lock"
fi

# A release that finds the reclaim mutex waits for it; one that outlasts the
# wait (a stalled reclaimer) fails without renaming anything.
_wul_relw="$_wul_tmp/release-mutex-stalled"
_wul_relw_lock="$_wul_relw/logs/.update.lock"
_wul_relw_token="starter-kit-update-$_wul_dead-2-2"
_wul_make_lock "$_wul_relw" "$_wul_relw_token"
command mkdir "$_wul_relw_lock.reclaim"
_wul_relw_rc=0
(
  sleep() { :; }
  mv() { : > "$_wul_relw/mv-called"; command mv "$@"; }
  _wce_runtime_update_lock_release "$_wul_relw" "$_wul_relw_token"
) >/dev/null 2>&1 || _wul_relw_rc=$?
if [[ "$_wul_relw_rc" -ne 0 && ! -e "$_wul_relw/mv-called" ]] \
  && grep -qx "$_wul_relw_token" "$_wul_relw_lock/owner" \
  && [[ -d "$_wul_relw_lock.reclaim" ]]; then
  pass "WCE lock: a release never renames while a reclaimer holds the mutex"
else
  echo "  rc=$_wul_relw_rc" >&2
  fail "WCE lock: a release renamed while a reclaimer held the mutex"
fi

# Several reclaimers racing for one abandoned lock are serialized by the
# mutex: exactly one performs the recovery, nobody fails, nothing is left.
_wul_conc="$_wul_tmp/reclaim-concurrent"
_wul_make_lock "$_wul_conc" "$_wul_dead:$_wul_uuid" old
_wul_conc_pids=()
for _wul_case in 1 2 3 4 5 6 7 8; do
  (
    KIT_MDM_MANAGED=false
    _wce_runtime_update_lock_preflight "$_wul_conc"
  ) > "$_wul_conc.$_wul_case.out" 2>&1 &
  _wul_conc_pids+=("$!")
done
_wul_conc_failed=0
for _wul_case in "${_wul_conc_pids[@]}"; do
  wait "$_wul_case" || _wul_conc_failed=$((_wul_conc_failed + 1))
done
_wul_conc_recovered="$({ grep -Fl "$_wul_dead" "$_wul_conc".*.out \
  2>/dev/null || true; } | wc -l | tr -d '[:space:]')"
if [[ "$_wul_conc_failed" -eq 0 && "$_wul_conc_recovered" == 1 ]] \
  && [[ ! -e "$_wul_conc/logs/.update.lock" ]] \
  && ! _wul_lock_residue "$_wul_conc"; then
  pass "WCE reclaim: concurrent reclaimers are serialized to one recovery"
else
  echo "  failed=$_wul_conc_failed recovered=$_wul_conc_recovered" >&2
  fail "WCE reclaim: concurrent reclaimers failed, repeated, or left residue"
fi

# The same serialization, made deterministic: while another reclaimer holds
# the mutex, a second preflight must look again instead of failing. The mutex
# and the lock disappear together when that reclaimer finishes.
_wul_peer="$_wul_tmp/reclaim-peer"
_wul_make_lock "$_wul_peer" "$_wul_dead:$_wul_uuid" old
mkdir "$_wul_peer/logs/.update.lock.reclaim"
(
  sleep 1
  rm -rf "$_wul_peer/logs/.update.lock"
  rmdir "$_wul_peer/logs/.update.lock.reclaim"
) &
_wul_peer_bg=$!
_wul_peer_rc="$(_wul_preflight "$_wul_peer" "$_wul_peer.out" 20)"
wait "$_wul_peer_bg" 2>/dev/null || true
if [[ "$_wul_peer_rc" == 0 ]] && ! _wul_lock_residue "$_wul_peer"; then
  pass "WCE reclaim: a reclaim in progress elsewhere is waited for, not failed"
else
  echo "  rc=$_wul_peer_rc" >&2
  sed 's/^/    | /' "$_wul_peer.out" >&2 || true
  fail "WCE reclaim: losing the mutex to a live reclaimer failed the preflight"
fi

# A concurrent reclaimer can remove the lock between this preflight's look and
# its own age probe, which then fails on a path that is gone. That is not a
# reason to stop: the verdict must come from what is there afterwards.
_wul_vanish="$_wul_tmp/preflight-vanish"
_wul_make_lock "$_wul_vanish" "$_wul_dead:$_wul_uuid" old
_wul_vanish_rc=0
(
  find() {
    if [[ "$1" == "$_wul_vanish/logs/.update.lock/owner" ]]; then
      command rm -rf "$_wul_vanish/logs/.update.lock"
    fi
    command find "$@"
  }
  # shellcheck disable=SC2034 # consumed indirectly by the sourced helper
  _WCE_RUNTIME_LOCK_WAIT_SECONDS=0 KIT_MDM_MANAGED=false
  _wce_runtime_update_lock_preflight "$_wul_vanish"
) > "$_wul_vanish.out" 2>&1 || _wul_vanish_rc=$?
if [[ "$_wul_vanish_rc" -eq 0 && ! -s "$_wul_vanish.out" ]]; then
  pass "WCE preflight: a lock removed mid-evaluation is not reported as held"
else
  echo "  rc=$_wul_vanish_rc" >&2
  sed 's/^/    | /' "$_wul_vanish.out" >&2 || true
  fail "WCE preflight: a lock that had already gone still stopped the run"
fi

# --- A running owner is waited for, within a bound ----------------------------
_wul_wait="$_wul_tmp/preflight-wait"
_wul_make_lock "$_wul_wait" "$_wul_live_pid:$_wul_uuid"
( sleep 1; rm -rf "$_wul_wait/logs/.update.lock" ) &
_wul_wait_bg=$!
_wul_wait_rc="$(_wul_preflight "$_wul_wait" "$_wul_wait.out" 20)"
wait "$_wul_wait_bg" 2>/dev/null || true
if [[ "$_wul_wait_rc" == 0 ]] \
  && grep -Fq "$_wul_live_pid" "$_wul_wait.out"; then
  pass "WCE preflight: a running owner is waited for until it releases"
else
  echo "  rc=$_wul_wait_rc" >&2
  fail "WCE preflight: a running owner was not waited for"
fi

# Acquisition is mkdir followed by the owner write. A preflight that looks in
# between must not report a writer that is merely starting as unverifiable.
_wul_starting="$_wul_tmp/preflight-starting"
mkdir -p "$_wul_starting/logs/.update.lock"
(
  sleep 1
  printf '%s\n' "$_wul_live_pid:$_wul_uuid" \
    > "$_wul_starting/logs/.update.lock/owner"
  sleep 2
  rm -rf "$_wul_starting/logs/.update.lock"
) &
_wul_starting_bg=$!
_wul_starting_rc="$(_wul_preflight "$_wul_starting" "$_wul_starting.out" 20)"
wait "$_wul_starting_bg" 2>/dev/null || true
if [[ "$_wul_starting_rc" == 0 ]]; then
  pass "WCE preflight: a writer between mkdir and owner write is waited for"
else
  echo "  rc=$_wul_starting_rc" >&2
  sed 's/^/    | /' "$_wul_starting.out" >&2 || true
  fail "WCE preflight: a starting writer was reported as an unverifiable lock"
fi

# --- The low-level helper reports, and still never reclaims -------------------
_wul_diag="$_wul_tmp/diagnostic"
_wul_make_lock "$_wul_diag" foreign-updater old
_wul_diag_rc=0
_WCE_RUNTIME_LOCK_FAILURE_NOTE="caller-note-marker" \
  _wce_with_runtime_update_lock "$_wul_diag" true \
  > "$_wul_diag.out" 2> "$_wul_diag.err" || _wul_diag_rc=$?
if [[ "$_wul_diag_rc" -eq 75 ]] \
  && grep -Fq "$_wul_diag/logs/.update.lock" "$_wul_diag.err" \
  && grep -Fq caller-note-marker "$_wul_diag.err" \
  && [[ ! -s "$_wul_diag.out" ]] \
  && grep -qx foreign-updater "$_wul_diag/logs/.update.lock/owner"; then
  pass "WCE lock: contention is diagnosed on stderr with the caller's note"
else
  fail "WCE lock: contention exited 75 without naming the lock"
fi

_wul_lowlevel="$_wul_tmp/lowlevel-stale"
_wul_make_lock "$_wul_lowlevel" "$_wul_dead:$_wul_uuid" old
cp -p "$_wul_lowlevel/logs/.update.lock/owner" "$_wul_lowlevel.owner"
_wul_lowlevel_rc=0
_wce_with_runtime_update_lock "$_wul_lowlevel" true \
  >/dev/null 2> "$_wul_lowlevel.err" || _wul_lowlevel_rc=$?
if [[ "$_wul_lowlevel_rc" -eq 75 ]] \
  && cmp -s "$_wul_lowlevel/logs/.update.lock/owner" "$_wul_lowlevel.owner" \
  && ! _wul_lock_residue "$_wul_lowlevel" \
  && grep -Fq "$_wul_dead" "$_wul_lowlevel.err"; then
  pass "WCE lock: acquisition itself never reclaims, even a reclaimable lock"
else
  fail "WCE lock: the low-level acquire path reclaimed an existing lock"
fi

_wul_unreleased="$_wul_tmp/release-failure"
mkdir -p "$_wul_unreleased"
_wul_break_release() { printf 'intruder\n' > "$1/logs/.update.lock/owner"; }
_wul_unreleased_rc=0
# The caller's note describes work an acquisition failure left undone. A
# release failure comes after the callback finished, so it must not appear;
# the caller's release note (setup stops before its final steps) must.
_WCE_RUNTIME_LOCK_FAILURE_NOTE="caller-note-marker" \
_WCE_RUNTIME_LOCK_RELEASE_NOTE="release-note-marker" \
  _wce_with_runtime_update_lock "$_wul_unreleased" \
  _wul_break_release "$_wul_unreleased" \
  >/dev/null 2> "$_wul_unreleased.err" || _wul_unreleased_rc=$?
if [[ "$_wul_unreleased_rc" -eq 74 ]] \
  && grep -Fq "$_wul_unreleased/logs/.update.lock" "$_wul_unreleased.err" \
  && ! grep -Fq caller-note-marker "$_wul_unreleased.err" \
  && grep -Fq release-note-marker "$_wul_unreleased.err" \
  && grep -qx intruder "$_wul_unreleased/logs/.update.lock/owner"; then
  pass "WCE lock: a failed release is diagnosed without the acquisition note"
else
  sed 's/^/    | /' "$_wul_unreleased.err" >&2 || true
  fail "WCE lock: a failed release exited 74 without naming the lock, or claimed work was left undone"
fi

# --- npm ci after update: the announced exit code is the real one -------------
# maybe_install_web_content_deps acquires the lock again after run_update
# released it. The helper's diagnosis says "exit 75" / "exit 74"; the function
# must return that code (not 1) and, on 75, note that the kit files are done.
_wul_npm_check() { # <75|74>
  local code="$1" root="$_wul_tmp/npm-$1" rc=0
  local skill="$root/.claude/skills/web-content-extraction"
  mkdir -p "$skill/logs"
  printf '{}\n' > "$skill/package.json"
  if [[ "$code" == 75 ]]; then
    _wul_make_lock "$skill" foreign-updater old
  fi
  (
    CLAUDE_DIR="$root/.claude"
    # shellcheck disable=SC2034 # consumed indirectly by the sourced function
    INSTALL_SKILLS=true DRY_RUN=false KIT_MDM_MANAGED=false
    unset WCE_SKIP_NPM_INSTALL
    # shellcheck disable=SC2034 # consumed indirectly by the sourced helper
    STR_WCE_LOCK_DEPS_NOTE="deps-note-marker"
    # shellcheck disable=SC2034 # consumed indirectly by the sourced helper
    STR_WCE_LOCK_RELEASE_NOTE="release-note-marker"
    _deploy_mdm_managed() { return 1; }
    _fresh_wce_pair_is_skipped() { return 1; }
    # Never run npm here; stand in for the callback.
    if [[ "$code" == 74 ]]; then
      _wce_run_non_mdm_npm_ci() { _wul_break_release "$1"; }
    else
      _wce_run_non_mdm_npm_ci() { :; }
    fi
    maybe_install_web_content_deps
  ) > "$root.out" 2>&1 || rc=$?
  if [[ "$rc" -eq "$code" ]] \
    && grep -Fq "$skill/logs/.update.lock" "$root.out" \
    && { [[ "$code" == 74 ]] || grep -Fq deps-note-marker "$root.out"; } \
    && { [[ "$code" == 75 ]] || ! grep -Fq deps-note-marker "$root.out"; } \
    && { [[ "$code" == 74 ]] || ! grep -Fq release-note-marker "$root.out"; } \
    && { [[ "$code" == 75 ]] || grep -Fq release-note-marker "$root.out"; }; then
    pass "WCE npm ci: lock exit $code is returned as announced"
  else
    echo "  rc=$rc" >&2
    sed 's/^/    | /' "$root.out" >&2 || true
    fail "WCE npm ci: lock exit $code was returned as a different code or misnoted"
  fi
}
# After a late 75/74, setup stops before the manifest, saved config, and
# plugin setup, so rerunning the same command is the only complete recovery.
# The shipped notes must not offer a bare `npm ci` as an equal alternative.
_wul_notes_ok=true
for _wul_lang in en ja; do
  _wul_notes="$(
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/i18n/$_wul_lang/strings.sh" >/dev/null 2>&1
    builtin printf '%s\n%s\n' "${STR_WCE_LOCK_DEPS_NOTE:-}" \
      "${STR_WCE_LOCK_RELEASE_NOTE:-}"
  )"
  if [[ "$_wul_notes" == *"npm ci --omit=dev"* ]] \
    || [[ "$(grep -c manifest <<< "$_wul_notes")" -ne 2 ]]; then
    _wul_notes_ok=false
  fi
done
if [[ "$_wul_notes_ok" == true ]]; then
  pass "WCE lock notes: late 75/74 notes name the skipped final steps and only offer a rerun"
else
  fail "WCE lock notes: a late 75/74 note offers npm ci alone or omits the skipped final steps"
fi

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  _wul_npm_check 75
  _wul_npm_check 74
else
  skip "WCE npm ci: node/npm not on PATH"
fi

# --- setup_deploy (update) checks the lock before backup or any write ---------
_wul_check_update_preflight() { # <blocked|stale|mdm>
  local mode="$1"
  local case_root="$_wul_tmp/update-preflight-$1"
  local case_home="$case_root/home"
  local case_claude="$case_home/.claude"
  local case_skill="$case_claude/skills/web-content-extraction"
  local case_rc=0 backup_count ok=true
  mkdir -p "$case_skill" "$case_claude/.starter-kit-snapshot"
  printf '{"marker":"before"}\n' > "$case_claude/settings.json"
  printf 'claude-md-before\n' > "$case_claude/CLAUDE.md"
  printf '{}\n' > "$case_claude/.starter-kit-manifest.json"
  if [[ "$mode" == stale ]]; then
    _wul_make_lock "$case_skill" "$_wul_dead:$_wul_uuid" old
  else
    _wul_make_lock "$case_skill" foreign-updater old
  fi
  cp -p "$case_claude/settings.json" "$case_root/settings.saved"
  cp -p "$case_claude/CLAUDE.md" "$case_root/claude-md.saved"

  (
    HOME="$case_home"
    # shellcheck source=setup.sh
    source "$PROJECT_DIR/setup.sh"
    # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
    UPDATE_MODE=true DRY_RUN=false KIT_MDM_MANAGED=false
    # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
    [[ "$mode" != mdm ]] || KIT_MDM_MANAGED=true
    # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
    INSTALL_SKILLS=true WIZARD_NONINTERACTIVE=true
    # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
    _WCE_RUNTIME_LOCK_WAIT_SECONDS=0 _CONFIG_ALLOWED_KEYS=""
    unset KIT_MDM_OUTER_TRANSACTION KIT_MDM_OUTER_TRANSACTION_BACKUP
    _prepare_mdm_claude_root() { :; }
    _has_user_customizations() { return 1; }
    backup_existing() { : > "$case_root/backup-called"; }
    _snapshot_exists() { return 0; }
    _validate_dismissed_features() { :; }
    _validate_plugin_csv() { :; }
    run_update() { : > "$case_root/update-called"; }
    _detect_and_write_pending_features() { :; }
    _detect_and_offer_new_plugins() { :; }
    maybe_install_web_content_deps() { :; }
    setup_deploy
  ) > "$case_root/out" 2>&1 || case_rc=$?
  backup_count="$(find "$case_home" -maxdepth 1 \
    -name '.claude.backup.*' -print | wc -l | tr -d '[:space:]')"

  cmp -s "$case_claude/settings.json" "$case_root/settings.saved" || ok=false
  cmp -s "$case_claude/CLAUDE.md" "$case_root/claude-md.saved" || ok=false
  [[ "$backup_count" == 0 ]] || ok=false
  case "$mode" in
    blocked)
      [[ "$case_rc" -eq 75 ]] || ok=false
      [[ ! -e "$case_root/backup-called" \
        && ! -e "$case_root/update-called" ]] || ok=false
      grep -Fq "$case_skill/logs/.update.lock" "$case_root/out" || ok=false
      grep -qx foreign-updater "$case_skill/logs/.update.lock/owner" \
        || ok=false
      ;;
    stale)
      [[ "$case_rc" -eq 0 ]] || ok=false
      [[ -e "$case_root/backup-called" \
        && -e "$case_root/update-called" ]] || ok=false
      [[ ! -e "$case_skill/logs/.update.lock" ]] || ok=false
      _wul_lock_residue "$case_skill" && ok=false
      grep -Fq "$_wul_dead" "$case_root/out" || ok=false
      ;;
    mdm)
      # MDM never takes this lock, so the preflight must not run either.
      [[ "$case_rc" -eq 0 ]] || ok=false
      [[ -e "$case_root/backup-called" \
        && -e "$case_root/update-called" ]] || ok=false
      grep -qx foreign-updater "$case_skill/logs/.update.lock/owner" \
        || ok=false
      ;;
  esac
  if [[ "$ok" == true ]]; then
    pass "WCE update preflight ($mode): the lock is settled before backup and update"
  else
    echo "  rc=$case_rc backups=$backup_count" >&2
    sed 's/^/    | /' "$case_root/out" >&2 || true
    fail "WCE update preflight ($mode): backup or update ran in the wrong lock state"
  fi
}
_wul_check_update_preflight blocked
_wul_check_update_preflight stale
_wul_check_update_preflight mdm

# The fresh / full re-setup branch recovers the same abandoned lock before it
# creates any deployment state.
_wul_fresh_stale="$_wul_tmp/fresh-stale"
_wul_fresh_stale_skill="$_wul_fresh_stale/home/.claude/skills/web-content-extraction"
_wul_make_lock "$_wul_fresh_stale_skill" "$_wul_dead:$_wul_uuid" old
printf '{}\n' > "$_wul_fresh_stale/home/.claude/settings.json"
printf '{}\n' > "$_wul_fresh_stale/home/.claude/.starter-kit-manifest.json"
_wul_fresh_stale_rc=0
(
  HOME="$_wul_fresh_stale/home"
  # shellcheck source=setup.sh
  source "$PROJECT_DIR/setup.sh"
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  UPDATE_MODE=false DRY_RUN=false KIT_MDM_MANAGED=false
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  INSTALL_AGENTS=false INSTALL_RULES=false INSTALL_COMMANDS=false
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  INSTALL_SKILLS=true WIZARD_NONINTERACTIVE=true
  # shellcheck disable=SC2034 # consumed indirectly by sourced setup_deploy
  _WCE_RUNTIME_LOCK_WAIT_SECONDS=0
  unset KIT_MDM_OUTER_TRANSACTION KIT_MDM_OUTER_TRANSACTION_BACKUP
  section() { :; }
  warn_existing_claude_reconfigure() { :; }
  _setup_deploy_fresh_body() {
    _wce_runtime_update_lock_owner_matches \
      "$CLAUDE_DIR/skills/web-content-extraction" \
      "$_WCE_RUNTIME_LOCK_TOKEN" || return 1
    : > "$_wul_fresh_stale/body-called"
    _setup_write_fresh_deploy_state "$7"
  }
  setup_deploy
) > "$_wul_fresh_stale/out" 2>&1 || _wul_fresh_stale_rc=$?
if [[ "$_wul_fresh_stale_rc" -eq 0 && -e "$_wul_fresh_stale/body-called" ]] \
  && [[ ! -e "$_wul_fresh_stale_skill/logs/.update.lock" ]] \
  && ! _wul_lock_residue "$_wul_fresh_stale_skill" \
  && grep -Fq "$_wul_dead" "$_wul_fresh_stale/out"; then
  pass "WCE fresh preflight: an abandoned lock is recovered before deployment"
else
  echo "  rc=$_wul_fresh_stale_rc" >&2
  sed 's/^/    | /' "$_wul_fresh_stale/out" >&2 || true
  fail "WCE fresh preflight: an abandoned lock still blocked re-setup"
fi

# --- Dry-run inspects the real lock read-only and only warns ------------------
_wul_dry_notice() { # <real-claude-dir> <output-file>
  local rc=0
  (
    # shellcheck disable=SC2034 # consumed indirectly by the sourced helper
    KIT_MDM_MANAGED=false
    # Fixed markers: another test file may have loaded either language.
    # shellcheck disable=SC2034 # consumed indirectly by the sourced helper
    STR_WCE_LOCK_DRYRUN_BLOCKED="dry-run-blocked-marker"
    # shellcheck disable=SC2034 # consumed indirectly by the sourced helper
    STR_WCE_LOCK_DRYRUN_RECOVERABLE="dry-run-recoverable-marker"
    _wce_runtime_update_lock_dryrun_notice "$1"
  ) > "$2" 2>&1 || rc=$?
  printf '%s' "$rc"
}
_wul_dry="$_wul_tmp/dryrun-notice"
_wul_dry_skill="$_wul_dry/blocked/.claude/skills/web-content-extraction"
_wul_make_lock "$_wul_dry_skill" foreign-updater old
cp -p "$_wul_dry_skill/logs/.update.lock/owner" "$_wul_dry/blocked.owner"
_wul_dry_blocked_rc="$(_wul_dry_notice "$_wul_dry/blocked/.claude" \
  "$_wul_dry/blocked.out")"
_wul_dry_stale_skill="$_wul_dry/stale/.claude/skills/web-content-extraction"
_wul_make_lock "$_wul_dry_stale_skill" "$_wul_dead:$_wul_uuid" old
cp -p "$_wul_dry_stale_skill/logs/.update.lock/owner" "$_wul_dry/stale.owner"
_wul_dry_stale_rc="$(_wul_dry_notice "$_wul_dry/stale/.claude" \
  "$_wul_dry/stale.out")"
mkdir -p "$_wul_dry/free/.claude/skills/web-content-extraction"
_wul_dry_free_rc="$(_wul_dry_notice "$_wul_dry/free/.claude" \
  "$_wul_dry/free.out")"
if [[ "$_wul_dry_blocked_rc" == 0 && "$_wul_dry_stale_rc" == 0 \
  && "$_wul_dry_free_rc" == 0 ]] \
  && grep -Fq dry-run-blocked-marker "$_wul_dry/blocked.out" \
  && grep -Fq "$_wul_dry_skill/logs/.update.lock" "$_wul_dry/blocked.out" \
  && grep -Fq dry-run-recoverable-marker "$_wul_dry/stale.out" \
  && grep -Fq "$_wul_dry_stale_skill/logs/.update.lock" "$_wul_dry/stale.out" \
  && [[ ! -s "$_wul_dry/free.out" ]] \
  && cmp -s "$_wul_dry_skill/logs/.update.lock/owner" "$_wul_dry/blocked.owner" \
  && cmp -s "$_wul_dry_stale_skill/logs/.update.lock/owner" \
    "$_wul_dry/stale.owner" \
  && ! _wul_lock_residue "$_wul_dry_stale_skill"; then
  pass "WCE dry-run: a held lock is reported without being touched"
else
  echo "  rc=$_wul_dry_blocked_rc/$_wul_dry_stale_rc/$_wul_dry_free_rc" >&2
  fail "WCE dry-run: the real lock was not reported, or was modified"
fi

kill "$_wul_live_pid" 2>/dev/null || true
wait "$_wul_live_pid" 2>/dev/null || true

rm -rf "$_wul_tmp"
