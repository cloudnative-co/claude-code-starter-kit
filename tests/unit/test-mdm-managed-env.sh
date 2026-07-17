#!/bin/bash
# tests/unit/test-mdm-managed-env.sh - MDM 管理 env が update/fresh の設定復元に
# 上書きされないこと（R2-High: KIT_MDM_MANAGED 再適用機構）
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
#    非空 env 値を KEY=VALUE で列挙する ──
(
  export KIT_MDM_MANAGED=true
  export ENABLE_GHOSTTY_SETUP=false PROFILE=full
  out="$(_capture_mdm_env_overrides 2>/dev/null)" || true
  printf '%s\n' "$out" | grep -q '^ENABLE_GHOSTTY_SETUP=false$' \
    && printf '%s\n' "$out" | grep -q '^PROFILE=full$' \
    && pass "mdm-managed: MDM env を capture する" \
    || fail "mdm-managed: MDM env の capture が不正 (out: $out)"
)
(
  unset KIT_MDM_MANAGED
  export ENABLE_GHOSTTY_SETUP=false
  out="$(_capture_mdm_env_overrides 2>/dev/null)" || true
  if [[ -z "$out" ]]; then
    pass "mdm-managed: KIT_MDM_MANAGED 未設定では capture しない"
  else
    fail "mdm-managed: 非 MDM 文脈で capture してしまう (out: $out)"
  fi
)

# ── 復元クロバー後の再適用で MDM 値が勝つ（_restore_cli_overrides 互換形式）──
(
  export KIT_MDM_MANAGED=true
  export ENABLE_GHOSTTY_SETUP=false
  _saved=()
  while IFS= read -r _pair; do
    [[ -n "$_pair" ]] && _saved+=("$_pair")
  done < <(_capture_mdm_env_overrides)
  # manifest/saved config の復元が値を巻き戻したと仮定
  ENABLE_GHOSTTY_SETUP=true
  _restore_cli_overrides "${_saved[@]+"${_saved[@]}"}"
  [[ "$ENABLE_GHOSTTY_SETUP" == "false" ]] \
    && pass "mdm-managed: 復元後の再適用で MDM 値が勝つ" \
    || fail "mdm-managed: 復元に MDM 値が負ける (got '$ENABLE_GHOSTTY_SETUP')"
)

# ── run_wizard の配線（static）: update 分岐と fresh 経路の両方で再適用される ──
if grep -q '_capture_mdm_env_overrides' "$PROJECT_DIR/wizard/wizard.sh" \
  && [[ "$(grep -c '_saved_mdm\[@\]' "$PROJECT_DIR/wizard/wizard.sh")" -ge 2 ]]; then
  pass "mdm-managed: run_wizard が update/fresh 両経路で MDM env を再適用する配線"
else
  fail "mdm-managed: run_wizard の MDM env 再適用配線が無い/不完全"
fi
