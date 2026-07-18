#!/bin/bash
# tests/unit/test-mdm-detect.sh - MDM receipt and deployed-state detection.

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/detect-mdm.sh"

_mdm_detect_tmp="$(mktemp -d)"
_mdm_detect_tmp="$(cd "$_mdm_detect_tmp" && pwd -P)"
_mdm_detect_home="$_mdm_detect_tmp/Users/jane"
_mdm_detect_install="$_mdm_detect_home/.claude-starter-kit"
_mdm_detect_claude="$_mdm_detect_home/.claude"
_mdm_detect_snapshot="$_mdm_detect_claude/.starter-kit-snapshot"
_mdm_detect_trust_base="$_mdm_detect_tmp/trust-base"
_mdm_detect_receipts="$_mdm_detect_trust_base/ClaudeCodeStarterKit"
_mdm_detect_private_base="$_mdm_detect_tmp/private"

mkdir -p "$_mdm_detect_install" "$_mdm_detect_snapshot" \
  "$_mdm_detect_receipts" "$_mdm_detect_private_base"
chmod 700 "$_mdm_detect_trust_base" "$_mdm_detect_private_base"
chmod 755 "$_mdm_detect_receipts"
_mdm_detect_plus_path="$_mdm_detect_tmp/no-acl+path"
mkdir "$_mdm_detect_plus_path"
_mdm_is_darwin && chmod -N "$_mdm_detect_plus_path" 2>/dev/null || true
if _mdm_has_acl "$_mdm_detect_plus_path"; then
  fail "mdm-detect: path 中の + を ACL marker と誤認"
else
  pass "mdm-detect: ACL 判定は path 中の + を無視"
fi
/bin/rmdir "$_mdm_detect_plus_path"
_mdm_detect_acl_xattr_path="$_mdm_detect_tmp/acl-xattr"
: > "$_mdm_detect_acl_xattr_path"
if _mdm_is_darwin \
  && /usr/bin/xattr -w com.cloudnative.mdm-test 1 \
    "$_mdm_detect_acl_xattr_path" 2>/dev/null \
  && /bin/chmod +a 'everyone allow write' \
    "$_mdm_detect_acl_xattr_path" 2>/dev/null; then
  _mdm_detect_acl_listing="$(LC_ALL=C /bin/ls -lde \
    "$_mdm_detect_acl_xattr_path")"
  _mdm_detect_acl_perms="${_mdm_detect_acl_listing%%[[:space:]]*}"
  if [[ "$_mdm_detect_acl_perms" != *@ ]]; then
    skip "mdm-detect: xattr 併存 ACL の continuation を拒否" \
      "ls permission token did not retain @"
  elif ! _mdm_launcher_acl_safe "$_mdm_detect_acl_xattr_path" \
    && _mdm_has_acl "$_mdm_detect_acl_xattr_path"; then
    pass "mdm-detect: xattr 併存 ACL の continuation を拒否"
  else
    fail "mdm-detect: xattr 併存 ACL を launcher/main が許可"
  fi
  /bin/chmod -N "$_mdm_detect_acl_xattr_path" 2>/dev/null || true
  /usr/bin/xattr -d com.cloudnative.mdm-test \
    "$_mdm_detect_acl_xattr_path" 2>/dev/null || true
else
  skip "mdm-detect: xattr 併存 ACL の continuation を拒否" \
    "ACL+xattr fixture unavailable on this platform"
fi
/bin/rm -f "$_mdm_detect_acl_xattr_path"
(
  unset MDM_DETECT_HOME_OVERRIDE
  _mdm_detect_read_user_home_record() {
    printf 'NFSHomeDirectory:\n /Users/Jane Doe\n'
  }
  if [[ "$(_mdm_detect_user_home jane)" == "/Users/Jane Doe" ]]; then
    pass "mdm-detect: dscl 2行形式の home 内部空白を保持"
  else
    fail "mdm-detect: 空白を含む dscl home の解析が不正"
  fi
)
(
  if [[ "$(printf 'NFSHomeDirectory: /Users/jane\n' \
    | _mdm_detect_parse_user_home)" == /Users/jane ]]; then
    pass "mdm-detect: dscl 同一行形式の home を維持"
  else
    fail "mdm-detect: dscl 同一行形式の home を拒否"
  fi
)
(
  _invalid_home=""; _invalid_rc=0
  _invalid_home="$(printf 'NFSHomeDirectory:  /Users/jane\n' \
    | _mdm_detect_parse_user_home)" || _invalid_rc=$?
  if [[ "$_invalid_rc" -ne 0 && -z "$_invalid_home" ]]; then
    pass "mdm-detect: dscl 同一行の余分な delimiter を拒否"
  else
    fail "mdm-detect: dscl の曖昧な delimiter を正規化"
  fi
)
(
  unset MDM_DETECT_HOME_OVERRIDE
  _mdm_detect_read_user_home_record() {
    printf 'NFSHomeDirectory: /Users/jane\n'
    return 1
  }
  _invalid_home=""; _invalid_rc=0
  _invalid_home="$(_mdm_detect_user_home jane)" || _invalid_rc=$?
  if [[ "$_invalid_rc" -ne 0 && -z "$_invalid_home" ]]; then
    pass "mdm-detect: dscl の非0終了は valid-looking stdout ごと拒否"
  else
    fail "mdm-detect: 失敗した dscl の stdout を home として許可"
  fi
)
(
  _invalid_home=""; _invalid_rc=0
  _invalid_home="$(_mdm_detect_parse_user_home <<'EOF'
NFSHomeDirectory:
 /Users/jane
 /Users/other
EOF
)" || _invalid_rc=$?
  if [[ "$_invalid_rc" -ne 0 && -z "$_invalid_home" ]]; then
    pass "mdm-detect: dscl の複数 home 値を出力前に拒否"
  else
    fail "mdm-detect: dscl の曖昧な複数 home 値を許可"
  fi
)
(
  unset MDM_CONSOLE_USER_OVERRIDE
  _mdm_detect_read_console_user_record() {
    printf '<dictionary> {\n  Name : wrong-user\n}\n'
    return 42
  }
  _mdm_stat_owner() { printf 'fallback-user'; }
  if [[ "$(_mdm_detect_console_user)" == fallback-user ]]; then
    pass "mdm-detect: scutil 非0の valid-looking stdout を破棄して stat へfallback"
  else
    fail "mdm-detect: 失敗した scutil の ConsoleUser を採用"
  fi
)
(
  _console_user=""; _console_rc=0
  _console_user="$(_mdm_detect_parse_console_user_record <<'EOF'
<dictionary> {
  Name : jane
  Name : alice
}
EOF
)" || _console_rc=$?
  if [[ "$_console_rc" -ne 0 && -z "$_console_user" ]]; then
    pass "mdm-detect: scutil record の重複 Name を拒否"
  else
    fail "mdm-detect: 曖昧な scutil ConsoleUser を許可"
  fi
)
(
  _console_records_rejected=true
  for _console_record in $'Name :  jane\n' $'Name : \tjane\n'; do
    if printf '%s' "$_console_record" | _mdm_detect_parse_console_user_record \
      >/dev/null 2>&1; then
      _console_records_rejected=false
    fi
  done
  [[ "$_console_records_rejected" == true ]] \
    && pass "mdm-detect: scutil Name 値の余分な空白/tabを拒否" \
    || fail "mdm-detect: malformed ConsoleUser delimiter を正規化"
)
(
  unset MDM_DETECT_EXPECTED_UID_OVERRIDE
  _mdm_detect_read_user_uid_record() { printf 'UniqueID: 501\n'; }
  _mdm_detect_search_policy_uid() { printf '%s' "${_search_uid_fixture:?}"; }
  _search_uid_fixture=501
  _bound_uid="$(_mdm_detect_user_uid jane)" || _bound_rc=$?
  _mismatch_rc=0
  _search_uid_fixture=777
  _mdm_detect_user_uid jane >/dev/null 2>&1 || _mismatch_rc=$?
  if [[ "${_bound_uid:-}" == 501 && "${_bound_rc:-0}" -eq 0 \
    && "$_mismatch_rc" -ne 0 ]]; then
    pass "mdm-detect: local dscl UID と search-policy UID の一致だけを受理"
  else
    fail "mdm-detect: local/search-policy UID の束縛が不正"
  fi
)
(
  unset MDM_DETECT_EXPECTED_UID_OVERRIDE
  _mdm_detect_read_user_uid_record() {
    printf 'UniqueID: 501\n'
    return 42
  }
  _mdm_detect_search_policy_uid() { printf '501'; }
  _uid=""; _uid_rc=0
  _uid="$(_mdm_detect_user_uid jane)" || _uid_rc=$?
  if [[ "$_uid_rc" -ne 0 && -z "$_uid" ]]; then
    pass "mdm-detect: dscl UID producer 非0の stdout を破棄"
  else
    fail "mdm-detect: 失敗した dscl の UID を採用"
  fi
)
/usr/bin/git -C "$_mdm_detect_install" init -q
printf 'fixture\n' > "$_mdm_detect_install/file"
/usr/bin/git -C "$_mdm_detect_install" add -A
/usr/bin/git -C "$_mdm_detect_install" \
  -c user.name=test -c user.email=test@example.invalid commit -qm fixture
_mdm_detect_sha="$(/usr/bin/git -C "$_mdm_detect_install" rev-parse HEAD)"
/usr/bin/git -C "$_mdm_detect_install" checkout -q --detach "$_mdm_detect_sha"
_mdm_detect_short="${_mdm_detect_sha:0:7}"
_mdm_detect_persistent_marker="$_mdm_detect_install/.claude-starter-kit-mdm-managed"
printf 'claude-code-starter-kit-mdm-user-v1\n' > "$_mdm_detect_persistent_marker"
chmod 444 "$_mdm_detect_persistent_marker"

printf '{"managed":true}\n' > "$_mdm_detect_claude/settings.json"
printf '%s\n# managed\n%s\n# user\npersonal\n' \
  "$_MDM_MARKER_BEGIN" "$_MDM_MARKER_END" > "$_mdm_detect_claude/CLAUDE.md"
cp "$_mdm_detect_claude/settings.json" "$_mdm_detect_snapshot/settings.json"
printf '%s\n# managed\n%s\n' \
  "$_MDM_MARKER_BEGIN" "$_MDM_MARKER_END" > "$_mdm_detect_snapshot/CLAUDE.md"

_mdm_detect_manifest="$_mdm_detect_claude/.starter-kit-manifest.json"
_mdm_detect_manifest_profile=standard
_mdm_detect_manifest_language=ja
_mdm_detect_manifest_absent_json='[]'
_mdm_detect_write_manifest() {
  cat > "$_mdm_detect_manifest" <<JSON
{
  "version": "2",
  "mdm_managed": true,
  "kit_commit": "$_mdm_detect_short",
  "profile": "$_mdm_detect_manifest_profile",
  "language": "$_mdm_detect_manifest_language",
  "claude_dir": "$_mdm_detect_claude",
  "snapshot_dir": "$_mdm_detect_snapshot",
  "mdm_absent_files": $_mdm_detect_manifest_absent_json,
  "files": [
    "$_mdm_detect_claude/settings.json",
    "$_mdm_detect_claude/CLAUDE.md"
  ]
}
JSON
}
_mdm_detect_write_manifest

_mdm_detect_fixture_mode() {
  local _metadata _without_nlink _mode
  _metadata="$(_mdm_stat_metadata "$1")" || return 1
  _without_nlink="${_metadata%:*}"
  _mode="${_without_nlink##*:}"
  _mdm_mode_normalize "$_mode"
}

_mdm_detect_fixture_deployment_sha() {
  local _input="$_mdm_detect_tmp/fixture-deployment-input"
  local _relative _live_hash _snapshot_hash _live_mode _snapshot_mode _digest
  local _live_source _snapshot_source _live_managed _snapshot_managed
  local _absent_count _absent_index=0 _absent_relative
  : > "$_input"
  for _relative in settings.json CLAUDE.md; do
    _live_source="$_mdm_detect_claude/$_relative"
    _snapshot_source="$_mdm_detect_snapshot/$_relative"
    if [[ "$_relative" == CLAUDE.md ]]; then
      _live_managed="$_input.live-managed"
      _snapshot_managed="$_input.snapshot-managed"
      _mdm_extract_managed_section "$_live_source" "$_live_managed" 0 || return 1
      _mdm_extract_managed_section "$_snapshot_source" "$_snapshot_managed" 1 \
        || return 1
      /usr/bin/cmp -s "$_snapshot_source" "$_snapshot_managed" || return 1
      _live_hash="$(_mdm_sha256 "$_live_managed")" || return 1
      _snapshot_hash="$(_mdm_sha256 "$_snapshot_source")" || return 1
      rm -f "$_live_managed" "$_snapshot_managed"
    else
      _live_hash="$(_mdm_sha256 "$_live_source")" || return 1
      _snapshot_hash="$(_mdm_sha256 "$_snapshot_source")" || return 1
    fi
    _live_mode="$(_mdm_detect_fixture_mode "$_mdm_detect_claude/$_relative")" || return 1
    _snapshot_mode="$(_mdm_detect_fixture_mode "$_mdm_detect_snapshot/$_relative")" \
      || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$_relative" "$_live_hash" "$_snapshot_hash" "$_live_mode" "$_snapshot_mode" \
      >> "$_input"
  done
  _absent_count="$(_mdm_json_array_count \
    "$_mdm_detect_manifest" mdm_absent_files)" || return 1
  [[ "$_absent_count" =~ ^[0-9]+$ ]] || return 1
  while (( _absent_index < _absent_count )); do
    _absent_relative="$(_mdm_json_array_get \
      "$_mdm_detect_manifest" mdm_absent_files "$_absent_index")"
    [[ -n "$_absent_relative" ]] || return 1
    printf 'absent\t%s\n' "$_absent_relative" >> "$_input"
    _absent_index=$((_absent_index + 1))
  done
  _digest="$(_mdm_sha256 "$_input")"
  rm -f "$_input"
  printf '%s' "$_digest"
}

_mdm_detect_receipt="$_mdm_detect_receipts/receipt-jane.json"
_mdm_detect_write_receipt() { # <schema> <result> <sha> <target> <components> [version]
  local _schema="$1" _result="$2" _sha="$3" _target="$4" _components="$5"
  local _kit_version="${6:-0.73.0}"
  local _receipt_install="${7:-$_mdm_detect_install}"
  local _manifest_hash _deployment_hash
  _manifest_hash="$(_mdm_sha256 "$_mdm_detect_manifest")"
  _deployment_hash="$(_mdm_detect_fixture_deployment_sha)"
  cat > "$_mdm_detect_receipt" <<JSON
{
  "schema_version": $_schema,
  "kit_version": "$_kit_version",
  "git_ref": "main",
  "resolved_sha": "$_sha",
  "install_dir": "$_receipt_install",
  "manifest_path": "$_mdm_detect_manifest",
  "manifest_sha256": "$_manifest_hash",
  "deployment_sha256": "$_deployment_hash",
  "required_components": $_components,
  "profile": "standard",
  "language": "ja",
  "target_user": "$_target",
  "result": "$_result",
  "exit_code": 0,
  "partial": [],
  "timestamp": "2026-07-17T00:00:00Z",
  "log_path": "/Library/Logs/ClaudeCodeStarterKit/install.log"
}
JSON
  chmod 644 "$_mdm_detect_receipt"
}
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit","claude_cli"]'

export MDM_DETECT_EXPECTED_OWNER_OVERRIDE
MDM_DETECT_EXPECTED_OWNER_OVERRIDE="$(/usr/bin/id -un)"
export MDM_DETECT_EXPECTED_UID_OVERRIDE
MDM_DETECT_EXPECTED_UID_OVERRIDE="$(/usr/bin/id -u)"
export MDM_DETECT_TRUST_BASE_OVERRIDE="$_mdm_detect_trust_base"
export MDM_DETECT_TMP_BASE_OVERRIDE="$_mdm_detect_private_base"
export MDM_DETECT_HOME_OVERRIDE="$_mdm_detect_home"

# A complete, anchored installation is compliant.
(
  export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_mdm_detect_receipt" jane; then
    pass "mdm-detect: receipt v2 anchors clone, manifest, snapshot and files"
  else
    fail "mdm-detect: valid deployed state was rejected"
  fi
)

# A root receipt cannot redirect compliance to a trust-valid checkout outside
# the fixed per-user path used by the production installer.
_mdm_detect_alt_install="$_mdm_detect_tmp/kit-outside-home"
/bin/cp -R "$_mdm_detect_install" "$_mdm_detect_alt_install"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","claude_cli"]' 0.73.0 "$_mdm_detect_alt_install"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: receipt の home 外 install_dir を許可"
else
  pass "mdm-detect: install_dir は対象 home の固定パスに束縛"
fi
/bin/rm -rf "$_mdm_detect_alt_install"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","claude_cli"]'

# CLI is enforced only when the receipt declares it as required.
(
  export MDM_DETECT_CLI_PRESENT_OVERRIDE=0
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: missing required CLI was accepted"
  else
    pass "mdm-detect: missing required CLI is non-compliant"
  fi
)
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
(
  export MDM_DETECT_CLI_PRESENT_OVERRIDE=0
  if mdm_detect "$_mdm_detect_receipt" jane; then
    pass "mdm-detect: optional CLI may be absent"
  else
    fail "mdm-detect: optional CLI was treated as required"
  fi
)

# The retained checkout is compliant only while its target-user marker and
# detached HEAD satisfy the same trust contract used by remediation.
mv "$_mdm_detect_persistent_marker" "$_mdm_detect_persistent_marker.saved"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: markerless persistent checkout was accepted"
else
  pass "mdm-detect: persistent checkout requires the management marker"
fi
mv "$_mdm_detect_persistent_marker.saved" "$_mdm_detect_persistent_marker"

chmod 644 "$_mdm_detect_persistent_marker"
printf 'claude-code-starter-kit-mdm-user-v1\ntrailing-junk' \
  > "$_mdm_detect_persistent_marker"
chmod 444 "$_mdm_detect_persistent_marker"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: invalid persistent marker content was accepted"
else
  pass "mdm-detect: persistent marker content is byte-constrained"
fi
chmod 644 "$_mdm_detect_persistent_marker"
printf 'claude-code-starter-kit-mdm-user-v1\n\0' \
  > "$_mdm_detect_persistent_marker"
chmod 444 "$_mdm_detect_persistent_marker"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: persistent marker の NUL suffix を許可"
else
  pass "mdm-detect: persistent marker は NUL suffix も拒否"
fi
chmod 644 "$_mdm_detect_persistent_marker"
printf 'claude-code-starter-kit-mdm-user-v1\n' > "$_mdm_detect_persistent_marker"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: writable persistent marker was accepted"
else
  pass "mdm-detect: persistent marker requires mode 0444"
fi
chmod 444 "$_mdm_detect_persistent_marker"

ln "$_mdm_detect_persistent_marker" "$_mdm_detect_persistent_marker.peer"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: hardlinked persistent marker was accepted"
else
  pass "mdm-detect: persistent marker requires link count one"
fi
rm "$_mdm_detect_persistent_marker.peer"

mv "$_mdm_detect_persistent_marker" "$_mdm_detect_persistent_marker.real"
ln -s "${_mdm_detect_persistent_marker##*/}.real" \
  "$_mdm_detect_persistent_marker"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: symlink persistent marker was accepted"
else
  pass "mdm-detect: symlink persistent marker is rejected"
fi
rm "$_mdm_detect_persistent_marker"
mv "$_mdm_detect_persistent_marker.real" "$_mdm_detect_persistent_marker"

chmod 777 "$_mdm_detect_install"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: writable persistent checkout was accepted"
else
  pass "mdm-detect: persistent checkout owner and mode are verified"
fi
chmod 755 "$_mdm_detect_install"

chmod 777 "$_mdm_detect_install/.git"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: writable .git directory was accepted"
else
  pass "mdm-detect: persistent .git owner/mode/ACL is verified"
fi
chmod 755 "$_mdm_detect_install/.git"

(
  export MDM_DETECT_EXPECTED_UID_OVERRIDE
  MDM_DETECT_EXPECTED_UID_OVERRIDE=$(( $(/usr/bin/id -u) + 1 ))
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: wrong-owner persistent checkout was accepted"
  else
    pass "mdm-detect: persistent checkout must belong to the target UID"
  fi
)

chmod 666 "$_mdm_detect_install/.git/HEAD"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: writable detached HEAD was accepted"
else
  pass "mdm-detect: detached HEAD mode matches remediation trust"
fi
chmod 644 "$_mdm_detect_install/.git/HEAD"
ln "$_mdm_detect_install/.git/HEAD" "$_mdm_detect_install/.git/HEAD.peer"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: hardlinked detached HEAD was accepted"
else
  pass "mdm-detect: detached HEAD requires link count one"
fi
rm "$_mdm_detect_install/.git/HEAD.peer"

printf '%s\0' "$_mdm_detect_sha" > "$_mdm_detect_install/.git/HEAD"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: NUL-terminated detached HEAD was accepted"
else
  pass "mdm-detect: detached HEAD requires an exact trailing LF"
fi
printf '%s\n' "$_mdm_detect_sha" > "$_mdm_detect_install/.git/HEAD"

if _mdm_is_darwin \
  && chmod +a 'everyone allow write' "$_mdm_detect_persistent_marker" 2>/dev/null; then
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: persistent marker ACL was accepted"
  else
    pass "mdm-detect: persistent marker ACL is rejected"
  fi
  chmod -N "$_mdm_detect_persistent_marker"
else
  skip "mdm-detect: persistent marker ACL is rejected" \
    "ACL fixture unavailable on this platform"
fi

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '[]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: malformed required-components contract was accepted"
else
  pass "mdm-detect: required-components contract includes kit"
fi
mkdir -p "$_mdm_detect_home/.local/bin"
ln -s /usr/bin/true "$_mdm_detect_home/.local/bin/claude"
if _mdm_cli_present "$_mdm_detect_home"; then
  fail "mdm-detect: arbitrary executable symlink was accepted as Claude CLI"
else
  pass "mdm-detect: arbitrary executable symlink is rejected"
fi
rm "$_mdm_detect_home/.local/bin/claude"
mkdir -p "$_mdm_detect_home/.local/share/claude/versions"
/bin/cp /usr/bin/true "$_mdm_detect_home/.local/share/claude/versions/fake"
ln -s ../share/claude/versions/fake "$_mdm_detect_home/.local/bin/claude"
if _mdm_cli_present "$_mdm_detect_home"; then
  fail "mdm-detect: wrong-signer binary in Claude versions tree was accepted"
else
  pass "mdm-detect: Claude CLI requires an Apple-anchored Anthropic signature"
fi
rm "$_mdm_detect_home/.local/bin/claude"

# Display strings can be reproduced by a locally issued certificate.  Require
# codesign itself to evaluate the external Apple Developer ID requirement.
(
  _cli_requirement_log="$_mdm_detect_tmp/cli-requirement.log"
  _cli_requirement="$(_mdm_claude_cli_codesign_requirement)"
  _mdm_claude_codesign() {
    if [[ "$1" == --verify ]]; then
      printf '%s\n' "$@" > "$_cli_requirement_log"
      return 0
    fi
    printf '%s\n' \
      'Identifier=com.anthropic.claude-code' \
      'Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)' \
      'TeamIdentifier=Q6L2SF6YDW'
  }
  if _mdm_claude_cli_signature_trusted /dev/null \
    && /usr/bin/grep -Fxq -- '-R' "$_cli_requirement_log" \
    && /usr/bin/grep -Fxq -- "$_cli_requirement" "$_cli_requirement_log" \
    && [[ "$_cli_requirement" == *'anchor apple generic'* ]] \
    && [[ "$_cli_requirement" == *'certificate 1[field.1.2.840.113635.100.6.2.6]'* ]] \
    && [[ "$_cli_requirement" == *'certificate leaf[field.1.2.840.113635.100.6.1.13]'* ]]; then
    pass "mdm-detect: CLI は明示 Apple Developer ID requirement で検証"
  else
    fail "mdm-detect: CLI codesign に外部 trust requirement がない"
  fi
)
(
  _spoof_details=$'Identifier=com.anthropic.claude-code\nAuthority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)\nTeamIdentifier=Q6L2SF6YDW'
  _mdm_claude_codesign() {
    [[ "$1" == --verify ]] && return 3
    printf '%s\n' "$_spoof_details"
  }
  if [[ "$_spoof_details" == *'TeamIdentifier=Q6L2SF6YDW'* ]] \
    && ! _mdm_claude_cli_signature_trusted /dev/null; then
    pass "mdm-detect: 表示文字列を模倣した自己署名 CLI を拒否"
  else
    fail "mdm-detect: 表示文字列だけで自己署名 CLI を許容し得る"
  fi
)

# Legacy receipts and unsuccessful runs never become compliant.
_mdm_detect_write_receipt 1 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: legacy receipt schema was accepted"
else
  pass "mdm-detect: only receipt schema v2 is accepted"
fi
_mdm_detect_write_receipt 2 failure "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: failure receipt was accepted"
else
  pass "mdm-detect: failure receipt is non-compliant"
fi

# Receipt user, full SHA, and optional expected commit are exact matches.
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" alice '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: target-user mismatch was accepted"
else
  pass "mdm-detect: target-user mismatch is rejected"
fi
_mdm_detect_write_receipt 2 success "${_mdm_detect_sha:0:39}" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: abbreviated resolved SHA was accepted"
else
  pass "mdm-detect: resolved SHA must be full length"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane 0000000000000000000000000000000000000000; then
  fail "mdm-detect: expected commit mismatch was accepted"
else
  pass "mdm-detect: expected commit mismatch is rejected"
fi

# Source-only tests must explicitly name their trust root.
unset MDM_DETECT_TRUST_BASE_OVERRIDE
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: source-only receipt was trusted without an explicit base"
else
  pass "mdm-detect: source-only mode requires an explicit trust base"
fi
MDM_DETECT_TRUST_BASE_OVERRIDE="$_mdm_detect_trust_base"

(
  _MDM_DETECT_TEST_MODE=0
  if [[ "$(_mdm_receipt_trust_base)" == '/Library/Application Support' \
    && "$(_mdm_expected_trust_owner)" == root ]]; then
    pass "mdm-detect: production self-check always uses the root receipt contract"
  else
    fail "mdm-detect: production receipt trust varies by caller"
  fi
)

# The root-owned receipt contract rejects untrusted owners, modes, symlinks,
# ACLs and every unsafe directory component below the fixed trust root.
_mdm_detect_actual_owner="$(/usr/bin/id -un)"
if [[ "$_mdm_detect_actual_owner" == root ]]; then
  MDM_DETECT_EXPECTED_OWNER_OVERRIDE=nobody
else
  MDM_DETECT_EXPECTED_OWNER_OVERRIDE=root
fi
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: receipt with an unexpected owner was accepted"
else
  pass "mdm-detect: receipt owner must match the trusted owner"
fi
MDM_DETECT_EXPECTED_OWNER_OVERRIDE="$_mdm_detect_actual_owner"

chmod 664 "$_mdm_detect_receipt"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: group-writable receipt was accepted"
else
  pass "mdm-detect: group-writable receipt is rejected"
fi
chmod 644 "$_mdm_detect_receipt"
_mdm_detect_receipt_real="$_mdm_detect_receipts/receipt-real.json"
mv "$_mdm_detect_receipt" "$_mdm_detect_receipt_real"
ln -s "$_mdm_detect_receipt_real" "$_mdm_detect_receipt"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: symlink receipt was accepted"
else
  pass "mdm-detect: symlink receipt is rejected"
fi
rm "$_mdm_detect_receipt"
mv "$_mdm_detect_receipt_real" "$_mdm_detect_receipt"

if _mdm_is_darwin && chmod +a 'everyone allow write' "$_mdm_detect_receipt" 2>/dev/null; then
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: writable receipt ACL was accepted"
  else
    pass "mdm-detect: receipt ACL is rejected"
  fi
  chmod -N "$_mdm_detect_receipt"
else
  skip "mdm-detect: receipt ACL is rejected" "ACL fixture unavailable on this platform"
fi

chmod 777 "$_mdm_detect_receipts"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: writable receipt parent was accepted"
else
  pass "mdm-detect: writable receipt parent is rejected"
fi
chmod 755 "$_mdm_detect_receipts"

_mdm_detect_receipts_real="$_mdm_detect_trust_base/ClaudeCodeStarterKit.real"
mv "$_mdm_detect_receipts" "$_mdm_detect_receipts_real"
ln -s "$_mdm_detect_receipts_real" "$_mdm_detect_receipts"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: symlink in receipt parent chain was accepted"
else
  pass "mdm-detect: symlink in receipt parent chain is rejected"
fi
rm "$_mdm_detect_receipts"
mv "$_mdm_detect_receipts_real" "$_mdm_detect_receipts"

chmod 777 "$_mdm_detect_trust_base"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: writable receipt trust base was accepted"
else
  pass "mdm-detect: writable receipt trust base is rejected"
fi
chmod 700 "$_mdm_detect_trust_base"

if _mdm_is_darwin && chmod +a 'everyone allow write' "$_mdm_detect_receipts" 2>/dev/null; then
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: ACL on receipt parent chain was accepted"
  else
    pass "mdm-detect: ACL on receipt parent chain is rejected"
  fi
  chmod -N "$_mdm_detect_receipts"
else
  skip "mdm-detect: receipt parent ACL is rejected" "ACL fixture unavailable on this platform"
fi

# The receipt hash anchors the canonical manifest and deployed state.
printf '\n' >> "$_mdm_detect_manifest"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: modified manifest was accepted"
else
  pass "mdm-detect: manifest SHA-256 mismatch is rejected"
fi
_mdm_detect_write_manifest
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

{
  printf '{\n'
  printf '  "version": "2",\n'
  printf '  "mdm_managed": true,\n'
  printf '  "kit_commit": "%s",\n' "$_mdm_detect_short"
  printf '  "profile": "standard",\n'
  printf '  "language": "ja",\n'
  printf '  "claude_dir": "%s",\n' "$_mdm_detect_claude"
  printf '  "snapshot_dir": "%s",\n' "$_mdm_detect_snapshot"
  printf '  "mdm_absent_files": [],\n'
  printf '  "files": [\n'
  _mdm_detect_index=0
  while [[ "$_mdm_detect_index" -le 1000 ]]; do
    printf '    "%s"' "$_mdm_detect_claude/settings.json"
    [[ "$_mdm_detect_index" -eq 1000 ]] || printf ','
    printf '\n'
    _mdm_detect_index=$((_mdm_detect_index + 1))
  done
  printf '  ]\n}\n'
} > "$_mdm_detect_manifest"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: manifest with excessive file count was accepted"
else
  pass "mdm-detect: manifest file count is capped at 1000"
fi
_mdm_detect_write_manifest
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

# Manifest-declared absences are part of the deployment digest and must hold
# independently in both the live tree and its managed snapshot.
_mdm_detect_manifest_absent_json='["commands/retired.md"]'
_mdm_detect_write_manifest
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  pass "mdm-detect: manifest-declared absent paths are deployment-attested"
else
  fail "mdm-detect: a genuinely absent deployment path was rejected"
fi

mkdir -p "$_mdm_detect_claude/commands"
printf 'stale live payload\n' > "$_mdm_detect_claude/commands/retired.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: live retired payload was accepted as absent"
else
  pass "mdm-detect: manifest-declared path must be absent from the live tree"
fi
rm -rf "$_mdm_detect_claude/commands"

mkdir -p "$_mdm_detect_snapshot/commands"
printf 'stale snapshot payload\n' > "$_mdm_detect_snapshot/commands/retired.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: snapshot retired payload was accepted as absent"
else
  pass "mdm-detect: manifest-declared path must be absent from the snapshot"
fi
rm -rf "$_mdm_detect_snapshot/commands"

mkdir -p "$_mdm_detect_tmp/absence-symlink-target"
ln -s "$_mdm_detect_tmp/absence-symlink-target" \
  "$_mdm_detect_claude/commands"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: symlinked parent was treated as evidence of absence"
else
  pass "mdm-detect: symlinked absent-path parents fail closed"
fi
rm "$_mdm_detect_claude/commands"

mkdir -p "$_mdm_detect_claude/commands"
chmod 000 "$_mdm_detect_claude/commands"
if [[ "$(/usr/bin/id -u)" == 0 ]]; then
  skip "mdm-detect: unreadable absent-path parents fail closed" \
    "root can traverse the mode-000 fixture"
elif mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: unreadable parent was treated as evidence of absence"
else
  pass "mdm-detect: unreadable absent-path parents fail closed"
fi
chmod 700 "$_mdm_detect_claude/commands"
rm -rf "$_mdm_detect_claude/commands" \
  "$_mdm_detect_tmp/absence-symlink-target"

_mdm_detect_manifest_absent_json='[]'
_mdm_detect_write_manifest
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

mv "$_mdm_detect_claude/settings.json" "$_mdm_detect_claude/settings.json.missing"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: missing deployed file was accepted"
else
  pass "mdm-detect: all manifest files must exist"
fi
mv "$_mdm_detect_claude/settings.json.missing" "$_mdm_detect_claude/settings.json"

mv "$_mdm_detect_snapshot/settings.json" "$_mdm_detect_snapshot/settings.json.missing"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: missing snapshot file was accepted"
else
  pass "mdm-detect: snapshot state must exist"
fi
mv "$_mdm_detect_snapshot/settings.json.missing" "$_mdm_detect_snapshot/settings.json"

cp "$_mdm_detect_claude/settings.json" "$_mdm_detect_tmp/settings.real"
rm "$_mdm_detect_claude/settings.json"
ln -s "$_mdm_detect_tmp/settings.real" "$_mdm_detect_claude/settings.json"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: symlink managed file was accepted"
else
  pass "mdm-detect: managed live and snapshot paths must be canonical files"
fi
rm "$_mdm_detect_claude/settings.json"
mv "$_mdm_detect_tmp/settings.real" "$_mdm_detect_claude/settings.json"

_mdm_detect_live_mode="$(_mdm_stat_mode "$_mdm_detect_claude/settings.json")"
chmod 666 "$_mdm_detect_claude/settings.json"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: writable managed-file mode was accepted"
else
  pass "mdm-detect: live managed-file mode is deployment-attested"
fi
chmod "$_mdm_detect_live_mode" "$_mdm_detect_claude/settings.json"

_mdm_detect_snapshot_mode="$(_mdm_stat_mode "$_mdm_detect_snapshot/settings.json")"
chmod 600 "$_mdm_detect_snapshot/settings.json"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: changed snapshot mode was accepted"
else
  pass "mdm-detect: snapshot mode is deployment-attested separately"
fi
chmod "$_mdm_detect_snapshot_mode" "$_mdm_detect_snapshot/settings.json"

_mdm_detect_expected_uid_saved="$MDM_DETECT_EXPECTED_UID_OVERRIDE"
if [[ "$_mdm_detect_expected_uid_saved" == 0 ]]; then
  MDM_DETECT_EXPECTED_UID_OVERRIDE=1
else
  MDM_DETECT_EXPECTED_UID_OVERRIDE=0
fi
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: managed file with unexpected owner was accepted"
else
  pass "mdm-detect: live and snapshot files must belong to the target UID"
fi
MDM_DETECT_EXPECTED_UID_OVERRIDE="$_mdm_detect_expected_uid_saved"

# A present-file snapshot must be invalidated when its real parent is swapped
# after the original inode is open but before post-copy validation.  The
# third metadata read is the child's post-copy check.
if _mdm_is_darwin && [[ -x /usr/bin/python3 ]]; then
  (
    _present_swap_root="$_mdm_detect_tmp/present-parent-swap"
    _present_slot="$_present_swap_root/slot"
    _present_spare="$_present_swap_root/spare"
    _present_counter="$_present_swap_root/metadata-count"
    _present_swapped="$_present_swap_root/swapped"
    mkdir -p "$_present_slot" "$_present_spare"
    printf 'original-present\n' > "$_present_slot/managed"
    printf 'replacement-data\n' > "$_present_spare/managed"
    : > "$_present_counter"
    _mdm_stat_metadata() {
      if [[ "$1" == "$_present_slot/managed" ]]; then
        printf 'read\n' >> "$_present_counter"
        _present_reads="$(wc -l < "$_present_counter" | tr -d ' ')"
        if [[ "$_present_reads" -eq 3 ]] && /usr/bin/python3 -I -B -c '
import ctypes
import sys

renamex_np = ctypes.CDLL(None).renamex_np
renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int
raise SystemExit(0 if renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2) == 0 else 1)
' "$_present_slot" "$_present_spare"; then
          : > "$_present_swapped"
        fi
      fi
      /usr/bin/stat -f '%i:%HT:%z:%u:%Mp%Lp:%l' "$1" 2>/dev/null
    }
    _present_rc=0
    _mdm_snapshot_bound_file "$_present_slot/managed" \
      "$_mdm_detect_private_base/present-swap-copy" managed \
      "$MDM_DETECT_EXPECTED_UID_OVERRIDE" || _present_rc=$?
    if [[ ! -f "$_present_swapped" ]]; then
      skip "mdm-detect: present-file parent swaps invalidate stale snapshots" \
        "renamex_np fixture unavailable"
    elif [[ "$_present_rc" -ne 0 \
      && "$(< "$_present_slot/managed")" == replacement-data ]]; then
      pass "mdm-detect: present-file parent swaps invalidate stale snapshots"
    else
      fail "mdm-detect: stale present-file bytes survived a parent swap"
    fi
    rm -rf "$_present_swap_root"
    rm -f "$_mdm_detect_private_base/present-swap-copy"
  )
else
  skip "mdm-detect: present-file parent swaps invalidate stale snapshots" \
    "Darwin renamex_np fixture only"
fi

# An absent-path check must describe the current pathname.  Pause the helper
# after it opens the original real directory, atomically swap another real
# directory containing the target into that pathname, then resume.  A stale
# fd-only walk would return a false compliant result here.
if _mdm_is_darwin && [[ -x /usr/bin/python3 ]]; then
  (
    _absence_tmp="$(mktemp -d)"
    _absence_root="$_absence_tmp/root"
    _absence_slot="$_absence_root/slot"
    _absence_spare="$_absence_root/spare"
    _absence_wrapper="$_absence_tmp/python-wrapper"
    mkdir -p "$_absence_slot" "$_absence_spare"
    : > "$_absence_spare/target"
    cat > "$_absence_wrapper" <<'WRAPPER'
#!/bin/bash
[[ "$#" -eq 6 && "$1" == -I && "$2" == -B && "$3" == -c ]] || exit 64
exec /usr/bin/python3 -I -B -c '
import os
import sys
import time

root, relative, original_code = sys.argv[1], sys.argv[2], sys.argv[3]
real_open = os.open
ready = os.path.join(root, ".absence-ready")
proceed = os.path.join(root, ".absence-proceed")
blocked = False

def controlled_open(path, flags, *args, **kwargs):
    global blocked
    descriptor = real_open(path, flags, *args, **kwargs)
    if (
        not blocked
        and path == relative.split("/", 1)[0]
        and kwargs.get("dir_fd") is not None
    ):
        blocked = True
        marker = real_open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(marker)
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                raise SystemExit(70)
            time.sleep(0.005)
    return descriptor

os.open = controlled_open
exec(compile(original_code, "<absence-helper>", "exec"))
' "$5" "$6" "$4"
WRAPPER
    chmod 700 "$_absence_wrapper"
    _absence_python_saved="${_MDM_DETECT_ABSENCE_PYTHON:-}"
    _MDM_DETECT_ABSENCE_PYTHON="$_absence_wrapper"
    _mdm_path_is_absent_with_real_parents \
      "$_absence_root" slot/target >/dev/null 2>&1 &
    _absence_pid=$!
    _absence_wait=0
    while [[ ! -e "$_absence_root/.absence-ready" && "$_absence_wait" -lt 500 ]]; do
      /bin/sleep 0.01
      _absence_wait=$((_absence_wait + 1))
    done
    _absence_swap_rc=1
    if [[ -e "$_absence_root/.absence-ready" ]]; then
      /usr/bin/python3 -I -B -c '
import ctypes
import sys

renamex_np = ctypes.CDLL(None).renamex_np
renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int
raise SystemExit(0 if renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2) == 0 else 1)
' "$_absence_slot" "$_absence_spare" && _absence_swap_rc=0
    fi
    : > "$_absence_root/.absence-proceed"
    _absence_rc=0
    wait "$_absence_pid" || _absence_rc=$?
    _MDM_DETECT_ABSENCE_PYTHON="$_absence_python_saved"
    if [[ "$_absence_swap_rc" -ne 0 ]]; then
      skip "mdm-detect: absent path is rebound after a real-parent swap" \
        "renamex_np fixture unavailable"
    elif [[ "$_absence_rc" -ne 0 && -f "$_absence_slot/target" ]]; then
      pass "mdm-detect: absent path is rebound after a real-parent swap"
    else
      fail "mdm-detect: renamed-away parent produced false absence (rc=$_absence_rc)"
    fi
    rm -rf "$_absence_tmp"
  )
else
  skip "mdm-detect: absent path is rebound after a real-parent swap" \
    "Darwin renamex_np fixture only"
fi

if _mdm_is_darwin \
  && chmod +a 'everyone allow write' "$_mdm_detect_claude/settings.json" 2>/dev/null; then
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: managed file with a writable ACL was accepted"
  else
    pass "mdm-detect: managed-file ACLs are rejected"
  fi
  chmod -N "$_mdm_detect_claude/settings.json"
else
  skip "mdm-detect: managed-file ACLs are rejected" "ACL fixture unavailable on this platform"
fi

cp "$_mdm_detect_claude/settings.json" "$_mdm_detect_tmp/settings.hardlink"
rm "$_mdm_detect_claude/settings.json"
ln "$_mdm_detect_tmp/settings.hardlink" "$_mdm_detect_claude/settings.json"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: hard-linked managed file was accepted"
else
  pass "mdm-detect: managed live and snapshot files require link count one"
fi
rm "$_mdm_detect_claude/settings.json"
mv "$_mdm_detect_tmp/settings.hardlink" "$_mdm_detect_claude/settings.json"

cp "$_mdm_detect_claude/CLAUDE.md" "$_mdm_detect_tmp/claude.saved"
printf '# another personal instruction\n' >> "$_mdm_detect_claude/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  pass "mdm-detect: CLAUDE.md user-section changes remain compliant"
else
  fail "mdm-detect: CLAUDE.md user section leaked into deployment attestation"
fi
mv "$_mdm_detect_tmp/claude.saved" "$_mdm_detect_claude/CLAUDE.md"

cp "$_mdm_detect_claude/CLAUDE.md" "$_mdm_detect_tmp/claude.saved"
printf '%s\n# changed managed\n%s\n# user\npersonal\n' \
  "$_MDM_MARKER_BEGIN" "$_MDM_MARKER_END" > "$_mdm_detect_claude/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: changed CLAUDE.md managed section was accepted"
else
  pass "mdm-detect: CLAUDE.md managed-section drift is non-compliant"
fi
mv "$_mdm_detect_tmp/claude.saved" "$_mdm_detect_claude/CLAUDE.md"

cp "$_mdm_detect_claude/CLAUDE.md" "$_mdm_detect_tmp/claude.saved"
/usr/bin/awk '{ printf "%s\r\n", $0 }' "$_mdm_detect_tmp/claude.saved" \
  > "$_mdm_detect_claude/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: CLAUDE.md managed CRLF drift was accepted"
else
  pass "mdm-detect: CLAUDE.md managed section requires byte-exact LF content"
fi
mv "$_mdm_detect_tmp/claude.saved" "$_mdm_detect_claude/CLAUDE.md"

cp "$_mdm_detect_claude/CLAUDE.md" "$_mdm_detect_tmp/claude.saved"
printf '%s\n' "$_MDM_MARKER_BEGIN" >> "$_mdm_detect_claude/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: duplicate CLAUDE.md marker was accepted"
else
  pass "mdm-detect: duplicate CLAUDE.md markers are rejected"
fi
mv "$_mdm_detect_tmp/claude.saved" "$_mdm_detect_claude/CLAUDE.md"

cp "$_mdm_detect_snapshot/CLAUDE.md" "$_mdm_detect_tmp/snapshot-claude.saved"
printf '# marker missing\n' > "$_mdm_detect_snapshot/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: markerless CLAUDE.md snapshot was accepted"
else
  pass "mdm-detect: missing CLAUDE.md snapshot markers are rejected"
fi
printf '%s\n%s\n' "$_MDM_MARKER_END" "$_MDM_MARKER_BEGIN" \
  > "$_mdm_detect_snapshot/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: reversed CLAUDE.md marker order was accepted"
else
  pass "mdm-detect: reversed CLAUDE.md marker order is rejected"
fi
printf '%s\n# managed\n%s\n# unexpected snapshot tail\n' \
  "$_MDM_MARKER_BEGIN" "$_MDM_MARKER_END" > "$_mdm_detect_snapshot/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: user content in CLAUDE.md snapshot was accepted"
else
  pass "mdm-detect: CLAUDE.md snapshot must contain only the managed section"
fi
mv "$_mdm_detect_tmp/snapshot-claude.saved" "$_mdm_detect_snapshot/CLAUDE.md"

# The deployment digest binds the ordered relative path + live hash + snapshot
# hash + mode tuple, so either side drifting is non-compliant even when present.
cp "$_mdm_detect_claude/settings.json" "$_mdm_detect_tmp/settings.live.saved"
printf '{"managed":false}\n' > "$_mdm_detect_claude/settings.json"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: live managed-file drift was accepted"
else
  pass "mdm-detect: live managed-file drift is non-compliant"
fi
mv "$_mdm_detect_tmp/settings.live.saved" "$_mdm_detect_claude/settings.json"

cp "$_mdm_detect_snapshot/settings.json" "$_mdm_detect_tmp/settings.snapshot.saved"
printf '{"managed":false}\n' > "$_mdm_detect_snapshot/settings.json"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: snapshot managed-file drift was accepted"
else
  pass "mdm-detect: snapshot managed-file drift is non-compliant"
fi
mv "$_mdm_detect_tmp/settings.snapshot.saved" "$_mdm_detect_snapshot/settings.json"

# Receipt policy fields must describe the manifest snapshot that was actually
# deployed; no new policy CLI is needed for this internal consistency check.
_mdm_detect_manifest_profile=full
_mdm_detect_write_manifest
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: receipt/manifest profile mismatch was accepted"
else
  pass "mdm-detect: receipt profile must match manifest profile"
fi
_mdm_detect_manifest_profile=standard
_mdm_detect_manifest_language=en
_mdm_detect_write_manifest
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: receipt/manifest language mismatch was accepted"
else
  pass "mdm-detect: receipt language must match manifest language"
fi
_mdm_detect_manifest_language=ja
_mdm_detect_write_manifest
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

# Root never invokes Git in the target checkout.  A detached HEAD is read from
# an fd-bound byte snapshot, so Git config/attributes cannot trigger code.
cp "$_mdm_detect_install/.git/HEAD" "$_mdm_detect_tmp/head.saved"
printf '%040d\n' 0 > "$_mdm_detect_install/.git/HEAD"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: detached HEAD mismatch was accepted"
else
  pass "mdm-detect: detached HEAD must equal the receipt SHA"
fi
mv "$_mdm_detect_tmp/head.saved" "$_mdm_detect_install/.git/HEAD"

_mdm_detect_filter_canary="$_mdm_detect_tmp/git-filter-ran"
{
  printf '\n[filter "mdm-pwn"]\n'
  printf '\tclean = /usr/bin/touch %s\n' "$_mdm_detect_filter_canary"
} >> "$_mdm_detect_install/.git/config"
printf 'file filter=mdm-pwn\n' > "$_mdm_detect_install/.gitattributes"
printf 'changed\n' > "$_mdm_detect_install/file"
if mdm_detect "$_mdm_detect_receipt" jane \
  && [[ ! -e "$_mdm_detect_filter_canary" ]]; then
  pass "mdm-detect: target Git config and clean filters are never executed"
else
  fail "mdm-detect: target Git configuration influenced root detection"
fi

# An fd identity mismatch must fail before parsing, and all private workspaces
# must be removed on both success and failure.
(
  _mdm_stat_fd_identity() { printf '0:Regular File:0'; }
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: fd inode mismatch was accepted"
  else
    pass "mdm-detect: receipt/manifest snapshots require fd inode equality"
  fi
)
(
  _mdm_stat_metadata() {
    if [[ "$1" == "$_mdm_detect_manifest" ]]; then
      if _mdm_is_darwin; then
        _mdm_detect_actual_metadata="$(/usr/bin/stat \
          -f '%i:%HT:%z:%u:%Mp%Lp:%l' "$1" 2>/dev/null)"
      else
        _mdm_detect_actual_metadata="$(/usr/bin/stat \
          -c '%i:%F:%s:%u:%a:%h' "$1" 2>/dev/null)"
      fi
      printf '0:%s' "${_mdm_detect_actual_metadata#*:}"
    elif _mdm_is_darwin; then
      /usr/bin/stat -f '%i:%HT:%z:%u:%Mp%Lp:%l' "$1" 2>/dev/null
    else
      /usr/bin/stat -c '%i:%F:%s:%u:%a:%h' "$1" 2>/dev/null
    fi
  }
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: manifest fd inode mismatch was accepted"
  else
    pass "mdm-detect: user-owned manifest requires fd inode equality"
  fi
)

_mdm_detect_large="$_mdm_detect_tmp/oversized-json"
/bin/dd if=/dev/zero of="$_mdm_detect_large" bs=1 count=0 seek=4194305 2>/dev/null
if _mdm_snapshot_bound_file "$_mdm_detect_large" \
    "$_mdm_detect_private_base/receipt-copy" receipt \
  || _mdm_snapshot_bound_file "$_mdm_detect_large" \
    "$_mdm_detect_private_base/manifest-copy" manifest \
  || ! _mdm_snapshot_bound_file "$_mdm_detect_large" \
    "$_mdm_detect_private_base/managed-copy" managed \
    "$MDM_DETECT_EXPECTED_UID_OVERRIDE" \
  || [[ "$_MDM_DETECT_SNAPSHOT_SIZE" != 4194305 \
    || ! "$_MDM_DETECT_SNAPSHOT_MODE" =~ ^[0-7]{4}$ ]]; then
  fail "mdm-detect: receipt/manifest size cap was not label-specific"
else
  pass "mdm-detect: receipt and manifest snapshots are capped at 4 MiB"
fi
rm -f "$_mdm_detect_large" "$_mdm_detect_private_base/receipt-copy" \
  "$_mdm_detect_private_base/manifest-copy" "$_mdm_detect_private_base/managed-copy"

_mdm_detect_large="$_mdm_detect_tmp/oversized-managed"
/bin/dd if=/dev/zero of="$_mdm_detect_large" bs=1 count=0 seek=67108865 2>/dev/null
if _mdm_snapshot_bound_file "$_mdm_detect_large" \
  "$_mdm_detect_private_base/oversized-copy" managed \
  "$MDM_DETECT_EXPECTED_UID_OVERRIDE"; then
  fail "mdm-detect: oversized managed file was snapshotted"
else
  pass "mdm-detect: fd-bound snapshots enforce label-specific size caps"
fi
rm -f "$_mdm_detect_large" "$_mdm_detect_private_base/oversized-copy"

_mdm_detect_cli_source="$_mdm_detect_tmp/claude-cli-source"
_mdm_detect_cli_copy="$_mdm_detect_private_base/claude-cli-copy"
/bin/cp /usr/bin/true "$_mdm_detect_cli_source"
chmod 755 "$_mdm_detect_cli_source"
_mdm_detect_cli_mode="$(_mdm_detect_fixture_mode "$_mdm_detect_cli_source")"
if _mdm_snapshot_bound_file "$_mdm_detect_cli_source" \
    "$_mdm_detect_cli_copy" cli "$MDM_DETECT_EXPECTED_UID_OVERRIDE" \
  && /usr/bin/cmp -s "$_mdm_detect_cli_source" "$_mdm_detect_cli_copy" \
  && [[ "$_MDM_DETECT_SNAPSHOT_MODE" == "$_mdm_detect_cli_mode" ]]; then
  pass "mdm-detect: CLI verification uses an exact fd-bound byte snapshot"
else
  fail "mdm-detect: a valid CLI file could not be snapshotted"
fi
rm -f "$_mdm_detect_cli_copy"
ln "$_mdm_detect_cli_source" "$_mdm_detect_tmp/claude-cli-peer"
if _mdm_snapshot_bound_file "$_mdm_detect_cli_source" \
  "$_mdm_detect_cli_copy" cli "$MDM_DETECT_EXPECTED_UID_OVERRIDE"; then
  fail "mdm-detect: hard-linked CLI file was snapshotted"
else
  pass "mdm-detect: CLI snapshots require link count one"
fi
rm -f "$_mdm_detect_cli_source" "$_mdm_detect_tmp/claude-cli-peer" \
  "$_mdm_detect_cli_copy"

(
  _mdm_detect_budget_workspace="$_mdm_detect_private_base/budget-workspace"
  mkdir -m 700 "$_mdm_detect_budget_workspace"
  _mdm_snapshot_bound_file() {
    /bin/cp "$1" "$2" || return 1
    /bin/chmod 600 "$2" || return 1
    _MDM_DETECT_SNAPSHOT_SIZE=300000000
    _MDM_DETECT_SNAPSHOT_MODE=0644
  }
  _mdm_detect_manifest_hash="$(_mdm_sha256 "$_mdm_detect_manifest")"
  _mdm_detect_deployment_hash="$(_mdm_detect_fixture_deployment_sha)"
  if _mdm_manifest_is_valid "$_mdm_detect_manifest" \
    "$_mdm_detect_manifest_hash" "$_mdm_detect_sha" "$_mdm_detect_home" \
    standard ja "$_mdm_detect_deployment_hash" "$_mdm_detect_budget_workspace" \
    "$MDM_DETECT_EXPECTED_UID_OVERRIDE"; then
    fail "mdm-detect: aggregate managed-byte budget was ignored"
  else
    pass "mdm-detect: live and snapshot bytes share a 512 MiB aggregate budget"
  fi
  rm -rf "$_mdm_detect_budget_workspace"
)

# Force a regular-file-to-FIFO swap after the CLI pre-stat.  The child open
# must time out instead of blocking codesign verification indefinitely.
(
  _mdm_detect_fifo="$_mdm_detect_tmp/swap-to-fifo"
  printf 'regular\n' > "$_mdm_detect_fifo"
  _mdm_detect_real_metadata="$(_mdm_stat_metadata "$_mdm_detect_fifo")"
  _mdm_stat_metadata() {
    if [[ "$1" == "$_mdm_detect_fifo" ]]; then
      rm -f "$_mdm_detect_fifo"
      /usr/bin/mkfifo "$_mdm_detect_fifo"
      printf '%s' "$_mdm_detect_real_metadata"
    elif _mdm_is_darwin; then
      /usr/bin/stat -f '%i:%HT:%z:%u:%Mp%Lp:%l' "$1" 2>/dev/null
    else
      /usr/bin/stat -c '%i:%F:%s:%u:%a:%h' "$1" 2>/dev/null
    fi
  }
  SECONDS=0
  if _mdm_snapshot_bound_file "$_mdm_detect_fifo" \
    "$_mdm_detect_private_base/fifo-copy" cli \
    "$MDM_DETECT_EXPECTED_UID_OVERRIDE"; then
    fail "mdm-detect: swapped CLI FIFO was accepted"
  elif [[ "$SECONDS" -le 8 ]]; then
    pass "mdm-detect: swapped CLI FIFO cannot block detection indefinitely"
  else
    fail "mdm-detect: swapped CLI FIFO timeout exceeded its bound"
  fi
  rm -f "$_mdm_detect_fifo" "$_mdm_detect_private_base/fifo-copy"
)
if find "$_mdm_detect_private_base" -mindepth 1 -maxdepth 1 -print | grep -q .; then
  fail "mdm-detect: private detector workspace leaked"
else
  pass "mdm-detect: private detector workspaces are always cleaned"
fi

if grep -q '/usr/bin/git' "$PROJECT_DIR/mdm/detect-mdm.sh"; then
  fail "mdm-detect: detector still invokes Git as root"
else
  pass "mdm-detect: detector performs no Git command execution"
fi

# SemVer precedence follows the 2.0.0 identifier rules without integer
# arithmetic, including prerelease ordering and build-metadata neutrality.
_mdm_semver_ok=1
for _mdm_semver_valid in 0.73.0 v1.2.3-rc.1+build.005 1.0.0-alpha; do
  _mdm_semver_is_valid "$_mdm_semver_valid" || _mdm_semver_ok=0
done
for _mdm_semver_invalid in 01.2.3 1.02.3 1.2.03 1.2.3-rc..1 \
  1.2.3-01 1.2.3+; do
  if _mdm_semver_is_valid "$_mdm_semver_invalid"; then _mdm_semver_ok=0; fi
done
_mdm_semver_previous=""
for _mdm_semver_current in 1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta \
  1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0; do
  if [[ -n "$_mdm_semver_previous" ]] \
    && ! _mdm_version_lt "$_mdm_semver_previous" "$_mdm_semver_current"; then
    _mdm_semver_ok=0
  fi
  _mdm_semver_previous="$_mdm_semver_current"
done
if _mdm_version_lt 1.0.0+build.1 1.0.0+build.2 \
  || _mdm_version_lt 1.0.0+build.2 1.0.0+build.1; then
  _mdm_semver_ok=0
fi
_mdm_version_lt 99999999999999999999.0.0 \
  100000000000000000000.0.0 || _mdm_semver_ok=0
if [[ "$_mdm_semver_ok" -eq 1 ]]; then
  pass "mdm-detect: SemVer prerelease/build/任意長数値を正しく比較"
else
  fail "mdm-detect: SemVer 2.0 precedence が不正"
fi

# Source-only main tests exercise strict argument status codes and constraints.
export MDM_RECEIPT_DIR_OVERRIDE="$_mdm_detect_receipts"
export MDM_EUID_OVERRIDE=0 MDM_CONSOLE_USER_OVERRIDE=jane
export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
_mdm_detect_main_rc=0
_mdm_detect_main_out="$(mdm_detect_main --expected-commit "$_mdm_detect_sha")" \
  || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 0 && "$_mdm_detect_main_out" == compliant ]]; then
  pass "mdm-detect: main accepts an exact expected commit"
else
  fail "mdm-detect: valid main invocation failed"
fi

for _mdm_detect_bad_args in \
  '--min-verison 0.73.0' \
  '--min-version garbage' \
  '--min-version 01.2.3' \
  '--expected-commit short' \
  '--user'; do
  _mdm_detect_main_rc=0
  # Intentional word splitting supplies each argument vector without eval.
  # shellcheck disable=SC2086
  mdm_detect_main $_mdm_detect_bad_args >/dev/null 2>&1 || _mdm_detect_main_rc=$?
  if [[ "$_mdm_detect_main_rc" -eq 2 ]]; then
    pass "mdm-detect: invalid arguments exit 2 ($_mdm_detect_bad_args)"
  else
    fail "mdm-detect: invalid arguments returned $_mdm_detect_main_rc ($_mdm_detect_bad_args)"
  fi
done

for _mdm_detect_valid_user in John.Smith alice@corp; do
  _mdm_detect_main_rc=0
  mdm_detect_main --user "$_mdm_detect_valid_user" >/dev/null 2>&1 \
    || _mdm_detect_main_rc=$?
  if [[ "$_mdm_detect_main_rc" -eq 1 ]]; then
    pass "mdm-detect: macOS short name を引数として受理 ($_mdm_detect_valid_user)"
  else
    fail "mdm-detect: 有効な short name の引数判定が不正 ($_mdm_detect_valid_user rc=$_mdm_detect_main_rc)"
  fi
done

for _mdm_detect_bad_user in .john john. john..smith @john john@ \
  123456789012345678901234567890123; do
  _mdm_detect_main_rc=0
  mdm_detect_main --user "$_mdm_detect_bad_user" >/dev/null 2>&1 \
    || _mdm_detect_main_rc=$?
  if [[ "$_mdm_detect_main_rc" -eq 2 ]]; then
    pass "mdm-detect: path-like username を拒否 ($_mdm_detect_bad_user)"
  else
    fail "mdm-detect: 不正 username を許可 ($_mdm_detect_bad_user rc=$_mdm_detect_main_rc)"
  fi
done

_mdm_detect_main_rc=0
mdm_detect_main --min-version 0.74.0 >/dev/null 2>&1 || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 1 ]]; then
  pass "mdm-detect: deployment below minimum version is non-compliant"
else
  fail "mdm-detect: minimum-version failure returned $_mdm_detect_main_rc"
fi

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]' \
  '0.73.0-rc.1'
_mdm_detect_main_rc=0
mdm_detect_main --min-version 0.73.0 >/dev/null 2>&1 || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 1 ]]; then
  pass "mdm-detect: prerelease は同じ core の final 要件を満たさない"
else
  fail "mdm-detect: prerelease を final 以上として許可 (rc=$_mdm_detect_main_rc)"
fi

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]' \
  '0.73.0+build.7'
_mdm_detect_main_rc=0
mdm_detect_main --min-version 0.73.0 >/dev/null 2>&1 || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 0 ]]; then
  pass "mdm-detect: build metadata は version precedence から除外"
else
  fail "mdm-detect: build metadata だけで minimum 判定が変化 (rc=$_mdm_detect_main_rc)"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

# Executable production mode discards every source-only override.
_mdm_detect_main_rc=0
MDM_SOURCE_ONLY=1 MDM_RECEIPT_DIR_OVERRIDE="$_mdm_detect_receipts" \
  MDM_EUID_OVERRIDE=0 MDM_CONSOLE_USER_OVERRIDE=jane \
  "$PROJECT_DIR/mdm/detect-mdm.sh" --min-verison 0.73.0 >/dev/null 2>&1 \
  || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 2 ]]; then
  pass "mdm-detect: production entrypoint cannot be disabled by source-only mode"
else
  fail "mdm-detect: production source-only isolation failed (rc=$_mdm_detect_main_rc)"
fi

_mdm_detect_main_rc=0
MDM_SOURCE_ONLY=1 MDM_RECEIPT_DIR_OVERRIDE="$_mdm_detect_receipts" \
  MDM_DETECT_EXPECTED_OWNER_OVERRIDE="$(/usr/bin/id -un)" \
  MDM_DETECT_HOME_OVERRIDE="$_mdm_detect_home" \
  MDM_DETECT_CLI_PRESENT_OVERRIDE=1 \
  "$PROJECT_DIR/mdm/detect-mdm.sh" --user jane \
    --expected-commit "$_mdm_detect_sha" >/dev/null 2>&1 \
  || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 1 ]]; then
  pass "mdm-detect: production entrypoint discards test receipt overrides"
else
  fail "mdm-detect: production receipt override isolation failed (rc=$_mdm_detect_main_rc)"
fi

# The direct launcher is privileged Bash, trusts a physical root-owned chain,
# rejects final symlinks, and snapshots exact inode+size-bound bytes.
_mdm_detect_launcher_first="$(/usr/bin/head -n 1 "$PROJECT_DIR/mdm/detect-mdm.sh")"
if [[ -x "$PROJECT_DIR/mdm/detect-mdm.sh" \
  && "$_mdm_detect_launcher_first" == '#!/bin/bash -p' ]] \
  && ! grep -Eq '/bin/sh([[:space:]]|$)' "$PROJECT_DIR/mdm/detect-mdm.sh"; then
  pass "mdm-detect: direct launcher uses privileged Bash without a sh wrapper"
else
  fail "mdm-detect: direct launcher interpreter contract is unsafe"
fi
if _mdm_launcher_path_trusted /usr/bin/true \
  && [[ "$_MDM_LAUNCHER_PHYSICAL" == /usr/bin/true ]]; then
  pass "mdm-detect: launcher accepts a canonical root-owned physical chain"
else
  fail "mdm-detect: launcher rejected a trusted system path"
fi
_mdm_detect_sticky_base=/tmp
_mdm_is_darwin && _mdm_detect_sticky_base=/private/tmp
_mdm_detect_sticky_script="$(/usr/bin/mktemp \
  "$_mdm_detect_sticky_base/mdm-detect-launcher.XXXXXX")"
chmod 755 "$_mdm_detect_sticky_script"
(
  _mdm_launcher_stat_owner() { printf '0'; }
  _mdm_detect_sticky_physical="$(cd -P "$_mdm_detect_sticky_base" && pwd)/${_mdm_detect_sticky_script##*/}"
  if [[ "$(_mdm_launcher_stat_mode "$_mdm_detect_sticky_base")" == 1777 ]] \
    && _mdm_launcher_path_trusted "$_mdm_detect_sticky_script" \
    && [[ "$_MDM_LAUNCHER_PHYSICAL" == "$_mdm_detect_sticky_physical" ]]; then
    pass "mdm-detect: root-owned script is trusted below a physical sticky parent"
  else
    fail "mdm-detect: sticky root-owned launcher parent was rejected"
  fi
)
rm -f "$_mdm_detect_sticky_script"
ln -s /usr/bin/true "$_mdm_detect_tmp/launcher-symlink"
if _mdm_launcher_path_trusted "$_mdm_detect_tmp/launcher-symlink"; then
  fail "mdm-detect: launcher trusted a final symlink"
else
  pass "mdm-detect: launcher rejects a final symlink"
fi
rm "$_mdm_detect_tmp/launcher-symlink"
_mdm_detect_launcher_copy="$(_mdm_launcher_snapshot "$PROJECT_DIR/mdm/detect-mdm.sh")"
if cmp -s "$PROJECT_DIR/mdm/detect-mdm.sh" "$_mdm_detect_launcher_copy" \
  && [[ "$(_mdm_stat_mode "$_mdm_detect_launcher_copy")" == 500 ]] \
  && _mdm_launcher_mode_safe 755 \
  && ! _mdm_launcher_mode_safe 775 \
  && grep -q '"$_mode" == 1777' "$PROJECT_DIR/mdm/detect-mdm.sh" \
  && [[ "$(grep -c "'%i:%z'" "$PROJECT_DIR/mdm/detect-mdm.sh")" -ge 2 ]] \
  && /usr/bin/awk '
    /^[[:space:]]*\. "\$_mdm_script"$/ { source_line = NR }
    source_line && NR == source_line + 1 && /\/bin\/rm -f "\$_mdm_script"/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$PROJECT_DIR/mdm/detect-mdm.sh"; then
  pass "mdm-detect: launcher snapshot and sticky-parent mode contract are enforced"
else
  fail "mdm-detect: launcher snapshot or parent mode contract is incomplete"
fi
rm -f "$_mdm_detect_launcher_copy"

# The privileged shebang must reject both non-interactive startup files and
# imported functions before the clean env boundary executes.
_mdm_detect_canary="$_mdm_detect_tmp/hostile-env-ran"
printf '/usr/bin/touch %q\n' "$_mdm_detect_canary" > "$_mdm_detect_tmp/bash-env"
_mdm_detect_main_rc=0
/usr/bin/env \
  "BASH_ENV=$_mdm_detect_tmp/bash-env" \
  "SHELLOPTS=xtrace" \
  "PS4=\$(/usr/bin/touch '$_mdm_detect_canary')" \
  "$PROJECT_DIR/mdm/detect-mdm.sh" --unknown >/dev/null 2>&1 \
  || _mdm_detect_main_rc=$?
if [[ ! -e "$_mdm_detect_canary" && "$_mdm_detect_main_rc" -eq 2 ]]; then
  pass "mdm-detect: privileged launcher rejects BASH_ENV and inherited shell options"
else
  fail "mdm-detect: hostile startup environment executed (rc=$_mdm_detect_main_rc)"
fi

rm -rf "$_mdm_detect_tmp"
unset MDM_DETECT_EXPECTED_OWNER_OVERRIDE MDM_DETECT_EXPECTED_UID_OVERRIDE
unset MDM_DETECT_TRUST_BASE_OVERRIDE
unset MDM_DETECT_TMP_BASE_OVERRIDE MDM_DETECT_HOME_OVERRIDE
unset MDM_RECEIPT_DIR_OVERRIDE MDM_EUID_OVERRIDE MDM_CONSOLE_USER_OVERRIDE
unset MDM_DETECT_CLI_PRESENT_OVERRIDE MDM_SOURCE_ONLY
