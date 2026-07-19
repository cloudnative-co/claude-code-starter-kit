#!/bin/bash
# tests/unit/test-mdm-detect.sh - MDM receipt and deployed-state detection.

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/detect-mdm.sh"

# Keep independently shipped issuer/deployer/verifier constants bound to the
# same production contract. These comparisons intentionally execute each
# implementation rather than copying a fourth set of pins into the test.
_mdm_detect_font_canonical="$(bash -c '
  set -euo pipefail
  source "$1/lib/fonts-mdm.sh"
  for family in ibm hackgen; do
    while read -r name sha; do
      printf "%s %s %s\n" "$name" "$sha" "$family"
    done < <(_font_mdm_expected_inventory "$family")
  done
' _ "$PROJECT_DIR")"
_mdm_detect_font_issuer="$(bash -c '
  set -euo pipefail
  MDM_SOURCE_ONLY=1 source "$1/mdm/install-mdm.sh"
  _mdm_component_font_expected_inventory
' _ "$PROJECT_DIR")"
_mdm_detect_font_verifier="$(_mdm_font_expected_inventory)"
if [[ "$_mdm_detect_font_canonical" == "$_mdm_detect_font_issuer" \
  && "$_mdm_detect_font_issuer" == "$_mdm_detect_font_verifier" \
  && "$(printf '%s\n' "$_mdm_detect_font_verifier" | /usr/bin/wc -l \
    | /usr/bin/tr -d '[:space:]')" == 20 ]]; then
  pass "mdm-detect: font pin全20件はcanonical/issuer/verifierでbyte-identical"
else
  fail "mdm-detect: font pin inventoryが実装間でdrift"
fi

_mdm_detect_node_prerequisite="$(bash -c '
  set -euo pipefail
  source "$1/lib/prerequisites.sh"
  printf "arm64 %s %s %s\n" "$_MDM_NODE_ARM64_SOURCE_URL" \
    "$_MDM_NODE_ARM64_SOURCE_SHA256" "$_MDM_NODE_ARM64_CONTENT_SHA256"
  printf "x64 %s %s %s\n" "$_MDM_NODE_X64_SOURCE_URL" \
    "$_MDM_NODE_X64_SOURCE_SHA256" "$_MDM_NODE_X64_CONTENT_SHA256"
' _ "$PROJECT_DIR")"
_mdm_detect_node_issuer="$(bash -c '
  set -euo pipefail
  MDM_SOURCE_ONLY=1 source "$1/mdm/install-mdm.sh"
  for arch in arm64 x64; do
    url= archive_sha= top=
    _mdm_node_runtime_source "$arch" url archive_sha top
    content_sha="$(_mdm_node_runtime_expected_content_sha256 "$arch")"
    printf "%s %s %s %s\n" "$arch" "$url" "$archive_sha" "$content_sha"
  done
' _ "$PROJECT_DIR")"
_mdm_detect_node_verifier="$(
  for _mdm_detect_contract_arch in arm64 x64; do
    _mdm_detect_contract_url=""
    _mdm_detect_contract_archive=""
    _mdm_node_runtime_source "$_mdm_detect_contract_arch" \
      _mdm_detect_contract_url _mdm_detect_contract_archive
    _mdm_detect_contract_content="$(
      _mdm_node_runtime_expected_content_sha256 "$_mdm_detect_contract_arch"
    )"
    printf '%s %s %s %s\n' "$_mdm_detect_contract_arch" \
      "$_mdm_detect_contract_url" "$_mdm_detect_contract_archive" \
      "$_mdm_detect_contract_content"
  done
)"
if [[ "$_mdm_detect_node_prerequisite" == "$_mdm_detect_node_issuer" \
  && "$_mdm_detect_node_issuer" == "$_mdm_detect_node_verifier" ]]; then
  pass "mdm-detect: Node arm64/x64 source/content pinは全実装でbyte-identical"
else
  fail "mdm-detect: Node runtime source contractが実装間でdrift"
fi

_mdm_detect_wce_paths=""
for _mdm_detect_contract_arch in arm64 x64; do
  _mdm_detect_wce_issuer="$(bash -c '
    set -euo pipefail
    contract_arch=$2
    MDM_SOURCE_ONLY=1 source "$1/mdm/install-mdm.sh"
    _mdm_wce_runtime_hardware_arch() { printf "%s" "$contract_arch"; }
    _mdm_wce_runtime_base() {
      printf "%s" "/Library/Application Support/ClaudeCodeStarterKit/runtime/web-content-extraction"
    }
    _mdm_wce_runtime_path
  ' _ "$PROJECT_DIR" "$_mdm_detect_contract_arch")"
  _mdm_detect_wce_deployer="$(bash -c '
    set -euo pipefail
    contract_arch=$2
    source "$1/lib/deploy.sh"
    _mdm_current_darwin_arch() { printf "%s" "$contract_arch"; }
    _wce_mdm_expected_bundle
  ' _ "$PROJECT_DIR" "$_mdm_detect_contract_arch")"
  _mdm_detect_wce_verifier="$({
    _mdm_receipt_trust_base() { printf '%s' '/Library/Application Support'; }
    _mdm_node_runtime_arch() { printf '%s' "$_mdm_detect_contract_arch"; }
    _mdm_wce_runtime_root
  })"
  if [[ "$_mdm_detect_wce_issuer" != "$_mdm_detect_wce_deployer" \
    || "$_mdm_detect_wce_deployer" != "$_mdm_detect_wce_verifier" ]]; then
    _mdm_detect_wce_paths=drift
  fi
done
if [[ -z "$_mdm_detect_wce_paths" ]]; then
  pass "mdm-detect: WCE arm64/x64 runtime pathはissuer/deployer/verifierで一致"
else
  fail "mdm-detect: WCE runtime path contractが実装間でdrift"
fi
unset _mdm_detect_contract_arch _mdm_detect_contract_url
unset _mdm_detect_contract_archive _mdm_detect_contract_content
unset _mdm_detect_font_canonical _mdm_detect_font_issuer
unset _mdm_detect_font_verifier _mdm_detect_node_prerequisite
unset _mdm_detect_node_issuer _mdm_detect_node_verifier
unset _mdm_detect_wce_paths _mdm_detect_wce_issuer
unset _mdm_detect_wce_deployer _mdm_detect_wce_verifier

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
if _mdm_username_is_safe jane \
  && ! _mdm_username_is_safe _unresolved \
  && ! _mdm_username_is_safe _UnReSoLvEd; then
  pass "mdm-detect: 障害 receipt の予約名をユーザー名として拒否"
else
  fail "mdm-detect: _unresolved 予約名と実ユーザーが衝突"
fi
(
  _MDM_DETECT_TEST_MODE=0
  _mdm_expected_trust_owner() { printf 'root'; }
  _mdm_canonical_dir() { printf '%s' "$1"; }
  _mdm_trusted_component() {
    [[ "$2" == root && "$3" == dir ]]
  }
  _mdm_stat_mode() {
    case "$1" in /Library) printf '0711' ;; *) printf '0755' ;; esac
  }
  if _mdm_runtime_system_ancestors_are_trusted; then
    fail "mdm-detect: runtime system ancestor の 0711 drift を許可"
  else
    pass "mdm-detect: runtime system ancestors は issuer 同様 exact 0755"
  fi
  _mdm_stat_mode() { printf '0755'; }
  if _mdm_runtime_system_ancestors_are_trusted; then
    pass "mdm-detect: exact 0755 runtime system chain を受理"
  else
    fail "mdm-detect: valid runtime system chain を拒否"
  fi
)
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
  _console_user="$(_mdm_detect_parse_console_user_record <<'EOF'
<dictionary> {
  Name : jane42
  UID : 501
}
EOF
)"
  if [[ "$_console_user" == jane42 ]]; then
    pass "mdm-detect: 正常な scutil ConsoleUser record を解析"
  else
    fail "mdm-detect: 正常な scutil ConsoleUser record を拒否"
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
  _uid_records_rejected=true
  for _uid_record in $'UniqueID:\n 0501\n' \
    $'UniqueID:\n 501\n 502\n' $'UniqueID:  501\n' \
    $'UniqueID: 501\nUnexpected: value\n'; do
    if printf '%s' "$_uid_record" | _mdm_detect_parse_user_uid \
      >/dev/null 2>&1; then
      _uid_records_rejected=false
    fi
  done
  [[ "$_uid_records_rejected" == true ]] \
    && pass "mdm-detect: 曖昧または非canonicalな dscl UID を拒否" \
    || fail "mdm-detect: 不正な dscl UID record を許可"
)
(
  unset MDM_DETECT_EXPECTED_UID_OVERRIDE MDM_DETECT_GENERATED_UID_OVERRIDE
  _mdm_detect_read_local_identity_record() {
    printf 'UniqueID: 501\nGeneratedUID: 12345678-ABCD-1234-ABCD-1234567890EF\n'
  }
  _mdm_detect_read_search_identity_record() {
    printf 'UniqueID: %s\nGeneratedUID: 12345678-ABCD-1234-ABCD-1234567890EF\n' \
      "${_search_uid_fixture:?}"
  }
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
  unset MDM_DETECT_EXPECTED_UID_OVERRIDE MDM_DETECT_GENERATED_UID_OVERRIDE
  _mdm_detect_read_local_identity_record() {
    printf 'UniqueID: 501\nGeneratedUID: 12345678-ABCD-1234-ABCD-1234567890EF\n'
    return 42
  }
  _mdm_detect_read_search_identity_record() {
    printf 'UniqueID: 501\nGeneratedUID: 12345678-ABCD-1234-ABCD-1234567890EF\n'
  }
  _uid=""; _uid_rc=0
  _uid="$(_mdm_detect_user_uid jane)" || _uid_rc=$?
  if [[ "$_uid_rc" -ne 0 && -z "$_uid" ]]; then
    pass "mdm-detect: dscl UID producer 非0の stdout を破棄"
  else
    fail "mdm-detect: 失敗した dscl の UID を採用"
  fi
)
(
  unset MDM_DETECT_EXPECTED_UID_OVERRIDE MDM_DETECT_GENERATED_UID_OVERRIDE
  _mdm_detect_read_local_identity_record() {
    printf 'UniqueID: 500\nGeneratedUID: 12345678-ABCD-1234-ABCD-1234567890EF\n'
  }
  _mdm_detect_read_search_identity_record() {
    printf 'UniqueID: 500\nGeneratedUID: 12345678-ABCD-1234-ABCD-1234567890EF\n'
  }
  if _mdm_detect_user_uid jane >/dev/null 2>&1; then
    fail "mdm-detect: UID 500 を対象ユーザーとして許可"
  else
    pass "mdm-detect: UID 下限 501 をbinderでも強制"
  fi
)
(
  unset MDM_DETECT_EXPECTED_UID_OVERRIDE MDM_DETECT_GENERATED_UID_OVERRIDE
  _mdm_detect_read_local_identity_record() {
    printf 'UniqueID: 501\nGeneratedUID:\n 12345678-abcd-1234-abcd-1234567890ef\n'
  }
  _mdm_detect_read_search_identity_record() {
    printf 'GeneratedUID: 12345678-ABCD-1234-ABCD-1234567890EF\nUniqueID: 501\n'
  }
  _generated="$(_mdm_detect_user_generated_uid jane)" || _generated_rc=$?
  _mdm_detect_read_search_identity_record() {
    printf 'UniqueID: 501\nGeneratedUID: 00000000-ABCD-1234-ABCD-1234567890EF\n'
  }
  _generated_mismatch_rc=0
  _mdm_detect_user_generated_uid jane >/dev/null 2>&1 \
    || _generated_mismatch_rc=$?
  _mdm_detect_read_local_identity_record() {
    printf 'UniqueID: 501\nGeneratedUID: 00000000-0000-0000-0000-000000000000\n'
  }
  _mdm_detect_read_search_identity_record() {
    printf 'UniqueID: 501\nGeneratedUID: 00000000-0000-0000-0000-000000000000\n'
  }
  _generated_nil_rc=0
  _mdm_detect_user_generated_uid jane >/dev/null 2>&1 || _generated_nil_rc=$?
  if [[ "${_generated:-}" == 12345678-ABCD-1234-ABCD-1234567890EF \
    && "${_generated_rc:-0}" -eq 0 && "$_generated_mismatch_rc" -ne 0 \
    && "$_generated_nil_rc" -ne 0 ]]; then
    pass "mdm-detect: local/search GeneratedUID をcanonical UUIDへ束縛"
  else
    fail "mdm-detect: GeneratedUID の正規化または束縛が不正"
  fi
)
# Host-global Git templates may contain absolute hook symlinks.  The retained
# checkout fixture is intentionally self-contained so its artifact contract is
# independent of developer-machine configuration.
_mdm_detect_empty_git_template="$_mdm_detect_tmp/empty-git-template"
mkdir "$_mdm_detect_empty_git_template"
/usr/bin/git -C "$_mdm_detect_install" init -q \
  --template="$_mdm_detect_empty_git_template"
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
_mdm_detect_policy_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
_mdm_detect_fixture_uid="$(/usr/bin/id -u)"
_mdm_detect_fixture_generated_uid=12345678-ABCD-1234-ABCD-1234567890EF
_mdm_detect_component_manifest="$_mdm_detect_receipts/components-$_mdm_detect_fixture_generated_uid.json"
_mdm_detect_component_hash=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
_mdm_detect_write_manifest() {
  local _python
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_mdm_detect_manifest" "$_mdm_detect_short" \
    "$_mdm_detect_manifest_profile" "$_mdm_detect_manifest_language" \
    "$_mdm_detect_claude" "$_mdm_detect_snapshot" \
    "$_mdm_detect_policy_sha" "$_mdm_detect_manifest_absent_json" <<'PY'
import json
import sys

(path, commit, profile, language, claude_dir, snapshot_dir, policy,
 absent_json) = sys.argv[1:]
absent = json.loads(absent_json)
value = {
    "version": "2",
    "timestamp": "2026-07-17T00:00:00Z",
    "kit_version": "0.73.0",
    "kit_commit": commit,
    "profile": profile,
    "language": language,
    "editor": "vscode",
    "commit_attribution": "false",
    "new_init": "false",
    "plugins": "",
    "codex_plugin": "false",
    "files": [claude_dir + "/settings.json", claude_dir + "/CLAUDE.md"],
    "cleanup_paths": [],
    "mdm_absent_files": absent,
    "mdm_managed": True,
    "snapshot_dir": snapshot_dir,
    "claude_dir": claude_dir,
    "policy_sha256": policy,
}
with open(path, "wb") as handle:
    handle.write((json.dumps(value, ensure_ascii=False, indent=2,
                             separators=(",", ": ")) + "\n").encode("utf-8"))
PY
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
  local _receipt_uid="${8:-$_mdm_detect_fixture_uid}"
  local _receipt_generated="${9:-$_mdm_detect_fixture_generated_uid}"
  local _component_path="${10:-$_mdm_detect_component_manifest}"
  local _component_hash="${11:-$_mdm_detect_component_hash}"
  local _receipt_policy="${12:-$_mdm_detect_policy_sha}"
  local _manifest_hash _deployment_hash
  # Most fixtures predate receipt v3.  Keep their call sites focused on the
  # state being varied while emitting the current schema by default.
  [[ "$_schema" != 2 ]] || _schema=3
  _manifest_hash="$(_mdm_sha256 "$_mdm_detect_manifest")"
  _deployment_hash="$(_mdm_detect_fixture_deployment_sha)"
  cat > "$_mdm_detect_receipt" <<JSON
{
  "schema_version": $_schema,
  "kit_version": "$_kit_version",
  "git_ref": "$_sha",
  "resolved_sha": "$_sha",
  "install_dir": "$_receipt_install",
  "required_components": $_components,
  "profile": "standard",
  "language": "ja",
  "manifest_path": "$_mdm_detect_manifest",
  "manifest_sha256": "$_manifest_hash",
  "deployment_sha256": "$_deployment_hash",
  "policy_sha256": "$_receipt_policy",
  "component_manifest_path": "$_component_path",
  "component_manifest_sha256": "$_component_hash",
  "target_user": "$_target",
  "target_uid": $_receipt_uid,
  "target_generated_uid": "$_receipt_generated",
  "result": "$_result",
  "exit_code": 0,
  "partial": [],
  "timestamp": "2026-07-17T00:00:00Z",
  "log_path": "/Library/Logs/ClaudeCodeStarterKit/install.log"
}
JSON
  chmod 600 "$_mdm_detect_receipt"
}
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

export MDM_DETECT_EXPECTED_OWNER_OVERRIDE
MDM_DETECT_EXPECTED_OWNER_OVERRIDE="$(/usr/bin/id -un)"
export MDM_DETECT_EXPECTED_UID_OVERRIDE
MDM_DETECT_EXPECTED_UID_OVERRIDE="$_mdm_detect_fixture_uid"
export MDM_DETECT_EXPECTED_COMMIT_OVERRIDE="$_mdm_detect_sha"
export MDM_DETECT_EXPECTED_POLICY_SHA_OVERRIDE="$_mdm_detect_policy_sha"
export MDM_DETECT_GENERATED_UID_OVERRIDE
MDM_DETECT_GENERATED_UID_OVERRIDE="$_mdm_detect_fixture_generated_uid"
export MDM_DETECT_COMPONENT_MANIFEST_OVERRIDE=1
export MDM_DETECT_TRUST_BASE_OVERRIDE="$_mdm_detect_trust_base"
export MDM_DETECT_TMP_BASE_OVERRIDE="$_mdm_detect_private_base"
export MDM_DETECT_HOME_OVERRIDE="$_mdm_detect_home"
_mdm_detect_wce_root="$(_mdm_wce_runtime_root)"

_mdm_detect_history="$_mdm_detect_receipts/managed-history-$MDM_DETECT_GENERATED_UID_OVERRIDE.json"
_mdm_detect_write_history() { # [schema] [uid] [generated-uid]
  local _schema="${1:-2}" _uid="${2:-$MDM_DETECT_EXPECTED_UID_OVERRIDE}"
  local _generated="${3:-$MDM_DETECT_GENERATED_UID_OVERRIDE}"
  cat > "$_mdm_detect_history" <<JSON
{
  "schema_version": $_schema,
  "target_user": "jane",
  "target_uid": $_uid,
  "target_generated_uid": "$_generated",
  "home": "$_mdm_detect_home",
  "managed_inventory": ["settings.json", "CLAUDE.md"]
}
JSON
  chmod 600 "$_mdm_detect_history"
}
_mdm_detect_write_history

_mdm_detect_write_components() { # <entries-json> [schema] [uid] [generated] [policy] [outer-extra]
  local _entries="$1" _schema="${2:-1}"
  local _uid="${3:-$_mdm_detect_fixture_uid}"
  local _generated="${4:-$_mdm_detect_fixture_generated_uid}"
  local _policy="${5:-$_mdm_detect_policy_sha}"
  local _outer_extra="${6:-}"
  local _canonical_entries _python
  _python="$(_mdm_detect_system_python)" || return 1
  if _canonical_entries="$("$_python" -I -B - "$_entries" <<'PY'
import json
import sys

def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate key")
        value[key] = item
    return value

try:
    entries = json.loads(sys.argv[1], object_pairs_hook=unique_object)
    keys = {"component", "kind", "path", "sha256"}
    if (type(entries) is not list
            or any(type(entry) is not dict or set(entry) != keys
                   or any(type(entry[key]) is not str for key in keys)
                   for entry in entries)):
        raise ValueError("invalid entries")
    print("[")
    for index, entry in enumerate(entries):
        suffix = "," if index + 1 < len(entries) else ""
        print("    " + json.dumps(entry, ensure_ascii=True, sort_keys=True,
                                  separators=(",", ":")) + suffix)
    print("  ]")
except (ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
)"; then
    _entries="$_canonical_entries"
  fi
  {
    printf '{\n  "schema_version": %s,\n' "$_schema"
    printf '  "target_user": "jane",\n'
    printf '  "target_uid": %s,\n' "$_uid"
    printf '  "target_generated_uid": "%s",\n' "$_generated"
    printf '  "policy_sha256": "%s",\n' "$_policy"
    [[ -z "$_outer_extra" ]] || printf '  %s\n' "$_outer_extra"
    printf '  "entries": %s\n}\n' "$_entries"
  } > "$_mdm_detect_component_manifest"
  chmod 600 "$_mdm_detect_component_manifest"
  _mdm_detect_component_hash="$(_mdm_sha256 "$_mdm_detect_component_manifest")"
}
_mdm_detect_kit_artifact_hash="$(_mdm_artifact_digest tree "$_mdm_detect_install")"
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

_mdm_detect_control_json="$_mdm_detect_tmp/control-scalars.json"
printf '%s\n' \
  '{"valid":"standard","line":"standard\n","carriage":"standard\r","nul":"standard\u0000","del":"standard\u007f","c1":"standard\u0085","array":["kit\n"]}' \
  > "$_mdm_detect_control_json"
_mdm_detect_control_scalar_rc=0
_mdm_detect_control_carriage_rc=0
_mdm_detect_control_nul_rc=0
_mdm_detect_control_del_rc=0
_mdm_detect_control_c1_rc=0
_mdm_detect_control_array_rc=0
_mdm_json_get "$_mdm_detect_control_json" line >/dev/null 2>&1 \
  || _mdm_detect_control_scalar_rc=$?
_mdm_json_get "$_mdm_detect_control_json" carriage >/dev/null 2>&1 \
  || _mdm_detect_control_carriage_rc=$?
_mdm_json_get "$_mdm_detect_control_json" nul >/dev/null 2>&1 \
  || _mdm_detect_control_nul_rc=$?
_mdm_json_get "$_mdm_detect_control_json" del >/dev/null 2>&1 \
  || _mdm_detect_control_del_rc=$?
_mdm_json_get "$_mdm_detect_control_json" c1 >/dev/null 2>&1 \
  || _mdm_detect_control_c1_rc=$?
_mdm_json_array_get "$_mdm_detect_control_json" array 0 >/dev/null 2>&1 \
  || _mdm_detect_control_array_rc=$?
if [[ "$(_mdm_json_get "$_mdm_detect_control_json" valid)" == standard \
  && "$_mdm_detect_control_scalar_rc" -ne 0 \
  && "$_mdm_detect_control_carriage_rc" -ne 0 \
  && "$_mdm_detect_control_nul_rc" -ne 0 \
  && "$_mdm_detect_control_del_rc" -ne 0 \
  && "$_mdm_detect_control_c1_rc" -ne 0 \
  && "$_mdm_detect_control_array_rc" -ne 0 ]]; then
  pass "mdm-detect: JSON getter は C0/C1/DEL を正規化せず拒否"
else
  fail "mdm-detect: JSON getter の control-free contract が不正"
fi

_mdm_detect_deep_json="$_mdm_detect_tmp/deep-json.json"
_mdm_detect_python="$(_mdm_detect_system_python)"
"$_mdm_detect_python" -I -B - "$_mdm_detect_deep_json" <<'PY'
import sys

with open(sys.argv[1], "wb") as handle:
    handle.write(b'{"value":' + (b"[" * 1500) + b"0"
                 + (b"]" * 1500) + b"}\n")
PY
_mdm_detect_deep_output=""
_mdm_detect_deep_canonical_output=""
if _mdm_detect_deep_output="$(_mdm_json_get \
    "$_mdm_detect_deep_json" value 2>&1)"; then
  fail "mdm-detect: deeply nested JSONでquery tracebackを許可"
elif [[ -n "$_mdm_detect_deep_output" ]]; then
  fail "mdm-detect: deeply nested JSONのtracebackを露出"
elif _mdm_detect_deep_canonical_output="$(_mdm_issuer_json_is_canonical \
    "$_mdm_detect_deep_json" receipt 2>&1)"; then
  fail "mdm-detect: deeply nested JSONをcanonical receiptとして受理"
elif [[ -n "$_mdm_detect_deep_canonical_output" ]]; then
  fail "mdm-detect: canonical validatorが深いJSONのtracebackを露出"
else
  pass "mdm-detect: 深いJSONを全validatorでtracebackなしfail-closed"
fi

if _mdm_issuer_json_is_canonical "$_mdm_detect_receipt" receipt \
  && _mdm_issuer_json_is_canonical \
    "$_mdm_detect_component_manifest" component \
  && _mdm_issuer_json_is_canonical "$_mdm_detect_manifest" deployment; then
  pass "mdm-detect: issuer生成3種manifestのcanonical JSONを受理"
else
  fail "mdm-detect: issuer canonical JSON fixtureを拒否"
fi

_mdm_detect_json_variant() { # <source> <target> <kind> <variant>
  local _source="$1" _target="$2" _kind="$3" _variant="$4" _python
  _python="$(_mdm_detect_system_python)" || return 1
  "$_python" -I -B - "$_source" "$_target" "$_kind" "$_variant" <<'PY'
import sys

source, target, kind, variant = sys.argv[1:]
data = open(source, "rb").read()
if variant == "trailing":
    data += b" "
elif variant == "internal-space":
    if b'": ' not in data:
        raise SystemExit(1)
    data = data.replace(b'": ', b'":  ', 1)
elif variant == "key-order":
    lines = data.splitlines(keepends=True)
    if len(lines) < 4:
        raise SystemExit(1)
    lines[1], lines[2] = lines[2], lines[1]
    data = b"".join(lines)
elif variant == "equivalent-escape":
    if b"/" not in data:
        raise SystemExit(1)
    data = data.replace(b"/", b"\\/", 1)
elif variant == "extra":
    if not data.endswith(b"\n}\n"):
        raise SystemExit(1)
    data = data[:-3] + b',\n  "_extra": true\n}\n'
elif variant == "duplicate":
    duplicate = {
        "receipt": b'  "schema_version": 3,\n',
        "component": b'  "schema_version": 1,\n',
        "deployment": b'  "version": "2",\n',
    }[kind]
    if not data.startswith(b"{\n"):
        raise SystemExit(1)
    data = b"{\n" + duplicate + data[2:]
else:
    raise SystemExit(1)
open(target, "wb").write(data)
PY
}

_mdm_detect_strict_json_rc=0
for _mdm_detect_json_spec in \
  "receipt:$_mdm_detect_receipt" \
  "component:$_mdm_detect_component_manifest" \
  "deployment:$_mdm_detect_manifest"; do
  _mdm_detect_json_kind="${_mdm_detect_json_spec%%:*}"
  _mdm_detect_json_source="${_mdm_detect_json_spec#*:}"
  for _mdm_detect_json_mutation in \
    trailing internal-space key-order equivalent-escape extra duplicate; do
    _mdm_detect_json_copy="$_mdm_detect_tmp/${_mdm_detect_json_kind}-${_mdm_detect_json_mutation}.json"
    _mdm_detect_json_variant "$_mdm_detect_json_source" \
      "$_mdm_detect_json_copy" "$_mdm_detect_json_kind" \
      "$_mdm_detect_json_mutation" || _mdm_detect_strict_json_rc=1
    if _mdm_issuer_json_is_canonical "$_mdm_detect_json_copy" \
        "$_mdm_detect_json_kind"; then
      _mdm_detect_strict_json_rc=1
    fi
  done
done
if [[ "$_mdm_detect_strict_json_rc" -eq 0 ]]; then
  pass "mdm-detect: 3種manifestのnon-canonical JSON bytesを拒否"
else
  fail "mdm-detect: strict JSON key/byte contractが不正"
fi

if _mdm_is_darwin; then
  _mdm_detect_plist_rc=0
  for _mdm_detect_json_spec in \
    "receipt:$_mdm_detect_receipt" \
    "component:$_mdm_detect_component_manifest" \
    "deployment:$_mdm_detect_manifest"; do
    _mdm_detect_json_kind="${_mdm_detect_json_spec%%:*}"
    _mdm_detect_json_source="${_mdm_detect_json_spec#*:}"
    for _mdm_detect_plist_format in binary1 xml1; do
      _mdm_detect_json_copy="$_mdm_detect_tmp/${_mdm_detect_json_kind}-${_mdm_detect_plist_format}.plist"
      /bin/cp "$_mdm_detect_json_source" "$_mdm_detect_json_copy"
      /usr/bin/plutil -convert "$_mdm_detect_plist_format" \
        "$_mdm_detect_json_copy" || _mdm_detect_plist_rc=1
      if _mdm_issuer_json_is_canonical "$_mdm_detect_json_copy" \
          "$_mdm_detect_json_kind"; then
        _mdm_detect_plist_rc=1
      fi
    done
  done
  if [[ "$_mdm_detect_plist_rc" -eq 0 ]]; then
    pass "mdm-detect: binary/XML plistのsemantic equivalenceを拒否"
  else
    fail "mdm-detect: issuer JSON入口がplistを受理"
  fi
else
  skip "mdm-detect: binary/XML plistを拒否" "plutil unavailable"
fi

_mdm_detect_component_check() (
  unset MDM_DETECT_COMPONENT_MANIFEST_OVERRIDE
  _component_workspace="$_mdm_detect_private_base/component-check-workspace"
  rm -rf "$_component_workspace"
  mkdir -m 700 "$_component_workspace"
  _mdm_component_manifest_is_valid "$_mdm_detect_receipt" jane \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_fixture_generated_uid" \
    "$_mdm_detect_home" "$_mdm_detect_policy_sha" "$_component_workspace"
  _rc=$?
  rm -rf "$_component_workspace"
  return "$_rc"
)

if _mdm_detect_component_check; then
  pass "mdm-detect: root component manifest とlive artifactを再検証"
else
  fail "mdm-detect: valid component attestationを拒否"
fi

_mdm_detect_bad_component_hash=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]' \
  0.73.0 "$_mdm_detect_install" "$_mdm_detect_fixture_uid" \
  "$_mdm_detect_fixture_generated_uid" "$_mdm_detect_component_manifest" \
  "$_mdm_detect_bad_component_hash"
if _mdm_detect_component_check; then
  fail "mdm-detect: receipt/component manifest hash mismatchを許可"
else
  pass "mdm-detect: component manifestをreceipt hashへ束縛"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]" '"1"'
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if _mdm_detect_component_check; then
  fail "mdm-detect: string型 component schema_versionを許可"
else
  pass "mdm-detect: component manifest JSON型をfail-closedで検証"
fi

_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":7}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if _mdm_detect_component_check; then
  fail "mdm-detect: non-string component entry hashを許可"
else
  pass "mdm-detect: component entry各fieldのJSON型を検証"
fi

_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\",\"extra\":true}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
_mdm_detect_entry_extra_rc=0
_mdm_detect_component_check || _mdm_detect_entry_extra_rc=$?
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
_mdm_detect_duplicate_key_rc=0
_mdm_detect_component_check || _mdm_detect_duplicate_key_rc=$?
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]" \
  1 "$_mdm_detect_fixture_uid" "$_mdm_detect_fixture_generated_uid" \
  "$_mdm_detect_policy_sha" '"extra":true,'
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
_mdm_detect_outer_extra_rc=0
_mdm_detect_component_check || _mdm_detect_outer_extra_rc=$?
if [[ "$_mdm_detect_entry_extra_rc" -ne 0 \
  && "$_mdm_detect_duplicate_key_rc" -ne 0 \
  && "$_mdm_detect_outer_extra_rc" -ne 0 ]]; then
  pass "mdm-detect: component manifest key set/duplicateをstrict検証"
else
  fail "mdm-detect: component manifestの余剰/duplicate keyを許可"
fi

_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]" \
  1 "$((_mdm_detect_fixture_uid + 1))"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if _mdm_detect_component_check; then
  fail "mdm-detect: component manifestの別UIDを許可"
else
  pass "mdm-detect: component manifestを対象UIDへ束縛"
fi

_mdm_detect_other_generated=00000000-ABCD-1234-ABCD-1234567890EF
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]" \
  1 "$_mdm_detect_fixture_uid" "$_mdm_detect_other_generated"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if _mdm_detect_component_check; then
  fail "mdm-detect: component manifestの別GeneratedUIDを許可"
else
  pass "mdm-detect: component manifestを対象GeneratedUIDへ束縛"
fi

_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","node_runtime","web_content_runtime"]'
if _mdm_detect_component_check; then
  fail "mdm-detect: required component coverage欠落を許可"
else
  pass "mdm-detect: 全required componentのattestationを必須化"
fi

_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"},{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
_mdm_detect_duplicate_component_rc=0
_mdm_detect_component_check || _mdm_detect_duplicate_component_rc=$?
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"},{\"component\":\"web_content_runtime\",\"path\":\"$_mdm_detect_wce_root\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
_mdm_detect_extraneous_component_rc=0
_mdm_detect_component_check || _mdm_detect_extraneous_component_rc=$?
if [[ "$_mdm_detect_duplicate_component_rc" -ne 0 \
  && "$_mdm_detect_extraneous_component_rc" -ne 0 ]]; then
  pass "mdm-detect: duplicate/extraneous component entryを拒否"
else
  fail "mdm-detect: component exact set/count contractが不正"
fi

_mdm_detect_write_components "[{\"component\":\"web_content_runtime\",\"path\":\"$_mdm_detect_wce_root\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"},{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","node_runtime","web_content_runtime"]'
if _mdm_detect_component_check; then
  fail "mdm-detect: non-canonical component entry orderを許可"
else
  pass "mdm-detect: component/path entry順序をcanonicalに固定"
fi

_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

cp "$_mdm_detect_install/file" "$_mdm_detect_tmp/component-file.saved"
printf 'component drift\n' > "$_mdm_detect_install/file"
(
  unset MDM_DETECT_COMPONENT_MANIFEST_OVERRIDE
  _component_workspace="$_mdm_detect_private_base/component-drift-workspace"
  mkdir -m 700 "$_component_workspace"
  if _mdm_component_manifest_is_valid "$_mdm_detect_receipt" jane \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_fixture_generated_uid" \
    "$_mdm_detect_home" "$_mdm_detect_policy_sha" "$_component_workspace"; then
    fail "mdm-detect: retained checkout driftをcompliant判定"
  else
    pass "mdm-detect: .gitを含むretained checkout全体のdriftを検出"
  fi
  rm -rf "$_component_workspace"
)
mv "$_mdm_detect_tmp/component-file.saved" "$_mdm_detect_install/file"

_mdm_detect_commit_object="$_mdm_detect_install/.git/objects/${_mdm_detect_sha:0:2}/${_mdm_detect_sha:2}"
if [[ -f "$_mdm_detect_commit_object" && ! -L "$_mdm_detect_commit_object" ]]; then
  mv "$_mdm_detect_commit_object" "$_mdm_detect_tmp/commit-object.saved"
  if _mdm_detect_component_check; then
    fail "mdm-detect: HEAD commit object欠落をcompliant判定"
  else
    pass "mdm-detect: retained checkoutのGit object欠落を検出"
  fi
  mv "$_mdm_detect_tmp/commit-object.saved" "$_mdm_detect_commit_object"
else
  fail "mdm-detect: isolated fixtureのHEAD commit objectが見つからない"
fi

ln "$_mdm_detect_component_manifest" "$_mdm_detect_component_manifest.peer"
(
  unset MDM_DETECT_COMPONENT_MANIFEST_OVERRIDE
  _component_workspace="$_mdm_detect_private_base/component-link-workspace"
  mkdir -m 700 "$_component_workspace"
  if _mdm_component_manifest_is_valid "$_mdm_detect_receipt" jane \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_fixture_generated_uid" \
    "$_mdm_detect_home" "$_mdm_detect_policy_sha" "$_component_workspace"; then
    fail "mdm-detect: hardlink component manifestを許可"
  else
    pass "mdm-detect: component manifestはlink count 1に固定"
  fi
  rm -rf "$_component_workspace"
)
rm "$_mdm_detect_component_manifest.peer"

if _mdm_is_darwin \
  && chmod +a 'everyone allow write' "$_mdm_detect_component_manifest" \
    2>/dev/null; then
  if _mdm_detect_component_check; then
    fail "mdm-detect: ACL付き component manifestを許可"
  else
    pass "mdm-detect: component manifest ACLを拒否"
  fi
  chmod -N "$_mdm_detect_component_manifest"
else
  skip "mdm-detect: component manifest ACLを拒否" \
    "ACL fixture unavailable on this platform"
fi

_mdm_detect_artifact_tree="$_mdm_detect_tmp/artifact-tree"
mkdir "$_mdm_detect_artifact_tree"
printf 'inside\n' > "$_mdm_detect_artifact_tree/inside"
ln -s inside "$_mdm_detect_artifact_tree/internal-link"
_mdm_detect_internal_digest="$(_mdm_artifact_digest \
  tree "$_mdm_detect_artifact_tree")" || true
ln -s missing "$_mdm_detect_artifact_tree/dangling"
_mdm_detect_dangling_rc=0
_mdm_artifact_digest tree "$_mdm_detect_artifact_tree" >/dev/null 2>&1 \
  || _mdm_detect_dangling_rc=$?
rm "$_mdm_detect_artifact_tree/dangling"
ln -s ../outside "$_mdm_detect_artifact_tree/escape"
printf 'outside\n' > "$_mdm_detect_tmp/outside"
_mdm_detect_escape_rc=0
_mdm_artifact_digest tree "$_mdm_detect_artifact_tree" >/dev/null 2>&1 \
  || _mdm_detect_escape_rc=$?
if [[ "$_mdm_detect_internal_digest" =~ ^[0-9a-f]{64}$ \
  && "$_mdm_detect_dangling_rc" -ne 0 && "$_mdm_detect_escape_rc" -ne 0 ]]; then
  pass "mdm-detect: tree内relative symlinkだけをartifact digestで許可"
else
  fail "mdm-detect: dangling/tree外symlinkのartifact契約が不正"
fi
rm "$_mdm_detect_artifact_tree/escape"

ln "$_mdm_detect_artifact_tree/inside" "$_mdm_detect_tmp/artifact-hardlink"
if _mdm_artifact_digest tree "$_mdm_detect_artifact_tree" \
  >/dev/null 2>&1; then
  fail "mdm-detect: external hardlink付きartifact fileを許可"
else
  pass "mdm-detect: artifact regular fileはlink count 1を必須化"
fi
rm "$_mdm_detect_tmp/artifact-hardlink"

chmod 0666 "$_mdm_detect_artifact_tree/inside"
if _mdm_artifact_digest tree "$_mdm_detect_artifact_tree" \
  >/dev/null 2>&1; then
  fail "mdm-detect: group/other writable artifact entryを許可"
else
  pass "mdm-detect: artifact dir/regularのmode 0022を拒否"
fi
chmod 0644 "$_mdm_detect_artifact_tree/inside"

_mdm_detect_artifact_gid="$(_mdm_stat_gid "$_mdm_detect_artifact_tree")"
if _mdm_artifact_digest tree "$_mdm_detect_artifact_tree" "" \
    "$_mdm_detect_artifact_gid" >/dev/null 2>&1 \
  && ! _mdm_artifact_digest tree "$_mdm_detect_artifact_tree" "" \
    "$((_mdm_detect_artifact_gid + 1))" >/dev/null 2>&1; then
  pass "mdm-detect: artifact全entryをexpected GIDへ束縛"
else
  fail "mdm-detect: artifact group ownership contractが不正"
fi

if _mdm_is_darwin \
  && chmod +a 'everyone allow read' "$_mdm_detect_artifact_tree/inside" \
    2>/dev/null; then
  if _mdm_artifact_digest tree "$_mdm_detect_artifact_tree" \
    >/dev/null 2>&1; then
    fail "mdm-detect: ACL付きartifact entryを許可"
  else
    pass "mdm-detect: artifact全entryのextended ACLを拒否"
  fi
  chmod -N "$_mdm_detect_artifact_tree/inside"
else
  skip "mdm-detect: artifact全entryのextended ACLを拒否" \
    "ACL fixture unavailable on this platform"
fi

if [[ -x /usr/bin/xattr ]] \
  && /usr/bin/xattr -w com.cloudnative.mdm-test one \
    "$_mdm_detect_artifact_tree/inside" 2>/dev/null; then
  _mdm_detect_xattr_hash_one="$(_mdm_artifact_digest \
    tree "$_mdm_detect_artifact_tree")" || true
  /usr/bin/xattr -w com.cloudnative.mdm-test two \
    "$_mdm_detect_artifact_tree/inside"
  _mdm_detect_xattr_hash_two="$(_mdm_artifact_digest \
    tree "$_mdm_detect_artifact_tree")" || true
  if [[ "$_mdm_detect_xattr_hash_one" =~ ^[0-9a-f]{64}$ \
    && "$_mdm_detect_xattr_hash_two" =~ ^[0-9a-f]{64}$ \
    && "$_mdm_detect_xattr_hash_one" != "$_mdm_detect_xattr_hash_two" ]]; then
    pass "mdm-detect: bounded xattr name/valueをartifact digestへ含める"
  else
    fail "mdm-detect: xattr value driftをartifact digestが捕捉しない"
  fi
  /usr/bin/xattr -d com.cloudnative.mdm-test \
    "$_mdm_detect_artifact_tree/inside"
else
  skip "mdm-detect: xattr value driftをartifact digestへ反映" \
    "xattr fixture unavailable"
fi

rm -rf "$_mdm_detect_artifact_tree"
rm "$_mdm_detect_tmp/outside"

_mdm_detect_installer_walker="$_mdm_detect_tmp/installer-walker.py"
_mdm_detect_detector_walker="$_mdm_detect_tmp/detector-walker.py"
/usr/bin/awk '
  /^_mdm_artifact_digest\(\)/ { function_seen = 1 }
  function_seen && /^import base64$/ { python = 1 }
  python && /^PY$/ { exit }
  python { print }
' "$PROJECT_DIR/mdm/install-mdm.sh" > "$_mdm_detect_installer_walker"
/usr/bin/awk '
  /^_mdm_artifact_digest\(\)/ { function_seen = 1 }
  function_seen && /^import base64$/ { python = 1 }
  python && /^PY$/ { exit }
  python { print }
' "$PROJECT_DIR/mdm/detect-mdm.sh" > "$_mdm_detect_detector_walker"
if [[ -s "$_mdm_detect_installer_walker" \
  && -s "$_mdm_detect_detector_walker" ]] \
  && /usr/bin/cmp -s "$_mdm_detect_installer_walker" \
    "$_mdm_detect_detector_walker"; then
  pass "mdm-detect: issuer/verifier artifact walker heredocはbyte-identical"
else
  fail "mdm-detect: installer/detector artifact algorithmが非対称"
fi
rm "$_mdm_detect_installer_walker" "$_mdm_detect_detector_walker"

_mdm_detect_installer_node_content="$_mdm_detect_tmp/installer-node-content.py"
_mdm_detect_detector_node_content="$_mdm_detect_tmp/detector-node-content.py"
for _mdm_detect_pair in \
  "$PROJECT_DIR/mdm/install-mdm.sh:$_mdm_detect_installer_node_content" \
  "$PROJECT_DIR/mdm/detect-mdm.sh:$_mdm_detect_detector_node_content"; do
  _mdm_detect_source="${_mdm_detect_pair%%:*}"
  _mdm_detect_output="${_mdm_detect_pair#*:}"
  /usr/bin/awk '
    /^_mdm_node_runtime_content_sha256\(\)/ { function_seen = 1 }
    function_seen && /^import hashlib$/ { python = 1 }
    python && /^PY$/ { exit }
    python { print }
  ' "$_mdm_detect_source" > "$_mdm_detect_output"
done
if [[ -s "$_mdm_detect_installer_node_content" \
  && -s "$_mdm_detect_detector_node_content" ]] \
  && /usr/bin/cmp -s "$_mdm_detect_installer_node_content" \
    "$_mdm_detect_detector_node_content"; then
  pass "mdm-detect: Node canonical content algorithmはissuerとbyte-identical"
else
  fail "mdm-detect: Node canonical content algorithmがissuerと非対称"
fi
rm "$_mdm_detect_installer_node_content" \
  "$_mdm_detect_detector_node_content"

_mdm_detect_safety_root="$_mdm_detect_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6"
_mdm_detect_biome_scope="$_mdm_detect_home/.local/lib/claude-code-starter-kit/biome/2.5.4"
mkdir -p "$_mdm_detect_home/.local/bin" \
  "$_mdm_detect_safety_root/bin" "$_mdm_detect_safety_root/dist/bin" \
  "$_mdm_detect_biome_scope"
printf '#!/bin/bash\nexit 0\n' \
  > "$_mdm_detect_safety_root/bin/cc-safety-net"
printf 'process.exit(0);\n' \
  > "$_mdm_detect_safety_root/dist/bin/cc-safety-net.js"
printf '#!/bin/bash\nexit 0\n' > "$_mdm_detect_safety_root/bin/cli-b"
printf '{"name":"cc-safety-net","version":"1.0.6"}\n' \
  > "$_mdm_detect_safety_root/package.json"
printf '#!/bin/sh\nexit 0\n' > "$_mdm_detect_biome_scope/biome"
chmod 700 "$_mdm_detect_safety_root/bin/cc-safety-net" \
  "$_mdm_detect_safety_root/bin/cli-b" \
  "$_mdm_detect_biome_scope/biome"
ln -s ../lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cc-safety-net \
  "$_mdm_detect_home/.local/bin/cc-safety-net"
ln -s ../lib/claude-code-starter-kit/biome/2.5.4/biome \
  "$_mdm_detect_home/.local/bin/biome"
_mdm_detect_safety_command="$(_mdm_component_command_path \
  "$_mdm_detect_home" cc-safety-net "$_mdm_detect_fixture_uid")" || true
_mdm_detect_biome_command="$(_mdm_component_command_path \
  "$_mdm_detect_home" biome "$_mdm_detect_fixture_uid")" || true
if [[ "$(_mdm_safety_package_root "$_mdm_detect_home" \
      "$_mdm_detect_safety_command" 2>/dev/null || true)" \
      == "$_mdm_detect_safety_root" \
  && "$(_mdm_biome_package_root "$_mdm_detect_home" \
      "$_mdm_detect_biome_command" 2>/dev/null || true)" \
      == "$_mdm_detect_biome_scope" ]]; then
  pass "mdm-detect: Safety/Biomeをversioned private treeへ固定"
else
  fail "mdm-detect: command wrapperだけをcomponent rootとして解決"
fi

_mdm_detect_private_node="$(_mdm_node_runtime_root)/bin/node"
_mdm_test_write_safety_wrapper() { # <output> <node> <script>
  local _output="$1" _node="$2" _script="$3" LC_ALL=C
  printf '#!/bin/bash\nunset NODE_OPTIONS NODE_PATH\nexec %q %q "$@"\n' \
    "$_node" "$_script" > "$_output"
}
_mdm_detect_unicode_home="$_mdm_detect_tmp/Users/利用者 home"
_mdm_detect_unicode_root="$_mdm_detect_unicode_home/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6"
/bin/mkdir -p "$_mdm_detect_unicode_root/bin" \
  "$_mdm_detect_unicode_root/dist/bin"
: > "$_mdm_detect_unicode_root/dist/bin/cc-safety-net.js"
_mdm_test_write_safety_wrapper \
  "$_mdm_detect_unicode_root/bin/cc-safety-net" \
  "$_mdm_detect_private_node" \
  "$_mdm_detect_unicode_root/dist/bin/cc-safety-net.js"
/bin/chmod 755 "$_mdm_detect_unicode_root/bin/cc-safety-net"
if (
  LC_ALL=C.UTF-8
  export LC_ALL
  _mdm_safety_wrapper_is_bound "$_mdm_detect_unicode_home" \
    "$_mdm_detect_unicode_root/bin/cc-safety-net" \
    "$_mdm_detect_private_node"
); then
  pass "mdm-detect: Unicode home の Safety wrapper を C locale で束縛"
else
  fail "mdm-detect: Safety wrapper binding が caller locale に依存"
fi
_mdm_test_write_safety_wrapper \
  "$_mdm_detect_safety_root/bin/cc-safety-net" \
  "$_mdm_detect_private_node" \
  "$_mdm_detect_safety_root/dist/bin/cc-safety-net.js"
chmod 755 "$_mdm_detect_safety_root/bin/cc-safety-net"
_mdm_detect_safety_bound=0
_mdm_safety_wrapper_is_bound "$_mdm_detect_home" \
  "$_mdm_detect_safety_root/bin/cc-safety-net" \
  "$_mdm_detect_private_node" || _mdm_detect_safety_bound=$?
printf '# drift\n' >> "$_mdm_detect_safety_root/bin/cc-safety-net"
if [[ "$_mdm_detect_safety_bound" -eq 0 ]] \
  && ! _mdm_safety_wrapper_is_bound "$_mdm_detect_home" \
    "$_mdm_detect_safety_root/bin/cc-safety-net" \
    "$_mdm_detect_private_node"; then
  pass "mdm-detect: Safety wrapperをprivate Node+bundled JSへbyte束縛"
else
  fail "mdm-detect: Safety wrapperのprivate Node bindingが不正"
fi
_mdm_test_write_safety_wrapper \
  "$_mdm_detect_safety_root/bin/cc-safety-net" \
  "$_mdm_detect_private_node" \
  "$_mdm_detect_safety_root/dist/bin/cc-safety-net.js"
printf '\0hidden-suffix\n' >> "$_mdm_detect_safety_root/bin/cc-safety-net"
if _mdm_safety_wrapper_is_bound "$_mdm_detect_home" \
    "$_mdm_detect_safety_root/bin/cc-safety-net" \
    "$_mdm_detect_private_node"; then
  fail "mdm-detect: Safety wrapper の NUL suffix を許可"
else
  pass "mdm-detect: Safety wrapper を descriptor-bound exact bytes で検証"
fi
_mdm_test_write_safety_wrapper \
  "$_mdm_detect_safety_root/bin/cc-safety-net" \
  "$_mdm_detect_private_node" \
  "$_mdm_detect_safety_root/dist/bin/cc-safety-net.js"

chmod 0611 "$_mdm_detect_home/.local/bin"
if _mdm_component_command_path "$_mdm_detect_home" cc-safety-net \
  "$_mdm_detect_fixture_uid" >/dev/null 2>&1; then
  fail "mdm-detect: target ownerがsearch不能なcommand parentを許可"
else
  pass "mdm-detect: original command pathのtarget search権を検証"
fi
chmod 0755 "$_mdm_detect_home/.local/bin"

if _mdm_is_darwin \
  && chmod +a 'everyone deny delete' "$_mdm_detect_home/.local/bin" \
    2>/dev/null; then
  if _mdm_component_command_path "$_mdm_detect_home" cc-safety-net \
    "$_mdm_detect_fixture_uid" >/dev/null 2>&1; then
    pass "mdm-detect: 標準deny-delete ACLはeffective searchを妨げない"
  else
    fail "mdm-detect: harmless ancestor ACLだけでcomponentを拒否"
  fi
  chmod -N "$_mdm_detect_home/.local/bin"
  chmod +a 'everyone deny search' "$_mdm_detect_home/.local/bin"
  if _mdm_component_command_path "$_mdm_detect_home" cc-safety-net \
    "$_mdm_detect_fixture_uid" >/dev/null 2>&1; then
    fail "mdm-detect: deny-search ACL付きcommand parentを許可"
  else
    pass "mdm-detect: ancestor ACLはnumeric UIDのeffective accessで検証"
  fi
  chmod -N "$_mdm_detect_home/.local/bin"
else
  skip "mdm-detect: command parent effective ACLを検証" \
    "ACL fixture unavailable on this platform"
fi

_mdm_detect_safety_hash="$(_mdm_artifact_digest \
  tree "$_mdm_detect_safety_root")"
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"},{\"component\":\"safety_net\",\"path\":\"$_mdm_detect_safety_root\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_safety_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","safety_net"]'
(
  _mdm_required_components_are_valid() { return 0; }
  _mdm_artifact_digest() {
    if [[ "$2" == "$_mdm_detect_safety_root" ]]; then
      rm "$_mdm_detect_home/.local/bin/cc-safety-net"
      ln -s ../lib/claude-code-starter-kit/cc-safety-net/1.0.6/bin/cli-b \
        "$_mdm_detect_home/.local/bin/cc-safety-net"
      printf '%s' "$_mdm_detect_safety_hash"
    else
      printf '%s' "$_mdm_detect_kit_artifact_hash"
    fi
  }
  if _mdm_detect_component_check; then
    fail "mdm-detect: digest中のactive command差替えを許可"
  else
    pass "mdm-detect: component digest後にactive commandを再束縛"
  fi
)
rm -rf "$_mdm_detect_home/.local"
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

_mdm_detect_access_parent="$_mdm_detect_tmp/runtime-access"
mkdir -p "$_mdm_detect_access_parent/node_modules"
if ! _mdm_component_tree_accessible \
    "$_mdm_detect_access_parent/node_modules" "$_mdm_detect_fixture_uid"; then
  fail "mdm-detect: readable runtime treeを対象UIDで検証できない"
fi
chmod 0600 "$_mdm_detect_access_parent"
if _mdm_component_tree_accessible \
  "$_mdm_detect_access_parent/node_modules" "$_mdm_detect_fixture_uid"; then
  fail "mdm-detect: ancestor search不能なruntime treeを許可"
else
  pass "mdm-detect: user-executed treeのancestor traverse/readを検証"
fi
chmod 0700 "$_mdm_detect_access_parent"
rm -rf "$_mdm_detect_access_parent"

_mdm_detect_node_fixture="$_mdm_detect_tmp/node-version-fixture"
printf '#!/bin/sh\nprintf "v24.18.0\\n"\n' > "$_mdm_detect_node_fixture"
chmod 700 "$_mdm_detect_node_fixture"
_mdm_detect_node_good=0
_mdm_node_runtime_version_is_valid "$_mdm_detect_node_fixture" \
  "$_mdm_detect_fixture_uid" "$_mdm_detect_home" \
  || _mdm_detect_node_good=$?
printf '#!/bin/sh\nprintf "v24.18.1\\n"\n' > "$_mdm_detect_node_fixture"
_mdm_detect_node_other=0
_mdm_node_runtime_version_is_valid "$_mdm_detect_node_fixture" \
  "$_mdm_detect_fixture_uid" "$_mdm_detect_home" \
  || _mdm_detect_node_other=$?
printf '#!/bin/sh\nprintf "v24.18.0\\nextra\\n"\n' > "$_mdm_detect_node_fixture"
_mdm_detect_node_extra=0
_mdm_node_runtime_version_is_valid "$_mdm_detect_node_fixture" \
  "$_mdm_detect_fixture_uid" "$_mdm_detect_home" \
  || _mdm_detect_node_extra=$?
if [[ "$_mdm_detect_node_good" -eq 0 && "$_mdm_detect_node_other" -ne 0 \
  && "$_mdm_detect_node_extra" -ne 0 ]]; then
  pass "mdm-detect: private Node versionをstrict v24.18.0へ固定"
else
  fail "mdm-detect: Node runtime version contractが不正"
fi

_mdm_detect_node_platform_arch="$(_mdm_node_runtime_arch)"
printf '#!/bin/sh\nif [ "$1" = "-p" ]; then printf "%s\\n"; else printf "v24.18.0\\n"; fi\n' \
  "$_mdm_detect_node_platform_arch" > "$_mdm_detect_node_fixture"
(
  _mdm_node_lipo() {
    case "$_mdm_detect_node_platform_arch" in
      arm64) printf 'arm64\n' ;;
      x64) printf 'x86_64\n' ;;
    esac
  }
  _mdm_node_otool() {
    printf '%s:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n' \
      "$2"
  }
  if _mdm_node_runtime_platform_is_valid "$_mdm_detect_node_fixture" \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_home"; then
    pass "mdm-detect: Node Mach-O/process arch/system dylibをlive検証"
  else
    fail "mdm-detect: valid Node platform contractを拒否"
  fi
  _mdm_node_otool() {
    printf '%s:\n\t/tmp/libInjected.dylib (compatibility version 1.0.0)\n' \
      "$2"
  }
  if _mdm_node_runtime_platform_is_valid "$_mdm_detect_node_fixture" \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_home"; then
    fail "mdm-detect: Nodeの非system dylib依存を許可"
  else
    pass "mdm-detect: Node dylibをsystem pathだけへ固定"
  fi
)

_mdm_detect_node_source_scope() {
  local _url="" _sha=""
  _mdm_node_runtime_source arm64 _url _sha || return 1
  [[ "$_url" == *node-v24.18.0-darwin-arm64.tar.xz \
    && "$_sha" == 4477b9f78efb77744cf5eb57a0e9594dba66466b38b4e93fa9f35cb907a095a6 ]]
}
if _mdm_detect_node_source_scope; then
  pass "mdm-detect: Node provenance outputをcaller scopeへ返す"
else
  fail "mdm-detect: Node provenance outputがdynamic localへ消失"
fi

(
  _mdm_is_darwin() { return 0; }
  _mdm_node_sysctl() {
    [[ "$#" -eq 2 && "$1" == -in && "$2" == hw.optional.arm64 ]] \
      || return 9
    printf '%s' "$_mdm_detect_arch_sysctl_value"
    return "$_mdm_detect_arch_sysctl_rc"
  }
  _mdm_node_uname() {
    [[ "$#" -eq 1 && "$1" == -m ]] || return 9
    printf '%s' "$_mdm_detect_arch_machine"
  }
  _mdm_detect_arch_case() { # <sysctl-value> <sysctl-rc> <uname-m> <expected>
    _mdm_detect_arch_sysctl_value="$1"
    _mdm_detect_arch_sysctl_rc="$2"
    _mdm_detect_arch_machine="$3"
    if _mdm_detect_arch_actual="$(_mdm_node_runtime_arch 2>/dev/null)"; then
      _mdm_detect_arch_rc=0
    else
      _mdm_detect_arch_rc=$?
    fi
    if [[ "$4" == FAIL ]]; then
      [[ "$_mdm_detect_arch_rc" -ne 0 && -z "$_mdm_detect_arch_actual" ]]
    else
      [[ "$_mdm_detect_arch_rc" -eq 0 \
        && "$_mdm_detect_arch_actual" == "$4" ]]
    fi
  }
  if _mdm_detect_arch_case '' 0 x86_64 x64 \
    && _mdm_detect_arch_case 0 0 x86_64 x64 \
    && _mdm_detect_arch_case 1 0 arm64 arm64 \
    && _mdm_detect_arch_case 1 0 x86_64 arm64 \
    && _mdm_detect_arch_case invalid 0 x86_64 FAIL \
    && _mdm_detect_arch_case 1 0 unknown FAIL \
    && _mdm_detect_arch_case '' 1 x86_64 FAIL; then
    pass "mdm-detect: Node runtime arch はIntel/native ARM/Rosettaを厳格判定"
  else
    fail "mdm-detect: Node runtime arch のhardware判定契約が不正"
  fi
)
rm "$_mdm_detect_node_fixture"

_mdm_detect_node_requirement="$(_mdm_node_codesign_requirement)"
if [[ "$_mdm_detect_node_requirement" \
  == '=identifier "node" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "HX7739G8FX"' ]]; then
  pass "mdm-detect: Nodeをofficial Developer ID requirementへ固定"
else
  fail "mdm-detect: Node codesign requirementが不正"
fi

unset MDM_DETECT_NODE_CONTENT_SHA256_OVERRIDE
if [[ "$(_mdm_node_runtime_expected_content_sha256 arm64)" \
    == 3b87679d20e675468b9281755c823b528b6406ba7af6cc7086ef00e5c8af6533 \
  && "$(_mdm_node_runtime_expected_content_sha256 x64)" \
    == a9f69014ea08981c1b1822f565a39ae6970a319518ebf3e43d96ba9fc70aa209 ]]; then
  pass "mdm-detect: Node official extracted-tree digestをarch別固定"
else
  fail "mdm-detect: Node official content digest定数が不正"
fi

_mdm_detect_node_root="$(_mdm_node_runtime_root)"
_mdm_detect_node_path="$_mdm_detect_node_root/bin/node"
_mdm_detect_node_arch="$(_mdm_node_runtime_arch)"
_mdm_detect_node_url=""
_mdm_detect_node_archive_sha=""
_mdm_node_runtime_source "$_mdm_detect_node_arch" \
  _mdm_detect_node_url _mdm_detect_node_archive_sha
mkdir -p "$_mdm_detect_node_root/bin" "$_mdm_detect_home/.local/bin" \
  "$_mdm_detect_node_root/lib/node_modules/npm/bin"
printf '#!/bin/sh\nprintf "v24.18.0\\n"\n' > "$_mdm_detect_node_path"
printf '#!/bin/sh\nprintf "11.16.0\\n"\n' \
  > "$_mdm_detect_node_root/lib/node_modules/npm/bin/npm-cli.js"
printf '#!/bin/sh\nprintf "11.16.0\\n"\n' \
  > "$_mdm_detect_node_root/lib/node_modules/npm/bin/npx-cli.js"
printf '{"name":"npm"}\n' \
  > "$_mdm_detect_node_root/lib/node_modules/npm/package.json"
ln -s ../lib/node_modules/npm/bin/npm-cli.js \
  "$_mdm_detect_node_root/bin/npm"
ln -s ../lib/node_modules/npm/bin/npx-cli.js \
  "$_mdm_detect_node_root/bin/npx"
printf 'schema=1\nversion=v24.18.0\narch=%s\nurl=%s\nsha256=%s\n' \
  "$_mdm_detect_node_arch" "$_mdm_detect_node_url" \
  "$_mdm_detect_node_archive_sha" \
  > "$_mdm_detect_node_root/.claude-code-starter-kit-node-runtime"
chmod 755 "$_mdm_detect_node_path" "$_mdm_detect_node_root" \
  "$_mdm_detect_node_root/bin" "$_mdm_detect_receipts/runtime" \
  "$_mdm_detect_node_root/lib/node_modules/npm/bin/npm-cli.js" \
  "$_mdm_detect_node_root/lib/node_modules/npm/bin/npx-cli.js"
export MDM_DETECT_NODE_CONTENT_SHA256_OVERRIDE
MDM_DETECT_NODE_CONTENT_SHA256_OVERRIDE="$(_mdm_node_runtime_content_sha256 \
  "$_mdm_detect_node_root")"
ln -s "$_mdm_detect_node_path" "$_mdm_detect_home/.local/bin/node"
if [[ "$(_mdm_node_command_path "$_mdm_detect_home" \
      "$_mdm_detect_fixture_uid" "$_mdm_detect_node_root")" \
      == "$_mdm_detect_node_path" ]] \
  && _mdm_node_runtime_tree_is_trusted "$_mdm_detect_node_root"; then
  pass "mdm-detect: private Node treeとabsolute activation linkを束縛"
else
  fail "mdm-detect: valid private Node activationを拒否"
fi

/bin/cp "$_mdm_detect_node_root/lib/node_modules/npm/package.json" \
  "$_mdm_detect_tmp/node-package.saved"
printf 'drift\n' \
  >> "$_mdm_detect_node_root/lib/node_modules/npm/package.json"
if _mdm_node_runtime_tree_is_trusted "$_mdm_detect_node_root"; then
  fail "mdm-detect: signed Node treeのcontent driftを許可"
else
  pass "mdm-detect: Node全contentをofficial extracted-tree digestへ固定"
fi
/bin/mv "$_mdm_detect_tmp/node-package.saved" \
  "$_mdm_detect_node_root/lib/node_modules/npm/package.json"

if _mdm_is_darwin \
  && chmod +a 'everyone deny delete' "$_mdm_detect_home" 2>/dev/null; then
  if _mdm_node_command_path "$_mdm_detect_home" \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_node_root" \
    >/dev/null 2>&1; then
    pass "mdm-detect: standard home deny-delete ACLはNodeを妨げない"
  else
    fail "mdm-detect: benign home ACLだけでprivate Nodeを拒否"
  fi
  chmod -N "$_mdm_detect_home"
  chmod +a 'everyone allow write' "$_mdm_detect_home/.local/bin"
  if _mdm_node_command_path "$_mdm_detect_home" \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_node_root" \
    >/dev/null 2>&1; then
    fail "mdm-detect: writable ACL付きNode activation parentを許可"
  else
    pass "mdm-detect: Node activation parentのmutating ACLを拒否"
  fi
  chmod -N "$_mdm_detect_home/.local/bin"
fi

printf 'tampered\n' \
  >> "$_mdm_detect_node_root/.claude-code-starter-kit-node-runtime"
if _mdm_node_runtime_tree_is_trusted "$_mdm_detect_node_root"; then
  fail "mdm-detect: private Node provenance marker driftを許可"
else
  pass "mdm-detect: Node treeをpinned official archive provenanceへ束縛"
fi
printf 'schema=1\nversion=v24.18.0\narch=%s\nurl=%s\nsha256=%s\n' \
  "$_mdm_detect_node_arch" "$_mdm_detect_node_url" \
  "$_mdm_detect_node_archive_sha" \
  > "$_mdm_detect_node_root/.claude-code-starter-kit-node-runtime"

rm "$_mdm_detect_home/.local/bin/node"
ln -s "../not-the-managed-runtime/node" \
  "$_mdm_detect_home/.local/bin/node"
if _mdm_node_command_path "$_mdm_detect_home" \
  "$_mdm_detect_fixture_uid" "$_mdm_detect_node_root" \
  >/dev/null 2>&1; then
  fail "mdm-detect: relative Node activation linkを許可"
else
  pass "mdm-detect: Node activationはexact absolute targetへ固定"
fi
rm "$_mdm_detect_home/.local/bin/node"
ln -s "$_mdm_detect_node_path" "$_mdm_detect_home/.local/bin/node"

_mdm_detect_wce="$_mdm_detect_wce_root"
_mdm_detect_wce_link="$_mdm_detect_home/.claude/skills/web-content-extraction/node_modules"
_mdm_detect_wce_arch="$(_mdm_node_runtime_arch)"
mkdir -p "$_mdm_detect_wce/node_modules" \
  "${_mdm_detect_wce%/*}" \
  "$_mdm_detect_home/.claude/skills/web-content-extraction"
/bin/cp "$PROJECT_DIR/skills/web-content-extraction/package.json" \
  "$_mdm_detect_wce/package.json"
/bin/cp "$PROJECT_DIR/skills/web-content-extraction/package-lock.json" \
  "$_mdm_detect_wce/package-lock.json"
if _mdm_is_darwin; then
  /usr/bin/xattr -c "$_mdm_detect_wce/package.json" \
    "$_mdm_detect_wce/package-lock.json"
fi
printf '%s\n' \
  "{\"arch\":\"$_mdm_detect_wce_arch\",\"lock_sha256\":\"f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd\",\"node_version\":\"v24.18.0\",\"npm_version\":\"11.16.0\",\"package_sha256\":\"e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c\",\"registry\":\"https://registry.npmjs.org/\",\"schema_version\":1}" \
  > "$_mdm_detect_wce/.claude-code-starter-kit-wce-runtime.json"
printf 'runtime\n' > "$_mdm_detect_wce/node_modules/runtime.js"
for _mdm_detect_wce_dependency in defuddle jsdom pdfjs-dist undici; do
  mkdir -p \
    "$_mdm_detect_wce/node_modules/$_mdm_detect_wce_dependency"
  printf '{"name":"%s"}\n' "$_mdm_detect_wce_dependency" \
    > "$_mdm_detect_wce/node_modules/$_mdm_detect_wce_dependency/package.json"
done
chmod 755 "$_mdm_detect_receipts/runtime" \
  "$_mdm_detect_receipts/runtime/web-content-extraction" \
  "${_mdm_detect_wce%/*}" "$_mdm_detect_wce" \
  "$_mdm_detect_wce/node_modules" \
  "$_mdm_detect_wce/node_modules/defuddle" \
  "$_mdm_detect_wce/node_modules/jsdom" \
  "$_mdm_detect_wce/node_modules/pdfjs-dist" \
  "$_mdm_detect_wce/node_modules/undici" \
  "$_mdm_detect_home/.claude/skills" \
  "$_mdm_detect_home/.claude/skills/web-content-extraction"
chmod 644 "$_mdm_detect_wce/.claude-code-starter-kit-wce-runtime.json" \
  "$_mdm_detect_wce/package.json" "$_mdm_detect_wce/package-lock.json" \
  "$_mdm_detect_wce/node_modules/runtime.js" \
  "$_mdm_detect_wce/node_modules/defuddle/package.json" \
  "$_mdm_detect_wce/node_modules/jsdom/package.json" \
  "$_mdm_detect_wce/node_modules/pdfjs-dist/package.json" \
  "$_mdm_detect_wce/node_modules/undici/package.json"
if _mdm_is_darwin; then
  /usr/bin/xattr -cr "$_mdm_detect_wce"
  /usr/bin/xattr -c "$_mdm_detect_receipts" \
    "$_mdm_detect_receipts/runtime" \
    "$_mdm_detect_receipts/runtime/web-content-extraction" \
    "${_mdm_detect_wce%/*}"
fi
_mdm_detect_wce_provenance_fixture=0
if _mdm_is_darwin \
  && /usr/bin/xattr -w com.apple.provenance mdm-test \
    "$_mdm_detect_wce/node_modules/runtime.js" 2>/dev/null \
  && /usr/bin/xattr -p com.apple.provenance \
    "$_mdm_detect_wce/node_modules/runtime.js" >/dev/null 2>&1; then
  _mdm_detect_wce_provenance_fixture=1
fi
ln -s "$_mdm_detect_wce/node_modules" "$_mdm_detect_wce_link"
_mdm_detect_node_hash="$(_mdm_artifact_digest \
  tree "$_mdm_detect_node_root" "$_mdm_detect_fixture_uid" \
  "$(_mdm_stat_gid "$_mdm_detect_node_root")")"
_mdm_detect_wce_hash="$(_mdm_artifact_digest \
  tree "$_mdm_detect_wce" "$(_mdm_stat_uid "$_mdm_detect_wce")" \
  "$(_mdm_stat_gid "$_mdm_detect_wce")")"
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"},{\"component\":\"node_runtime\",\"path\":\"$_mdm_detect_node_root\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_node_hash\"},{\"component\":\"web_content_runtime\",\"path\":\"$_mdm_detect_wce\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_wce_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","node_runtime","web_content_runtime"]'
if _mdm_wce_runtime_metadata_is_valid "$_mdm_detect_wce"; then
  pass "mdm-detect: WCE root tree metadata正常系"
else
  fail "mdm-detect: valid WCE root tree metadataを拒否"
fi
if _mdm_wce_runtime_marker_is_valid "$_mdm_detect_wce" \
  && [[ "$(_mdm_sha256 "$_mdm_detect_wce/package.json")" \
      == e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c \
    && "$(_mdm_sha256 "$_mdm_detect_wce/package-lock.json")" \
      == f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd ]]; then
  pass "mdm-detect: WCE marker/source hash正常系"
else
  fail "mdm-detect: valid WCE marker/source hashを拒否"
fi
if _mdm_artifact_digest tree "$_mdm_detect_wce" \
    "$(_mdm_stat_uid "$_mdm_detect_wce")" \
    "$(_mdm_stat_gid "$_mdm_detect_wce")" >/dev/null; then
  pass "mdm-detect: WCE root artifact digest正常系"
else
  fail "mdm-detect: valid WCE root artifactを拒否"
fi
(
  _mdm_node_runtime_platform_is_valid() { return 0; }
  _mdm_node_codesign() {
    case " $* " in
      *' -dv '*)
        printf '%s\n' 'Identifier=node' 'TeamIdentifier=HX7739G8FX' \
          'Authority=Developer ID Application: Node.js Foundation (HX7739G8FX)' \
          'Authority=Developer ID Certification Authority' \
          'Authority=Apple Root CA' >&2 ;;
      *) return 0 ;;
    esac
  }
  if _mdm_detect_component_check; then
    pass "mdm-detect: signed Node/WCE tree/link digestを再検証"
  else
    fail "mdm-detect: valid Node/WCE runtime attestationを拒否"
  fi
)
if _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce" \
  && [[ -n "$(_mdm_wce_activation_record "$_mdm_detect_home" \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_wce")" ]]; then
  pass "mdm-detect: root-owned WCE bundleとuser activationを束縛"
else
  fail "mdm-detect: valid root-owned WCE runtimeを拒否"
fi

_mdm_detect_base_gid="$(_mdm_stat_gid "$_mdm_detect_trust_base")"
_mdm_detect_managed_gid="$(_mdm_stat_gid "$_mdm_detect_receipts")"
_mdm_detect_base_alternate_gid="$(/usr/bin/id -G | /usr/bin/awk \
  -v managed="$_mdm_detect_managed_gid" -v base="$_mdm_detect_base_gid" \
  '{ for (i = 1; i <= NF; i++) if ($i != managed && $i != base) { print $i; exit } }')"
if [[ "$_mdm_detect_base_alternate_gid" =~ ^[0-9]+$ ]] \
  && /usr/bin/chgrp "$_mdm_detect_base_alternate_gid" \
    "$_mdm_detect_trust_base" 2>/dev/null; then
  if _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce"; then
    pass "mdm-detect: WCE metadata GIDはmanaged rootを基準化"
  else
    fail "mdm-detect: system base GIDをWCE bundle GIDへ誤適用"
  fi
  /usr/bin/chgrp "$_mdm_detect_base_gid" "$_mdm_detect_trust_base"
else
  skip "mdm-detect: WCE managed-root GID基準" \
    "alternate supplementary group unavailable"
fi

chmod 0711 "$_mdm_detect_receipts/runtime"
_mdm_detect_node_ancestor_rc=0
_mdm_detect_wce_ancestor_rc=0
_mdm_node_runtime_tree_is_trusted "$_mdm_detect_node_root" \
  || _mdm_detect_node_ancestor_rc=$?
_mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce" \
  || _mdm_detect_wce_ancestor_rc=$?
if [[ "$_mdm_detect_node_ancestor_rc" -ne 0 \
  && "$_mdm_detect_wce_ancestor_rc" -ne 0 ]]; then
  pass "mdm-detect: Node/WCE managed ancestors は exact 0755"
else
  fail "mdm-detect: Node/WCE managed ancestor の 0711 drift を許可"
fi
chmod 0755 "$_mdm_detect_receipts/runtime"

_mdm_detect_runtime_gid="$(_mdm_stat_gid "$_mdm_detect_receipts/runtime")"
_mdm_detect_alternate_gid="$(/usr/bin/id -G | /usr/bin/awk \
  -v original="$_mdm_detect_runtime_gid" \
  '{ for (i = 1; i <= NF; i++) if ($i != original) { print $i; exit } }')"
if [[ "$_mdm_detect_alternate_gid" =~ ^[0-9]+$ ]] \
  && /usr/bin/chgrp "$_mdm_detect_alternate_gid" \
    "$_mdm_detect_receipts/runtime" 2>/dev/null; then
  _mdm_detect_node_gid_rc=0
  _mdm_detect_wce_gid_rc=0
  _mdm_node_runtime_tree_is_trusted "$_mdm_detect_node_root" \
    || _mdm_detect_node_gid_rc=$?
  _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce" \
    || _mdm_detect_wce_gid_rc=$?
  if [[ "$_mdm_detect_node_gid_rc" -ne 0 \
    && "$_mdm_detect_wce_gid_rc" -ne 0 ]]; then
    pass "mdm-detect: Node/WCE managed chain を issuer GID へ固定"
  else
    fail "mdm-detect: Node/WCE managed parent の issuer GID drift を許可"
  fi
  /usr/bin/chgrp "$_mdm_detect_runtime_gid" \
    "$_mdm_detect_receipts/runtime"
else
  skip "mdm-detect: Node/WCE managed chain GIDを固定" \
    "alternate supplementary group unavailable"
fi

(
  _mdm_runtime_system_ancestors_are_trusted() { return 1; }
  if _mdm_node_runtime_tree_is_trusted "$_mdm_detect_node_root" \
    || _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce"; then
    fail "mdm-detect: Node/WCE verifier が system ancestor 契約を迂回"
  else
    pass "mdm-detect: Node/WCE verifier を system ancestor 契約へ配線"
  fi
)

if [[ "$_mdm_detect_wce_provenance_fixture" -eq 1 ]]; then
  if _mdm_wce_runtime_metadata_is_valid "$_mdm_detect_wce"; then
    pass "mdm-detect: WCE bundleのmacOS provenance xattrを許容"
  else
    fail "mdm-detect: WCE bundleのmacOS provenance xattrだけで拒否"
  fi
else
  skip "mdm-detect: WCE bundleのmacOS provenance xattrを許容" \
    "provenance xattr fixture unavailable on this platform"
fi

/bin/mv "$_mdm_detect_wce/node_modules" \
  "$_mdm_detect_tmp/wce-node-modules.saved"
mkdir -m 755 "$_mdm_detect_wce/node_modules"
if _mdm_wce_runtime_metadata_is_valid "$_mdm_detect_wce"; then
  fail "mdm-detect: empty WCE node_modules baselineを許可"
else
  pass "mdm-detect: WCE direct dependency packageを成功条件に固定"
fi
/bin/rm -rf "$_mdm_detect_wce/node_modules"
/bin/mv "$_mdm_detect_tmp/wce-node-modules.saved" \
  "$_mdm_detect_wce/node_modules"

/bin/mv "$_mdm_detect_wce/node_modules/defuddle" \
  "$_mdm_detect_tmp/wce-defuddle.saved"
if _mdm_wce_runtime_metadata_is_valid "$_mdm_detect_wce"; then
  fail "mdm-detect: WCE direct dependency directory欠落を許可"
else
  pass "mdm-detect: 各WCE direct dependency directoryを必須化"
fi
/bin/mv "$_mdm_detect_tmp/wce-defuddle.saved" \
  "$_mdm_detect_wce/node_modules/defuddle"

/bin/mv "$_mdm_detect_wce/node_modules/jsdom/package.json" \
  "$_mdm_detect_tmp/wce-jsdom-package.saved"
if _mdm_wce_runtime_metadata_is_valid "$_mdm_detect_wce"; then
  fail "mdm-detect: WCE direct dependency package.json欠落を許可"
else
  pass "mdm-detect: 各WCE direct dependency package.jsonを必須化"
fi
/bin/mv "$_mdm_detect_tmp/wce-jsdom-package.saved" \
  "$_mdm_detect_wce/node_modules/jsdom/package.json"

if _mdm_is_darwin \
  && /usr/bin/xattr -w com.cloudnative.mdm-test 1 \
    "${_mdm_detect_wce%/*}" 2>/dev/null; then
  if _mdm_wce_runtime_metadata_is_valid "$_mdm_detect_wce"; then
    pass "mdm-detect: WCE root ancestorの通常xattrを許容"
  else
    fail "mdm-detect: WCE root ancestorの通常xattrだけで拒否"
  fi
  /usr/bin/xattr -d com.cloudnative.mdm-test "${_mdm_detect_wce%/*}"
else
  skip "mdm-detect: WCE root ancestorの通常xattrを許容" \
    "xattr fixture unavailable on this platform"
fi

_mdm_detect_wce_user_xattr_fixture=1
if _mdm_is_darwin; then
  for _mdm_detect_wce_user_dir in \
    "$_mdm_detect_home/.claude" \
    "$_mdm_detect_home/.claude/skills" \
    "$_mdm_detect_home/.claude/skills/web-content-extraction"; do
    /usr/bin/xattr -w com.cloudnative.mdm-test 1 \
      "$_mdm_detect_wce_user_dir" 2>/dev/null \
      || _mdm_detect_wce_user_xattr_fixture=0
  done
else
  _mdm_detect_wce_user_xattr_fixture=0
fi
if [[ "$_mdm_detect_wce_user_xattr_fixture" -eq 1 ]]; then
  if _mdm_wce_activation_record "$_mdm_detect_home" \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_wce" >/dev/null; then
    pass "mdm-detect: WCE user-owned ancestorの通常xattrを許容"
  else
    fail "mdm-detect: WCE user-owned ancestorの通常xattrだけで拒否"
  fi
else
  skip "mdm-detect: WCE user-owned ancestorの通常xattrを許容" \
    "xattr fixture unavailable on this platform"
fi
for _mdm_detect_wce_user_dir in \
  "$_mdm_detect_home/.claude" \
  "$_mdm_detect_home/.claude/skills" \
  "$_mdm_detect_home/.claude/skills/web-content-extraction"; do
  /usr/bin/xattr -d com.cloudnative.mdm-test \
    "$_mdm_detect_wce_user_dir" 2>/dev/null || true
done

if _mdm_is_darwin \
  && /usr/bin/xattr -s -w com.cloudnative.mdm-test 1 \
    "$_mdm_detect_wce_link" 2>/dev/null; then
  if _mdm_wce_activation_record "$_mdm_detect_home" \
    "$_mdm_detect_fixture_uid" "$_mdm_detect_wce" >/dev/null; then
    pass "mdm-detect: WCE activation symlinkの通常xattrを許容"
  else
    fail "mdm-detect: WCE activation symlinkの通常xattrだけで拒否"
  fi
  /usr/bin/xattr -s -d com.cloudnative.mdm-test "$_mdm_detect_wce_link"
else
  skip "mdm-detect: WCE activation symlinkの通常xattrを許容" \
    "symlink xattr fixture unavailable on this platform"
fi

/bin/cp "$_mdm_detect_wce/node_modules/runtime.js" \
  "$_mdm_detect_tmp/wce-runtime.saved"
printf 'drift\n' >> "$_mdm_detect_wce/node_modules/runtime.js"
(
  _mdm_node_signature_trusted() { return 0; }
  _mdm_node_runtime_platform_is_valid() { return 0; }
  if _mdm_detect_component_check; then
    fail "mdm-detect: WCE bundle content driftを許可"
  else
    pass "mdm-detect: WCE全treeをreceipt artifact hashへ束縛"
  fi
)
/bin/mv "$_mdm_detect_tmp/wce-runtime.saved" \
  "$_mdm_detect_wce/node_modules/runtime.js"

/bin/cp "$_mdm_detect_wce/.claude-code-starter-kit-wce-runtime.json" \
  "$_mdm_detect_tmp/wce-marker.saved"
printf 'tampered\n' \
  >> "$_mdm_detect_wce/.claude-code-starter-kit-wce-runtime.json"
if _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce"; then
  fail "mdm-detect: WCE provenance marker driftを許可"
else
  pass "mdm-detect: WCE provenance markerをcanonical bytesへ固定"
fi
/bin/mv "$_mdm_detect_tmp/wce-marker.saved" \
  "$_mdm_detect_wce/.claude-code-starter-kit-wce-runtime.json"

/bin/cp "$_mdm_detect_wce/.claude-code-starter-kit-wce-runtime.json" \
  "$_mdm_detect_tmp/wce-marker.saved"
printf '\0' \
  >> "$_mdm_detect_wce/.claude-code-starter-kit-wce-runtime.json"
if _mdm_wce_runtime_marker_is_valid "$_mdm_detect_wce"; then
  fail "mdm-detect: NUL suffix付きWCE markerを許可"
else
  pass "mdm-detect: WCE markerのNUL suffixをbyte検証で拒否"
fi
/bin/mv "$_mdm_detect_tmp/wce-marker.saved" \
  "$_mdm_detect_wce/.claude-code-starter-kit-wce-runtime.json"

printf 'extra\n' > "$_mdm_detect_wce/unexpected"
if _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce"; then
  fail "mdm-detect: WCE bundleの余剰top-level entryを許可"
else
  pass "mdm-detect: WCE bundleのtop-level inventoryをexact固定"
fi
/bin/rm "$_mdm_detect_wce/unexpected"

chmod 775 "$_mdm_detect_wce/node_modules"
if _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce"; then
  fail "mdm-detect: group-writable WCE runtimeを許可"
else
  pass "mdm-detect: WCE runtime全entryのmodeを固定"
fi
chmod 755 "$_mdm_detect_wce/node_modules"

/bin/cp "$_mdm_detect_wce/package-lock.json" \
  "$_mdm_detect_tmp/wce-lock.saved"
printf ' ' >> "$_mdm_detect_wce/package-lock.json"
if _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce"; then
  fail "mdm-detect: WCE package-lock driftを許可"
else
  pass "mdm-detect: WCE package-lockをpinned source hashへ固定"
fi
/bin/mv "$_mdm_detect_tmp/wce-lock.saved" \
  "$_mdm_detect_wce/package-lock.json"

ln -s runtime.js "$_mdm_detect_wce/node_modules/unexpected-link"
if _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce"; then
  fail "mdm-detect: WCE bundle内relative symlinkを許可"
else
  pass "mdm-detect: WCE bundle内symlinkを全面拒否"
fi
/bin/rm "$_mdm_detect_wce/node_modules/unexpected-link"

if _mdm_is_darwin \
  && /usr/bin/xattr -w com.cloudnative.mdm-test 1 \
    "$_mdm_detect_wce/node_modules/runtime.js" 2>/dev/null; then
  if _mdm_wce_runtime_tree_is_trusted "$_mdm_detect_wce"; then
    fail "mdm-detect: 非provenance xattr付きWCE entryを許可"
  else
    pass "mdm-detect: WCE runtimeの非provenance xattrを拒否"
  fi
  /usr/bin/xattr -d com.cloudnative.mdm-test \
    "$_mdm_detect_wce/node_modules/runtime.js"
else
  skip "mdm-detect: WCE runtimeの非provenance xattrを拒否" \
    "xattr fixture unavailable on this platform"
fi

(
  _mdm_stat_gid() {
    if [[ "$1" == "$_mdm_detect_receipts" ]]; then
      printf '2147483647'
    else
      /usr/bin/stat -f '%g' "$1" 2>/dev/null
    fi
  }
  if _mdm_wce_runtime_metadata_is_valid "$_mdm_detect_wce"; then
    fail "mdm-detect: WCE runtimeのmanaged-root外GIDを許可"
  else
    pass "mdm-detect: WCE runtime全entryをmanaged root GIDへ束縛"
  fi
)

_mdm_detect_old_wce_path="$_mdm_detect_wce_link"
if _mdm_component_entry_path_is_valid web_content_runtime \
    "$_mdm_detect_old_wce_path" tree "$_mdm_detect_home" '' '' '' '' '' \
    "$_mdm_detect_node_root" "$_mdm_detect_wce" \
  || _mdm_component_entry_path_is_valid web_content_runtime \
    "$_mdm_detect_wce" file "$_mdm_detect_home" '' '' '' '' '' \
    "$_mdm_detect_node_root" "$_mdm_detect_wce"; then
  fail "mdm-detect: WCE旧user treeまたはfile kindを許可"
else
  pass "mdm-detect: WCE componentをcanonical root treeだけへ固定"
fi

/bin/rm "$_mdm_detect_wce_link"
ln -s "$_mdm_detect_wce/node_modules/../node_modules" \
  "$_mdm_detect_wce_link"
if _mdm_wce_activation_record "$_mdm_detect_home" \
  "$_mdm_detect_fixture_uid" "$_mdm_detect_wce" >/dev/null 2>&1; then
  fail "mdm-detect: non-exact WCE activation targetを許可"
else
  pass "mdm-detect: WCE activationをexact absolute targetへ固定"
fi
/bin/rm "$_mdm_detect_wce_link"
ln -s "$_mdm_detect_wce/node_modules" "$_mdm_detect_wce_link"

(
  _mdm_detect_wce_digest_count_file="$_mdm_detect_private_base/wce-digest-count"
  printf '0\n' > "$_mdm_detect_wce_digest_count_file"
  _mdm_node_signature_trusted() { return 0; }
  _mdm_node_runtime_platform_is_valid() { return 0; }
  _mdm_artifact_digest() {
    case "$2" in
      "$_mdm_detect_wce")
        _mdm_detect_wce_digest_count="$(< \
          "$_mdm_detect_wce_digest_count_file")"
        _mdm_detect_wce_digest_count=$((_mdm_detect_wce_digest_count + 1))
        printf '%s\n' "$_mdm_detect_wce_digest_count" \
          > "$_mdm_detect_wce_digest_count_file"
        if [[ "$_mdm_detect_wce_digest_count" -eq 3 ]]; then
          /bin/rm "$_mdm_detect_wce_link"
          ln -s "$_mdm_detect_wce/node_modules/../node_modules" \
            "$_mdm_detect_wce_link"
        fi
        printf '%s' "$_mdm_detect_wce_hash" ;;
      "$_mdm_detect_node_root") printf '%s' "$_mdm_detect_node_hash" ;;
      *) printf '%s' "$_mdm_detect_kit_artifact_hash" ;;
    esac
  }
  if _mdm_detect_component_check; then
    fail "mdm-detect: WCE digest中のactivation swapを許可"
  else
    pass "mdm-detect: WCE semantic/digest後にactivation identityを再束縛"
  fi
  /bin/rm "$_mdm_detect_wce_digest_count_file"
)
/bin/rm "$_mdm_detect_wce_link"
ln -s "$_mdm_detect_wce/node_modules" "$_mdm_detect_wce_link"
(
  _mdm_detect_node_digest_count_file="$_mdm_detect_private_base/node-digest-count"
  printf '0\n' > "$_mdm_detect_node_digest_count_file"
  _mdm_node_signature_trusted() { return 0; }
  _mdm_node_runtime_platform_is_valid() { return 0; }
  _mdm_artifact_digest() {
    case "$2" in
      "$_mdm_detect_node_root")
        _mdm_detect_node_digest_count="$(< \
          "$_mdm_detect_node_digest_count_file")"
        _mdm_detect_node_digest_count=$((_mdm_detect_node_digest_count + 1))
        printf '%s\n' "$_mdm_detect_node_digest_count" \
          > "$_mdm_detect_node_digest_count_file"
        if [[ "$_mdm_detect_node_digest_count" -eq 3 ]]; then
          rm "$_mdm_detect_home/.local/bin/node"
          ln -s ../wrong-runtime/node "$_mdm_detect_home/.local/bin/node"
        fi
        printf '%s' "$_mdm_detect_node_hash" ;;
      "$_mdm_detect_wce") printf '%s' "$_mdm_detect_wce_hash" ;;
      *) printf '%s' "$_mdm_detect_kit_artifact_hash" ;;
    esac
  }
  if _mdm_detect_component_check; then
    fail "mdm-detect: final digest中のNode activation swapを許可"
  else
    pass "mdm-detect: Node semantic/digest後にactivation linkを再束縛"
  fi
  rm "$_mdm_detect_node_digest_count_file"
)
rm "$_mdm_detect_home/.local/bin/node"
ln -s "$_mdm_detect_node_path" "$_mdm_detect_home/.local/bin/node"
rm -rf "$_mdm_detect_home/.claude/skills" \
  "$_mdm_detect_receipts/runtime/web-content-extraction" \
  "$_mdm_detect_node_root"
rm "$_mdm_detect_home/.local/bin/node"
unset MDM_DETECT_NODE_CONTENT_SHA256_OVERRIDE
_mdm_detect_write_components "[{\"component\":\"kit\",\"path\":\"$_mdm_detect_install\",\"kind\":\"tree\",\"sha256\":\"$_mdm_detect_kit_artifact_hash\"}]"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

# A complete, anchored installation is compliant.
(
  export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_mdm_detect_receipt" jane; then
    pass "mdm-detect: receipt v3 anchors policy, clone, manifest and files"
  else
    fail "mdm-detect: valid deployed state was rejected"
  fi
)

# Rebind the complete account tuple after the long deployment scan.  A
# directory-service recreation or home remap during detection must not inherit
# the initially verified state and become compliant.
(
  _mdm_detect_binding_phase=initial
  _mdm_component_manifest_is_valid() {
    _mdm_detect_binding_phase=final
    return 0
  }
  _mdm_detect_target_identity_tuple() {
    if [[ "$_mdm_detect_binding_phase" == final ]]; then
      printf '%s\t%s' "$_mdm_detect_fixture_uid" \
        00000000-ABCD-1234-ABCD-1234567890EF
    else
      printf '%s\t%s' "$_mdm_detect_fixture_uid" \
        "$MDM_DETECT_GENERATED_UID_OVERRIDE"
    fi
  }
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: scan中のtarget account再作成を許可"
  else
    pass "mdm-detect: scan末尾でUID/GeneratedUIDを再束縛"
  fi
)
(
  _mdm_detect_binding_phase=initial
  _mdm_component_manifest_is_valid() {
    _mdm_detect_binding_phase=final
    return 0
  }
  _mdm_detect_user_home() {
    if [[ "$_mdm_detect_binding_phase" == final ]]; then
      printf '%s' "$_mdm_detect_home-remapped"
    else
      printf '%s' "$_mdm_detect_home"
    fi
  }
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: scan中のtarget home remapを許可"
  else
    pass "mdm-detect: scan末尾でtarget homeを再束縛"
  fi
)

chmod 0777 "$_mdm_detect_home"
if _mdm_home_boundary_is_safe \
    "$_mdm_detect_home" "$_mdm_detect_fixture_uid"; then
  fail "mdm-detect: mode 0777 home boundary を許可"
else
  pass "mdm-detect: home boundary は group/other-write を拒否"
fi
chmod 0755 "$_mdm_detect_home"

if _mdm_is_darwin \
  && /bin/chmod +a 'everyone deny delete' "$_mdm_detect_home" 2>/dev/null; then
  if _mdm_home_boundary_is_safe \
      "$_mdm_detect_home" "$_mdm_detect_fixture_uid"; then
    pass "mdm-detect: 標準 home deny-delete ACL だけを受理"
  else
    fail "mdm-detect: 標準 home deny-delete ACL を拒否"
  fi
  /bin/chmod -N "$_mdm_detect_home"
  if /bin/chmod +a \
      'everyone deny delete,file_inherit,directory_inherit' \
      "$_mdm_detect_home" 2>/dev/null; then
    if _mdm_home_boundary_is_safe \
        "$_mdm_detect_home" "$_mdm_detect_fixture_uid"; then
      fail "mdm-detect: inheritable home ACL を許可"
    else
      pass "mdm-detect: inheritable home ACL を標準 ACL と区別"
    fi
    /bin/chmod -N "$_mdm_detect_home"
  else
    skip "mdm-detect: inheritable home ACL を拒否" \
      "ACL inheritance fixture unavailable"
  fi
else
  skip "mdm-detect: home ACL exact contract" "ACL fixture unavailable"
fi

(
  _mdm_user_dir_acl_is_supported() { return 1; }
  if _mdm_target_dir_is_accessible \
      "$_mdm_detect_home/.local/bin" "$_mdm_detect_fixture_uid"; then
    fail "mdm-detect: generic target dir helper が mutating ACL を許可"
  else
    pass "mdm-detect: 全 user-owned dir を exact ACL classifier へ束縛"
  fi
)

mkdir -p "$_mdm_detect_home/Library/Fonts"
printf 'font fixture\n' > "$_mdm_detect_home/Library/Fonts/fixture.ttf"
(
  _mdm_user_dir_acl_is_supported() {
    [[ "$1" != "$_mdm_detect_home/Library/Fonts" ]]
  }
  if _mdm_component_file_readable \
      "$_mdm_detect_home/Library/Fonts/fixture.ttf" \
      "$_mdm_detect_fixture_uid" "$_mdm_detect_home"; then
    fail "mdm-detect: font ancestor の unsupported ACL を許可"
  else
    pass "mdm-detect: fonts を home 配下 ancestor ACL 契約へ束縛"
  fi
)
rm -f "$_mdm_detect_home/Library/Fonts/fixture.ttf"

_mdm_detect_external="$_mdm_detect_tmp/external-component"
_mdm_detect_external_file="$_mdm_detect_external/tool"
mkdir -p "$_mdm_detect_external"
chmod 0755 "$_mdm_detect_external"
printf 'tool fixture\n' > "$_mdm_detect_external_file"
chmod 0644 "$_mdm_detect_external_file"
if _mdm_is_darwin \
  && /bin/chmod +a \
    'group:everyone allow search,list,add_file,add_subdirectory,delete_child' \
    "$_mdm_detect_external" 2>/dev/null; then
  _mdm_detect_external_allow_rc=0
  _mdm_component_file_readable \
    "$_mdm_detect_external_file" "$_mdm_detect_fixture_uid" \
    "$_mdm_detect_home" >/dev/null 2>&1 || _mdm_detect_external_allow_rc=$?
  /bin/chmod -N "$_mdm_detect_external"
  /bin/chmod +a 'group:everyone deny delete' "$_mdm_detect_external"
  _mdm_detect_external_deny_rc=0
  _mdm_component_file_readable \
    "$_mdm_detect_external_file" "$_mdm_detect_fixture_uid" \
    "$_mdm_detect_home" >/dev/null 2>&1 || _mdm_detect_external_deny_rc=$?
  /bin/chmod -N "$_mdm_detect_external"
  if [[ "$_mdm_detect_external_allow_rc" -ne 0 \
    && "$_mdm_detect_external_deny_rc" -eq 0 ]]; then
    pass "mdm-detect: home外ancestorのallow-write ACLを拒否しdeny-deleteだけ許可"
  else
    fail "mdm-detect: home外component ancestor ACL契約が不正"
  fi
else
  skip "mdm-detect: home外component ancestor ACL契約" \
    "ACL fixture unavailable on this platform"
fi
rm -rf "$_mdm_detect_external"

(
  _mdm_home_boundary_is_safe() { return 1; }
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: compliance が universal home boundary を迂回"
  else
    pass "mdm-detect: compliance を universal home boundary へ束縛"
  fi
)

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
mv "$_mdm_detect_history" "$_mdm_detect_history.saved"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: root managed history の欠落を許可"
else
  pass "mdm-detect: 成功状態には root managed history が必須"
fi
mv "$_mdm_detect_history.saved" "$_mdm_detect_history"

chmod 644 "$_mdm_detect_history"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: 読み取り可能な managed history mode を許可"
else
  pass "mdm-detect: managed history は mode 0600 に固定"
fi
chmod 600 "$_mdm_detect_history"

ln "$_mdm_detect_history" "$_mdm_detect_history.peer"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: hardlink managed history を許可"
else
  pass "mdm-detect: managed history は link count 1 に固定"
fi
rm "$_mdm_detect_history.peer"

_mdm_detect_write_history '"2"'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: string型 history schema_version を許可"
else
  pass "mdm-detect: managed history JSON 型をfail-closedで検証"
fi
_mdm_detect_write_history

_mdm_detect_write_history 2 "$((MDM_DETECT_EXPECTED_UID_OVERRIDE + 1))"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: 別UIDの managed history を許可"
else
  pass "mdm-detect: managed history を現在の対象UIDへ束縛"
fi
_mdm_detect_write_history 2 "$MDM_DETECT_EXPECTED_UID_OVERRIDE" \
  00000000-ABCD-1234-ABCD-1234567890EF
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: 別GeneratedUIDの managed history を許可"
else
  pass "mdm-detect: managed history を現在のGeneratedUIDへ束縛"
fi
_mdm_detect_write_history

# A root receipt cannot redirect compliance to a trust-valid checkout outside
# the fixed per-user path used by the production installer.
_mdm_detect_alt_install="$_mdm_detect_tmp/kit-outside-home"
/bin/cp -R "$_mdm_detect_install" "$_mdm_detect_alt_install"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["claude_cli","kit"]' 0.73.0 "$_mdm_detect_alt_install"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: receipt の home 外 install_dir を許可"
else
  pass "mdm-detect: install_dir は対象 home の固定パスに束縛"
fi
/bin/rm -rf "$_mdm_detect_alt_install"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["claude_cli","kit"]'

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
/bin/rm -f "$_mdm_detect_persistent_marker.peer"

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
_mdm_detect_required_control_rc=0
for _mdm_detect_required_control in \
  '["kit\n"]' '["kit\r"]' '["kit\u0000"]'; do
  _mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
    "$_mdm_detect_required_control"
  if mdm_detect "$_mdm_detect_receipt" jane; then
    _mdm_detect_required_control_rc=1
  fi
done
if [[ "$_mdm_detect_required_control_rc" -eq 0 ]]; then
  pass "mdm-detect: required_components の LF/CR/NUL suffixを拒否"
else
  fail "mdm-detect: required_components control suffixを正規化して受理"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
/usr/bin/sed 's/"partial": \[\]/"partial": ["kit"]/' \
  "$_mdm_detect_receipt" > "$_mdm_detect_receipt.partial"
/bin/mv "$_mdm_detect_receipt.partial" "$_mdm_detect_receipt"
/bin/chmod 600 "$_mdm_detect_receipt"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: success receipt の non-empty partialを許可"
else
  pass "mdm-detect: success receipt は partial=[] に固定"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","safety_net"]'
_mdm_detect_missing_node_rc=0
_mdm_required_components_are_valid "$_mdm_detect_receipt" \
  || _mdm_detect_missing_node_rc=$?
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","node_runtime"]'
_mdm_detect_orphan_node_rc=0
_mdm_required_components_are_valid "$_mdm_detect_receipt" \
  || _mdm_detect_orphan_node_rc=$?
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","web_content_runtime"]'
_mdm_detect_web_missing_node_rc=0
_mdm_required_components_are_valid "$_mdm_detect_receipt" \
  || _mdm_detect_web_missing_node_rc=$?
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["biome","kit"]'
_mdm_detect_biome_native_rc=0
_mdm_required_components_are_valid "$_mdm_detect_receipt" \
  || _mdm_detect_biome_native_rc=$?
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["biome","kit","node_runtime"]'
_mdm_detect_biome_orphan_node_rc=0
_mdm_required_components_are_valid "$_mdm_detect_receipt" \
  || _mdm_detect_biome_orphan_node_rc=$?
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane \
  '["kit","node_runtime","safety_net"]'
if [[ "$_mdm_detect_missing_node_rc" -ne 0 \
  && "$_mdm_detect_orphan_node_rc" -ne 0 \
  && "$_mdm_detect_web_missing_node_rc" -ne 0 \
  && "$_mdm_detect_biome_native_rc" -eq 0 \
  && "$_mdm_detect_biome_orphan_node_rc" -ne 0 ]] \
  && _mdm_required_components_are_valid "$_mdm_detect_receipt"; then
  pass "mdm-detect: Node consumer依存を双方向に固定"
else
  fail "mdm-detect: Node runtime dependency contractが非対称"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
mkdir -p "$_mdm_detect_home/.local/bin" \
  "$_mdm_detect_home/.local/share/claude/versions"
/bin/cp /usr/bin/true "$_mdm_detect_home/.local/share/claude/versions/fake"
_mdm_detect_cli_absolute_target="$_mdm_detect_home/.local/share/claude/versions/fake"
_mdm_detect_cli_workspace="$_mdm_detect_private_base/cli-link-workspace"
mkdir -m 700 "$_mdm_detect_cli_workspace"
ln -s /usr/bin/true "$_mdm_detect_home/.local/bin/claude"
if _mdm_cli_present "$_mdm_detect_home" \
  "$MDM_DETECT_EXPECTED_UID_OVERRIDE" "$_mdm_detect_cli_workspace"; then
  fail "mdm-detect: arbitrary executable symlink was accepted as Claude CLI"
else
  pass "mdm-detect: arbitrary executable symlink is rejected"
fi
rm "$_mdm_detect_home/.local/bin/claude"
ln -s "$_mdm_detect_cli_absolute_target" \
  "$_mdm_detect_home/.local/bin/claude"
if _mdm_cli_present "$_mdm_detect_home" \
  "$MDM_DETECT_EXPECTED_UID_OVERRIDE" "$_mdm_detect_cli_workspace"; then
  fail "mdm-detect: wrong-signer binary in Claude versions tree was accepted"
else
  pass "mdm-detect: Claude CLI requires an Apple-anchored Anthropic signature"
fi
rm "$_mdm_detect_home/.local/bin/claude"

_mdm_detect_link_target='../share/claude/versions/fake'
ln -s "${_mdm_detect_link_target}" "$_mdm_detect_home/.local/bin/claude"
if [[ "$(_mdm_readlink_value "$_mdm_detect_home/.local/bin/claude")" \
  == "$_mdm_detect_link_target" ]]; then
  pass "mdm-detect: symlink target を末尾byteを失わず読み取る"
else
  fail "mdm-detect: 正常な CLI symlink target の読み取りに失敗"
fi

(
  _mdm_claude_cli_signature_trusted() { return 0; }
  _mdm_detect_cli_target_rc=0
  _mdm_detect_cli_present_rc=0
  _mdm_cli_target_path "$_mdm_detect_home" \
    "$MDM_DETECT_EXPECTED_UID_OVERRIDE" >/dev/null 2>&1 \
    || _mdm_detect_cli_target_rc=$?
  _mdm_cli_present "$_mdm_detect_home" \
    "$MDM_DETECT_EXPECTED_UID_OVERRIDE" "$_mdm_detect_cli_workspace" \
    >/dev/null 2>&1 || _mdm_detect_cli_present_rc=$?
  if [[ "$_mdm_detect_cli_target_rc" -ne 0 \
    && "$_mdm_detect_cli_present_rc" -ne 0 ]]; then
    pass "mdm-detect: Claude CLI activationをexact absolute targetへ固定"
  else
    fail "mdm-detect: relative Claude CLI activationを許可"
  fi
)
rm "$_mdm_detect_home/.local/bin/claude"
ln -s "$_mdm_detect_cli_absolute_target" \
  "$_mdm_detect_home/.local/bin/claude"
if [[ "$(_mdm_cli_activation_target "$_mdm_detect_home" \
    "$MDM_DETECT_EXPECTED_UID_OVERRIDE")" \
    == "$_mdm_detect_cli_absolute_target" ]]; then
  pass "mdm-detect: valid absolute Claude CLI activationを受理"
else
  fail "mdm-detect: valid absolute Claude CLI activationを拒否"
fi
(
  _mdm_stat_uid() {
    printf '%s' "$((MDM_DETECT_EXPECTED_UID_OVERRIDE + 1))"
  }
  if _mdm_cli_activation_target "$_mdm_detect_home" \
    "$MDM_DETECT_EXPECTED_UID_OVERRIDE" >/dev/null 2>&1; then
    fail "mdm-detect: 別UID所有のClaude CLI activationを許可"
  else
    pass "mdm-detect: Claude CLI activationを対象UIDへ束縛"
  fi
)
(
  _mdm_stat_metadata() {
    printf '1:Symbolic Link:0:%s:0777:2' \
      "$MDM_DETECT_EXPECTED_UID_OVERRIDE"
  }
  if _mdm_cli_activation_target "$_mdm_detect_home" \
    "$MDM_DETECT_EXPECTED_UID_OVERRIDE" >/dev/null 2>&1; then
    fail "mdm-detect: multi-link Claude CLI activationを許可"
  else
    pass "mdm-detect: Claude CLI activationをlink count 1へ固定"
  fi
)
rm "$_mdm_detect_home/.local/bin/claude"
_mdm_detect_newline_target="${_mdm_detect_link_target}"$'\n'
ln -s "$_mdm_detect_newline_target" "$_mdm_detect_home/.local/bin/claude"
if _mdm_readlink_value "$_mdm_detect_home/.local/bin/claude" \
  >/dev/null 2>&1; then
  fail "mdm-detect: 末尾LF付き CLI symlink target を正規化"
else
  pass "mdm-detect: CLI symlink target の末尾LFを検出して拒否"
fi
rm "$_mdm_detect_home/.local/bin/claude"
rm -rf "$_mdm_detect_cli_workspace"

if _mdm_mode_owner_executable 0700 \
  && ! _mdm_mode_owner_executable 0001 \
  && ! _mdm_mode_owner_executable 0611; then
  pass "mdm-detect: CLI/親directory はowner execute/searchを必須化"
else
  fail "mdm-detect: other execute bitを対象ユーザー権限と誤認"
fi
if [[ -x /usr/bin/codesign ]]; then
  (
    _cli_workspace="$_mdm_detect_private_base/cli-mode-workspace"
    mkdir -m 700 "$_cli_workspace"
    _mdm_claude_cli_signature_trusted() { return 0; }
    chmod 0401 "$_mdm_detect_home/.local/share/claude/versions/fake"
    ln -s "$_mdm_detect_cli_absolute_target" \
      "$_mdm_detect_home/.local/bin/claude"
    if _mdm_cli_present "$_mdm_detect_home" \
      "$MDM_DETECT_EXPECTED_UID_OVERRIDE" "$_cli_workspace"; then
      fail "mdm-detect: owner executeなし CLI をcompliant判定"
    else
      pass "mdm-detect: CLI実体に対象ownerのexecute bitを要求"
    fi
    chmod 0700 "$_mdm_detect_home/.local/share/claude/versions/fake"
    chmod 0611 "$_mdm_detect_home/.local/share"
    if _mdm_cli_present "$_mdm_detect_home" \
      "$MDM_DETECT_EXPECTED_UID_OVERRIDE" "$_cli_workspace"; then
      fail "mdm-detect: owner searchなし CLI parent をcompliant判定"
    else
      pass "mdm-detect: CLI parentに対象ownerのsearch bitを要求"
    fi
    chmod 0755 "$_mdm_detect_home/.local/share"
    chmod 0777 "$_mdm_detect_home/.local/share/claude"
    if _mdm_cli_present "$_mdm_detect_home" \
        "$MDM_DETECT_EXPECTED_UID_OVERRIDE" "$_cli_workspace" \
      || _mdm_cli_target_path "$_mdm_detect_home" \
        "$MDM_DETECT_EXPECTED_UID_OVERRIDE" >/dev/null 2>&1; then
      fail "mdm-detect: writable Claude CLI intermediate parentを許可"
    else
      pass "mdm-detect: Claude CLI intermediate parentもsafe modeへ固定"
    fi
    chmod 0755 "$_mdm_detect_home/.local/share/claude"
    rm "$_mdm_detect_home/.local/bin/claude"
    rm -rf "$_cli_workspace"
  )
else
  skip "mdm-detect: CLI owner execute/search integration" \
    "codesign unavailable on this platform"
fi

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

(
  _ghostty_fixture="$_mdm_detect_tmp/Ghostty.app"
  mkdir -p "$_ghostty_fixture/Contents/MacOS"
  printf 'ghostty\n' > "$_ghostty_fixture/Contents/MacOS/ghostty"
  chmod 755 "$_ghostty_fixture/Contents/MacOS/ghostty"
  _ghostty_requirement="$(_mdm_ghostty_codesign_requirement)"
  _ghostty_verify_args=""
  _ghostty_quarantined=false
  _ghostty_xattr_args=()
  _mdm_ghostty_codesign() {
    if [[ "$1" == -dv ]]; then
      printf '%s\n' \
        'Identifier=com.mitchellh.ghostty' \
        'Authority=Developer ID Application: Mitchell Hashimoto (24VZTF6M5V)' \
        'Authority=Developer ID Certification Authority' \
        'Authority=Apple Root CA' \
        'TeamIdentifier=24VZTF6M5V' >&2
      return 0
    fi
    _ghostty_verify_args="$*"
    [[ "$*" == *'--verify --deep --strict -R '* ]]
  }
  _mdm_ghostty_xattr() {
    _ghostty_xattr_args=("$@")
    [[ "$_ghostty_quarantined" == true ]]
  }
  if _mdm_ghostty_signature_trusted "$_ghostty_fixture" \
    && [[ "$_ghostty_requirement" == '=identifier "com.mitchellh.ghostty"'* \
      && "$_ghostty_requirement" == *'anchor apple generic'* \
      && "$_ghostty_requirement" == *'certificate 1[field.1.2.840.113635.100.6.2.6] exists'* \
      && "$_ghostty_requirement" == *'certificate leaf[field.1.2.840.113635.100.6.1.13] exists'* \
      && "$_ghostty_requirement" == *'certificate leaf[subject.OU] = "24VZTF6M5V"'* ]]; then
    pass "mdm-detect: GhosttyをApple Developer ID/identifier/teamへ固定"
  else
    fail "mdm-detect: Ghostty codesign trust contractが不正"
  fi
  _ghostty_quarantined=true
  if _mdm_ghostty_signature_trusted "$_ghostty_fixture"; then
    fail "mdm-detect: quarantine付きGhosttyをcompliant判定"
  elif [[ "${#_ghostty_xattr_args[@]}" -eq 4 \
    && "${_ghostty_xattr_args[0]}" == -p \
    && "${_ghostty_xattr_args[1]}" == com.apple.quarantine \
    && "${_ghostty_xattr_args[2]}" == -- \
    && "${_ghostty_xattr_args[3]}" == "$_ghostty_fixture" ]]; then
    pass "mdm-detect: quarantine付きGhosttyをnon-compliant判定"
  else
    fail "mdm-detect: Ghostty quarantine検査の引数が不正"
  fi
  _ghostty_quarantined=false
  _mdm_ghostty_codesign() {
    if [[ "$1" == -dv ]]; then
      printf '%s\n' \
        'Identifier=com.mitchellh.ghostty' \
        'Authority=Developer ID Application: Spoof (24VZTF6M5V)' \
        'Authority=Developer ID Certification Authority' \
        'Authority=Apple Root CA' \
        'TeamIdentifier=24VZTF6M5V' >&2
    fi
    return 0
  }
  if _mdm_ghostty_signature_trusted "$_ghostty_fixture"; then
    fail "mdm-detect: Ghosttyのspoofed Authority表示を許可"
  else
    pass "mdm-detect: Ghostty codesign詳細もexactに検証"
  fi
  rm "$_ghostty_fixture/Contents/MacOS/ghostty"
  ln -s /usr/bin/true "$_ghostty_fixture/Contents/MacOS/ghostty"
  if _mdm_ghostty_signature_trusted "$_ghostty_fixture"; then
    fail "mdm-detect: symlink Ghostty executableを許可"
  else
    pass "mdm-detect: Ghostty actual executableをregular fileへ固定"
  fi
  rm -rf "$_ghostty_fixture"
)

_mdm_detect_font_fixture="$_mdm_detect_tmp/font-magic"
printf '\000\001\000\000font' > "$_mdm_detect_font_fixture"
_mdm_detect_ttf_ok=0
_mdm_ttf_magic_is_valid "$_mdm_detect_font_fixture" \
  || _mdm_detect_ttf_ok=$?
printf 'OTTOfont' > "$_mdm_detect_font_fixture"
_mdm_detect_otf_ok=0
_mdm_ttf_magic_is_valid "$_mdm_detect_font_fixture" \
  || _mdm_detect_otf_ok=$?
printf 'fakefont' > "$_mdm_detect_font_fixture"
if [[ "$_mdm_detect_ttf_ok" -eq 0 && "$_mdm_detect_otf_ok" -eq 0 ]] \
  && ! _mdm_ttf_magic_is_valid "$_mdm_detect_font_fixture"; then
  pass "mdm-detect: attested fontにTrueType/OpenType magicを要求"
else
  fail "mdm-detect: font magic検証が不正"
fi
rm "$_mdm_detect_font_fixture"

_mdm_detect_font_inventory_count="$(_mdm_font_expected_inventory | wc -l \
  | tr -d '[:space:]')"
_mdm_detect_font_record="$(_mdm_font_expected_record \
  IBMPlexMono-Regular.ttf)"
_mdm_detect_fake_pinned_font="$_mdm_detect_tmp/IBMPlexMono-Regular.ttf"
printf '\000\001\000\000fake' > "$_mdm_detect_fake_pinned_font"
if [[ "$_mdm_detect_font_inventory_count" == 20 \
  && "$_mdm_detect_font_record" \
    == $'fe11304a5fe956d5744e9b6a246cc83d90425245e75a62230044966ca96a7f50\tibm' ]] \
  && ! _mdm_font_expected_record IBMPlexMono-Unknown.ttf >/dev/null 2>&1 \
  && ! _mdm_font_file_is_trusted "$_mdm_detect_fake_pinned_font" \
    >/dev/null 2>&1; then
  pass "mdm-detect: fontsをexact20 path/pinned SHA/internal identityへ固定"
else
  fail "mdm-detect: managed font inventory/provenance contractが不正"
fi
rm "$_mdm_detect_fake_pinned_font"

# Legacy receipts and unsuccessful runs never become compliant.
_mdm_detect_write_receipt '"2"' success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: string型 receipt schema_version を許可"
else
  pass "mdm-detect: receipt JSON scalar型をfail-closedで検証"
fi
_mdm_detect_write_receipt 1 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: legacy receipt schema was accepted"
else
  pass "mdm-detect: only receipt schema v3 is accepted"
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

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]' \
  0.73.0 "$_mdm_detect_install" "$((_mdm_detect_fixture_uid + 1))"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: receiptの別target_uidを許可"
else
  pass "mdm-detect: receiptを現在のatomic target UIDへ束縛"
fi

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]' \
  0.73.0 "$_mdm_detect_install" "$_mdm_detect_fixture_uid" \
  00000000-ABCD-1234-ABCD-1234567890EF
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: receiptの別target_generated_uidを許可"
else
  pass "mdm-detect: receiptを現在のatomic GeneratedUIDへ束縛"
fi

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]' \
  0.73.0 "$_mdm_detect_install" '"501"'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: string型 target_uidを許可"
else
  pass "mdm-detect: receipt target identityのJSON型を検証"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
/usr/bin/sed -E \
  's/"component_manifest_sha256": "[0-9a-f]+"/"component_manifest_sha256": 7/' \
  "$_mdm_detect_receipt" > "$_mdm_detect_receipt.typed"
mv "$_mdm_detect_receipt.typed" "$_mdm_detect_receipt"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: numeric component_manifest_sha256を許可"
else
  pass "mdm-detect: receipt component attestationのJSON型を検証"
fi
_mdm_detect_write_receipt 2 success "${_mdm_detect_sha:0:39}" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: abbreviated resolved SHA was accepted"
else
  pass "mdm-detect: resolved SHA must be full length"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
/usr/bin/sed \
  's/"git_ref": "[0-9a-f]*"/"git_ref": "0000000000000000000000000000000000000000"/' \
  "$_mdm_detect_receipt" > "$_mdm_detect_receipt.git-ref"
/bin/mv "$_mdm_detect_receipt.git-ref" "$_mdm_detect_receipt"
/bin/chmod 600 "$_mdm_detect_receipt"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: receipt git_ref/resolved_sha mismatchを許可"
else
  pass "mdm-detect: success receiptはfull SHA git_refへ固定"
fi
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane 0000000000000000000000000000000000000000; then
  fail "mdm-detect: expected commit mismatch was accepted"
else
  pass "mdm-detect: expected commit mismatch is rejected"
fi
_mdm_detect_other_policy=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if mdm_detect "$_mdm_detect_receipt" jane "$_mdm_detect_sha" \
  "$_mdm_detect_other_policy"; then
  fail "mdm-detect: desired policy mismatch を許可"
else
  pass "mdm-detect: 同一commitでもdesired policy driftを検出"
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
chmod 600 "$_mdm_detect_receipt"

chmod 644 "$_mdm_detect_receipt"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: legacy mode 0644 receiptを許可"
else
  pass "mdm-detect: root receiptをexact mode 0600へ固定"
fi
chmod 600 "$_mdm_detect_receipt"

ln "$_mdm_detect_receipt" "$_mdm_detect_receipt.peer"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: hardlink receiptを許可"
else
  pass "mdm-detect: root receiptはlink count 1を必須化"
fi
rm "$_mdm_detect_receipt.peer"
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

_mdm_detect_manifest_peer="$_mdm_detect_tmp/manifest.peer"
mv "$_mdm_detect_manifest" "$_mdm_detect_manifest_peer"
ln "$_mdm_detect_manifest_peer" "$_mdm_detect_manifest"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: hardlink manifest を許可"
else
  pass "mdm-detect: manifest は link count 1 に固定"
fi
rm "$_mdm_detect_manifest"
mv "$_mdm_detect_manifest_peer" "$_mdm_detect_manifest"

if _mdm_is_darwin \
  && chmod +a 'everyone allow write' "$_mdm_detect_manifest" 2>/dev/null; then
  if mdm_detect "$_mdm_detect_receipt" jane; then
    fail "mdm-detect: ACL付き manifest を許可"
  else
    pass "mdm-detect: manifest ACL を拒否"
  fi
  chmod -N "$_mdm_detect_manifest"
else
  skip "mdm-detect: manifest ACL を拒否" \
    "ACL fixture unavailable on this platform"
fi

/usr/bin/sed 's/"mdm_managed": true/"mdm_managed": "true"/' \
  "$_mdm_detect_manifest" > "$_mdm_detect_manifest.typed"
mv "$_mdm_detect_manifest.typed" "$_mdm_detect_manifest"
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: string型 mdm_managed をbooleanとして許可"
else
  pass "mdm-detect: manifest JSON scalar型をfail-closedで検証"
fi
_mdm_detect_write_manifest
_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]'

{
  printf '{\n'
  printf '  "version": "2",\n'
  printf '  "timestamp": "2026-07-17T00:00:00Z",\n'
  printf '  "kit_version": "0.73.0",\n'
  printf '  "kit_commit": "%s",\n' "$_mdm_detect_short"
  printf '  "profile": "standard",\n'
  printf '  "language": "ja",\n'
  printf '  "editor": "vscode",\n'
  printf '  "commit_attribution": "false",\n'
  printf '  "new_init": "false",\n'
  printf '  "plugins": "",\n'
  printf '  "codex_plugin": "false",\n'
  printf '  "files": [\n'
  _mdm_detect_index=0
  while [[ "$_mdm_detect_index" -le 1000 ]]; do
    printf '    "%s"' "$_mdm_detect_claude/settings.json"
    [[ "$_mdm_detect_index" -eq 1000 ]] || printf ','
    printf '\n'
    _mdm_detect_index=$((_mdm_detect_index + 1))
  done
  printf '  ],\n'
  printf '  "cleanup_paths": [],\n'
  printf '  "mdm_absent_files": [],\n'
  printf '  "mdm_managed": true,\n'
  printf '  "snapshot_dir": "%s",\n' "$_mdm_detect_snapshot"
  printf '  "claude_dir": "%s",\n' "$_mdm_detect_claude"
  printf '  "policy_sha256": "%s"\n}\n' "$_mdm_detect_policy_sha"
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
printf '%s\n# managed\0hidden\n%s\n# user\npersonal\n' \
  "$_MDM_MARKER_BEGIN" "$_MDM_MARKER_END" > "$_mdm_detect_claude/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: managed section の NUL suffix を許可"
else
  pass "mdm-detect: managed section はNULを含まないbyte-exact textに固定"
fi
mv "$_mdm_detect_tmp/claude.saved" "$_mdm_detect_claude/CLAUDE.md"

cp "$_mdm_detect_claude/CLAUDE.md" "$_mdm_detect_tmp/claude.saved"
printf '%s\n# managed\n%s\n# user\npersonal' \
  "$_MDM_MARKER_BEGIN" "$_MDM_MARKER_END" > "$_mdm_detect_claude/CLAUDE.md"
if mdm_detect "$_mdm_detect_receipt" jane; then
  fail "mdm-detect: LFなしEOFの CLAUDE.md を許可"
else
  pass "mdm-detect: managed section 入力は末尾LFを必須化"
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
cp "$_mdm_detect_install/.git/config" "$_mdm_detect_tmp/git-config.saved"
cp "$_mdm_detect_install/file" "$_mdm_detect_tmp/git-file.saved"
{
  printf '\n[filter "mdm-pwn"]\n'
  printf '\tclean = /usr/bin/touch %s\n' "$_mdm_detect_filter_canary"
} >> "$_mdm_detect_install/.git/config"
printf 'file filter=mdm-pwn\n' > "$_mdm_detect_install/.gitattributes"
printf 'changed\n' > "$_mdm_detect_install/file"
if ! _mdm_detect_component_check \
  && [[ ! -e "$_mdm_detect_filter_canary" ]]; then
  pass "mdm-detect: Git configを実行せずcheckout driftを拒否"
else
  fail "mdm-detect: target Git configurationがroot検出へ影響"
fi
mv "$_mdm_detect_tmp/git-config.saved" "$_mdm_detect_install/.git/config"
mv "$_mdm_detect_tmp/git-file.saved" "$_mdm_detect_install/file"
rm "$_mdm_detect_install/.gitattributes"

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
_mdm_detect_small_timeout="$(_mdm_snapshot_timeout_for_size 1024)"
_mdm_detect_cli_timeout="$(_mdm_snapshot_timeout_for_size 255852544)"
_mdm_detect_max_timeout="$(_mdm_snapshot_timeout_for_size 536870912)"
if [[ "$_mdm_detect_small_timeout" == 5 \
  && "$_mdm_detect_cli_timeout" -gt "$_mdm_detect_small_timeout" \
  && "$_mdm_detect_max_timeout" -le 60 ]]; then
  pass "mdm-detect: snapshot timeoutはsize比例かつ上限付き"
else
  fail "mdm-detect: 大容量CLIに固定5秒timeoutを適用"
fi
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
    standard ja "$_mdm_detect_deployment_hash" "$_mdm_detect_policy_sha" \
    "$_mdm_detect_budget_workspace" "$MDM_DETECT_EXPECTED_UID_OVERRIDE"; then
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
(
  export MDM_EUID_OVERRIDE=501
  _mdm_detect_main_rc=0
  _mdm_detect_main_out="$(mdm_detect_main \
    --expected-commit "$_mdm_detect_sha" \
    --expected-policy-sha256 "$_mdm_detect_policy_sha")" \
    || _mdm_detect_main_rc=$?
  if [[ "$_mdm_detect_main_rc" -eq 4 \
    && "$_mdm_detect_main_out" == 'indeterminate: root privileges required' ]]; then
    pass "mdm-detect: non-root self-checkをindeterminateへ分離"
  else
    fail "mdm-detect: non-rootがcompliant/non-compliantを判定 (rc=$_mdm_detect_main_rc)"
  fi
)
for _mdm_detect_implicit_user in '' root Root _mbsetupuser _MBSetupUser \
  _unresolved _UNRESOLVED loginwindow LoginWindow daemon nobody; do
  (
    _mdm_detect_console_user() { printf '%s' "$_mdm_detect_implicit_user"; }
    _mdm_detect_main_rc=0
    _mdm_detect_main_out="$(mdm_detect_main \
      --expected-commit "$_mdm_detect_sha" \
      --expected-policy-sha256 "$_mdm_detect_policy_sha")" \
      || _mdm_detect_main_rc=$?
    if [[ "$_mdm_detect_main_rc" -eq 3 \
      && "$_mdm_detect_main_out" \
        == 'not-applicable: no eligible console user' ]]; then
      pass "mdm-detect: 対象外console userをremediation対象から分離"
    else
      fail "mdm-detect: 対象外console userのstatusが不正 ($_mdm_detect_implicit_user rc=$_mdm_detect_main_rc)"
    fi
  )
done
for _mdm_detect_explicit_system_user in root Root _mbsetupuser _unresolved \
  _UNRESOLVED LoginWindow daemon nobody; do
  _mdm_detect_main_rc=0
  mdm_detect_main --user "$_mdm_detect_explicit_system_user" \
    --expected-commit "$_mdm_detect_sha" \
    --expected-policy-sha256 "$_mdm_detect_policy_sha" >/dev/null 2>&1 \
    || _mdm_detect_main_rc=$?
  if [[ "$_mdm_detect_main_rc" -eq 2 ]]; then
    pass "mdm-detect: explicit system userをusage errorで拒否"
  else
    fail "mdm-detect: explicit system userのstatusが不正 ($_mdm_detect_explicit_system_user rc=$_mdm_detect_main_rc)"
  fi
done

for _mdm_detect_missing_desired in commit policy; do
  _mdm_detect_main_rc=0
  if [[ "$_mdm_detect_missing_desired" == commit ]]; then
    mdm_detect_main --expected-policy-sha256 "$_mdm_detect_policy_sha" \
      >/dev/null 2>&1 || _mdm_detect_main_rc=$?
  else
    mdm_detect_main --expected-commit "$_mdm_detect_sha" \
      >/dev/null 2>&1 || _mdm_detect_main_rc=$?
  fi
  if [[ "$_mdm_detect_main_rc" -eq 2 ]]; then
    pass "mdm-detect: desired commit/policy引数を必須化 ($_mdm_detect_missing_desired)"
  else
    fail "mdm-detect: desired state引数欠落を許可 ($_mdm_detect_missing_desired rc=$_mdm_detect_main_rc)"
  fi
done

_mdm_detect_main_rc=0
_mdm_detect_main_out="$(mdm_detect_main --expected-commit "$_mdm_detect_sha" \
  --expected-policy-sha256 "$_mdm_detect_policy_sha")" \
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
    --expected-commit "$_mdm_detect_sha" \
    --expected-policy-sha256 "$_mdm_detect_policy_sha" \
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
  mdm_detect_main --user "$_mdm_detect_bad_user" \
    --expected-commit "$_mdm_detect_sha" \
    --expected-policy-sha256 "$_mdm_detect_policy_sha" >/dev/null 2>&1 \
    || _mdm_detect_main_rc=$?
  if [[ "$_mdm_detect_main_rc" -eq 2 ]]; then
    pass "mdm-detect: path-like username を拒否 ($_mdm_detect_bad_user)"
  else
    fail "mdm-detect: 不正 username を許可 ($_mdm_detect_bad_user rc=$_mdm_detect_main_rc)"
  fi
done

_mdm_detect_main_rc=0
mdm_detect_main --min-version 0.74.0 --expected-commit "$_mdm_detect_sha" \
  --expected-policy-sha256 "$_mdm_detect_policy_sha" >/dev/null 2>&1 \
  || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 1 ]]; then
  pass "mdm-detect: deployment below minimum version is non-compliant"
else
  fail "mdm-detect: minimum-version failure returned $_mdm_detect_main_rc"
fi

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]' \
  '0.73.0-rc.1'
_mdm_detect_main_rc=0
mdm_detect_main --min-version 0.73.0 --expected-commit "$_mdm_detect_sha" \
  --expected-policy-sha256 "$_mdm_detect_policy_sha" >/dev/null 2>&1 \
  || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 1 ]]; then
  pass "mdm-detect: prerelease は同じ core の final 要件を満たさない"
else
  fail "mdm-detect: prerelease を final 以上として許可 (rc=$_mdm_detect_main_rc)"
fi

_mdm_detect_write_receipt 2 success "$_mdm_detect_sha" jane '["kit"]' \
  '0.73.0+build.7'
_mdm_detect_main_rc=0
mdm_detect_main --min-version 0.73.0 --expected-commit "$_mdm_detect_sha" \
  --expected-policy-sha256 "$_mdm_detect_policy_sha" >/dev/null 2>&1 \
  || _mdm_detect_main_rc=$?
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
    --expected-commit "$_mdm_detect_sha" \
    --expected-policy-sha256 "$_mdm_detect_policy_sha" >/dev/null 2>&1 \
  || _mdm_detect_main_rc=$?
if [[ "$_mdm_detect_main_rc" -eq 4 ]]; then
  pass "mdm-detect: production entrypoint discards test/root overrides"
else
  fail "mdm-detect: production privilege isolation failed (rc=$_mdm_detect_main_rc)"
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
_mdm_detect_launcher_copy=""
if _mdm_launcher_snapshot \
    "$PROJECT_DIR/mdm/detect-mdm.sh" _mdm_detect_launcher_copy \
  && cmp -s "$PROJECT_DIR/mdm/detect-mdm.sh" "$_mdm_detect_launcher_copy" \
  && [[ "$(_mdm_stat_mode "$_mdm_detect_launcher_copy")" == 500 ]] \
  && _mdm_launcher_mode_safe 755 \
  && ! _mdm_launcher_mode_safe 775 \
  && grep -q '"$_mode" == 1777' "$PROJECT_DIR/mdm/detect-mdm.sh" \
  && [[ "$(grep -c "'%i:%z'" "$PROJECT_DIR/mdm/detect-mdm.sh")" -ge 2 ]] \
  && grep -Fq \
    '_mdm_launcher_snapshot "$_mdm_clean_script" _mdm_clean_snapshot' \
    "$PROJECT_DIR/mdm/detect-mdm.sh" \
  && ! grep -Fq 'exec /usr/bin/env -i' "$PROJECT_DIR/mdm/detect-mdm.sh" \
  && /usr/bin/awk '
    /^[[:space:]]*if ! \. "\$_mdm_script"; then$/ { source_line = NR }
    source_line && !source_end && /^[[:space:]]*fi$/ { source_end = NR }
    source_end && NR == source_end + 1 && /\/bin\/rm -f "\$_mdm_script"/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$PROJECT_DIR/mdm/detect-mdm.sh"; then
  pass "mdm-detect: launcher snapshot and sticky-parent mode contract are enforced"
else
  fail "mdm-detect: launcher snapshot or parent mode contract is incomplete"
fi
rm -f "$_mdm_detect_launcher_copy"

# The parent owns the snapshot pathname before copying begins and retains its
# cleanup traps while the clean shell starts. Exercise all catchable signals
# during copy and after handoff, plus ordinary EXIT and the pre-snapshot state.
(
  _mdm_detect_launcher_signal_base=/tmp
  _mdm_is_darwin && _mdm_detect_launcher_signal_base=/private/tmp
  _mdm_detect_launcher_signal_dir="$_mdm_detect_tmp/launcher-signal"
  mkdir "$_mdm_detect_launcher_signal_dir"

  _mdm_detect_arm_launcher_cleanup() {
    trap '_mdm_launcher_cleanup_snapshot' EXIT
    trap '_mdm_launcher_exit_on_signal HUP 129' HUP
    trap '_mdm_launcher_exit_on_signal INT 130' INT
    trap '_mdm_launcher_exit_on_signal TERM 143' TERM
  }

  _mdm_detect_launcher_copy_signal_case() { # <signal> <exit-code>
    local _signal="$1" _expected="$2" _fifo _record _token _candidate _rc=0
    _fifo="$_mdm_detect_launcher_signal_dir/copy-$_signal.fifo"
    _record="$_mdm_detect_launcher_signal_dir/copy-$_signal.path"
    _token="launcher-copy-$_signal-$$"
    /usr/bin/mkfifo "$_fifo"
    (
      _mdm_clean_snapshot=""
      _mdm_detect_arm_launcher_cleanup
      {
        printf '%s\n' "$_token"
        _mdm_detect_slow_count=0
        while [[ "$_mdm_detect_slow_count" -lt 40 ]]; do
          printf '.\n'
          /bin/sleep 0.01
          _mdm_detect_slow_count=$((_mdm_detect_slow_count + 1))
        done
      } > "$_fifo" &
      /bin/sh -c '
        target=$PPID
        count=0
        while [ "$count" -lt 300 ]; do
          for candidate in "$2"/claude-kit-mdm-launcher.*; do
            if [ -f "$candidate" ] \
              && /usr/bin/grep -Fq -- "$3" "$candidate"; then
              printf "%s" "$candidate" > "$4"
              /bin/kill "-$1" "$target"
              exit $?
            fi
          done
          /bin/sleep 0.01
          count=$((count + 1))
        done
        exit 90
      ' launcher-signal "$_signal" "$_mdm_detect_launcher_signal_base" \
        "$_token" "$_record" &
      _mdm_launcher_snapshot "$_fifo" _mdm_clean_snapshot
      exit 91
    ) || _rc=$?
    _candidate="$(/bin/cat "$_record" 2>/dev/null || true)"
    if [[ "$_rc" -eq "$_expected" && -n "$_candidate" \
      && "$_candidate" != *$'\n'* && ! -e "$_candidate" ]]; then
      pass "mdm-detect: copy中の$_signal でlauncher snapshotを回収"
    else
      fail "mdm-detect: copy中の$_signal cleanupが不正 (rc=$_rc)"
    fi
    [[ -z "$_candidate" ]] || /bin/rm -f "$_candidate"
    /bin/rm -f "$_fifo" "$_record"
  }

  _mdm_detect_launcher_handoff_signal_case() { # <signal> <exit-code>
    local _signal="$1" _expected="$2" _record _candidate _rc=0
    _record="$_mdm_detect_launcher_signal_dir/handoff-$_signal.path"
    (
      _mdm_clean_snapshot=""
      _mdm_detect_arm_launcher_cleanup
      _mdm_launcher_snapshot \
        "$PROJECT_DIR/mdm/detect-mdm.sh" _mdm_clean_snapshot || exit 90
      printf '%s' "$_mdm_clean_snapshot" > "$_record"
      /bin/sh -c '/bin/kill "-$1" "$PPID"' launcher-signal "$_signal"
      exit 91
    ) || _rc=$?
    _candidate="$(/bin/cat "$_record" 2>/dev/null || true)"
    if [[ "$_rc" -eq "$_expected" && -n "$_candidate" \
      && "$_candidate" != *$'\n'* && ! -e "$_candidate" ]]; then
      pass "mdm-detect: handoff後の$_signal でlauncher snapshotを回収"
    else
      fail "mdm-detect: handoff後の$_signal cleanupが不正 (rc=$_rc)"
    fi
    [[ -z "$_candidate" ]] || /bin/rm -f "$_candidate"
    /bin/rm -f "$_record"
  }

  _mdm_detect_launcher_copy_signal_case HUP 129
  _mdm_detect_launcher_copy_signal_case INT 130
  _mdm_detect_launcher_copy_signal_case TERM 143
  _mdm_detect_launcher_handoff_signal_case HUP 129
  _mdm_detect_launcher_handoff_signal_case INT 130
  _mdm_detect_launcher_handoff_signal_case TERM 143

  _mdm_detect_launcher_supervisor_signal_case() { # <signal> <exit-code>
    local _signal="$1" _expected="$2" _ready _marker _foreground _snapshot
    local _observed _foreground_pid _rc=0
    _ready="$_mdm_detect_launcher_signal_dir/supervisor-$_signal.ready"
    _marker="$_mdm_detect_launcher_signal_dir/supervisor-$_signal.marker"
    _foreground="$_mdm_detect_launcher_signal_dir/supervisor-$_signal.foreground"
    _snapshot="$_mdm_detect_launcher_signal_dir/supervisor-$_signal.snapshot"
    (
      _mdm_clean_snapshot="$_snapshot"
      _mdm_clean_child_pid=""
      _mdm_clean_child_pgid=""
      _mdm_clean_child_starting=0
      printf '%s\n' snapshot > "$_mdm_clean_snapshot"
      _mdm_detect_arm_launcher_cleanup
      set -m
      /bin/bash --noprofile --norc -c '
        _ready=$1
        _marker=$2
        _mdm_child_hup() { printf "%s" HUP > "$_marker"; exit 129; }
        _mdm_child_int() { printf "%s" INT > "$_marker"; exit 130; }
        _mdm_child_term() { printf "%s" TERM > "$_marker"; exit 143; }
        trap _mdm_child_hup HUP
        trap _mdm_child_int INT
        trap _mdm_child_term TERM
        : > "$_ready"
        /bin/sh -c '\''printf "%s" "$$" > "$1"; exec /bin/sleep 10'\'' \
          launcher-foreground "$3"
        exit 92
      ' launcher-child "$_ready" "$_marker" "$_foreground" 2>/dev/null &
      _mdm_clean_child_pid=$!
      _mdm_clean_child_pgid="$_mdm_clean_child_pid"
      set +m
      _mdm_detect_ready_count=0
      while [[ ( ! -e "$_ready" || ! -s "$_foreground" ) \
        && "$_mdm_detect_ready_count" -lt 300 ]]; do
        /bin/sleep 0.01
        _mdm_detect_ready_count=$((_mdm_detect_ready_count + 1))
      done
      if [[ ! -e "$_ready" || ! -s "$_foreground" ]]; then
        /bin/kill -TERM -- "-$_mdm_clean_child_pgid" 2>/dev/null || true
        wait "$_mdm_clean_child_pid" 2>/dev/null || true
        _mdm_clean_child_pid=""
        _mdm_clean_child_pgid=""
        exit 90
      fi
      /bin/sh -c '/bin/kill "-$1" "$PPID"' launcher-signal "$_signal"
      exit 91
    ) || _rc=$?
    _observed="$(/bin/cat "$_marker" 2>/dev/null || true)"
    _foreground_pid="$(/bin/cat "$_foreground" 2>/dev/null || true)"
    if [[ "$_rc" -eq "$_expected" && "$_observed" == "$_signal" \
      && "$_foreground_pid" =~ ^[1-9][0-9]*$ ]] \
      && ! /bin/kill -0 "$_foreground_pid" 2>/dev/null \
      && [[ ! -e "$_snapshot" ]]; then
      pass "mdm-detect: outer $_signal をchild groupへ転送して回収"
    else
      fail "mdm-detect: outer $_signal supervisorが不正 (rc=$_rc child=$_observed)"
    fi
    [[ ! "$_foreground_pid" =~ ^[1-9][0-9]*$ ]] \
      || /bin/kill -TERM "$_foreground_pid" 2>/dev/null || true
    /bin/rm -f "$_ready" "$_marker" "$_foreground" "$_snapshot"
  }

  _mdm_detect_launcher_supervisor_signal_case HUP 129
  _mdm_detect_launcher_supervisor_signal_case INT 130
  _mdm_detect_launcher_supervisor_signal_case TERM 143

  _mdm_detect_launcher_starting_signal_case() { # <signal> <exit-code>
    local _signal="$1" _expected="$2" _pid_record _snapshot _child _rc=0
    _pid_record="$_mdm_detect_launcher_signal_dir/starting-$_signal.pid"
    _snapshot="$_mdm_detect_launcher_signal_dir/starting-$_signal.snapshot"
    (
      _mdm_clean_snapshot="$_snapshot"
      _mdm_clean_child_pid=""
      _mdm_clean_child_pgid=""
      _mdm_clean_child_starting=0
      printf '%s\n' snapshot > "$_mdm_clean_snapshot"
      _mdm_detect_arm_launcher_cleanup
      set -m
      _mdm_clean_child_starting=1
      /bin/sleep 10 >/dev/null 2>&1 &
      printf '%s' "$!" > "$_pid_record"
      /bin/sh -c '/bin/kill "-$1" "$PPID"' launcher-signal "$_signal"
      exit 91
    ) >/dev/null 2>&1 || _rc=$?
    _child="$(/bin/cat "$_pid_record" 2>/dev/null || true)"
    if [[ "$_rc" -eq "$_expected" && "$_child" =~ ^[1-9][0-9]*$ ]] \
      && ! /bin/kill -0 "$_child" 2>/dev/null \
      && [[ ! -e "$_snapshot" ]]; then
      pass "mdm-detect: child PID handoff前のouter $_signal もorphanなく回収"
    else
      fail "mdm-detect: child PID handoff前のouter $_signal cleanupが不正 (rc=$_rc)"
    fi
    [[ ! "$_child" =~ ^[1-9][0-9]*$ ]] \
      || /bin/kill -TERM "$_child" 2>/dev/null || true
    /bin/rm -f "$_pid_record" "$_snapshot"
  }

  _mdm_detect_launcher_starting_signal_case HUP 129
  _mdm_detect_launcher_starting_signal_case INT 130
  _mdm_detect_launcher_starting_signal_case TERM 143

  _mdm_detect_launcher_exit_record="$_mdm_detect_launcher_signal_dir/exit.path"
  _mdm_detect_launcher_exit_rc=0
  (
    _mdm_clean_snapshot=""
    _mdm_detect_arm_launcher_cleanup
    _mdm_launcher_snapshot \
      "$PROJECT_DIR/mdm/detect-mdm.sh" _mdm_clean_snapshot || exit 90
    printf '%s' "$_mdm_clean_snapshot" > "$_mdm_detect_launcher_exit_record"
    exit 77
  ) || _mdm_detect_launcher_exit_rc=$?
  _mdm_detect_launcher_exit_candidate="$(
    /bin/cat "$_mdm_detect_launcher_exit_record" 2>/dev/null || true
  )"
  if [[ "$_mdm_detect_launcher_exit_rc" -eq 77 \
    && -n "$_mdm_detect_launcher_exit_candidate" \
    && ! -e "$_mdm_detect_launcher_exit_candidate" ]]; then
    pass "mdm-detect: launcher snapshotを通常EXITで回収"
  else
    fail "mdm-detect: launcher snapshotのEXIT cleanupが不正"
  fi
  [[ -z "$_mdm_detect_launcher_exit_candidate" ]] \
    || /bin/rm -f "$_mdm_detect_launcher_exit_candidate"
  /bin/rm -f "$_mdm_detect_launcher_exit_record"

  _mdm_detect_launcher_original="$_mdm_detect_launcher_signal_dir/original.sh"
  printf '%s\n' original > "$_mdm_detect_launcher_original"
  _mdm_detect_launcher_pre_rc=0
  (
    _mdm_clean_script="$_mdm_detect_launcher_original"
    _mdm_clean_snapshot=""
    _mdm_detect_arm_launcher_cleanup
    /bin/sh -c '/bin/kill -TERM "$PPID"'
    exit 91
  ) || _mdm_detect_launcher_pre_rc=$?
  if [[ "$_mdm_detect_launcher_pre_rc" -eq 143 \
    && "$(/bin/cat "$_mdm_detect_launcher_original")" == original ]]; then
    pass "mdm-detect: snapshot取得前のsignalは原本を変更しない"
  else
    fail "mdm-detect: snapshot取得前のsignalが原本へ影響"
  fi
  /bin/rm -f "$_mdm_detect_launcher_original"
  /bin/rmdir "$_mdm_detect_launcher_signal_dir"
)

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
