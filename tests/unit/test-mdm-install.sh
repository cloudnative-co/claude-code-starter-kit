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
# spec §5.4: 実在するローカルアカウント（dscl 実在確認）かつ UID >= 501 を要求。
# テストは MDM_DSCL_UID_OVERRIDE で UID をモックする。
(
  export KIT_MDM_TARGET_USER="jane" MDM_DSCL_UID_OVERRIDE=501
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "jane" ]]; then
    pass "mdm-install: KIT_MDM_TARGET_USER が優先される"
  else
    fail "mdm-install: KIT_MDM_TARGET_USER 優先が効かない (got '$out')"
  fi
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="alice" MDM_DSCL_UID_OVERRIDE=502   # テスト用フック
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "alice" ]]; then
    pass "mdm-install: コンソールユーザーにフォールバック"
  else
    fail "mdm-install: コンソールユーザー解決失敗 (got '$out')"
  fi
)
# UID < 501（システムアカウント）は明示指定でも拒否（最終レビュー High#8）
(
  export KIT_MDM_TARGET_USER="svcaccount" MDM_DSCL_UID_OVERRIDE=89
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "UID<501 は exit USER" \
    && pass "mdm-install: UID<501 のシステムアカウントを拒否" \
    || fail "mdm-install: UID<501 を拒否すべき (got $_rc)"
)
# 実在しないユーザー（dscl 解決不能 = UID 空）は拒否
(
  export KIT_MDM_TARGET_USER="mdm-no-such-user-x"
  unset MDM_DSCL_UID_OVERRIDE
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "実在しないユーザーは exit USER" \
    && pass "mdm-install: 実在しないユーザーを拒否" \
    || fail "mdm-install: 実在しないユーザーを拒否すべき (got $_rc)"
)
# username 文字種違反は拒否（injection/パス操作防止）
(
  export KIT_MDM_TARGET_USER='bad;user' MDM_DSCL_UID_OVERRIDE=501
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "文字種違反は exit USER" \
    && pass "mdm-install: username 文字種違反を拒否" \
    || fail "mdm-install: username 文字種違反を拒否すべき (got $_rc)"
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

# ── 降格 argv 構築（グローバル配列 MDM_DROP_ARGV へ直接構築。最終レビュー High#4）──
# 旧実装の「改行区切り stdout → read -r で配列化」は、改行を含む値（env 由来
# EDITOR_CHOICE 等）で env のコマンド位置に任意コマンドを注入できたため廃止。
(
  export PROFILE="standard" LANGUAGE="ja" KIT_MDM_GIT_REF="main"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh --non-interactive 2>/dev/null \
    || fail "mdm-install: mdm_build_drop_argv が失敗した"
  [[ "${MDM_DROP_ARGV[0]}" == "/usr/bin/env" && "${MDM_DROP_ARGV[1]}" == "-i" ]] \
    && pass "mdm-install: /usr/bin/env -i を絶対パスで先頭に置く" \
    || fail "mdm-install: env -i が絶対パスで先頭に無い (got '${MDM_DROP_ARGV[0]}' '${MDM_DROP_ARGV[1]:-}')"
  _has() { local _e; for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == "$1" ]] && return 0; done; return 1; }
  _has 'HOME=/Users/jane' && pass "mdm-install: HOME を固定" || fail "mdm-install: HOME 固定なし"
  _has 'USER=jane' && pass "mdm-install: USER を固定" || fail "mdm-install: USER 固定なし"
  _has 'PROFILE=standard' && pass "mdm-install: PROFILE を伝搬" || fail "mdm-install: PROFILE 伝搬なし"
  _has 'LANGUAGE=ja' && pass "mdm-install: LANGUAGE を伝搬" || fail "mdm-install: LANGUAGE 伝搬なし"
  # 実行コマンドは呼び出し側指定の位置に単一要素で並ぶ
  _has '/bin/bash' && _has '/path/to/setup.sh' && _has '--non-interactive' \
    && pass "mdm-install: 実行コマンドと引数が argv に含まれる" \
    || fail "mdm-install: 実行コマンド/引数が argv に無い"
)
(
  unset PROFILE
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do case "$_e" in PROFILE=*) _found=1 ;; esac; done
  if [[ "$_found" -eq 1 ]]; then
    fail "mdm-install: 未設定の PROFILE は渡さない"
  else
    pass "mdm-install: 未設定変数は伝搬しない"
  fi
)
# ★注入回帰: 改行を含む passthrough 値は拒否する（env のコマンド位置注入防止）
(
  export EDITOR_CHOICE=$'none\n/usr/bin/id'
  _rc=0
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: 改行を含む passthrough 値を拒否"
  else
    fail "mdm-install: 改行を含む passthrough 値が argv に混入し得る（注入回帰）"
  fi
)
# 空白を含む値は単一の argv 要素のまま保持される（word splitting されない）
(
  export EDITOR_CHOICE='none plus extra'
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null \
    || fail "mdm-install: 空白入り値で失敗した"
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'EDITOR_CHOICE=none plus extra' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: 空白入り値が単一要素で保持される" \
    || fail "mdm-install: 空白入り値が単一要素で保持されない"
)

# ── LANG マッピング回帰テスト（Task 8 バグ修正）─────────────
# 旧実装は "LANG=${LANGUAGE}_JP.UTF-8" と決め打ちしており、LANGUAGE=en のとき
# 不正ロケール "en_JP.UTF-8" を生成していた。_mdm_lang_to_locale 経由で
# en->en_US.UTF-8 / ja->ja_JP.UTF-8 に正しくマップされることを確認する。
(
  export LANGUAGE="en"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'LANG=en_US.UTF-8' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: LANGUAGE=en は LANG=en_US.UTF-8 にマップ" \
    || fail "mdm-install: LANGUAGE=en の LANG マッピングが不正"
)
(
  export LANGUAGE="ja"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'LANG=ja_JP.UTF-8' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: LANGUAGE=ja は LANG=ja_JP.UTF-8 にマップ" \
    || fail "mdm-install: LANGUAGE=ja の LANG マッピングが不正"
)

# ── _mdm_exec_as_user は launchctl/sudo を絶対パスで組み立てる ──
# MDM_EXEC_AS_USER_DRYRUN=1 で実行せず argv を表示のみ（表示は再パースされない）。
(
  export MDM_EXEC_AS_USER_DRYRUN=1
  out="$(_mdm_exec_as_user 501 jane /Users/jane /bin/bash /path/to/setup.sh --non-interactive 2>/dev/null)"
  printf '%s' "$out" | head -1 | grep -q '^/bin/launchctl$' \
    && pass "mdm-install: launchctl を絶対パスで起動" \
    || fail "mdm-install: launchctl が絶対パスでない (out: $(printf '%s' "$out" | head -1))"
  printf '%s\n' "$out" | grep -q '^/usr/bin/sudo$' \
    && pass "mdm-install: sudo を絶対パスで起動" \
    || fail "mdm-install: sudo が絶対パスでない"
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

# ── MDM 既定値の適用（Ghostty は MDM 既定 off・spec §5.6）─────
# mdm_config_apply と同じ「既存 env 値は上書きしない」優先順位を踏襲する
# ことを確認する: 未設定時のみ false を既定にし、conf/env で明示済みの
# true/false はそのまま維持されなければならない。
(
  unset ENABLE_GHOSTTY_SETUP
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "false" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP 未設定時は既定 false"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP 未設定時の既定が不正 (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)
(
  export ENABLE_GHOSTTY_SETUP=true
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "true" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP=true の明示指定を維持"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP=true の明示指定が上書きされた (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)
(
  export ENABLE_GHOSTTY_SETUP=false
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "false" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP=false の明示指定を維持"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP=false の明示指定が上書きされた (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)

# ── setup.sh 引数の組み立て（グローバル配列 MDM_SETUP_ARGV へ直接構築）──
# 実 setup.sh 実行は副作用があるため、argv 組み立て (mdm_build_setup_argv)
# のみを検証する。mdm_validate_bool は test-mdm-config.sh（アルファベット順
# でこのファイルより先に実行される）が共有プロセスへ source 済みの前提
# （mdm_prereq_plan の既存テストと同じ依存関係）。
_setup_argv_has() { local _e; for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == "$1" ]] && return 0; done; return 1; }
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv 2>/dev/null
  _setup_argv_has '--non-interactive' \
    && pass "mdm-install: setup.sh argv に --non-interactive を含む" \
    || fail "mdm-install: setup.sh argv に --non-interactive が無い (argv: ${MDM_SETUP_ARGV[*]})"
  if _setup_argv_has '--dry-run'; then
    fail "mdm-install: KIT_MDM_DRY_RUN 未設定なのに --dry-run が含まれる"
  else
    pass "mdm-install: KIT_MDM_DRY_RUN 未設定時は --dry-run を含まない"
  fi
)
(
  export KIT_MDM_DRY_RUN=true
  mdm_build_setup_argv 2>/dev/null
  _setup_argv_has '--dry-run' \
    && pass "mdm-install: KIT_MDM_DRY_RUN=true で --dry-run を配線" \
    || fail "mdm-install: KIT_MDM_DRY_RUN=true なのに --dry-run が無い (argv: ${MDM_SETUP_ARGV[*]})"
)
(
  export KIT_MDM_DRY_RUN=false
  mdm_build_setup_argv 2>/dev/null
  if _setup_argv_has '--dry-run'; then
    fail "mdm-install: KIT_MDM_DRY_RUN=false なのに --dry-run が含まれる"
  else
    pass "mdm-install: KIT_MDM_DRY_RUN=false 時は --dry-run を含まない"
  fi
)
