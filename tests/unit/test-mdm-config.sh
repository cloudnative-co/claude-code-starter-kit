#!/bin/bash
# tests/unit/test-mdm-config.sh - Unit tests for mdm/lib-mdm-config.sh

# shellcheck source=mdm/lib-mdm-config.sh
source "$PROJECT_DIR/mdm/lib-mdm-config.sh"

# ── bool 検証 ─────────────────────────────────────────────
if out="$(mdm_validate_bool "true")" && [[ "$out" == "true" ]]; then
  pass "mdm-config: bool 'true' -> true"
else
  fail "mdm-config: bool 'true' should normalize to true (got '$out')"
fi

if out="$(mdm_validate_bool "yes")" && [[ "$out" == "true" ]]; then
  pass "mdm-config: bool 'yes' -> true"
else
  fail "mdm-config: bool 'yes' should normalize to true (got '$out')"
fi

if out="$(mdm_validate_bool "0")" && [[ "$out" == "false" ]]; then
  pass "mdm-config: bool '0' -> false"
else
  fail "mdm-config: bool '0' should normalize to false (got '$out')"
fi

if mdm_validate_bool "maybe" >/dev/null 2>&1; then
  fail "mdm-config: bool 'maybe' should be rejected"
else
  pass "mdm-config: bool 'maybe' rejected"
fi

# ── enum 検証 ─────────────────────────────────────────────
if out="$(mdm_validate_enum "standard" "minimal,standard,full")" && [[ "$out" == "standard" ]]; then
  pass "mdm-config: enum 'standard' accepted"
else
  fail "mdm-config: enum 'standard' should be accepted (got '$out')"
fi

if mdm_validate_enum "custom" "minimal,standard,full" >/dev/null 2>&1; then
  fail "mdm-config: enum 'custom' should be rejected"
else
  pass "mdm-config: enum 'custom' rejected"
fi

# ── git ref 検証（--branch 方式）────────────────────────────
for _ref in "main" "v0.72.0" "feature/x" "0123456789abcdef0123456789abcdef01234567"; do
  if mdm_validate_gitref "$_ref" >/dev/null 2>&1; then
    pass "mdm-config: gitref '$_ref' accepted"
  else
    fail "mdm-config: gitref '$_ref' should be accepted"
  fi
done
for _bad in "" "--force" "a b" "refs/../../etc" "x~1"; do
  if mdm_validate_gitref "$_bad" >/dev/null 2>&1; then
    fail "mdm-config: gitref '$_bad' should be rejected"
  else
    pass "mdm-config: gitref '$_bad' rejected"
  fi
done

# ── username 検証 ─────────────────────────────────────────
if mdm_validate_username "jane" >/dev/null 2>&1; then
  pass "mdm-config: username 'jane' accepted"
else
  fail "mdm-config: username 'jane' should be accepted"
fi
if mdm_validate_username "root; rm" >/dev/null 2>&1; then
  fail "mdm-config: username with metachar should be rejected"
else
  pass "mdm-config: username with metachar rejected"
fi

# ── abspath 検証 ──────────────────────────────────────────
if mdm_validate_abspath "/Users/jane/.claude-starter-kit" >/dev/null 2>&1; then
  pass "mdm-config: abspath accepted"
else
  fail "mdm-config: abspath should be accepted"
fi
if mdm_validate_abspath "relative/path" >/dev/null 2>&1; then
  fail "mdm-config: relative path should be rejected"
else
  pass "mdm-config: relative path rejected"
fi
if mdm_validate_abspath "/a/../../etc/passwd" >/dev/null 2>&1; then
  fail "mdm-config: path with .. should be rejected"
else
  pass "mdm-config: path with .. rejected"
fi

# ── ファイル安全性 ────────────────────────────────────────
_tmpd="$(mktemp -d)"
_conf="$_tmpd/mdm-config.conf"
cat > "$_conf" <<'CONF'
PROFILE="standard"
LANGUAGE="ja"
KIT_MDM_INSTALL_HOMEBREW="true"
CONF
chmod 600 "$_conf"

export MDM_CONFIG_SKIP_OWNER_CHECK=1  # テスト環境は非root所有のため owner 検査を無効化
if mdm_config_file_is_secure "$_conf"; then
  pass "mdm-config: 600 の通常ファイルは secure"
else
  fail "mdm-config: 600 の通常ファイルが secure 判定されない"
fi

chmod 666 "$_conf"
if mdm_config_file_is_secure "$_conf"; then
  fail "mdm-config: group/other 書込可は reject すべき"
else
  pass "mdm-config: group/other 書込可を reject"
fi
chmod 600 "$_conf"

ln -s "$_conf" "$_tmpd/link.conf"
if mdm_config_file_is_secure "$_tmpd/link.conf"; then
  fail "mdm-config: symlink は reject すべき"
else
  pass "mdm-config: symlink を reject"
fi

# 親ディレクトリが group/other 書込可なら reject（Medium・spec §9.2:
# 書込可能な親では他者が symlink/差し替えを植えられる）
_openparent="$_tmpd/open-parent"
mkdir -p "$_openparent"
chmod 777 "$_openparent"
cat > "$_openparent/mdm-config.conf" <<'CONF'
PROFILE="standard"
CONF
chmod 600 "$_openparent/mdm-config.conf"
if mdm_config_file_is_secure "$_openparent/mdm-config.conf"; then
  fail "mdm-config: 書込可能な親ディレクトリを reject すべき"
else
  pass "mdm-config: 書込可能な親ディレクトリを reject"
fi
chmod 755 "$_openparent"
if mdm_config_file_is_secure "$_openparent/mdm-config.conf"; then
  pass "mdm-config: 安全な親ディレクトリ（755）は許容"
else
  fail "mdm-config: 755 の親ディレクトリが reject される"
fi

# ── 読込・優先順位・型検証 ──────────────────────────────────
( # subshell で環境汚染を隔離
  unset PROFILE LANGUAGE KIT_MDM_INSTALL_HOMEBREW
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  if mdm_config_apply "$_conf" && [[ "$PROFILE" == "standard" && "$LANGUAGE" == "ja" ]]; then
    pass "mdm-config: apply が値を export"
  else
    fail "mdm-config: apply が値を export しない (PROFILE='$PROFILE')"
  fi
)

( # 優先順位: 既存の env 値は上書きしない
  export PROFILE="full"  # CLI/env 相当（先に設定済み）
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  mdm_config_apply "$_conf" >/dev/null 2>&1
  if [[ "$PROFILE" == "full" ]]; then
    pass "mdm-config: 既存 env 値を conf が上書きしない（優先順位）"
  else
    fail "mdm-config: 優先順位違反 PROFILE='$PROFILE'（full を維持すべき）"
  fi
)

# 不正値は exit 50
cat > "$_conf" <<'CONF'
PROFILE="nonsense"
CONF
chmod 600 "$_conf"
( export MDM_CONFIG_SKIP_OWNER_CHECK=1
  # NOTE: mdm_config_apply を裸のステートメントとして呼ぶと、失敗時(50)に
  # 継承された `set -e` によりこのサブシェルが assert 行の手前で即終了し、
  # さらにその終了コードが外側の test runner (set -euo pipefail 下で
  # source される) に伝播してテストスイート全体が停止する
  # (実機検証済み)。`|| _rc=$?` で明示的に捕捉して errexit を回避する。
  _rc=0
  mdm_config_apply "$_conf" >/dev/null 2>&1 || _rc=$?
  assert_exit_code 50 "$_rc" "不正 PROFILE は exit 50" \
    && pass "mdm-config: 不正 enum 値で exit 50" \
    || fail "mdm-config: 不正 enum 値で exit 50 を返すべき"
)

# ══ staging 一括検証（最終レビュー High#3）══
# 優先順位 CLI > env > config を staging に集めて確定後、全入力源の値を
# 一括で型検証する。env / CLI 由来の値も無検証で通過してはならない。

# env 由来の不正値も exit 50（旧実装は既存 env 値を無検証で保持していた）
(
  export PROFILE="nonsense" MDM_CONFIG_SKIP_OWNER_CHECK=1
  _rc=0
  mdm_config_apply "/nonexistent-mdm-config" >/dev/null 2>&1 || _rc=$?
  assert_exit_code 50 "$_rc" "env 不正値は exit 50" \
    && pass "mdm-config: env 由来の不正値も exit 50" \
    || fail "mdm-config: env 由来の不正値を検証すべき (got $_rc)"
)

# env 由来の値も正規化されて export される（YES -> true）
(
  export ENABLE_STATUSLINE="YES" MDM_CONFIG_SKIP_OWNER_CHECK=1
  mdm_config_apply "/nonexistent-mdm-config" >/dev/null 2>&1 || true
  [[ "$ENABLE_STATUSLINE" == "true" ]] \
    && pass "mdm-config: env 値が正規化される (YES -> true)" \
    || fail "mdm-config: env 値の正規化が効かない (got '$ENABLE_STATUSLINE')"
)

# CLI 引数（KEY=VALUE）は env より優先
(
  export PROFILE="minimal" MDM_CONFIG_SKIP_OWNER_CHECK=1
  mdm_config_apply "/nonexistent-mdm-config" "PROFILE=full" >/dev/null 2>&1 || true
  [[ "$PROFILE" == "full" ]] \
    && pass "mdm-config: CLI 引数が env より優先" \
    || fail "mdm-config: CLI > env の優先順位違反 (got '$PROFILE')"
)

# CLI 引数の不正値は exit 50
(
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _rc=0
  mdm_config_apply "/nonexistent-mdm-config" "PROFILE=nonsense" >/dev/null 2>&1 || _rc=$?
  assert_exit_code 50 "$_rc" "CLI 不正値は exit 50" \
    && pass "mdm-config: CLI 引数の不正値で exit 50" \
    || fail "mdm-config: CLI 引数の不正値を検証すべき (got $_rc)"
)

# CLI 引数の未知キーは警告して無視（config ファイルの未知キーと同じ方針）、
# 空引数は無視（Jamf の未使用スクリプトパラメータ対策）
(
  unset PROFILE
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _rc=0
  mdm_config_apply "/nonexistent-mdm-config" "" "UNKNOWN_KEY=x" "PROFILE=standard" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 && "${PROFILE:-}" == "standard" ]] \
    && pass "mdm-config: CLI 未知キー/空引数を無視して続行" \
    || fail "mdm-config: CLI 未知キー/空引数の扱いが不正 (rc=$_rc PROFILE='${PROFILE:-}')"
)

# config ファイル値が env に上書きされる場合、負けた config 値は結果に影響しない
(
  cat > "$_conf" <<'CONF'
PROFILE="minimal"
CONF
  chmod 600 "$_conf"
  export PROFILE="full" MDM_CONFIG_SKIP_OWNER_CHECK=1
  mdm_config_apply "$_conf" >/dev/null 2>&1 || true
  [[ "$PROFILE" == "full" ]] \
    && pass "mdm-config: env が config ファイルより優先（staging 後も維持）" \
    || fail "mdm-config: env > config の優先順位違反 (got '$PROFILE')"
)
rm -rf "$_tmpd"
