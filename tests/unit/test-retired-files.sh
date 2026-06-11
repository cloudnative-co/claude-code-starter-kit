#!/bin/bash
# tests/unit/test-retired-files.sh - retired-file sweep / update hook deploy /
# statusline migration regression guards
#
# Covers the update-path bugs fixed after the #78-#103 refactor review:
#   1. git-push-review scripts must deploy via _update_hook_scripts
#   2. _remove_retired_managed_files must not treat user-deleted (but still
#      kit-shipped) files as retired, must keep customized retired files, and
#      must map manifest paths recorded under a different claude_dir (dry-run)
#   3. _migrate_statusline_command rewrites the retired bash statusLine

source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/template.sh"
source "$PROJECT_DIR/lib/features.sh"
source "$PROJECT_DIR/lib/json-builder.sh"
source "$PROJECT_DIR/lib/snapshot.sh"
source "$PROJECT_DIR/lib/merge.sh"
source "$PROJECT_DIR/lib/dryrun.sh"

declare -a _SETUP_TMP_FILES=()
CLAUDE_DIR="$(mktemp -d)"
_SETUP_TMP_FILES+=("$CLAUDE_DIR")
LANGUAGE="en"
# shellcheck disable=SC2034  # globals are consumed by sourced deploy.sh
INSTALL_SKILLS="false"
# shellcheck disable=SC2034  # globals are consumed by sourced deploy.sh
ENABLE_CODEX_PLUGIN="false"

source "$PROJECT_DIR/lib/deploy.sh"
source "$PROJECT_DIR/lib/update.sh"

# Disable every scripted feature, then enable only git-push-review so the
# update deploy assertions stay focused.
for _rt_feat in "${_FEATURE_SCRIPT_ORDER[@]}"; do
  _rt_flag="${_FEATURE_FLAGS[$_rt_feat]:-}"
  [[ -n "$_rt_flag" ]] && printf -v "$_rt_flag" '%s' "false"
done
# shellcheck disable=SC2034  # read via ${!flag} indirection in sourced libs
printf -v ENABLE_GIT_PUSH_REVIEW '%s' "true"

# ── 1. update path deploys git-push-review scripts ────────────────────────
{
  test_name="retired-files: _update_hook_scripts deploys git-push-review remind.sh"
  _rt_cd="$(mktemp -d)"
  _rt_snap="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_rt_cd" "$_rt_snap")
  _rt_rc=0
  _update_hook_scripts "$_rt_cd" "$_rt_snap" || _rt_rc=$?
  if [[ "$_rt_rc" -eq 0 ]] && [[ -x "$_rt_cd/hooks/git-push-review/remind.sh" ]]; then
    pass "$test_name"
  else
    fail "$test_name (rc=$_rt_rc)"
  fi
}

# ── 2. manifest/snapshot tracking covers git-push-review ──────────────────
{
  test_name="retired-files: collect_managed_target_files includes git-push-review script"
  collect_managed_target_files
  if printf '%s\n' "${_MANAGED_TARGET_FILES[@]+"${_MANAGED_TARGET_FILES[@]}"}" \
    | grep -qx "$CLAUDE_DIR/hooks/git-push-review/remind.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ── 3-5. retired sweep: protection + removal + pruning in one manifest ────
{
  _rt_snap2="$CLAUDE_DIR/.starter-kit-snapshot"

  # (3) kit still ships agents/planner.md; user deleted it → NOT retired,
  #     baseline must survive so _update_file's restore/skip flow keeps working
  mkdir -p "$_rt_snap2/agents"
  printf 'baseline planner\n' > "$_rt_snap2/agents/planner.md"

  # (4) kit no longer ships continuous-learning → pristine copy is removed
  #     and the emptied directory is pruned
  mkdir -p "$CLAUDE_DIR/skills/continuous-learning" "$_rt_snap2/skills/continuous-learning"
  printf 'old skill\n' > "$CLAUDE_DIR/skills/continuous-learning/SKILL.md"
  printf 'old skill\n' > "$_rt_snap2/skills/continuous-learning/SKILL.md"

  # (5) retired commands/code-review.md was customized → kept, with warning
  mkdir -p "$CLAUDE_DIR/commands" "$_rt_snap2/commands"
  printf 'user customized\n' > "$CLAUDE_DIR/commands/code-review.md"
  printf 'kit original\n' > "$_rt_snap2/commands/code-review.md"

  jq -n --arg cd "$CLAUDE_DIR" '{
    version: "2",
    claude_dir: $cd,
    files: [
      ($cd + "/agents/planner.md"),
      ($cd + "/skills/continuous-learning/SKILL.md"),
      ($cd + "/commands/code-review.md")
    ]
  }' > "$CLAUDE_DIR/.starter-kit-manifest.json"

  _rt_rc=0
  _remove_retired_managed_files "$CLAUDE_DIR" "$_rt_snap2" >/dev/null 2>&1 || _rt_rc=$?

  test_name="retired-files: user-deleted kit-shipped file keeps its snapshot baseline"
  if [[ "$_rt_rc" -eq 0 ]] && [[ -f "$_rt_snap2/agents/planner.md" ]]; then
    pass "$test_name"
  else
    fail "$test_name (rc=$_rt_rc)"
  fi

  test_name="retired-files: pristine retired file is removed and empty dirs pruned"
  if [[ ! -e "$CLAUDE_DIR/skills/continuous-learning/SKILL.md" ]] \
    && [[ ! -d "$CLAUDE_DIR/skills/continuous-learning" ]] \
    && [[ ! -e "$_rt_snap2/skills/continuous-learning/SKILL.md" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi

  test_name="retired-files: customized retired file is kept (no silent data loss)"
  if [[ -f "$CLAUDE_DIR/commands/code-review.md" ]] \
    && [[ "$(cat "$CLAUDE_DIR/commands/code-review.md")" == "user customized" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ── 6. manifest recorded under another claude_dir (dry-run sim mapping) ───
{
  test_name="retired-files: manifest claude_dir root is remapped (dry-run sim dirs)"
  _rt_sim="$(mktemp -d)"
  _rt_sim_snap="$(mktemp -d)"
  _SETUP_TMP_FILES+=("$_rt_sim" "$_rt_sim_snap")
  mkdir -p "$_rt_sim/commands" "$_rt_sim_snap/commands"
  printf 'kit original\n' > "$_rt_sim/commands/code-review.md"
  printf 'kit original\n' > "$_rt_sim_snap/commands/code-review.md"
  jq -n '{
    version: "2",
    claude_dir: "/original/home/.claude",
    files: ["/original/home/.claude/commands/code-review.md"]
  }' > "$_rt_sim/.starter-kit-manifest.json"

  _rt_prev_cd="$CLAUDE_DIR"
  CLAUDE_DIR="$_rt_sim"
  _rt_rc=0
  _remove_retired_managed_files "$_rt_sim" "$_rt_sim_snap" >/dev/null 2>&1 || _rt_rc=$?
  CLAUDE_DIR="$_rt_prev_cd"

  if [[ "$_rt_rc" -eq 0 ]] && [[ ! -e "$_rt_sim/commands/code-review.md" ]]; then
    pass "$test_name"
  else
    fail "$test_name (rc=$_rt_rc)"
  fi
}

# ── 7. statusline migration ───────────────────────────────────────────────
{
  test_name="retired-files: _migrate_statusline_command rewrites retired bash statusLine"
  _rt_settings="$(mktemp)"
  _SETUP_TMP_FILES+=("$_rt_settings")
  jq -n --arg cmd "bash $HOME/.claude/hooks/statusline/statusline-command.sh" \
    '{statusLine: {type: "command", command: $cmd}}' > "$_rt_settings"
  printf -v ENABLE_STATUSLINE '%s' "true"
  _rt_rc=0
  _migrate_statusline_command "$_rt_settings" >/dev/null 2>&1 || _rt_rc=$?
  printf -v ENABLE_STATUSLINE '%s' "false"
  _rt_cmd="$(jq -r '.statusLine.command' "$_rt_settings")"
  if [[ "$_rt_rc" -eq 0 ]] \
    && [[ "$_rt_cmd" == *statusline-command.py* ]] \
    && [[ "$_rt_cmd" != *__HOME__* ]] \
    && [[ "$_rt_cmd" != *statusline-command.sh* ]]; then
    pass "$test_name"
  else
    fail "$test_name (rc=$_rt_rc cmd=$_rt_cmd)"
  fi
}

{
  test_name="retired-files: _migrate_statusline_command leaves non-retired statusLine untouched"
  _rt_settings2="$(mktemp)"
  _SETUP_TMP_FILES+=("$_rt_settings2")
  jq -n '{statusLine: {type: "command", command: "my-custom-statusline"}}' > "$_rt_settings2"
  printf -v ENABLE_STATUSLINE '%s' "true"
  _rt_rc=0
  _migrate_statusline_command "$_rt_settings2" >/dev/null 2>&1 || _rt_rc=$?
  # shellcheck disable=SC2034  # read via is_true indirection in sourced libs
  printf -v ENABLE_STATUSLINE '%s' "false"
  if [[ "$_rt_rc" -eq 0 ]] \
    && [[ "$(jq -r '.statusLine.command' "$_rt_settings2")" == "my-custom-statusline" ]]; then
    pass "$test_name"
  else
    fail "$test_name (rc=$_rt_rc)"
  fi
}
