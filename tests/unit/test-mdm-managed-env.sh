#!/bin/bash
# tests/unit/test-mdm-managed-env.sh - MDM 管理 env が update/fresh の設定復元に
# 上書きされないこと（R2-High）+ capture の改行注入排除（R3-Medium）
#
# 背景: setup.sh の update 経路（_restore_config_from_manifest）と fresh 経路
# （_load_config_preserving_cli_overrides → _safe_source_config）は、既存の
# 環境変数値を無条件に上書きする。MDM ラッパーが検証済みで注入した設定
# （例: ENABLE_GHOSTTY_SETUP=false）が保存済みユーザー設定に負けると、
# 管理端末で MDM 管理者の意図が更新のたびに巻き戻る。
# KIT_MDM_MANAGED=true のとき、復元後に MDM 注入 env を再適用する。

# wizard.sh は source 時に registry.sh / steps.sh を読み込む（test-wizard-utils.sh と同じ手法）
# shellcheck source=wizard/wizard.sh
source "$PROJECT_DIR/wizard/wizard.sh"

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

# ── run_wizard の配線（static）: update 分岐と fresh 経路の両方で再適用される ──
if grep -q '_capture_mdm_env_overrides' "$PROJECT_DIR/wizard/wizard.sh" \
  && [[ "$(grep -c '_MDM_ENV_OVERRIDES\[@\]' "$PROJECT_DIR/wizard/wizard.sh")" -ge 2 ]]; then
  pass "mdm-managed: run_wizard が update/fresh 両経路で MDM env を再適用する配線"
else
  fail "mdm-managed: run_wizard の MDM env 再適用配線が無い/不完全"
fi
