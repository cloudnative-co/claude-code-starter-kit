#!/bin/bash
# tests/unit/test-mdm-detect.sh - レシート実体照合による compliant 判定（spec §8.4）

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/detect-mdm.sh"

_tmpd="$(mktemp -d)"
_tmpd="$(cd "$_tmpd" && pwd -P)"
_install="$_tmpd/kit"

# 実 git repo を fixture にする（resolved_sha は実 HEAD と照合されるため）
mkdir -p "$_install"
git -C "$_install" init -q
printf 'x\n' > "$_install/file"
git -C "$_install" add -A
git -C "$_install" -c user.name=t -c user.email=t@t commit -qm fixture
_sha="$(git -C "$_install" rev-parse HEAD)"

_rcpt="$_tmpd/receipt.json"
cat > "$_rcpt" <<JSON
{
  "schema_version": 1, "kit_version": "0.73.0", "git_ref": "main",
  "resolved_sha": "$_sha", "install_dir": "$_install",
  "required_components": ["kit","claude_cli"], "profile": "standard",
  "target_user": "jane", "result": "success", "exit_code": 0,
  "partial": [], "timestamp": "2026-07-16T00:00:00Z", "log_path": "/x.log"
}
JSON

# CLI ありなら compliant
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_rcpt" "jane"; then pass "mdm-detect: 成功レシート+CLI で compliant"; else fail "mdm-detect: compliant のはず"; fi )

# CLI 必須なのに CLI 無しなら非compliant
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=0
  if mdm_detect "$_rcpt" "jane"; then fail "mdm-detect: CLI 必須で欠如なら非compliant"; else pass "mdm-detect: CLI 欠如を検知"; fi )

# required_components に claude_cli が無ければ CLI 欠如でも compliant
_rcpt2="$_tmpd/receipt2.json"
sed 's/\["kit","claude_cli"\]/["kit"]/' "$_rcpt" > "$_rcpt2"
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=0
  if mdm_detect "$_rcpt2" "jane"; then pass "mdm-detect: CLI 非必須なら CLI 無しでも compliant"; else fail "mdm-detect: CLI 非必須で compliant のはず"; fi )

# result=failure は非compliant
_rcpt3="$_tmpd/receipt3.json"
sed 's/"result": "success"/"result": "failure"/' "$_rcpt" > "$_rcpt3"
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_rcpt3" "jane"; then fail "mdm-detect: failure は非compliant"; else pass "mdm-detect: failure レシートを非compliant"; fi )

# ══ §8.4 準拠強化（最終レビュー High#6）══

# resolved_sha と実 clone の HEAD の不一致は非compliant（実体照合）
_rcpt4="$_tmpd/receipt4.json"
sed "s/$_sha/0123456789abcdef0123456789abcdef01234567/" "$_rcpt" > "$_rcpt4"
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_rcpt4" "jane"; then
    fail "mdm-detect: resolved_sha 不一致でも compliant になる（実体照合なし）"
  else
    pass "mdm-detect: resolved_sha と HEAD の不一致を検知"
  fi )

# receipt の target_user と要求ユーザーの不一致は非compliant（退職者レシート除外）
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_rcpt" "alice"; then
    fail "mdm-detect: target_user 不一致でも compliant になる"
  else
    pass "mdm-detect: target_user 不一致を除外"
  fi )

# CLI 確認は対象ユーザーの home 実体（~/.local/bin/claude）を見る
_clihome="$_tmpd/Users/jane"
mkdir -p "$_clihome/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$_clihome/.local/bin/claude"
chmod +x "$_clihome/.local/bin/claude"
( unset MDM_DETECT_CLI_PRESENT_OVERRIDE
  export MDM_DETECT_HOME_OVERRIDE="$_clihome" MDM_EUID_OVERRIDE=0
  if mdm_detect "$_rcpt" "jane"; then
    pass "mdm-detect: 対象ユーザー home の claude を検出"
  else
    fail "mdm-detect: 対象ユーザー home の claude を検出できない"
  fi )
( unset MDM_DETECT_CLI_PRESENT_OVERRIDE
  export MDM_DETECT_HOME_OVERRIDE="$_tmpd/Users/empty" MDM_EUID_OVERRIDE=0
  mkdir -p "$_tmpd/Users/empty"
  if mdm_detect "$_rcpt" "jane"; then
    fail "mdm-detect: root 検知が検知プロセス環境の claude で成功扱いになる"
  else
    pass "mdm-detect: root 検知は home に CLI が無ければ非compliant"
  fi )

# ── エントリポイント（実行形）: root 時の既定ユーザーはコンソールユーザー ──
_rcpt_dir="$_tmpd/receipts"
mkdir -p "$_rcpt_dir"
cp "$_rcpt" "$_rcpt_dir/receipt-jane.json"
(
  out="$(MDM_RECEIPT_DIR_OVERRIDE="$_rcpt_dir" MDM_EUID_OVERRIDE=0 \
        MDM_CONSOLE_USER_OVERRIDE=jane MDM_DETECT_CLI_PRESENT_OVERRIDE=1 \
        bash "$PROJECT_DIR/mdm/detect-mdm.sh" 2>/dev/null)" && _rc=0 || _rc=$?
  if [[ "$_rc" -eq 0 ]] && printf '%s' "$out" | grep -q '^compliant$'; then
    pass "mdm-detect: root 実行の既定ユーザーがコンソールユーザー（receipt-jane を参照）"
  else
    fail "mdm-detect: root 実行の既定ユーザー解決が不正 (rc=$_rc out='$out')"
  fi
)
# --user の username 検証（不正文字種は非compliant で終了・レシート探索しない）
(
  _rc=0
  MDM_RECEIPT_DIR_OVERRIDE="$_rcpt_dir" bash "$PROJECT_DIR/mdm/detect-mdm.sh" --user 'bad;user' >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-detect: --user の文字種違反を拒否"
  else
    fail "mdm-detect: --user の文字種違反を許容してしまう"
  fi
)

rm -rf "$_tmpd"
