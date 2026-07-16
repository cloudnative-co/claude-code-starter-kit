#!/bin/bash
# tests/unit/test-mdm-install.sh - Unit tests for mdm/install-mdm.sh (関数単位)

# install-mdm.sh は main を末尾で条件実行する（BASH_SOURCE ガード）。source して関数だけ得る。
# shellcheck source=mdm/install-mdm.sh
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

# ── 終了コード定数 ────────────────────────────────────────
if [[ "$MDM_EXIT_CONFIG" == "50" && "$MDM_EXIT_USER" == "20" ]]; then
  pass "mdm-install: 終了コード定数が定義されている"
else
  fail "mdm-install: 終了コード定数が不正"
fi

# ── JSON エスケープ ───────────────────────────────────────
if out="$(mdm_json_escape 'a"b\c')" && [[ "$out" == 'a\"b\\c' ]]; then
  pass "mdm-install: JSON エスケープ（quote/backslash）"
else
  fail "mdm-install: JSON エスケープ失敗 (got '$out')"
fi

# ── レシート生成 ──────────────────────────────────────────
# NOTE: 以下の MDM_RCPT_* はこのファイルでは直接参照せず mdm_receipt_write
# 側が間接参照するグローバル。shellcheck は静的にそれを追えないため、Task 3
# の install-mdm.sh 自身の終了コード定数と同じ「1行1定数+個別disable」方式で
# 個別に SC2034 を無効化する。
_tmpd="$(mktemp -d)"
# shellcheck disable=SC2034
MDM_RCPT_KIT_VERSION="0.73.0"
# shellcheck disable=SC2034
MDM_RCPT_GIT_REF="main"
# shellcheck disable=SC2034
MDM_RCPT_RESOLVED_SHA="abc123"
# shellcheck disable=SC2034
MDM_RCPT_INSTALL_DIR="/Users/jane/.claude-starter-kit"
# shellcheck disable=SC2034
MDM_RCPT_REQUIRED_COMPONENTS='["kit","claude_cli"]'
# shellcheck disable=SC2034
MDM_RCPT_PROFILE="standard"
# shellcheck disable=SC2034
MDM_RCPT_TARGET_USER="jane"
# shellcheck disable=SC2034
MDM_RCPT_PARTIAL='[]'
# shellcheck disable=SC2034
MDM_RCPT_TIMESTAMP="2026-07-16T00:00:00Z"
# shellcheck disable=SC2034
MDM_RCPT_LOG_PATH="/Library/Logs/ClaudeCodeStarterKit/install.log"
mdm_receipt_write "$_tmpd/receipt.json" "success" "0"

# NOTE: assert_json_field は field を `jq -r "$field"` にそのまま渡すため、
# フィルタ式として先頭ドット (.result 等) が必須。ドット無し ("result") は
# jq のコンパイルエラーになり __JQ_ERROR__ 比較で常に失敗する。
if assert_json_field "$_tmpd/receipt.json" ".result" "success" "result=success"; then
  pass "mdm-install: レシート result フィールド"
else
  fail "mdm-install: レシート result フィールド不正"
fi
if assert_json_field "$_tmpd/receipt.json" ".exit_code" "0" "exit_code=0"; then
  pass "mdm-install: レシート exit_code フィールド"
else
  fail "mdm-install: レシート exit_code フィールド不正"
fi
if assert_json_field "$_tmpd/receipt.json" ".install_dir" "/Users/jane/.claude-starter-kit" "install_dir 記録"; then
  pass "mdm-install: レシート install_dir 記録"
else
  fail "mdm-install: レシート install_dir 未記録"
fi
# jq でパース可能な妥当 JSON か
if jq -e . "$_tmpd/receipt.json" >/dev/null 2>&1; then
  pass "mdm-install: レシートは妥当な JSON"
else
  fail "mdm-install: レシートが不正な JSON"
fi
rm -rf "$_tmpd"

# ── 対象ユーザー解決（モック）────────────────────────────
(
  export KIT_MDM_TARGET_USER="jane"
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "jane" ]]; then
    pass "mdm-install: KIT_MDM_TARGET_USER が優先される"
  else
    fail "mdm-install: KIT_MDM_TARGET_USER 優先が効かない (got '$out')"
  fi
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="alice"   # テスト用フック
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "alice" ]]; then
    pass "mdm-install: コンソールユーザーにフォールバック"
  else
    fail "mdm-install: コンソールユーザー解決失敗 (got '$out')"
  fi
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="root"     # 無効ユーザー
  # NOTE: 関数呼び出しを裸のステートメントとして書き $? を後で参照すると、
  # 失敗時(20)に継承された set -e でこのサブシェルが assert 行の手前で
  # 即終了し、外側の test runner (set -euo pipefail 下で source) まで
  # 停止する。`|| _rc=$?` で明示的に捕捉して errexit を回避する。
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "root は無効ユーザーで exit USER" \
    && pass "mdm-install: root/システムユーザーを拒否" \
    || fail "mdm-install: root を拒否すべき"
)

# ── home 検証（モック）────────────────────────────────────
_tmpd="$(mktemp -d)"
# macOS では mktemp -d が /var/... (実体は /private/var/... へのシンボリックリンク)
# を返すため、実装側の canonical 化 (cd && pwd -P) と比較する前に _tmpd 自体も
# 正規化しておかないと期待値がシンボリックリンク経由のパスのままズレる。
_tmpd="$(cd "$_tmpd" && pwd -P)"
_fakehome="$_tmpd/Users/jane"
mkdir -p "$_fakehome"
(
  export MDM_DSCL_HOME_OVERRIDE="$_fakehome"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1        # テストは非root所有のため owner 検査を切替
  if out="$(mdm_validate_user_home "jane" 2>/dev/null)" && [[ "$out" == "$_fakehome" ]]; then
    pass "mdm-install: home 検証が canonical パスを返す"
  else
    fail "mdm-install: home 検証失敗 (got '$out')"
  fi
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_tmpd/Users/nonexistent"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  _rc=0
  mdm_validate_user_home "jane" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "存在しない home は exit USER" \
    && pass "mdm-install: 存在しない home を拒否" \
    || fail "mdm-install: 存在しない home を拒否すべき"
)
rm -rf "$_tmpd"

# ── 前提方針判定 ─────────────────────────────────────────
( export MDM_BREW_PRESENT_OVERRIDE=1
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "skip" ]] && pass "mdm-install: brew あり -> skip" || fail "mdm-install: brew あり時は skip (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_INSTALL_HOMEBREW=true KIT_MDM_PREREQ_MODE=auto
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "bootstrap" ]] && pass "mdm-install: brew なし+install=true -> bootstrap" || fail "mdm-install: bootstrap 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_INSTALL_HOMEBREW=false
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "fail" ]] && pass "mdm-install: brew なし+install=false -> fail" || fail "mdm-install: fail 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_PREREQ_MODE=skip
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "skip" ]] && pass "mdm-install: PREREQ_MODE=skip は skip" || fail "mdm-install: skip 期待 (got '$out')" )

# ── 降格 argv 構築 ───────────────────────────────────────
(
  export PROFILE="standard" LANGUAGE="ja" KIT_MDM_GIT_REF="main"
  argv="$(mdm_build_drop_argv 501 jane /Users/jane /path/to/setup.sh --non-interactive 2>/dev/null)"
  # env -i と固定変数、許可された設定変数が含まれ、root の無関係な変数は含まれない
  echo "$argv" | grep -q 'env' || fail "mdm-install: env -i が無い"
  echo "$argv" | grep -q 'HOME=/Users/jane' && pass "mdm-install: HOME を固定" || fail "mdm-install: HOME 固定なし"
  echo "$argv" | grep -q 'USER=jane' && pass "mdm-install: USER を固定" || fail "mdm-install: USER 固定なし"
  echo "$argv" | grep -q 'PROFILE=standard' && pass "mdm-install: PROFILE を伝搬" || fail "mdm-install: PROFILE 伝搬なし"
  echo "$argv" | grep -q 'LANGUAGE=ja' && pass "mdm-install: LANGUAGE を伝搬" || fail "mdm-install: LANGUAGE 伝搬なし"
)
(
  unset PROFILE
  argv="$(mdm_build_drop_argv 501 jane /Users/jane /path/to/setup.sh 2>/dev/null)"
  if echo "$argv" | grep -q 'PROFILE='; then
    fail "mdm-install: 未設定の PROFILE は渡さない"
  else
    pass "mdm-install: 未設定変数は伝搬しない"
  fi
)

# ── LANG マッピング回帰テスト（Task 8 バグ修正）─────────────
# 旧実装は "LANG=${LANGUAGE}_JP.UTF-8" と決め打ちしており、LANGUAGE=en のとき
# 不正ロケール "en_JP.UTF-8" を生成していた。_mdm_lang_to_locale 経由で
# en->en_US.UTF-8 / ja->ja_JP.UTF-8 に正しくマップされることを確認する。
(
  export LANGUAGE="en"
  argv="$(mdm_build_drop_argv 501 jane /Users/jane /path/to/setup.sh 2>/dev/null)"
  echo "$argv" | grep -q '^LANG=en_US.UTF-8$' \
    && pass "mdm-install: LANGUAGE=en は LANG=en_US.UTF-8 にマップ" \
    || fail "mdm-install: LANGUAGE=en の LANG マッピングが不正 (argv: $argv)"
)
(
  export LANGUAGE="ja"
  argv="$(mdm_build_drop_argv 501 jane /Users/jane /path/to/setup.sh 2>/dev/null)"
  echo "$argv" | grep -q '^LANG=ja_JP.UTF-8$' \
    && pass "mdm-install: LANGUAGE=ja は LANG=ja_JP.UTF-8 にマップ" \
    || fail "mdm-install: LANGUAGE=ja の LANG マッピングが不正 (argv: $argv)"
)

# ── Homebrew pkg URL 解決（GitHub API レスポンスのモック。jq 非依存 grep/sed）──
_brew_tmpd="$(mktemp -d)"
_brew_fixture_ok="$_brew_tmpd/release-ok.json"
cat > "$_brew_fixture_ok" <<'EOF'
{
  "tag_name": "4.6.15",
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg.sha256",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg.sha256"
    },
    {
      "name": "Homebrew-4.6.15.pkg",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_ok"
  out="$(_mdm_resolve_brew_pkg_url 2>/dev/null)"
  if [[ "$out" == "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg" ]]; then
    pass "mdm-install: brew pkg URL を .pkg アセットから解決"
  else
    fail "mdm-install: brew pkg URL 解決が不正 (got '$out')"
  fi
)

_brew_fixture_nopkg="$_brew_tmpd/release-nopkg.json"
cat > "$_brew_fixture_nopkg" <<'EOF'
{
  "tag_name": "4.6.15",
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg.sha256",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg.sha256"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_nopkg"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: .pkg アセットが無い場合は失敗を返す"
  else
    fail "mdm-install: .pkg アセットが無いのに成功してしまう"
  fi
)

(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_tmpd/does-not-exist.json"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: JSON 取得不可（空応答）時は失敗を返す"
  else
    fail "mdm-install: 空応答なのに成功してしまう"
  fi
)
rm -rf "$_brew_tmpd"
