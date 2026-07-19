#!/bin/bash
# MDM_TEST_BASH_MIN=4
# tests/unit/test-mdm-managed-env.sh - MDM 管理 env だけを policy authority とし、
# target-user state を読まないこと + capture の改行注入排除（R3-Medium）
#
# 背景: target user が書ける manifest/config は MDM policy の入力にも、
# update/fresh の選択権限にもできない。KIT_MDM_MANAGED=true のときは wrapper
# が検証済みで注入した値だけから authoritative fresh reconciliation を行う。

# wizard.sh は source 時に registry.sh / steps.sh を読み込む（test-wizard-utils.sh と同じ手法）
# shellcheck source=wizard/wizard.sh
source "$PROJECT_DIR/wizard/wizard.sh"
# shellcheck source=lib/colors.sh
source "$PROJECT_DIR/lib/colors.sh"
# shellcheck source=lib/progress.sh
source "$PROJECT_DIR/lib/progress.sh"
# shellcheck source=lib/prerequisites.sh
source "$PROJECT_DIR/lib/prerequisites.sh"
# shellcheck source=lib/template.sh
source "$PROJECT_DIR/lib/template.sh"
# shellcheck source=lib/snapshot.sh
source "$PROJECT_DIR/lib/snapshot.sh"
# shellcheck source=lib/merge.sh
source "$PROJECT_DIR/lib/merge.sh"
# shellcheck source=lib/update.sh
source "$PROJECT_DIR/lib/update.sh"
# shellcheck source=lib/deploy.sh
source "$PROJECT_DIR/lib/deploy.sh"
load_strings en

_reset_mdm_config_vars() {
  local _var
  for _var in "${_CONFIG_KEYS[@]+"${_CONFIG_KEYS[@]}"}"; do
    [[ -n "$_var" ]] && printf -v "$_var" '%s' ""
  done
  _CLI_OVERRIDES=()
}

# MDM authority 判定は target-user PATH 上のコマンドに依存しない。
(
  tr() { printf 'false'; }
  export KIT_MDM_MANAGED=TrUe
  if [[ "$(_bool_normalize TrUe)" == "true" ]] && _wizard_mdm_managed; then
    pass "mdm-managed: 偽 tr で managed authority を無効化できない"
  else
    fail "mdm-managed: managed authority 判定が PATH 上の tr に依存する"
  fi
)

# ── _capture_mdm_env_overrides: KIT_MDM_MANAGED=true のとき _CONFIG_KEYS の
#    非空 env 値をグローバル配列 _MDM_ENV_OVERRIDES へ直接構築する（R3-M: 配列化）──
_mdm_env_has() { local _e; for _e in "${_MDM_ENV_OVERRIDES[@]+"${_MDM_ENV_OVERRIDES[@]}"}"; do [[ "$_e" == "$1" ]] && return 0; done; return 1; }
(
  export KIT_MDM_MANAGED=true
  export ENABLE_GHOSTTY_SETUP=false PROFILE=full
  _capture_mdm_env_overrides
  _mdm_env_has 'ENABLE_GHOSTTY_SETUP=false' && _mdm_env_has 'PROFILE=full' \
    && pass "mdm-managed: MDM env を配列へ capture する" \
    || fail "mdm-managed: MDM env の capture が不正 (${_MDM_ENV_OVERRIDES[*]-})"
)
(
  unset KIT_MDM_MANAGED
  export ENABLE_GHOSTTY_SETUP=false
  _capture_mdm_env_overrides
  if [[ "${#_MDM_ENV_OVERRIDES[@]}" -eq 0 ]]; then
    pass "mdm-managed: KIT_MDM_MANAGED 未設定では capture しない"
  else
    fail "mdm-managed: 非 MDM 文脈で capture してしまう (${_MDM_ENV_OVERRIDES[*]-})"
  fi
)

# ── 復元クロバー後の再適用で MDM 値が勝つ ──
(
  export KIT_MDM_MANAGED=true
  export ENABLE_GHOSTTY_SETUP=false
  _capture_mdm_env_overrides
  _saved=("${_MDM_ENV_OVERRIDES[@]+"${_MDM_ENV_OVERRIDES[@]}"}")
  # manifest/saved config の復元が値を巻き戻したと仮定
  ENABLE_GHOSTTY_SETUP=true
  _restore_cli_overrides "${_saved[@]+"${_saved[@]}"}"
  [[ "$ENABLE_GHOSTTY_SETUP" == "false" ]] \
    && pass "mdm-managed: 復元後の再適用で MDM 値が勝つ" \
    || fail "mdm-managed: 復元に MDM 値が負ける (got '$ENABLE_GHOSTTY_SETUP')"
)

# ══ R3-Medium 回帰: 改行を含む値で別代入を注入できない ══
# 非 root MDM 経路は環境を継承するため、SELECTED_PLUGINS 等の値に改行を含めて
# "PATH=/attacker" のような別行を注入すると、旧実装（KEY=VALUE\n → read -r）では
# PATH が再設定された。制御文字を含む値は capture 対象から除外する。
(
  export KIT_MDM_MANAGED=true
  export SELECTED_PLUGINS=$'safe\nPATH=/attacker'
  export PROFILE=standard
  _capture_mdm_env_overrides
  # 改行入りの SELECTED_PLUGINS は capture されない（PATH= 行も混入しない）
  _injected=0
  for _e in "${_MDM_ENV_OVERRIDES[@]+"${_MDM_ENV_OVERRIDES[@]}"}"; do
    case "$_e" in PATH=*) _injected=1 ;; esac
  done
  if [[ "$_injected" -eq 0 ]]; then
    pass "mdm-managed: 改行入り値から PATH 等の別代入を注入できない"
  else
    fail "mdm-managed: 改行入り値で別代入が混入した（R3-M 注入回帰）"
  fi
  # PROFILE（正常値）は影響を受けず capture される
  _mdm_env_has 'PROFILE=standard' \
    && pass "mdm-managed: 制御文字を含む値だけを除外し正常値は capture" \
    || fail "mdm-managed: 正常値まで巻き添えで除外された"
)
(
  # restore を実際に走らせても PATH が汚染されない
  export KIT_MDM_MANAGED=true
  export SELECTED_PLUGINS=$'safe\nPATH=/attacker'
  _capture_mdm_env_overrides
  _saved=("${_MDM_ENV_OVERRIDES[@]+"${_MDM_ENV_OVERRIDES[@]}"}")
  _orig_path="$PATH"
  _restore_cli_overrides "${_saved[@]+"${_saved[@]}"}"
  [[ "$PATH" == "$_orig_path" ]] \
    && pass "mdm-managed: restore 実行後も PATH が汚染されない" \
    || fail "mdm-managed: restore で PATH が汚染された ('$PATH')"
)

# ── _restore_cli_overrides は不正キー名で set -e 即死しない ──
(
  _rc=0
  ( _restore_cli_overrides 'bad key=x' 'PROFILE=minimal' ) >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 ]] \
    && pass "mdm-managed: 不正キー名を含んでも restore が即死しない" \
    || fail "mdm-managed: 不正キー名で restore が失敗 (rc=$_rc)"
)

# ── run_wizard の配線（static）: managed policy input を直接 capture する ──
if grep -q '_capture_mdm_env_overrides' "$PROJECT_DIR/wizard/wizard.sh" \
  && [[ "$(grep -c '_MDM_ENV_OVERRIDES\[@\]' "$PROJECT_DIR/wizard/wizard.sh")" -ge 2 ]]; then
  pass "mdm-managed: run_wizard が authoritative MDM env を capture する配線"
else
  fail "mdm-managed: run_wizard の MDM env authority 配線が無い/不完全"
fi

# ── production context: _CONFIG_KEYS の空 separator で errexit しない ──
set +e
_mdm_errexit_output="$(
  PROJECT_DIR="$PROJECT_DIR" "$BASH" --noprofile --norc -c '
    set -euo pipefail
    source "$PROJECT_DIR/wizard/wizard.sh"
    source "$PROJECT_DIR/lib/colors.sh"
    load_strings en
    KIT_MDM_MANAGED=true
    _apply_mdm_managed_profile
    printf "profile=%s\n" "$PROFILE"
  ' 2>&1
)"
_mdm_errexit_rc=$?
set -e
if [[ "$_mdm_errexit_rc" -eq 0 && "$_mdm_errexit_output" == "profile=standard" ]]; then
  pass "mdm-managed: production errexit 文脈で空 config separator を安全に無視"
else
  fail "mdm-managed: production errexit 文脈で profile 適用に失敗 (rc=$_mdm_errexit_rc output=$_mdm_errexit_output)"
fi

(
  _reset_mdm_config_vars
  export KIT_MDM_MANAGED=true
  PROFILE=full
  ENABLE_CODEX_PLUGIN=true
  ENABLE_DOC_BLOCKER=true
  SELECTED_PLUGINS=legacy-only
  _rc=0
  _apply_mdm_managed_profile >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && "$PROFILE" == "standard" ]] \
    && [[ "$ENABLE_CODEX_PLUGIN" == "false" && "$ENABLE_DOC_BLOCKER" == "false" ]] \
    && [[ -z "$SELECTED_PLUGINS" ]]; then
    pass "mdm-managed: current PROFILE 未指定時は manifest 旧値でなく standard preset"
  else
    fail "mdm-managed: manifest 旧 profile を explicit 扱いしている"
  fi
)

# ── authoritative profile: fresh install ────────────────────────────────
(
  _reset_mdm_config_vars
  _tmp="$(mktemp -d)"
  export HOME="$_tmp" KIT_MDM_MANAGED=true PROFILE=full LANGUAGE=ja
  export ENABLE_AUTO_UPDATE=true
  WIZARD_CONFIG_FILE="$_tmp/saved.conf"
  cat > "$WIZARD_CONFIG_FILE" <<'CONF'
PROFILE="standard"
LANGUAGE="en"
ENABLE_DOC_BLOCKER="false"
ENABLE_CODEX_PLUGIN="false"
SELECTED_PLUGINS="legacy-only"
CONF
  WIZARD_NONINTERACTIVE=true
  UPDATE_MODE=false
  _rc=0
  run_wizard >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$UPDATE_MODE" == "false" ]] \
    && [[ "$PROFILE" == "full" ]] \
    && [[ "$INSTALL_COMMANDS" == "true" && "$INSTALL_SKILLS" == "true" ]] \
    && [[ "$ENABLE_DOC_BLOCKER" == "true" && "$ENABLE_CODEX_PLUGIN" == "false" ]] \
    && [[ "$ENABLE_AUTO_UPDATE" == "false" && "$ENABLE_WEB_CONTENT_UPDATE" == "false" ]] \
    && [[ "$ENABLE_GHOSTTY_SETUP" == "false" && "$ENABLE_FONTS_SETUP" == "false" ]] \
    && [[ -z "$SELECTED_PLUGINS" ]] \
    && [[ "$LANGUAGE" == "ja" && "$STR_BANNER" == *スターターキット* ]]; then
    pass "mdm-managed: fresh は profile→MDM defaults→explicit の順で再構築"
  else
    fail "mdm-managed: fresh authoritative profile の収束に失敗"
  fi
  rm -rf "$_tmp"
)

# A current-checkout disabled path is removed only when its bytes still match
# the kit, unless a prior root postcondition explicitly recorded it as managed.
(
  source "$PROJECT_DIR/profiles/minimal.conf"
  _tmp="$(mktemp -d)"
  _live="$_tmp/live"; _snap="$_tmp/snapshot"
  mkdir -p "$_live/commands" "$_snap/commands"
  printf 'personal conflict\n' > "$_live/commands/oss-analyze.md"
  printf 'personal snapshot\n' > "$_snap/commands/oss-analyze.md"
  export KIT_MDM_MANAGED=true HOME="$_tmp/home" CLAUDE_DIR="$_live"
  unset KIT_MDM_PRIOR_MANAGED_INVENTORY
  _first_rc=0; _second_rc=0
  _mdm_reconcile_absent_managed_files "$_live" "$_snap" >/dev/null 2>&1 \
    || _first_rc=$?
  _mdm_reconcile_absent_managed_files "$_live" "$_snap" >/dev/null 2>&1 \
    || _second_rc=$?
  if [[ "$_first_rc" -ne 0 && "$_second_rc" -ne 0 ]] \
    && [[ "$(cat "$_live/commands/oss-analyze.md")" == 'personal conflict' ]] \
    && [[ "$(cat "$_snap/commands/oss-analyze.md")" == 'personal snapshot' ]]; then
    pass "mdm-managed: absent candidate は再実行しても user file を削除しない"
  else
    fail "mdm-managed: failed absent candidate が次回の削除権限へ昇格"
  fi
  rm -f "$_live/commands/oss-analyze.md" "$_snap/commands/oss-analyze.md"

  # Root capture/path attestation is covered by the installer and purpose
  # suites. This case isolates downstream deletion authority after the
  # inventory has already been authenticated and loaded.
  _mdm_load_prior_inventory() {
    local _rel="commands/legacy.md"
    _MDM_PRIOR_REL_SET=()
    _MDM_PRIOR_REL_SET["$_rel"]=1
  }
  printf 'locally changed old managed bytes\n' > "$_live/commands/legacy.md"
  printf 'different old snapshot bytes\n' > "$_snap/commands/legacy.md"
  _prior_rc=0
  _mdm_reconcile_absent_managed_files "$_live" "$_snap" >/dev/null 2>&1 \
    || _prior_rc=$?
  if [[ "$_prior_rc" -eq 0 && ! -e "$_live/commands/legacy.md" \
    && ! -e "$_snap/commands/legacy.md" ]]; then
    pass "mdm-managed: root history 済み retired path は内容変更後も収束"
  else
    fail "mdm-managed: root history 済み retired path を収束できない"
  fi
  rm -rf "$_tmp"
)

# MDM backups use a reserved prefix and retain exactly one generation without
# interpreting copied user-controlled marker contents.
(
  _tmp="$(mktemp -d)"; mkdir -p "$_tmp/home/.claude"
  export HOME="$_tmp/home" CLAUDE_DIR="$_tmp/home/.claude"
  export KIT_MDM_MANAGED=true DRY_RUN=false
  _SETUP_TMP_FILES=()
  printf 'managed\n' > "$CLAUDE_DIR/settings.json"
  mkdir "$HOME/.claude.mdm-backup.20000101000000"
  printf 'outside\n' > "$_tmp/outside"
  ln -s "$_tmp/outside" \
    "$HOME/.claude.mdm-backup.20000101000000/.starter-kit-mdm-backup"
  mkdir "$HOME/.claude.mdm-backup.not-reserved" "$HOME/.claude.backup.keep"
  _backup_rc=0
  backup_existing >/dev/null 2>&1 || _backup_rc=$?
  backup_existing >/dev/null 2>&1 || _backup_rc=$?
  _reserved_count=0
  for _candidate in "$HOME"/.claude.mdm-backup.*; do
    _suffix="${_candidate#"$HOME"/.claude.mdm-backup.}"
    [[ "$_suffix" =~ ^[0-9]{14}(\.[0-9]+)?$ ]] \
      && _reserved_count=$((_reserved_count + 1))
  done
  if [[ "$_backup_rc" -eq 0 && "$_reserved_count" -eq 1 ]] \
    && [[ -d "$HOME/.claude.mdm-backup.not-reserved" ]] \
    && [[ -d "$HOME/.claude.backup.keep" ]] \
    && [[ "$(cat "$_tmp/outside")" == outside ]] \
    && [[ -d "$_BACKUP_PATH" && ! -L "$_BACKUP_PATH" ]]; then
    pass "mdm-managed: MDM backup は予約 prefix の一世代だけを安全に保持"
  else
    fail "mdm-managed: MDM backup rotation の境界/保持世代が不正"
  fi
  rm -rf "$_tmp"
)

# A user edit must converge even when the kit baseline itself did not change.
(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$_tmp/claude/.starter-kit-snapshot"
  cat > "$_tmp/claude/.starter-kit-snapshot/settings.json" <<'JSON'
{"env":{"MANAGED":"desired"}}
JSON
  cat > "$_tmp/claude/settings.json" <<'JSON'
{"env":{"MANAGED":"local","USER_ONLY":"keep"}}
JSON
  cp "$_tmp/claude/.starter-kit-snapshot/settings.json" "$_tmp/new.json"
  _mdm_new_settings_fixture="$_tmp/new.json"
  build_settings_file() { cp "$_mdm_new_settings_fixture" "$1"; }
  is_true() { [[ "${1:-}" == "true" ]]; }
  _SETUP_TMP_FILES=()
  _UPDATE_ALL_UPDATED_FILES=()
  _UPDATE_ALL_SKIPPED_FILES=()
  _SNAPSHOT_BOOTSTRAPPED=false
  # shellcheck disable=SC2034  # _update_phase_settings reads this global.
  DRY_RUN=true
  ENABLE_STATUSLINE=false
  _rc=0
  _update_phase_settings "$_tmp/claude" "$_tmp/claude/.starter-kit-snapshot" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(jq -r '.env.MANAGED' "$_tmp/claude/settings.json")" == "desired" ]] \
    && [[ "$(jq -r '.env | has("USER_ONLY")' "$_tmp/claude/settings.json")" == "false" ]]; then
    pass "mdm-managed: kit unchanged でも settings 全体を desired へ収束"
  else
    fail "mdm-managed: kit unchanged 分岐が managed drift を保持している"
  fi
  rm -rf "$_tmp"
)

# ── settings conflicts: the complete desired document wins ──────────────
(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  cat > "$_tmp/snapshot.json" <<'JSON'
{"env":{"MANAGED":"old"},"hooks":["old"],"removed":"old"}
JSON
  cat > "$_tmp/current.json" <<'JSON'
{"env":{"MANAGED":"local","USER_ONLY":"keep","deep":{"user":true}},"hooks":["local"],"removed":"local","userTop":{"keep":true}}
JSON
  cat > "$_tmp/new.json" <<'JSON'
{"env":{"MANAGED":"desired","deep":{"kit":true}},"hooks":["desired"]}
JSON
  _MERGE_PREFS_LOADED=true
  _MERGE_PREFS='{"env.MANAGED":"keep-mine","hooks":"keep-mine","removed":"keep-mine"}'
  _rc=0
  merge_settings_3way "$_tmp/snapshot.json" "$_tmp/current.json" "$_tmp/new.json" "$_tmp/out.json" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(jq -r '.env.MANAGED' "$_tmp/out.json")" == "desired" ]] \
    && [[ "$(jq -r '.env | has("USER_ONLY")' "$_tmp/out.json")" == "false" ]] \
    && [[ "$(jq -r '.env.deep | has("user")' "$_tmp/out.json")" == "false" ]] \
    && [[ "$(jq -r '.env.deep.kit' "$_tmp/out.json")" == "true" ]] \
    && [[ "$(jq -r '.hooks[0]' "$_tmp/out.json")" == "desired" ]] \
    && [[ "$(jq -r 'has("removed")' "$_tmp/out.json")" == "false" ]] \
    && [[ "$(jq -r 'has("userTop")' "$_tmp/out.json")" == "false" ]]; then
    pass "mdm-managed: settings desired 全体が prefs/local conflict に勝つ"
  else
    fail "mdm-managed: authoritative settings merge が不正"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  KIT_MDM_POLICY_SHA256="$(printf 'a%.0s' {1..64})"
  export KIT_MDM_POLICY_SHA256
  _tmp="$(mktemp -d)"
  _tmp="$(cd -P "$_tmp" && pwd -P)"
  CLAUDE_DIR="$_tmp/.claude"
  mkdir -p "$CLAUDE_DIR"
  _SETUP_TMP_FILES=()
  managed_files_json() { printf '[]'; }
  mdm_absent_files_json() { printf '[]'; }
  cleanup_paths_json() { printf '[]'; }
  _rc=0
  write_manifest >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && jq -e --arg policy "$KIT_MDM_POLICY_SHA256" \
      '.version == "2" and .mdm_managed == true and .policy_sha256 == $policy' \
      "$CLAUDE_DIR/.starter-kit-manifest.json" >/dev/null 2>&1; then
    pass "mdm-managed: manifest が runtime mutation 抑止 marker を記録"
  else
    fail "mdm-managed: manifest の MDM marker が欠落"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  printf '%s\n' '{"managed":"local","userOnly":"keep"}' > "$_tmp/current.json"
  printf '%s\n' '{"managed":"desired","kitOnly":true}' > "$_tmp/new.json"
  _rc=0
  _merge_settings_bootstrap "$_tmp/current.json" "$_tmp/new.json" "$_tmp/out.json" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(jq -r '.managed' "$_tmp/out.json")" == "desired" ]] \
    && [[ "$(jq -r 'has("userOnly")' "$_tmp/out.json")" == "false" ]] \
    && [[ "$(jq -r '.kitOnly' "$_tmp/out.json")" == "true" ]]; then
    pass "mdm-managed: snapshot bootstrap でも desired 全体へ収束"
  else
    fail "mdm-managed: authoritative bootstrap merge が不正"
  fi
  rm -rf "$_tmp"
)

# A path previously owned as a scalar remains wholly managed when the kit
# changes it to an object; local object keys cannot become user-owned by a type
# swap at that same path.
(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  printf '%s\n' '{"managed":"old"}' > "$_tmp/snapshot.json"
  printf '%s\n' '{"managed":{"injected":true}}' > "$_tmp/current.json"
  printf '%s\n' '{"managed":{"desired":true}}' > "$_tmp/new.json"
  _rc=0
  merge_settings_3way "$_tmp/snapshot.json" "$_tmp/current.json" \
    "$_tmp/new.json" "$_tmp/out.json" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(jq -r '.managed.desired' "$_tmp/out.json")" == "true" ]] \
    && [[ "$(jq -r '.managed | has("injected")' "$_tmp/out.json")" == "false" ]]; then
    pass "mdm-managed: managed path の型変更でも desired 全体が勝つ"
  else
    fail "mdm-managed: managed path の型変更で local key が残った"
  fi
  rm -rf "$_tmp"
)

# ── managed files converge; unrelated user file and CLAUDE user section stay ──
(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/.claude"
  mkdir -p "$CLAUDE_DIR"
  printf '# Existing user instructions\nkeep this note\n' > "$CLAUDE_DIR/CLAUDE.md"
  LANGUAGE=en
  _MERGE_INTERACTIVE=false
  _FRESH_SKIPPED_FILES=()
  _SETUP_TMP_FILES=()
  build_claude_md_to_file() {
    printf '%s\n' \
      '<!-- BEGIN STARTER-KIT-MANAGED -->' \
      '# Desired managed section' \
      '<!-- END STARTER-KIT-MANAGED -->' \
      '' \
      '# User Settings' > "$1"
  }
  _rc=0
  _build_claude_md_safe >/dev/null 2>&1 || _rc=$?
  _begin_count="$(grep -cF '<!-- BEGIN STARTER-KIT-MANAGED -->' "$CLAUDE_DIR/CLAUDE.md" || true)"
  if [[ "$_rc" -eq 0 && "$_begin_count" -eq 1 ]] \
    && grep -qF '# Desired managed section' "$CLAUDE_DIR/CLAUDE.md" \
    && grep -qF '# Existing user instructions' "$CLAUDE_DIR/CLAUDE.md" \
    && grep -qF 'keep this note' "$CLAUDE_DIR/CLAUDE.md" \
    && [[ "${#_FRESH_SKIPPED_FILES[@]}" -eq 0 ]]; then
    pass "mdm-managed: fresh marker-less CLAUDE.md を user section 付きで収束"
  else
    fail "mdm-managed: fresh marker-less CLAUDE.md の保持/収束に失敗"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  PROJECT_DIR="$_tmp/project"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$PROJECT_DIR/agents" "$PROJECT_DIR/commands" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/commands"
  printf 'agent\n' > "$PROJECT_DIR/agents/managed.md"
  printf 'command\n' > "$PROJECT_DIR/commands/disabled.md"
  cp "$PROJECT_DIR/agents/managed.md" "$CLAUDE_DIR/agents/managed.md"
  cp "$PROJECT_DIR/commands/disabled.md" "$CLAUDE_DIR/commands/disabled.md"
  # shellcheck disable=SC2034  # collect_managed_target_files reads this global.
  INSTALL_AGENTS=true
  # shellcheck disable=SC2034  # collect_managed_target_files reads this global.
  INSTALL_RULES=false
  INSTALL_COMMANDS=false
  INSTALL_SKILLS=false
  _FEATURE_SCRIPT_ORDER=()
  collect_managed_target_files
  _joined="$(printf '%s\n' "${_MANAGED_TARGET_FILES[@]}")"
  if [[ "$_joined" == *'/agents/managed.md'* ]] \
    && [[ "$_joined" != *'/commands/disabled.md'* ]]; then
    pass "mdm-managed: manifest 対象は現在有効な配布物だけ"
  else
    fail "mdm-managed: 無効化済み配布物を manifest 対象に含めている"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  PROJECT_DIR="$_tmp/project"
  CLAUDE_DIR="$_tmp/.claude"
  mkdir -p "$PROJECT_DIR/features/test/scripts" "$CLAUDE_DIR/hooks/test"
  printf '#!/bin/sh\n' > "$PROJECT_DIR/features/test/scripts/run.sh"
  printf 'data\n' > "$CLAUDE_DIR/settings.json"
  printf '#!/bin/sh\n' > "$CLAUDE_DIR/hooks/test/run.sh"
  chmod 600 "$PROJECT_DIR/features/test/scripts/run.sh" \
    "$CLAUDE_DIR/hooks/test/run.sh"
  _MANAGED_TARGET_FILES=("$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/hooks/test/run.sh")
  collect_managed_target_files() { :; }
  _snapshot_claude_md() { :; }
  _rc=0
  write_managed_snapshot >/dev/null 2>&1 || _rc=$?
  _plain_mode="$(test_stat_mode "$CLAUDE_DIR/settings.json")"
  _exec_mode="$(test_stat_mode "$CLAUDE_DIR/hooks/test/run.sh")"
  _snap_plain_mode="$(test_stat_mode "$CLAUDE_DIR/.starter-kit-snapshot/settings.json")"
  _snap_exec_mode="$(test_stat_mode "$CLAUDE_DIR/.starter-kit-snapshot/hooks/test/run.sh")"
  if [[ "$_rc" -eq 0 && "$_plain_mode" == 600 && "$_exec_mode" == 700 \
    && "$_snap_plain_mode" == 600 && "$_snap_exec_mode" == 700 ]]; then
    pass "mdm-managed: live/snapshot modeを0600/0700へ正規化"
  else
    fail "mdm-managed: managed mode正規化が不正"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$_tmp/src" "$CLAUDE_DIR/rules"
  printf 'desired\n' > "$_tmp/src/managed.md"
  printf 'local\n' > "$CLAUDE_DIR/rules/managed.md"
  printf 'personal\n' > "$CLAUDE_DIR/rules/user-personal.md"
  _MERGE_INTERACTIVE=false
  _FRESH_SKIPPED_FILES=()
  _SETUP_TMP_FILES=()
  _rc=0
  _copy_dir_safe true "$_tmp/src" "$CLAUDE_DIR/rules" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(< "$CLAUDE_DIR/rules/managed.md")" == "desired" ]] \
    && [[ "$(< "$CLAUDE_DIR/rules/user-personal.md")" == "personal" ]]; then
    pass "mdm-managed: fresh の同名配布ファイルも desired へ収束"
  else
    fail "mdm-managed: fresh が同名の local managed file を保持した"
  fi
  rm -rf "$_tmp"
)

# MDM distribution writes must fail closed on symlinks/special paths. The
# complete tree is preflighted, so a later unsafe target cannot cause an earlier
# managed file to be replaced first.
(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$_tmp/src" "$CLAUDE_DIR/rules" "$_tmp/external"
  printf 'desired-safe\n' > "$_tmp/src/a-safe.md"
  printf 'desired-link\n' > "$_tmp/src/z-link.md"
  printf 'local-safe\n' > "$CLAUDE_DIR/rules/a-safe.md"
  printf 'external\n' > "$_tmp/external/personal.md"
  ln -s "$_tmp/external/personal.md" "$CLAUDE_DIR/rules/z-link.md"
  _SETUP_TMP_FILES=()
  _rc=0
  _copy_distribution_tree "$_tmp/src" "$CLAUDE_DIR/rules" overwrite \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]] \
    && [[ "$(< "$CLAUDE_DIR/rules/a-safe.md")" == "local-safe" ]] \
    && [[ "$(< "$_tmp/external/personal.md")" == "external" ]] \
    && [[ -L "$CLAUDE_DIR/rules/z-link.md" ]]; then
    pass "mdm-managed: symlink target を追従せず tree 全体を fail-closed"
  else
    fail "mdm-managed: symlink target 経由で無関係ファイルを上書きした"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$_tmp/src/nested" "$CLAUDE_DIR/rules" "$_tmp/external"
  printf 'desired\n' > "$_tmp/src/nested/managed.md"
  printf 'external\n' > "$_tmp/external/managed.md"
  ln -s "$_tmp/external" "$CLAUDE_DIR/rules/nested"
  _SETUP_TMP_FILES=()
  _rc=0
  _copy_distribution_tree "$_tmp/src" "$CLAUDE_DIR/rules" overwrite \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]] \
    && [[ "$(< "$_tmp/external/managed.md")" == "external" ]] \
    && [[ -L "$CLAUDE_DIR/rules/nested" ]]; then
    pass "mdm-managed: symlink parent 経由の distribution overwrite を拒否"
  else
    fail "mdm-managed: symlink parent 経由で無関係ファイルを上書きした"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  mkdir -p "$_tmp/src" "$_tmp/real-claude/rules"
  printf 'desired\n' > "$_tmp/src/managed.md"
  printf 'external\n' > "$_tmp/real-claude/rules/managed.md"
  ln -s "$_tmp/real-claude" "$_tmp/claude-link"
  CLAUDE_DIR="$_tmp/claude-link"
  _SETUP_TMP_FILES=()
  _rc=0
  _copy_distribution_tree "$_tmp/src" "$CLAUDE_DIR/rules" overwrite \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]] \
    && [[ "$(< "$_tmp/real-claude/rules/managed.md")" == "external" ]]; then
    pass "mdm-managed: symlink CLAUDE_DIR を distribution root に使わない"
  else
    fail "mdm-managed: symlink CLAUDE_DIR 経由で無関係ファイルを上書きした"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$_tmp/src" "$CLAUDE_DIR/rules" "$_tmp/external"
  printf 'desired\n' > "$_tmp/src/managed.md"
  printf 'external\n' > "$_tmp/external/personal.md"
  ln "$_tmp/external/personal.md" "$CLAUDE_DIR/rules/managed.md"
  printf 'personal\n' > "$CLAUDE_DIR/rules/user-personal.md"
  _SETUP_TMP_FILES=()
  _rc=0
  _copy_distribution_tree "$_tmp/src" "$CLAUDE_DIR/rules" overwrite \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(< "$CLAUDE_DIR/rules/managed.md")" == "desired" ]] \
    && [[ "$(< "$_tmp/external/personal.md")" == "external" ]] \
    && [[ "$(< "$CLAUDE_DIR/rules/user-personal.md")" == "personal" ]]; then
    pass "mdm-managed: hardlink target を置換し user-only file を保持"
  else
    fail "mdm-managed: hardlink 経由で無関係ファイルを上書きした"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp/claude"
  mkdir -p "$_tmp/src" "$CLAUDE_DIR/rules"
  printf 'desired\n' > "$_tmp/src/managed.md"
  mkfifo "$CLAUDE_DIR/rules/managed.md"
  _SETUP_TMP_FILES=()
  _rc=0
  _copy_distribution_tree "$_tmp/src" "$CLAUDE_DIR/rules" overwrite \
    >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 && -p "$CLAUDE_DIR/rules/managed.md" ]]; then
    pass "mdm-managed: special distribution target を fail-closed"
  else
    fail "mdm-managed: special distribution target を通常ファイル扱いした"
  fi
  rm -rf "$_tmp"
)

(
  export KIT_MDM_MANAGED=true
  _tmp="$(mktemp -d)"
  CLAUDE_DIR="$_tmp"
  mkdir -p "$_tmp/rules" "$_tmp/snapshot/rules"
  printf 'old\n' > "$_tmp/snapshot/rules/managed.md"
  printf 'local\n' > "$_tmp/rules/managed.md"
  printf 'desired\n' > "$_tmp/new-managed.md"
  printf 'personal\n' > "$_tmp/rules/user-personal.md"
  _rc=0
  _update_file "$_tmp/rules/managed.md" "$_tmp/snapshot/rules/managed.md" "$_tmp/new-managed.md" || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$(< "$_tmp/rules/managed.md")" == "desired" ]] \
    && [[ "$(< "$_tmp/rules/user-personal.md")" == "personal" ]]; then
    pass "mdm-managed: managed file は desired、user-only file は保持"
  else
    fail "mdm-managed: managed/user-only file の更新契約が不正"
  fi

  printf 'retired-local\n' > "$_tmp/rules/retired.md"
  printf 'retired-old\n' > "$_tmp/snapshot/rules/retired.md"
  jq -n --arg root "$_tmp" --arg file "$_tmp/rules/retired.md" \
    '{claude_dir:$root,files:[$file]}' > "$_tmp/.starter-kit-manifest.json"
  collect_managed_target_files() { _MANAGED_TARGET_FILES=(); }
  _rc=0
  _remove_retired_managed_files "$_tmp" "$_tmp/snapshot" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && -e "$_tmp/rules/retired.md" ]] \
    && [[ -e "$_tmp/snapshot/rules/retired.md" ]] \
    && [[ -e "$_tmp/rules/user-personal.md" ]]; then
    pass "mdm-managed: target-user manifest は収束や削除の authority にしない"
  else
    fail "mdm-managed: forged manifest が収束を阻害または user file を削除した"
  fi

  # A target-user-controlled manifest cannot escape CLAUDE_DIR, and a
  # manifest-only entry without a snapshot baseline is not deletion authority.
  printf 'outside\n' > "$_tmp/outside.md"
  printf 'manifest-only\n' > "$_tmp/rules/manifest-only.md"
  jq -n --arg root "$_tmp" \
    --arg escape "$_tmp/../$(basename "$_tmp")/outside.md" \
    --arg manifest_only "$_tmp/rules/manifest-only.md" \
    '{claude_dir:$root,files:[$escape,$manifest_only]}' \
    > "$_tmp/.starter-kit-manifest.json"
  _rc=0
  _remove_retired_managed_files "$_tmp" "$_tmp/snapshot" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && -f "$_tmp/outside.md" && -f "$_tmp/rules/manifest-only.md" ]]; then
    pass "mdm-managed: untrusted manifest entry は無視して user file を保持"
  else
    fail "mdm-managed: untrusted manifest entry が収束を阻害または file を削除した"
  fi

  # Even a syntactically safe relative path must not traverse a symlinked
  # parent directory into unrelated user data.
  mkdir -p "$_tmp/external" "$_tmp/snapshot/linked"
  printf 'external\n' > "$_tmp/external/personal.md"
  printf 'baseline\n' > "$_tmp/snapshot/linked/personal.md"
  ln -s "$_tmp/external" "$_tmp/linked"
  jq -n --arg root "$_tmp" --arg file "$_tmp/linked/personal.md" \
    '{claude_dir:$root,files:[$file]}' > "$_tmp/.starter-kit-manifest.json"
  _rc=0
  _remove_retired_managed_files "$_tmp" "$_tmp/snapshot" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && "$(< "$_tmp/external/personal.md")" == "external" ]]; then
    pass "mdm-managed: symlink parent 経由の retired 削除を拒否"
  else
    fail "mdm-managed: symlink parent 経由で無関係ファイルを削除した"
  fi

  cat > "$_tmp/current.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# locally edited kit section
<!-- END STARTER-KIT-MANAGED -->

# User Settings
personal note
MD
  cat > "$_tmp/snapshot.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# old kit section
<!-- END STARTER-KIT-MANAGED -->
MD
  cat > "$_tmp/new.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# desired kit section
<!-- END STARTER-KIT-MANAGED -->

# User Settings
MD
  _SETUP_TMP_FILES=()
  LANGUAGE=en
  _rc=0
  _update_claude_md "$_tmp/current.md" "$_tmp/snapshot.md" "$_tmp/new.md" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && grep -qF '# desired kit section' "$_tmp/current.md" \
    && ! grep -qF '# locally edited kit section' "$_tmp/current.md" \
    && grep -qF 'personal note' "$_tmp/current.md"; then
    pass "mdm-managed: CLAUDE managed section は desired、user section は保持"
  else
    fail "mdm-managed: CLAUDE section-aware authoritative update が不正"
  fi
  rm -rf "$_tmp"
)

# ── authoritative profile: update ignores manifest/saved feature values ──
(
  _reset_mdm_config_vars
  _tmp="$(mktemp -d)"
  mkdir -p "$_tmp/.claude"
  export HOME="$_tmp" KIT_MDM_MANAGED=true PROFILE=full LANGUAGE=ja
  export ENABLE_STATUSLINE=false
  WIZARD_CONFIG_FILE="$_tmp/saved.conf"
  cat > "$WIZARD_CONFIG_FILE" <<'CONF'
PROFILE="standard"
LANGUAGE="en"
ENABLE_DOC_BLOCKER="false"
ENABLE_STATUSLINE="true"
ENABLE_CODEX_PLUGIN="false"
SELECTED_PLUGINS="legacy-only"
CONF
  cat > "$_tmp/.claude/.starter-kit-manifest.json" <<'JSON'
{"profile":"standard","language":"en","editor":"none","plugins":"legacy-only","codex_plugin":"false"}
JSON
  WIZARD_NONINTERACTIVE=true
  UPDATE_MODE=true
  _rc=0
  run_wizard >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$UPDATE_MODE" == "false" ]] \
    && [[ "$PROFILE" == "full" ]] \
    && [[ "$INSTALL_COMMANDS" == "true" && "$INSTALL_SKILLS" == "true" ]] \
    && [[ "$ENABLE_DOC_BLOCKER" == "true" && "$ENABLE_CODEX_PLUGIN" == "false" ]] \
    && [[ "$ENABLE_STATUSLINE" == "false" ]] \
    && [[ "$ENABLE_AUTO_UPDATE" == "false" ]] \
    && [[ "$ENABLE_WEB_CONTENT_UPDATE" == "false" ]] \
    && [[ "$ENABLE_GHOSTTY_SETUP" == "false" && "$ENABLE_FONTS_SETUP" == "false" ]] \
    && [[ -z "$SELECTED_PLUGINS" ]] \
    && [[ "$LANGUAGE" == "ja" && "$STR_BANNER" == *スターターキット* ]]; then
    pass "mdm-managed: update は manifest を explicit 扱いせず full profile へ収束"
  else
    fail "mdm-managed: update authoritative profile の収束に失敗"
  fi
  rm -rf "$_tmp"
)

# ── malformed user state cannot obstruct authoritative self-healing ───────
(
  _reset_mdm_config_vars
  _tmp="$(mktemp -d)"
  mkdir -p "$_tmp/.claude"
  printf '{not-json\n' > "$_tmp/.claude/.starter-kit-manifest.json"
  cat > "$_tmp/saved.conf" <<'CONF'
PROFILE="minimal"
LANGUAGE="en"
ENABLE_STATUSLINE="true"
SELECTED_PLUGINS="user-controlled"
CONF
  export HOME="$_tmp" KIT_MDM_MANAGED=true PROFILE=full LANGUAGE=ja
  export ENABLE_STATUSLINE=false
  WIZARD_CONFIG_FILE="$_tmp/saved.conf"
  WIZARD_NONINTERACTIVE=true
  UPDATE_MODE=true
  _rc=0
  run_wizard >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && "$UPDATE_MODE" == "false" ]] \
    && [[ "$PROFILE" == "full" && "$LANGUAGE" == "ja" ]] \
    && [[ "$ENABLE_STATUSLINE" == "false" ]] \
    && [[ "$ENABLE_AUTO_UPDATE" == "false" ]] \
    && [[ -z "$SELECTED_PLUGINS" ]]; then
    pass "mdm-managed: malformed manifest/config を無視して authoritative fresh へ収束"
  else
    fail "mdm-managed: malformed user state が managed reconciliation を阻害"
  fi
  rm -rf "$_tmp"
)

(
  _reset_mdm_config_vars
  _tmp="$(mktemp -d)"
  mkdir -p "$_tmp/.claude"
  mkfifo "$_tmp/.claude/.starter-kit-manifest.json" "$_tmp/saved.conf"
  export HOME="$_tmp" KIT_MDM_MANAGED=true PROFILE=standard LANGUAGE=en
  WIZARD_CONFIG_FILE="$_tmp/saved.conf"
  WIZARD_NONINTERACTIVE=true
  UPDATE_MODE=true
  _rc=0
  run_wizard >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && "$UPDATE_MODE" == "false" ]] \
    && [[ "$PROFILE" == "standard" && "$WIZARD_RESULT" == "deploy" ]]; then
    pass "mdm-managed: special manifest/config path を読まず zero-touch 収束"
  else
    fail "mdm-managed: special user state path で managed run が停止"
  fi
  rm -rf "$_tmp"
)

# Managed initialization failures must survive callers that capture status
# with `cmd || rc=$?` (which disables Bash errexit in the dynamic call tree).
(
  _reset_mdm_config_vars
  export KIT_MDM_MANAGED=true PROFILE=standard LANGUAGE=en
  WIZARD_NONINTERACTIVE=true
  load_profile_config() { return 37; }
  _rc=0
  run_wizard >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 37 ]]; then
    pass "mdm-managed: authoritative initialization failure を明示伝播"
  else
    fail "mdm-managed: authoritative initialization failure を成功で上書き"
  fi
)

# Normal update/non-interactive branches must also preserve helper failures;
# production callers may capture run_wizard status and thereby disable errexit.
(
  _reset_mdm_config_vars
  unset KIT_MDM_MANAGED
  UPDATE_MODE=true
  WIZARD_NONINTERACTIVE=true
  _restore_config_from_manifest() { return 41; }
  _rc=0
  run_wizard >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 41 ]]; then
    pass "mdm-managed: non-MDM update helper failure を明示伝播"
  else
    fail "mdm-managed: non-MDM update helper failure を成功で上書き"
  fi
)

(
  _reset_mdm_config_vars
  unset KIT_MDM_MANAGED
  _tmp="$(mktemp -d)"
  export HOME="$_tmp"
  WIZARD_CONFIG_FILE="$_tmp/missing.conf"
  UPDATE_MODE=false
  WIZARD_NONINTERACTIVE=true
  _fill_noninteractive_defaults() { return 42; }
  _rc=0
  run_wizard >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 42 ]]; then
    pass "mdm-managed: non-MDM noninteractive helper failure を明示伝播"
  else
    fail "mdm-managed: non-MDM noninteractive helper failure を成功で上書き"
  fi
  rm -rf "$_tmp"
)

# ── non-MDM behavior remains saved-config preserving ─────────────────────
(
  _reset_mdm_config_vars
  unset KIT_MDM_MANAGED
  _tmp="$(mktemp -d)"
  export HOME="$_tmp"
  WIZARD_CONFIG_FILE="$_tmp/saved.conf"
  cat > "$WIZARD_CONFIG_FILE" <<'CONF'
PROFILE="full"
ENABLE_STATUSLINE="false"
SELECTED_PLUGINS="legacy-only"
CONF
  # shellcheck disable=SC2034  # run_wizard reads this global.
  WIZARD_NONINTERACTIVE=true
  # shellcheck disable=SC2034  # run_wizard reads this global.
  UPDATE_MODE=false
  _rc=0
  run_wizard >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 ]] \
    && [[ "$ENABLE_STATUSLINE" == "false" && "$SELECTED_PLUGINS" == "legacy-only" ]]; then
    pass "mdm-managed: non-MDM fresh の保存値優先は不変"
  else
    fail "mdm-managed: non-MDM fresh の挙動を変更している"
  fi
  rm -rf "$_tmp"
)

mdm_test_reached_end
