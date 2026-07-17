#!/bin/bash
# tests/unit/test-mdm-keys-in-sync.sh - MDM 許可キーが本体 _CONFIG_KEYS と整合するか

# 本体レジストリのキーを取得
# shellcheck source=wizard/registry.sh
source "$PROJECT_DIR/wizard/registry.sh" 2>/dev/null || true
# shellcheck source=mdm/lib-mdm-config.sh
source "$PROJECT_DIR/mdm/lib-mdm-config.sh"

# 代表的な本体キーが MDM allowlist に含まれること（EDITOR_CHOICE / ENABLE_GHOSTTY_SETUP は誤名検出の要）
for _k in PROFILE LANGUAGE EDITOR_CHOICE ENABLE_GHOSTTY_SETUP ENABLE_SAFETY_NET; do
  if printf '%s' "$_MDM_ALLOWED_KEYS" | grep -qw "$_k"; then
    pass "mdm-keys: '$_k' が MDM allowlist に存在"
  else
    fail "mdm-keys: '$_k' が MDM allowlist に無い（本体キー名との乖離）"
  fi
done

# 誤名が紛れていないこと（EDITOR / ENABLE_GHOSTTY は本体に無い旧誤名）
for _bad in EDITOR ENABLE_GHOSTTY; do
  if printf '%s' "$_MDM_ALLOWED_KEYS" | grep -qw "$_bad"; then
    fail "mdm-keys: 誤ったキー名 '$_bad' が混入（正しくは *_CHOICE / *_SETUP）"
  else
    pass "mdm-keys: 誤名 '$_bad' は含まれない"
  fi
done

# ── フル照合（Medium）: 代表キーだけでなく全キーの乖離を検出する ──
# (1) _MDM_ALLOWED_KEYS の非 KIT_MDM_ キーはすべて本体 _CONFIG_KEYS に実在すること
_drift=""
for _k in $_MDM_ALLOWED_KEYS; do
  case "$_k" in KIT_MDM_*) continue ;; esac
  _found=0
  for _ck in "${_CONFIG_KEYS[@]}"; do
    [[ "$_ck" == "$_k" ]] && _found=1 && break
  done
  [[ "$_found" -eq 0 ]] && _drift="$_drift $_k"
done
if [[ -z "$_drift" ]]; then
  pass "mdm-keys: allowlist の全非 KIT キーが本体 _CONFIG_KEYS に実在（フル照合）"
else
  fail "mdm-keys: 本体 _CONFIG_KEYS に無いキーが allowlist に混入:$_drift"
fi

# (2) install-mdm.sh の _MDM_PASSTHROUGH_KEYS（proxy 変数を除く）は
#     すべて _MDM_ALLOWED_KEYS に含まれること（伝搬キーと許可キーの整合）
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
_drift2=""
for _k in $_MDM_PASSTHROUGH_KEYS; do
  case "$_k" in HTTP_PROXY|HTTPS_PROXY|NO_PROXY) continue ;; esac
  printf '%s' "$_MDM_ALLOWED_KEYS" | grep -qw "$_k" || _drift2="$_drift2 $_k"
done
if [[ -z "$_drift2" ]]; then
  pass "mdm-keys: passthrough キーが allowlist と整合（フル照合）"
else
  fail "mdm-keys: allowlist に無い passthrough キー:$_drift2"
fi
