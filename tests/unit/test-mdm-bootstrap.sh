#!/bin/bash
# tests/unit/test-mdm-bootstrap.sh - 自己ブートストラップ判定 + R4 レシート出力先ロジック

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

_tmpd="$(mktemp -d)"
# lib-mdm-config.sh が無いディレクトリ -> 要ブートストラップ
( export MDM_SELF_DIR="$_tmpd"
  mdm_needs_bootstrap
  assert_exit_code 0 "$?" "lib 欠如で要ブートストラップ" \
    && pass "mdm-bootstrap: lib 欠如を検知" \
    || fail "mdm-bootstrap: lib 欠如を検知できない" )
# lib-mdm-config.sh がある -> 不要
touch "$_tmpd/lib-mdm-config.sh"
( export MDM_SELF_DIR="$_tmpd"
  if mdm_needs_bootstrap; then
    fail "mdm-bootstrap: lib がある時は不要と判定すべき"
  else
    pass "mdm-bootstrap: lib 存在時は再取得しない"
  fi )
rm -rf "$_tmpd"

# ── _mdm_receipt_dir_for（R4 のパス選択ロジック。実 id -u に依存しないよう
#    MDM_EUID_OVERRIDE でモック）────────────────────────────
(
  export MDM_EUID_OVERRIDE=0
  out="$(_mdm_receipt_dir_for "/Users/jane")"
  if [[ "$out" == "/Library/Application Support/ClaudeCodeStarterKit" ]]; then
    pass "mdm-bootstrap: root 時はシステム領域にレシート"
  else
    fail "mdm-bootstrap: root 時のレシート先が不正 (got '$out')"
  fi
)
(
  export MDM_EUID_OVERRIDE=501
  out="$(_mdm_receipt_dir_for "/Users/jane")"
  if [[ "$out" == "/Users/jane/Library/Application Support/ClaudeCodeStarterKit" ]]; then
    pass "mdm-bootstrap: 非root時はユーザー領域にレシート"
  else
    fail "mdm-bootstrap: 非root時のレシート先が不正 (got '$out')"
  fi
)

# ── _mdm_finish（レシート書き出し + exit）: exit はサブシェル内で完結する
#    ため安全にテストできる。実 exit を裸で受けず、サブシェル終了後の $? を見る。
(
  _tmpd2="$(mktemp -d)"
  _tmpd2="$(cd "$_tmpd2" && pwd -P)"
  _rc=0
  ( export MDM_EUID_OVERRIDE=501
    # mdm_log 内部で参照されるグローバル（このサブシェル内では直接は読まない）。
    # shellcheck disable=SC2034
    MDM_LOG_FILE=""
    _mdm_finish "jane" "$_tmpd2" success "0" ) || _rc=$?
  assert_exit_code 0 "$_rc" "_mdm_finish は指定 exit code で終了" \
    && pass "mdm-bootstrap: _mdm_finish が exit 0 で終了" \
    || fail "mdm-bootstrap: _mdm_finish の exit code 不一致 (got $_rc)"

  _rcpt="$_tmpd2/Library/Application Support/ClaudeCodeStarterKit/receipt-jane.json"
  if [[ -f "$_rcpt" ]]; then
    pass "mdm-bootstrap: _mdm_finish が対象ユーザー領域にレシートを書く"
  else
    fail "mdm-bootstrap: _mdm_finish のレシートが生成されていない"
  fi
  if assert_json_field "$_rcpt" ".result" "success" "result=success"; then
    pass "mdm-bootstrap: _mdm_finish のレシート result フィールド"
  else
    fail "mdm-bootstrap: _mdm_finish のレシート result フィールド不正"
  fi
  rm -rf "$_tmpd2"
)
