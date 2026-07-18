#!/bin/bash
# tests/unit/test-wce-backup-lifecycle.sh
# The MDM transition preserves a pre-existing node_modules directory beside
# the managed activation. Setup/update/uninstall must never consume that backup.

_wbl_inode() {
  if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
    stat -f '%d:%i' "$1"
  else
    stat -c '%d:%i' "$1"
  fi
}

_wbl_tmp="$(mktemp -d)"
_wbl_source="$_wbl_tmp/source"
_wbl_home="$_wbl_tmp/home"
_wbl_skill="$_wbl_home/.claude/skills/web-content-extraction"
_wbl_backup="$_wbl_skill/.node-modules.pre-mdm.KEEP01"
mkdir -p "$_wbl_source" "$_wbl_backup"
printf 'old dependency bytes\n' > "$_wbl_backup/preserved.txt"
printf 'v1\n' > "$_wbl_source/SKILL.md"

_wbl_before="$(_wbl_inode "$_wbl_backup")"
_wbl_copy_rc=0
(
  PROJECT_DIR="$PROJECT_DIR"
  CLAUDE_DIR="$_wbl_home/.claude"
  HOME="$_wbl_home"
  _SETUP_TMP_FILES=()
  # shellcheck source=lib/deploy.sh
  source "$PROJECT_DIR/lib/deploy.sh"
  _deploy_mdm_managed() { return 1; }
  _copy_distribution_tree "$_wbl_source" "$_wbl_skill" overwrite

  # The update path replaces individual managed files as well. Exercise that
  # primitive with an unchanged baseline and a new kit version.
  mkdir -p "$_wbl_tmp/snapshot" "$_wbl_tmp/new"
  cp "$_wbl_skill/SKILL.md" "$_wbl_tmp/snapshot/SKILL.md"
  printf 'v2\n' > "$_wbl_tmp/new/SKILL.md"
  # shellcheck source=lib/snapshot.sh
  source "$PROJECT_DIR/lib/snapshot.sh"
  # shellcheck source=lib/update.sh
  source "$PROJECT_DIR/lib/update.sh"
  _update_mdm_managed() { return 1; }
  _update_file "$_wbl_skill/SKILL.md" \
    "$_wbl_tmp/snapshot/SKILL.md" "$_wbl_tmp/new/SKILL.md"
) > "$_wbl_tmp/copy-update.out" 2>&1 || _wbl_copy_rc=$?
_wbl_after="$(_wbl_inode "$_wbl_backup" 2>/dev/null || true)"

if [[ "$_wbl_copy_rc" -eq 0 ]] \
  && [[ "$_wbl_before" == "$_wbl_after" ]] \
  && grep -qx 'old dependency bytes' "$_wbl_backup/preserved.txt" \
  && grep -qx 'v2' "$_wbl_skill/SKILL.md"; then
  pass "WCE backup lifecycle: fresh and update file deployment preserve the backup inode and bytes"
else
  fail "WCE backup lifecycle: fresh/update deployment changed the pre-MDM backup (rc=$_wbl_copy_rc)"
fi

# Current manifests must name only disposable runtime leaves. This also means
# the next update rewrites an old broad cleanup contract before a later
# uninstall, while uninstall.sh retains an explicit compatibility branch for
# machines uninstalled directly from that old manifest.
_wbl_cleanup_json="$(
  (
    # shellcheck disable=SC2034  # consumed indirectly by cleanup_paths_json
    CLAUDE_DIR="$_wbl_home/.claude"
    HOME="$_wbl_home"
    _SETUP_TMP_FILES=()
    # shellcheck source=lib/deploy.sh
    source "$PROJECT_DIR/lib/deploy.sh"
    cleanup_paths_json
  ) 2>/dev/null
)"
if jq -e --arg root "$_wbl_skill" '
    index($root) == null
    and index($root + "/node_modules") != null
    and index($root + "/logs") != null
  ' <<< "$_wbl_cleanup_json" >/dev/null; then
  pass "WCE backup lifecycle: manifest cleanup is leaf-scoped"
else
  fail "WCE backup lifecycle: manifest still authorizes recursive skill cleanup"
fi

_wbl_bin="$_wbl_tmp/bin"
mkdir -p "$_wbl_bin"
ln -s "$(command -v jq)" "$_wbl_bin/jq"

_wbl_run_uninstall() { # <home> <output>
  local case_home="$1" output="$2"
  local rc=0
  printf 'y\n' | HOME="$case_home" \
    STARTER_KIT_DIR="$case_home/nonexistent-kit" \
    PATH="$_wbl_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$PROJECT_DIR/uninstall.sh" > "$output" 2>&1 || rc=$?
  return "$rc"
}

# A fresh runtime-updater lock owns the whole package/runtime mutation range.
# Uninstall must stop before touching any tracked or cleanup target.
_wbl_active_home="$_wbl_tmp/uninstall-active-lock"
_wbl_active_skill="$_wbl_active_home/.claude/skills/web-content-extraction"
mkdir -p "$_wbl_active_skill/logs/.update.lock" \
  "$_wbl_active_skill/node_modules"
printf 'package\n' > "$_wbl_active_skill/package.json"
printf 'lockfile\n' > "$_wbl_active_skill/package-lock.json"
printf 'dependency\n' > "$_wbl_active_skill/node_modules/marker"
printf 'runtime-updater\n' > "$_wbl_active_skill/logs/.update.lock/owner"
jq -n \
  --arg package "$_wbl_active_skill/package.json" \
  --arg lockfile "$_wbl_active_skill/package-lock.json" \
  --arg modules "$_wbl_active_skill/node_modules" \
  --arg logs "$_wbl_active_skill/logs" \
  '{version:"2", profile:"standard", timestamp:"test",
    files:[$package,$lockfile], cleanup_paths:[$modules,$logs]}' \
  > "$_wbl_active_home/.claude/.starter-kit-manifest.json"
_wbl_active_rc=0
_wbl_run_uninstall "$_wbl_active_home" "$_wbl_tmp/uninstall-active-lock.out" \
  || _wbl_active_rc=$?
if [[ "$_wbl_active_rc" -ne 0 ]] \
  && grep -qx 'package' "$_wbl_active_skill/package.json" \
  && grep -qx 'lockfile' "$_wbl_active_skill/package-lock.json" \
  && grep -qx 'dependency' "$_wbl_active_skill/node_modules/marker" \
  && [[ "$(< "$_wbl_active_skill/logs/.update.lock/owner")" == runtime-updater ]] \
  && [[ -f "$_wbl_active_home/.claude/.starter-kit-manifest.json" ]] \
  && ! grep -q 'Uninstall complete' "$_wbl_tmp/uninstall-active-lock.out"; then
  pass "WCE backup lifecycle: active runtime lock blocks uninstall mutation"
else
  fail "WCE backup lifecycle: uninstall ignored or removed an active runtime lock"
fi

# Lock age is not proof that its owner is dead. Even an old lock fails closed
# until an administrator explicitly confirms and removes it.
_wbl_stale_home="$_wbl_tmp/uninstall-stale-lock"
_wbl_stale_skill="$_wbl_stale_home/.claude/skills/web-content-extraction"
mkdir -p "$_wbl_stale_skill/logs/.update.lock" \
  "$_wbl_stale_skill/node_modules"
printf 'package\n' > "$_wbl_stale_skill/package.json"
printf 'lockfile\n' > "$_wbl_stale_skill/package-lock.json"
printf 'dependency\n' > "$_wbl_stale_skill/node_modules/marker"
printf 'dead-updater\n' > "$_wbl_stale_skill/logs/.update.lock/owner"
touch -t 200001010000 "$_wbl_stale_skill/logs/.update.lock"
jq -n \
  --arg package "$_wbl_stale_skill/package.json" \
  --arg lockfile "$_wbl_stale_skill/package-lock.json" \
  --arg modules "$_wbl_stale_skill/node_modules" \
  --arg logs "$_wbl_stale_skill/logs" \
  '{version:"2", profile:"standard", timestamp:"test",
    files:[$package,$lockfile], cleanup_paths:[$modules,$logs]}' \
  > "$_wbl_stale_home/.claude/.starter-kit-manifest.json"
_wbl_stale_rc=0
_wbl_run_uninstall "$_wbl_stale_home" "$_wbl_tmp/uninstall-stale-lock.out" \
  || _wbl_stale_rc=$?
if [[ "$_wbl_stale_rc" -ne 0 ]] \
  && grep -qx 'package' "$_wbl_stale_skill/package.json" \
  && grep -qx 'lockfile' "$_wbl_stale_skill/package-lock.json" \
  && grep -qx 'dependency' "$_wbl_stale_skill/node_modules/marker" \
  && [[ "$(< "$_wbl_stale_skill/logs/.update.lock/owner")" == dead-updater ]] \
  && [[ -f "$_wbl_stale_home/.claude/.starter-kit-manifest.json" ]] \
  && grep -q 'remove it manually' "$_wbl_tmp/uninstall-stale-lock.out" \
  && ! grep -q 'Uninstall complete' "$_wbl_tmp/uninstall-stale-lock.out"; then
  pass "WCE backup lifecycle: stale runtime lock also fails closed"
else
  fail "WCE backup lifecycle: uninstall automatically reclaimed a stale lock"
fi

# If another owner replaces the lock after acquisition, token-bound release
# must preserve that foreign lock and the manifest needed to retry.
_wbl_race_home="$_wbl_tmp/uninstall-lock-race"
_wbl_race_skill="$_wbl_race_home/.claude/skills/web-content-extraction"
_wbl_race_bin="$_wbl_tmp/race-bin"
mkdir -p "$_wbl_race_skill/logs" "$_wbl_race_bin"
printf 'package\n' > "$_wbl_race_skill/package.json"
ln -s "$(command -v jq)" "$_wbl_race_bin/jq"
cat > "$_wbl_race_bin/rm" <<'EOF'
#!/bin/bash
case " $* " in
  *./package.json*)
    /bin/rm -rf "$WCE_RACE_LOCK" || exit 1
    /bin/mkdir "$WCE_RACE_LOCK" || exit 1
    printf 'runtime-racer\n' > "$WCE_RACE_LOCK/owner" || exit 1
    ;;
esac
exec /bin/rm "$@"
EOF
chmod +x "$_wbl_race_bin/rm"
jq -n \
  --arg package "$_wbl_race_skill/package.json" \
  --arg logs "$_wbl_race_skill/logs" \
  '{version:"2", profile:"standard", timestamp:"test",
    files:[$package], cleanup_paths:[$logs]}' \
  > "$_wbl_race_home/.claude/.starter-kit-manifest.json"
_wbl_race_rc=0
printf 'y\n' | HOME="$_wbl_race_home" \
  WCE_RACE_LOCK="$_wbl_race_skill/logs/.update.lock" \
  STARTER_KIT_DIR="$_wbl_race_home/nonexistent-kit" \
  PATH="$_wbl_race_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$PROJECT_DIR/uninstall.sh" > "$_wbl_tmp/uninstall-lock-race.out" 2>&1 \
  || _wbl_race_rc=$?
if [[ "$_wbl_race_rc" -ne 0 ]] \
  && [[ "$(< "$_wbl_race_skill/logs/.update.lock/owner")" == runtime-racer ]] \
  && [[ -f "$_wbl_race_home/.claude/.starter-kit-manifest.json" ]] \
  && grep -q 'Failed to release' "$_wbl_tmp/uninstall-lock-race.out"; then
  pass "WCE backup lifecycle: token-bound release preserves a replacement lock"
else
  fail "WCE backup lifecycle: uninstall removed a replacement runtime lock"
fi

# Signal traps must release only the lock token acquired by this uninstall,
# while keeping the manifest and untouched payload available for retry.
_wbl_signal_home="$_wbl_tmp/uninstall-lock-signal"
_wbl_signal_skill="$_wbl_signal_home/.claude/skills/web-content-extraction"
_wbl_signal_bin="$_wbl_tmp/signal-bin"
mkdir -p "$_wbl_signal_skill/logs" "$_wbl_signal_bin"
printf 'package\n' > "$_wbl_signal_skill/package.json"
ln -s "$(command -v jq)" "$_wbl_signal_bin/jq"
cat > "$_wbl_signal_bin/rm" <<'EOF'
#!/bin/bash
case " $* " in
  *./package.json*) kill -TERM "$PPID"; exit 1 ;;
esac
exec /bin/rm "$@"
EOF
chmod +x "$_wbl_signal_bin/rm"
jq -n --arg package "$_wbl_signal_skill/package.json" \
  '{version:"2", profile:"standard", timestamp:"test",
    files:[$package], cleanup_paths:[]}' \
  > "$_wbl_signal_home/.claude/.starter-kit-manifest.json"
_wbl_signal_rc=0
printf 'y\n' | HOME="$_wbl_signal_home" \
  STARTER_KIT_DIR="$_wbl_signal_home/nonexistent-kit" \
  PATH="$_wbl_signal_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$PROJECT_DIR/uninstall.sh" > "$_wbl_tmp/uninstall-lock-signal.out" 2>&1 \
  || _wbl_signal_rc=$?
if [[ "$_wbl_signal_rc" -ne 0 ]] \
  && [[ ! -e "$_wbl_signal_skill/logs/.update.lock" ]] \
  && grep -qx 'package' "$_wbl_signal_skill/package.json" \
  && [[ -f "$_wbl_signal_home/.claude/.starter-kit-manifest.json" ]]; then
  pass "WCE backup lifecycle: signal trap releases the uninstall-owned lock"
else
  fail "WCE backup lifecycle: signal trap leaked its lock or lost retry state"
fi

# New leaf-scoped manifest: remove the managed payload and runtime leaves, but
# retain real and unusual backup entries without changing their inode/content.
_wbl_case_home="$_wbl_tmp/uninstall-current"
_wbl_case_skill="$_wbl_case_home/.claude/skills/web-content-extraction"
_wbl_case_backup="$_wbl_case_skill/.node-modules.pre-mdm.KEEP02"
_wbl_external_runtime="$_wbl_tmp/external-runtime"
_wbl_external_backup="$_wbl_tmp/external-backup"
mkdir -p "$_wbl_case_backup" "$_wbl_external_runtime" \
  "$_wbl_external_backup" "$_wbl_case_skill/logs"
printf 'managed\n' > "$_wbl_case_skill/SKILL.md"
printf 'preserve me\n' > "$_wbl_case_backup/marker"
printf 'runtime target\n' > "$_wbl_external_runtime/marker"
printf 'foreign target\n' > "$_wbl_external_backup/marker"
ln -s "$_wbl_external_runtime" "$_wbl_case_skill/node_modules"
ln -s "$_wbl_external_backup" \
  "$_wbl_case_skill/.node-modules.pre-mdm.FOREIGN"
_wbl_case_inode="$(_wbl_inode "$_wbl_case_backup")"
jq -n \
  --arg file "$_wbl_case_skill/SKILL.md" \
  --arg modules "$_wbl_case_skill/node_modules" \
  --arg logs "$_wbl_case_skill/logs" \
  '{version:"2", profile:"standard", timestamp:"test", files:[$file],
    cleanup_paths:[$modules,$logs]}' \
  > "$_wbl_case_home/.claude/.starter-kit-manifest.json"
_wbl_uninstall_rc=0
_wbl_run_uninstall "$_wbl_case_home" "$_wbl_tmp/uninstall-current.out" \
  || _wbl_uninstall_rc=$?

if [[ "$_wbl_uninstall_rc" -eq 0 ]] \
  && [[ ! -e "$_wbl_case_skill/SKILL.md" ]] \
  && [[ ! -e "$_wbl_case_skill/node_modules" && ! -L "$_wbl_case_skill/node_modules" ]] \
  && [[ ! -e "$_wbl_case_skill/logs" ]] \
  && [[ "$(_wbl_inode "$_wbl_case_backup")" == "$_wbl_case_inode" ]] \
  && grep -qx 'preserve me' "$_wbl_case_backup/marker" \
  && [[ -L "$_wbl_case_skill/.node-modules.pre-mdm.FOREIGN" ]] \
  && grep -qx 'runtime target' "$_wbl_external_runtime/marker" \
  && grep -qx 'foreign target' "$_wbl_external_backup/marker"; then
  pass "WCE backup lifecycle: uninstall removes managed runtime without consuming backups"
else
  fail "WCE backup lifecycle: uninstall removed or changed a preserved backup"
fi

# Old manifests named the whole skill directory. The compatibility path must
# interpret that value selectively rather than recursively deleting it.
_wbl_legacy_home="$_wbl_tmp/uninstall-legacy"
_wbl_legacy_skill="$_wbl_legacy_home/.claude/skills/web-content-extraction"
_wbl_legacy_backup="$_wbl_legacy_skill/.node-modules.pre-mdm.KEEP03"
mkdir -p "$_wbl_legacy_backup" "$_wbl_legacy_skill/node_modules" \
  "$_wbl_legacy_skill/logs"
printf 'legacy backup\n' > "$_wbl_legacy_backup/marker"
_wbl_legacy_inode="$(_wbl_inode "$_wbl_legacy_backup")"
jq -n --arg root "$_wbl_legacy_skill" \
  '{version:"2", profile:"standard", timestamp:"test", files:[],
    cleanup_paths:[$root]}' \
  > "$_wbl_legacy_home/.claude/.starter-kit-manifest.json"
_wbl_legacy_rc=0
_wbl_run_uninstall "$_wbl_legacy_home" "$_wbl_tmp/uninstall-legacy.out" \
  || _wbl_legacy_rc=$?

if [[ "$_wbl_legacy_rc" -eq 0 ]] \
  && [[ ! -e "$_wbl_legacy_skill/node_modules" ]] \
  && [[ ! -e "$_wbl_legacy_skill/logs" ]] \
  && [[ "$(_wbl_inode "$_wbl_legacy_backup")" == "$_wbl_legacy_inode" ]] \
  && grep -qx 'legacy backup' "$_wbl_legacy_backup/marker"; then
  pass "WCE backup lifecycle: legacy broad cleanup is interpreted selectively"
else
  fail "WCE backup lifecycle: legacy manifest recursively removed the pre-MDM backup"
fi

# A symlinked skill directory is not a cleanup authority. Neither the link nor
# anything in its referent may be traversed or removed.
_wbl_link_home="$_wbl_tmp/uninstall-symlink"
_wbl_link_skill="$_wbl_link_home/.claude/skills/web-content-extraction"
_wbl_referent="$_wbl_tmp/foreign-skill"
mkdir -p "$_wbl_link_home/.claude/skills" \
  "$_wbl_referent/node_modules" "$_wbl_referent/logs" \
  "$_wbl_referent/.node-modules.pre-mdm.FOREIGN"
printf 'outside\n' > "$_wbl_referent/node_modules/marker"
printf 'outside log\n' > "$_wbl_referent/logs/marker"
printf 'outside backup\n' \
  > "$_wbl_referent/.node-modules.pre-mdm.FOREIGN/marker"
ln -s "$_wbl_referent" "$_wbl_link_skill"
jq -n --arg root "$_wbl_link_skill" \
  '{version:"2", profile:"standard", timestamp:"test", files:[],
    cleanup_paths:[$root]}' \
  > "$_wbl_link_home/.claude/.starter-kit-manifest.json"
_wbl_link_rc=0
_wbl_run_uninstall "$_wbl_link_home" "$_wbl_tmp/uninstall-symlink.out" \
  || _wbl_link_rc=$?

if [[ "$_wbl_link_rc" -ne 0 ]] \
  && [[ -L "$_wbl_link_skill" ]] \
  && [[ -f "$_wbl_link_home/.claude/.starter-kit-manifest.json" ]] \
  && grep -qx 'outside' "$_wbl_referent/node_modules/marker" \
  && grep -qx 'outside log' "$_wbl_referent/logs/marker" \
  && grep -qx 'outside backup' \
    "$_wbl_referent/.node-modules.pre-mdm.FOREIGN/marker" \
  && grep -q 'Existing or unsafe web-content-extraction update lock' \
    "$_wbl_tmp/uninstall-symlink.out" \
  && ! grep -q 'Uninstall complete' "$_wbl_tmp/uninstall-symlink.out"; then
  pass "WCE backup lifecycle: unsafe cleanup retains retry manifest"
else
  fail "WCE backup lifecycle: unsafe cleanup traversed a link or lost its retry manifest"
fi

rm -rf "$_wbl_tmp"
