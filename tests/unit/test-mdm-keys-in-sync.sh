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
