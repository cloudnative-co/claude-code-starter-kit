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

# ══ R2-High: レシートは umask に依存せず 644/755 で作成され、symlink を辿らない ══
(
  # MDM agent の umask が 000 でもレシート 644 / ディレクトリ 755（spec §9.3）。
  # 666 のレシートは一般ユーザーが書き換え可能になり detect-mdm の compliant
  # 偽装（任意 repo を導入済みキットとして通す）に直結する。
  umask 000
  _u0dir="$_tmpd/umask0/sub"
  mdm_receipt_write "$_u0dir/receipt-jane.json" success 0
  _fmode="$(stat -f '%Lp' "$_u0dir/receipt-jane.json" 2>/dev/null || stat -c '%a' "$_u0dir/receipt-jane.json" 2>/dev/null)"
  _dmode="$(stat -f '%Lp' "$_u0dir" 2>/dev/null || stat -c '%a' "$_u0dir" 2>/dev/null)"
  [[ "$_fmode" == "644" ]] \
    && pass "mdm-install: umask 000 でもレシートは 644" \
    || fail "mdm-install: umask 000 でレシートが ${_fmode}（書換可能な contract 違反）"
  [[ "$_dmode" == "755" ]] \
    && pass "mdm-install: umask 000 でもレシート dir は 755" \
    || fail "mdm-install: umask 000 でレシート dir が $_dmode"
)
(
  # レシートパスに先置きされた symlink を辿らない（標的ファイル無傷 + 実体化）
  _sldir="$_tmpd/rcpt-symlink"
  mkdir -p "$_sldir"
  printf 'victim\n' > "$_sldir/victim-file"
  ln -s "$_sldir/victim-file" "$_sldir/receipt-jane.json"
  mdm_receipt_write "$_sldir/receipt-jane.json" success 0
  if [[ ! -L "$_sldir/receipt-jane.json" && -f "$_sldir/receipt-jane.json" ]] \
     && [[ "$(cat "$_sldir/victim-file")" == "victim" ]]; then
    pass "mdm-install: レシート書込は symlink を辿らない（標的無傷・実体化）"
  else
    fail "mdm-install: レシート書込が symlink を辿る/実体化しない"
  fi
)
rm -rf "$_tmpd"

# ── JSON エスケープ: 制御文字（Medium: 無検証環境値の改行等で JSON が壊れない）──
(
  out="$(mdm_json_escape "$(printf 'a\nb\tc')")"
  if [[ "$out" == 'a\nb\tc' ]]; then
    pass "mdm-install: JSON エスケープが改行/タブを \\n \\t に変換"
  else
    fail "mdm-install: 制御文字のエスケープが不正 (got '$out')"
  fi
)

# ── 終了コード契約: CLT 不足=10 / Homebrew 失敗=11 を区別（Medium・spec §8.1）──
(
  export MDM_CLT_PRESENT_OVERRIDE=0 KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=false
  _rc=0
  _mdm_bootstrap_prereqs jane >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_PREREQ" "$_rc" "CLT 不足は exit 10" \
    && pass "mdm-install: CLT 不足を exit 10（前提不足）で返す" \
    || fail "mdm-install: CLT 不足の終了コードが不正 (got $_rc)"
)
(
  export MDM_CLT_PRESENT_OVERRIDE=1 MDM_BREW_PRESENT_OVERRIDE=0
  export MDM_BREW_RELEASES_JSON_OVERRIDE=/nonexistent-brew-json
  _rc=0
  _mdm_bootstrap_prereqs jane >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_BREW" "$_rc" "brew 失敗は exit 11" \
    && pass "mdm-install: Homebrew 失敗を exit 11 で返す" \
    || fail "mdm-install: Homebrew 失敗の終了コードが不正 (got $_rc)"
)

# ── 設定・ユーザー解決失敗時の best-effort _unresolved レシート（Medium・spec §8.3(a)）──
(
  _tmpu="$(mktemp -d)"
  export MDM_UNRESOLVED_RCPT_DIR_OVERRIDE="$_tmpu"
  _rc=0
  ( MDM_LOG_FILE=""; _mdm_fail_unresolved 50 ) >/dev/null 2>&1 || _rc=$?
  assert_exit_code 50 "$_rc" "_mdm_fail_unresolved は指定コードで exit" \
    && pass "mdm-install: _mdm_fail_unresolved が指定コードで終了" \
    || fail "mdm-install: _mdm_fail_unresolved の exit code 不一致 (got $_rc)"
  if assert_json_field "$_tmpu/receipt-_unresolved.json" ".result" "failure" "result=failure" 2>/dev/null; then
    pass "mdm-install: _unresolved レシートが best-effort で書かれる"
  else
    fail "mdm-install: _unresolved レシートが生成されない"
  fi
  rm -rf "$_tmpu"
)

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

# ── CLT marker の安全な作成（R2-High: /tmp 固定パスの symlink 追随排除）──
(
  _mk_tmpd="$(mktemp -d)"
  printf 'victim\n' > "$_mk_tmpd/victim"
  export MDM_CLT_MARKER_OVERRIDE="$_mk_tmpd/marker"
  ln -s "$_mk_tmpd/victim" "$MDM_CLT_MARKER_OVERRIDE"
  _rc=0
  _mdm_create_clt_marker >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && ! -L "$MDM_CLT_MARKER_OVERRIDE" && -f "$MDM_CLT_MARKER_OVERRIDE" ]] \
     && [[ "$(cat "$_mk_tmpd/victim")" == "victim" ]]; then
    pass "mdm-install: CLT marker が先置き symlink を辿らず実体作成される"
  else
    fail "mdm-install: CLT marker 作成が symlink を辿る/失敗する (rc=$_rc)"
  fi
  rm -rf "$_mk_tmpd"
)
(
  _mk_tmpd="$(mktemp -d)"
  export MDM_CLT_MARKER_OVERRIDE="$_mk_tmpd/marker"
  _rc=0
  _mdm_create_clt_marker >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 && -f "$MDM_CLT_MARKER_OVERRIDE" ]] \
    && pass "mdm-install: CLT marker の通常作成が成功する" \
    || fail "mdm-install: CLT marker の通常作成に失敗 (rc=$_rc)"
  rm -rf "$_mk_tmpd"
)

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
  _has 'KIT_MDM_MANAGED=true' && pass "mdm-install: KIT_MDM_MANAGED を注入" || fail "mdm-install: KIT_MDM_MANAGED 注入なし（update 復元で MDM 設定が巻き戻る）"
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

# ══ CRITICAL 回帰（最終レビュー #2）: root は対象ユーザー所有 repo を直接
#    git 操作しない。git は _mdm_git 経由で検証済みユーザーへ降格する ══
(
  # 降格コンテキスト設定時: /usr/bin/git が sudo -u <user> 配下で組み立てられる
  export MDM_EXEC_AS_USER_DRYRUN=1
  _MDM_GIT_DROP_UID=501; _MDM_GIT_DROP_USER=jane; _MDM_GIT_DROP_HOME=/Users/jane
  # NOTE: 未実装時（関数未定義 = 127）に set -e でサブシェルごと即死しないよう捕捉
  out="$(_mdm_git -C /Users/jane/.claude-starter-kit fetch origin main 2>/dev/null)" || true
  printf '%s\n' "$out" | grep -q '^/usr/bin/sudo$' \
    && printf '%s\n' "$out" | grep -q '^/usr/bin/git$' \
    && pass "mdm-install: _mdm_git が root 時に降格 argv で git を実行" \
    || fail "mdm-install: _mdm_git の降格が効いていない (out: $out)"
  printf '%s\n' "$out" | grep -q '^-u$' && printf '%s\n' "$out" | grep -q '^jane$' \
    && pass "mdm-install: _mdm_git の降格先が対象ユーザー" \
    || fail "mdm-install: _mdm_git の降格先が不正"
)
(
  # 降格コンテキスト未設定時（非 root）: 直接実行される
  _MDM_GIT_DROP_UID=""
  out="$(_mdm_git --version 2>/dev/null)" || true
  printf '%s' "$out" | grep -q 'git version' \
    && pass "mdm-install: _mdm_git が非 root 時は直接実行" \
    || fail "mdm-install: _mdm_git の直接実行が失敗 (out: $out)"
)
# chown -R は撤去済み（clone を初回からユーザー実行するため不要になった）
if grep -q 'chown -R' "$PROJECT_DIR/mdm/install-mdm.sh"; then
  fail "mdm-install: chown -R が残存している（root の任意 repo chown 経路）"
else
  pass "mdm-install: chown -R が撤去されている"
fi

# ── KIT_MDM_INSTALL_DIR は対象ユーザーの canonical home 配下に制約 ──
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_fakehome="$_tmpd/Users/jane"; mkdir -p "$_fakehome"
(
  export KIT_MDM_INSTALL_DIR="$_tmpd/outside-home"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 501 jane "$_fakehome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "home 外 install_dir は exit 50" \
    && pass "mdm-install: home 外の KIT_MDM_INSTALL_DIR を拒否" \
    || fail "mdm-install: home 外の KIT_MDM_INSTALL_DIR を拒否すべき (got $_rc)"
)
(
  export KIT_MDM_INSTALL_DIR="$_fakehome/../escape"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 501 jane "$_fakehome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" ".. 含みの install_dir は exit 50" \
    && pass "mdm-install: .. を含む KIT_MDM_INSTALL_DIR を拒否" \
    || fail "mdm-install: .. を含む KIT_MDM_INSTALL_DIR を拒否すべき (got $_rc)"
)
(
  # home そのもの（配下でなく一致）も拒否
  export KIT_MDM_INSTALL_DIR="$_fakehome"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 501 jane "$_fakehome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "home 自体は exit 50" \
    && pass "mdm-install: home 自体を install_dir にするのを拒否" \
    || fail "mdm-install: home 自体の install_dir を拒否すべき (got $_rc)"
)
rm -rf "$_tmpd"

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

# ══ Homebrew 導入経路の固定（最終レビュー High#7）══

# URL は https://github.com/Homebrew/brew/releases/download/ 配下の
# Homebrew*.pkg のみ許可（API 応答が改ざん/汚染されても他ホストへ飛ばない）
_brew_fixture_evil="$_brew_tmpd/release-evil.json"
cat > "$_brew_fixture_evil" <<'EOF'
{
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg",
      "browser_download_url": "https://evil.example.com/Homebrew-4.6.15.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_evil"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: 公式リリース URL 以外の .pkg を拒否"
  else
    fail "mdm-install: 非公式ホストの .pkg URL を許容してしまう"
  fi
)
# 現行リリースの実アセット名（バージョンなし Homebrew.pkg・6.0.11 で実測）も許可
_brew_fixture_new="$_brew_tmpd/release-new.json"
cat > "$_brew_fixture_new" <<'EOF'
{
  "assets": [
    {
      "name": "Homebrew.pkg",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/6.0.11/Homebrew.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_new"
  out="$(_mdm_resolve_brew_pkg_url 2>/dev/null)" || true
  [[ "$out" == "https://github.com/Homebrew/brew/releases/download/6.0.11/Homebrew.pkg" ]] \
    && pass "mdm-install: バージョンなしアセット名 Homebrew.pkg を許容" \
    || fail "mdm-install: 現行アセット名 Homebrew.pkg が拒否される (got '$out')"
)

# 署名検証は Homebrew の Team ID (927JGANW46) に pin する
# （2026-07-17 に release 6.0.11 の pkgutil --check-signature で実測:
#  "Developer ID Installer: Patrick Linnane (927JGANW46)" + notarized）
(
  _sig_ok='Package "Homebrew.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Notarization: trusted by the Apple notary service
   Certificate Chain:
    1. Developer ID Installer: Patrick Linnane (927JGANW46)'
  _rc=0
  _mdm_check_brew_signature_output "$_sig_ok" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 ]] \
    && pass "mdm-install: 正規 Team ID の署名を許容" \
    || fail "mdm-install: 正規 Team ID の署名が拒否される"
)
(
  _sig_evil='Package "Homebrew.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Certificate Chain:
    1. Developer ID Installer: Evil Corp (EVIL123456)'
  _rc=0
  _mdm_check_brew_signature_output "$_sig_evil" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 ]] \
    && pass "mdm-install: 別 Team ID の Developer ID 署名を拒否" \
    || fail "mdm-install: 別 Team ID の署名を許容してしまう（pin 不成立）"
)

# HOMEBREW_PKG_USER plist は symlink を辿らず root 所有 0600 で安全に作成する
# （Homebrew 側 homebrew-package-user は「非symlink 通常ファイル・root 所有・
#  mode 0600・ACL 無し」の場合のみ plist を尊重する — brew 実装で確認済み）
(
  _pl_tmpd="$(mktemp -d)"
  _victim="$_pl_tmpd/victim-file"
  printf 'original\n' > "$_victim"
  export MDM_BREW_PLIST_OVERRIDE="$_pl_tmpd/pkg_user.plist"
  ln -s "$_victim" "$MDM_BREW_PLIST_OVERRIDE"
  _rc=0
  _mdm_write_brew_pkg_user_plist "jane" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && ! -L "$MDM_BREW_PLIST_OVERRIDE" && -f "$MDM_BREW_PLIST_OVERRIDE" ]] \
     && [[ "$(cat "$_victim")" == "original" ]]; then
    pass "mdm-install: 先回り symlink を辿らず plist を作成（標的ファイル無傷）"
  else
    fail "mdm-install: plist 作成が symlink を辿る/失敗する (rc=$_rc)"
  fi
  grep -q '<string>jane</string>' "$MDM_BREW_PLIST_OVERRIDE" 2>/dev/null \
    && pass "mdm-install: plist に対象ユーザーが記録される" \
    || fail "mdm-install: plist の内容が不正"
  _mode="$(stat -f '%Lp' "$MDM_BREW_PLIST_OVERRIDE" 2>/dev/null || stat -c '%a' "$MDM_BREW_PLIST_OVERRIDE" 2>/dev/null)"
  [[ "$_mode" == "600" ]] \
    && pass "mdm-install: plist が mode 600 で作成される（brew 側の受理条件）" \
    || fail "mdm-install: plist の mode が 600 でない (got $_mode)"
  rm -rf "$_pl_tmpd"
)
rm -rf "$_brew_tmpd"

# ── ログ出力先の決定（最終レビュー High#3: 設定確定後に決定・許可プレフィックス制約）──
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_loghome="$_tmpd/Users/jane"; mkdir -p "$_loghome"
(
  # 非 root（ユーザーモード）の既定は ~/Library/Logs 配下（spec §8.2）
  unset KIT_MDM_LOG_DIR
  MDM_LOG_FILE=""
  _mdm_setup_log_file 501 "$_loghome" 2>/dev/null || fail "mdm-install: ログ既定パスの決定に失敗"
  case "$MDM_LOG_FILE" in
    "$_loghome/Library/Logs/ClaudeCodeStarterKit/install-"*.log)
      pass "mdm-install: ユーザーモードのログ既定が ~/Library/Logs 配下" ;;
    *)
      fail "mdm-install: ユーザーモードのログ既定が不正 (got '$MDM_LOG_FILE')" ;;
  esac
)
(
  # root の既定は /Library/Logs 配下
  unset KIT_MDM_LOG_DIR
  MDM_LOG_FILE=""
  _mdm_setup_log_file 0 "$_loghome" 2>/dev/null || fail "mdm-install: root ログ既定の決定に失敗"
  case "$MDM_LOG_FILE" in
    "/Library/Logs/ClaudeCodeStarterKit/install-"*.log)
      pass "mdm-install: root のログ既定が /Library/Logs 配下" ;;
    *)
      fail "mdm-install: root のログ既定が不正 (got '$MDM_LOG_FILE')" ;;
  esac
)
(
  # KIT_MDM_LOG_DIR の明示指定（許可プレフィックス配下）は尊重される
  export KIT_MDM_LOG_DIR="$_loghome/Library/Logs/CustomDir"
  MDM_LOG_FILE=""
  _mdm_setup_log_file 501 "$_loghome" 2>/dev/null || fail "mdm-install: LOG_DIR 明示指定の決定に失敗"
  case "$MDM_LOG_FILE" in
    "$_loghome/Library/Logs/CustomDir/install-"*.log)
      pass "mdm-install: KIT_MDM_LOG_DIR 明示指定がログパスに反映される" ;;
    *)
      fail "mdm-install: KIT_MDM_LOG_DIR 明示指定が反映されない (got '$MDM_LOG_FILE')" ;;
  esac
)
(
  # 許可プレフィックス外の KIT_MDM_LOG_DIR は exit 50（spec §9.2: root 書込先の制約）
  export KIT_MDM_LOG_DIR="/etc/evil-logs"
  _rc=0
  _mdm_setup_log_file 0 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "許可外 LOG_DIR は exit 50" \
    && pass "mdm-install: 許可プレフィックス外の LOG_DIR を拒否" \
    || fail "mdm-install: 許可外 LOG_DIR を拒否すべき (got $_rc)"
)
(
  # root はユーザー home 配下の LOG_DIR を指定できない（ユーザーが植えた
  # symlink を root が辿って任意 append する経路を塞ぐ）
  export KIT_MDM_LOG_DIR="$_loghome/Library/Logs/UserControlled"
  _rc=0
  _mdm_setup_log_file 0 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "root は home 配下 LOG_DIR 不可" \
    && pass "mdm-install: root 時にユーザー home 配下の LOG_DIR を拒否" \
    || fail "mdm-install: root 時の home 配下 LOG_DIR を拒否すべき (got $_rc)"
)
(
  # 非 root はシステム領域 /Library/Logs を指定できない（書けないだけでなく契約外）
  export KIT_MDM_LOG_DIR="/Library/Logs/ClaudeCodeStarterKit"
  _rc=0
  _mdm_setup_log_file 501 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "非rootはシステム LOG_DIR 不可" \
    && pass "mdm-install: 非 root 時にシステム領域の LOG_DIR を拒否" \
    || fail "mdm-install: 非 root 時のシステム LOG_DIR を拒否すべき (got $_rc)"
)
rm -rf "$_tmpd"

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

# ══ update 経路 + CLI 無効化の setup.sh 接続（最終レビュー High#5）══

# 既存インストール（対象ユーザーの manifest）検出時は --update を付与（spec §8.5）
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_updhome="$_tmpd/Users/jane"
mkdir -p "$_updhome/.claude"
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv "$_updhome" 2>/dev/null || true
  _found=0
  for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == '--update' ]] && _found=1; done
  if [[ "$_found" -eq 1 ]]; then
    fail "mdm-install: manifest 無しなのに --update が付与された"
  else
    pass "mdm-install: manifest 無しでは --update を付けない"
  fi
)
touch "$_updhome/.claude/.starter-kit-manifest.json"
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv "$_updhome" 2>/dev/null || true
  _found=0
  for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == '--update' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: 既存 manifest 検出で --update を付与" \
    || fail "mdm-install: 既存 manifest 検出でも --update が付かない (argv: ${MDM_SETUP_ARGV[*]})"
)

# root 実行時の CLI 確認は root の PATH を成功扱いにしない
(
  export MDM_EUID_OVERRIDE=0
  _rc=0
  _mdm_cli_present_for_home "$_updhome" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: root 時は PATH 上の claude を成功扱いにしない"
  else
    fail "mdm-install: root 時に root PATH の claude で成功扱いになる"
  fi
)
(
  export MDM_EUID_OVERRIDE=0
  mkdir -p "$_updhome/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$_updhome/.local/bin/claude"
  chmod +x "$_updhome/.local/bin/claude"
  _rc=0
  _mdm_cli_present_for_home "$_updhome" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 ]] \
    && pass "mdm-install: root 時も対象ユーザー home の claude は検出する" \
    || fail "mdm-install: 対象ユーザー home の claude を検出できない"
)
rm -rf "$_tmpd"

# setup.sh: KIT_MDM_INSTALL_CLAUDE_CLI=false で CLI 導入をスキップ（spec §11(a)）。
# 隔離 bash プロセスで setup.sh を source し、導入関数をスタブして挙動を検証する。
_setup_cli_probe() {  # $1 = KIT_MDM_INSTALL_CLAUDE_CLI の値（"__unset__" で未設定）
  PROJECT_DIR="$PROJECT_DIR" KIT_CLI_VAL="$1" bash -c '
    source "$PROJECT_DIR/setup.sh"
    set +u   # STR_*（i18n）はスタブ実行では未ロードのため
    info(){ :; }; ok(){ :; }; warn(){ :; }
    _need_claude_cli_install(){ return 0; }
    _install_claude_cli(){ echo INSTALL_CALLED; }
    _add_to_path_now_and_persist(){ :; }
    if [[ "$KIT_CLI_VAL" != "__unset__" ]]; then
      export KIT_MDM_INSTALL_CLAUDE_CLI="$KIT_CLI_VAL"
    fi
    install_claude_cli_if_needed
  ' 2>/dev/null
}
(
  out="$(_setup_cli_probe false)" || true
  if printf '%s' "$out" | grep -q 'INSTALL_CALLED'; then
    fail "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI=false でも CLI 導入が実行される"
  else
    pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI=false で CLI 導入をスキップ"
  fi
)
(
  out="$(_setup_cli_probe __unset__)" || true
  printf '%s' "$out" | grep -q 'INSTALL_CALLED' \
    && pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI 未設定では従来どおり導入" \
    || fail "mdm-install: 未設定なのに CLI 導入がスキップされた"
)
(
  # 不正値は fail-closed（導入する）— 検証済みでない値で機能を黙って無効化しない
  out="$(_setup_cli_probe garbage)" || true
  printf '%s' "$out" | grep -q 'INSTALL_CALLED' \
    && pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI 不正値は fail-closed で導入" \
    || fail "mdm-install: 不正値で CLI 導入がスキップされた（fail-open）"
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
