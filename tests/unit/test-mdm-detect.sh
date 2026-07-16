#!/bin/bash
# tests/unit/test-mdm-detect.sh - レシート実体照合による compliant 判定

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/detect-mdm.sh"

_tmpd="$(mktemp -d)"
_install="$_tmpd/kit"
mkdir -p "$_install/.git"
_sha="abcdef1234567890"
# resolved_sha と一致する git を装う(rev-parse をモックするため .git/HEAD を用意)
printf '%s\n' "$_sha" > "$_install/.git/mdm-sha"   # detect はこのファイルで照合(テスト用単純化)

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
  if mdm_detect "$_rcpt"; then pass "mdm-detect: 成功レシート+CLI で compliant"; else fail "mdm-detect: compliant のはず"; fi )

# CLI 必須なのに CLI 無しなら非compliant
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=0
  if mdm_detect "$_rcpt"; then fail "mdm-detect: CLI 必須で欠如なら非compliant"; else pass "mdm-detect: CLI 欠如を検知"; fi )

# required_components に claude_cli が無ければ CLI 欠如でも compliant
_rcpt2="$_tmpd/receipt2.json"
sed 's/\["kit","claude_cli"\]/["kit"]/' "$_rcpt" > "$_rcpt2"
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=0
  if mdm_detect "$_rcpt2"; then pass "mdm-detect: CLI 非必須なら CLI 無しでも compliant"; else fail "mdm-detect: CLI 非必須で compliant のはず"; fi )

# result=failure は非compliant
_rcpt3="$_tmpd/receipt3.json"
sed 's/"result": "success"/"result": "failure"/' "$_rcpt" > "$_rcpt3"
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_rcpt3"; then fail "mdm-detect: failure は非compliant"; else pass "mdm-detect: failure レシートを非compliant"; fi )

rm -rf "$_tmpd"
