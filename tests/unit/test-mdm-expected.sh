#!/bin/bash
# tests/unit/test-mdm-expected.sh - Independent MDM expected-tree renderer tests

_test_mdm_expected_main() {
local RENDERER="$PROJECT_DIR/mdm/render-expected.py"
local PYTHON=/usr/bin/python3
local _expected_tmp _logical_home _shell_settings _shell_claude
local _shell_paths _shell_modes _renderer_output _builder_bash _candidate _major
local _oracle_rc _render_rc _payload_mismatch _path _tail _feature _relative _source
local _manifest_check _fixture _bad_rc _unsafe_parent _unknown _unknown_rejected
local _case_root _case_dir _case _case_profile _case_language _case_render _parity_fail
_expected_tmp="$(mktemp -d)"
chmod 700 "$_expected_tmp"
_logical_home=/Users/mdm-fixture
_case_root="$_expected_tmp/cases"
_case_dir="$_case_root/standard-ja"
_shell_settings="$_case_dir/shell-settings.json"
_shell_claude="$_case_dir/shell-claude.md"
_shell_paths="$_case_dir/shell-paths"
_shell_modes="$_case_dir/shell-modes.tsv"
_renderer_output="$_case_dir/rendered"

# The MDM runner itself may be macOS Bash 3.2. Run only the current shell
# builder oracle in a proven Bash 4+ child; never source it into this process.
for _candidate in "$(command -v bash 2>/dev/null || true)" \
  /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
  [[ "$_candidate" == /* && -x "$_candidate" ]] || continue
  _major="$("$_candidate" -c 'printf "%s" "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
  if [[ "$_major" =~ ^[0-9]+$ && "$_major" -ge 4 ]]; then
    _builder_bash="$_candidate"
    break
  fi
done
if [[ -z "$_builder_bash" ]]; then
  fail "mdm-expected: Bash 4+ shell-builder oracle is unavailable"
  rm -rf "$_expected_tmp"
  return 0
fi

_oracle_rc=0
"$_builder_bash" -c '
set -euo pipefail
PROJECT_DIR="$1"
case_root="$2"
logical_home="$3"
source "$PROJECT_DIR/setup.sh"
render_case() (
profile="$1"
language="$2"
output="$case_root/$profile-$language"
mkdir -p "$output"
source "$PROJECT_DIR/lib/colors.sh"
source "$PROJECT_DIR/lib/prerequisites.sh"
source "$PROJECT_DIR/profiles/$profile.conf"
ENABLE_AUTO_UPDATE=false
ENABLE_WEB_CONTENT_UPDATE=false
ENABLE_CODEX_PLUGIN=false
ENABLE_GHOSTTY_SETUP=false
ENABLE_FONTS_SETUP=false
COMMIT_ATTRIBUTION=false
if [[ "$profile/$language" == standard/ja ]]; then
  ENABLE_DOC_SIZE_GUARD=true
  COMMIT_ATTRIBUTION=true
fi
LANGUAGE="$language"
KIT_MDM_MANAGED=true
KIT_MDM_ASYNC_HOOKS=false
_SETUP_TMP_FILES=()
source "$PROJECT_DIR/lib/features.sh"
source "$PROJECT_DIR/lib/template.sh"
source "$PROJECT_DIR/lib/json-builder.sh"
source "$PROJECT_DIR/lib/deploy.sh"
HOME="$logical_home"
build_settings_file "$output/shell-settings.json" >/dev/null
build_claude_md_to_file "$output/shell-claude-full.md" >/dev/null
_extract_kit_section "$output/shell-claude-full.md" > "$output/shell-claude.md"
CLAUDE_DIR="$output/deployed"
mkdir -p "$CLAUDE_DIR"
cp "$output/shell-settings.json" "$CLAUDE_DIR/settings.json"
cp "$output/shell-claude-full.md" "$CLAUDE_DIR/CLAUDE.md"
for pair in \
  "INSTALL_AGENTS:agents" "INSTALL_RULES:rules" \
  "INSTALL_COMMANDS:commands" "INSTALL_SKILLS:skills"; do
  flag="${pair%%:*}"
  source_dir="${pair#*:}"
  is_true "${!flag:-false}" || continue
  _copy_distribution_tree "$PROJECT_DIR/$source_dir" "$CLAUDE_DIR/$source_dir" overwrite
done
deploy_hook_scripts simple >/dev/null
collect_managed_target_files
_normalize_mdm_managed_modes "${_MANAGED_TARGET_FILES[@]}"

# Observe the real managed_files_json sort environment without replacing its
# sorting behavior. This fails if the function stops pinning LC_ALL=C.
mkdir "$output/sort-bin"
printf "%s\n" \
  "#!/bin/bash" \
  "printf \"%s\\n\" \"\${LC_ALL-}\" > \"\$SORT_ENV_LOG\"" \
  "exec /usr/bin/sort \"\$@\"" \
  > "$output/sort-bin/sort"
chmod 700 "$output/sort-bin/sort"
SORT_ENV_LOG="$output/shell-sort-locale"
export SORT_ENV_LOG
PATH="$output/sort-bin:$PATH"
managed_files_json | jq -r ".[]" | while IFS= read -r file; do
  case "$file" in
    "$CLAUDE_DIR"/*) printf "%s\n" "${file#"$CLAUDE_DIR"/}" ;;
    *) exit 1 ;;
  esac
done > "$output/shell-paths"
while IFS= read -r path; do
  mode=0600; [[ -x "$CLAUDE_DIR/$path" ]] && mode=0700
  printf "%s\t%s\t%s\n" "$path" "$mode" "$mode"
done < "$output/shell-paths" > "$output/shell-modes.tsv"
)
render_case standard ja
render_case minimal en
render_case full en
' mdm-expected-oracle "$PROJECT_DIR" "$_case_root" "$_logical_home" \
  >/dev/null 2>&1 || _oracle_rc=$?
if [[ "$_oracle_rc" -eq 0 && -s "$_shell_settings" && -s "$_shell_claude" \
  && -s "$_shell_paths" && -s "$_shell_modes" \
  && "$(cat "$_case_dir/shell-sort-locale" 2>/dev/null || true)" == C ]]; then
  pass "mdm-expected: Bash 4+ shell-builder oracle completed in isolation"
else
  fail "mdm-expected: shell-builder oracle failed or produced incomplete fixtures"
  rm -rf "$_expected_tmp"
  return 0
fi

_render_rc=0
"$PYTHON" "$RENDERER" \
  --checkout "$PROJECT_DIR" \
  --output "$_renderer_output" \
  --profile standard \
  --language ja \
  --logical-home "$_logical_home" \
  --override ENABLE_DOC_SIZE_GUARD=true \
  --override COMMIT_ATTRIBUTION=true \
  >/dev/null 2>&1 || _render_rc=$?
if [[ "$_render_rc" -eq 0 ]]; then
  pass "mdm-expected: authoritative checkout renders successfully with /usr/bin/python3"
else
  fail "mdm-expected: renderer failed (rc=$_render_rc)"
fi

if cmp -s "$_shell_settings" "$_renderer_output/tree/settings.json"; then
  pass "mdm-expected: settings.json has byte parity with the shell builder"
else
  fail "mdm-expected: settings.json differs from the shell builder"
fi

if cmp -s "$_shell_claude" "$_renderer_output/tree/CLAUDE.md" \
  && [[ "$(tail -c 1 "$_renderer_output/tree/CLAUDE.md" | od -An -tuC | tr -d ' ')" == 10 ]]; then
  pass "mdm-expected: CLAUDE.md managed section has strict byte parity and trailing LF"
else
  fail "mdm-expected: CLAUDE.md managed section parity failed"
fi

# Compare the renderer's path inventory and copied payload bytes with the same
# registry/distribution rules consumed by the shell deployment.
"$PYTHON" - "$_renderer_output/manifest.json" >"$_expected_tmp/rendered-paths" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
for path in manifest["files"]:
    print(path)
PY
if cmp -s "$_shell_paths" "$_expected_tmp/rendered-paths"; then
  pass "mdm-expected: managed path inventory matches the shell registry"
else
  fail "mdm-expected: managed path inventory differs from the shell registry"
fi

_payload_mismatch=""
while IFS= read -r _path; do
  case "$_path" in
    CLAUDE.md|settings.json) continue ;;
    hooks/*)
      _tail="${_path#hooks/}"
      _feature="${_tail%%/*}"
      _relative="${_tail#*/}"
      _source="$PROJECT_DIR/features/$_feature/scripts/$_relative"
      ;;
    *) _source="$PROJECT_DIR/$_path" ;;
  esac
  cmp -s "$_source" "$_renderer_output/tree/$_path" \
    || _payload_mismatch="$_payload_mismatch $_path"
done <"$_shell_paths"
if [[ -z "$_payload_mismatch" ]]; then
  pass "mdm-expected: every distribution and hook payload is byte-identical"
else
  fail "mdm-expected: copied payload mismatch:$_payload_mismatch"
fi

if cmp -s "$_shell_modes" "$_renderer_output/modes.tsv"; then
  pass "mdm-expected: modes.tsv has exact shell deployment parity for live/snapshot"
else
  fail "mdm-expected: modes.tsv differs from shell deployment modes"
fi

_manifest_check="$($PYTHON - "$_renderer_output/manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
valid = (
    value.get("profile") == "standard"
    and value.get("language") == "ja"
    and value.get("async_hooks") is False
    and value.get("files") == sorted(value.get("files", []))
    and value.get("absent_files") == sorted(value.get("absent_files", []))
    and not set(value.get("files", [])).intersection(value.get("absent_files", []))
    and len(value.get("entries", [])) == len(value.get("files", []))
)
print("yes" if valid else "no")
PY
)"
if [[ "$_manifest_check" == yes ]]; then
  pass "mdm-expected: manifest metadata and sorted file list are deterministic"
else
  fail "mdm-expected: manifest metadata is invalid"
fi

_prior_render="$_expected_tmp/prior-render"
_render_rc=0
"$PYTHON" "$RENDERER" --checkout "$PROJECT_DIR" --output "$_prior_render" \
  --profile minimal --language en --logical-home /Users/test \
  --prior-managed commands/retired-from-history.md \
  >/dev/null 2>&1 || _render_rc=$?
if [[ "$_render_rc" -eq 0 ]] \
  && jq -e '.absent_files | index("commands/retired-from-history.md") != null' \
    "$_prior_render/manifest.json" >/dev/null; then
  pass "mdm-expected: prior root inventory is carried into the absent contract"
else
  fail "mdm-expected: prior root inventory was lost from the absent contract"
fi

# Cover the smallest and largest profiles through the same real builder oracle.
_parity_fail=""
for _case in minimal:en full:en; do
  _case_profile="${_case%%:*}"
  _case_language="${_case#*:}"
  _case_dir="$_case_root/$_case_profile-$_case_language"
  _case_render="$_case_dir/rendered"
  _render_rc=0
  "$PYTHON" "$RENDERER" \
    --checkout "$PROJECT_DIR" \
    --output "$_case_render" \
    --profile "$_case_profile" \
    --language "$_case_language" \
    --logical-home "$_logical_home" \
    >/dev/null 2>&1 || _render_rc=$?
  if [[ "$_render_rc" -ne 0 ]]; then
    _parity_fail="$_parity_fail $_case_profile/$_case_language:render"
    continue
  fi
  "$PYTHON" - "$_case_render/manifest.json" >"$_case_dir/rendered-paths" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
for path in manifest["files"]:
    print(path)
PY
  cmp -s "$_case_dir/shell-settings.json" "$_case_render/tree/settings.json" \
    || _parity_fail="$_parity_fail $_case_profile/$_case_language:settings"
  cmp -s "$_case_dir/shell-claude.md" "$_case_render/tree/CLAUDE.md" \
    || _parity_fail="$_parity_fail $_case_profile/$_case_language:CLAUDE"
  cmp -s "$_case_dir/shell-paths" "$_case_dir/rendered-paths" \
    || _parity_fail="$_parity_fail $_case_profile/$_case_language:inventory"
  cmp -s "$_case_dir/shell-modes.tsv" "$_case_render/modes.tsv" \
    || _parity_fail="$_parity_fail $_case_profile/$_case_language:modes"
  [[ "$(cat "$_case_dir/shell-sort-locale" 2>/dev/null || true)" == C ]] \
    || _parity_fail="$_parity_fail $_case_profile/$_case_language:locale"
done
if [[ -z "$_parity_fail" ]]; then
  pass "mdm-expected: minimal/en and full/en match settings, CLAUDE, inventory, and modes"
else
  fail "mdm-expected: cross-profile parity failed:$_parity_fail"
fi

# Fail-closed input checks use a minimal checkout fixture so the authoritative
# working tree is never modified by the test.
_fixture="$_expected_tmp/fixture"
mkdir -p "$_fixture/lib" "$_fixture/config" "$_fixture/i18n/en" \
  "$_fixture/features/agent-teams" \
  "$_fixture/agents" "$_fixture/rules" "$_fixture/commands" \
  "$_fixture/skills" "$_fixture/profiles"
for _feature in doc-blocker tmux-hooks prettier-hooks biome-hooks \
  pr-creation-log auto-update statusline doc-size-guard feature-recommendation; do
  mkdir -p "$_fixture/features/$_feature/scripts"
done
cp "$PROJECT_DIR/lib/features.sh" "$_fixture/lib/"
cp "$PROJECT_DIR/profiles"/*.conf "$_fixture/profiles/"
cp "$PROJECT_DIR/config/settings-base.json" "$PROJECT_DIR/config/permissions.json" "$_fixture/config/"
cp "$PROJECT_DIR/i18n/en/CLAUDE.md.base" "$_fixture/i18n/en/"
cp "$PROJECT_DIR/features/agent-teams/hooks.json" "$_fixture/features/agent-teams/"
cp -R "$PROJECT_DIR/agents/." "$_fixture/agents/"
cp -R "$PROJECT_DIR/rules/." "$_fixture/rules/"
ln -s /etc/passwd "$_fixture/agents/linked.md"
_bad_rc=0
"$PYTHON" "$RENDERER" --checkout "$_fixture" --output "$_expected_tmp/symlink-out" \
  --profile minimal --language en --logical-home /Users/test >/dev/null 2>&1 || _bad_rc=$?
if [[ "$_bad_rc" -ne 0 && ! -e "$_expected_tmp/symlink-out" ]]; then
  pass "mdm-expected: managed source symlinks fail closed without partial output"
else
  fail "mdm-expected: managed source symlink was accepted"
fi
rm "$_fixture/agents/linked.md"

"$PYTHON" - "$_fixture/i18n/en/CLAUDE.md.base" <<'PY'
import sys
path = sys.argv[1]
with open(path, "rb") as source:
    data = source.read()
marker = b"<!-- END STARTER-KIT-MANAGED -->"
replacement = b"non-LF-separator:\xe2\x80\xa8preserved\n" + marker
if data.count(marker) != 1:
    raise SystemExit(1)
with open(path, "wb") as destination:
    destination.write(data.replace(marker, replacement))
PY
_bad_rc=0
"$PYTHON" "$RENDERER" --checkout "$_fixture" \
  --output "$_expected_tmp/non-lf-out" \
  --profile minimal --language en --logical-home /Users/test \
  >/dev/null 2>&1 || _bad_rc=$?
if [[ "$_bad_rc" -eq 0 ]] && "$PYTHON" - "$_expected_tmp/non-lf-out/tree/CLAUDE.md" <<'PY'
import sys
with open(sys.argv[1], "rb") as source:
    data = source.read()
raise SystemExit(0 if b"non-LF-separator:\xe2\x80\xa8preserved\n" in data else 1)
PY
then
  pass "mdm-expected: only LF is treated as a CLAUDE.md line separator"
else
  fail "mdm-expected: non-LF content was normalized during CLAUDE.md rendering"
fi
cp "$PROJECT_DIR/i18n/en/CLAUDE.md.base" "$_fixture/i18n/en/CLAUDE.md.base"

printf '{"hooks": {}, "hooks": {}}\n' >"$_fixture/config/settings-base.json"
_bad_rc=0
"$PYTHON" "$RENDERER" --checkout "$_fixture" --output "$_expected_tmp/json-out" \
  --profile minimal --language en --logical-home /Users/test >/dev/null 2>&1 || _bad_rc=$?
if [[ "$_bad_rc" -ne 0 && ! -e "$_expected_tmp/json-out" ]]; then
  pass "mdm-expected: duplicate JSON keys fail closed without partial output"
else
  fail "mdm-expected: duplicate JSON key was accepted"
fi

cp "$PROJECT_DIR/config/settings-base.json" "$_fixture/config/settings-base.json"
"$PYTHON" - "$_fixture/agents/oversized.md" <<'PY'
import os
import sys
with open(sys.argv[1], "wb") as destination:
    destination.truncate(64 * 1024 * 1024 + 1)
PY
_bad_rc=0
"$PYTHON" "$RENDERER" --checkout "$_fixture" --output "$_expected_tmp/oversized-out" \
  --profile minimal --language en --logical-home /Users/test >/dev/null 2>&1 || _bad_rc=$?
if [[ "$_bad_rc" -ne 0 && ! -e "$_expected_tmp/oversized-out" ]]; then
  pass "mdm-expected: oversized managed payloads fail closed without partial output"
else
  fail "mdm-expected: oversized managed payload was accepted"
fi
rm "$_fixture/agents/oversized.md"

_unknown_rejected=0
for _unknown in ENABLE_UNKNOWN_RENDERER_COMPONENT INSTALL_UNKNOWN_RENDERER_TREE; do
  cp "$PROJECT_DIR/profiles"/*.conf "$_fixture/profiles/"
  for _path in "$_fixture/profiles"/*.conf; do
    printf '\n%s=true\n' "$_unknown" >>"$_path"
  done
  _bad_rc=0
  "$PYTHON" "$RENDERER" --checkout "$_fixture" \
    --output "$_expected_tmp/unknown-$_unknown" \
    --profile minimal --language en --logical-home /Users/test \
    >/dev/null 2>&1 || _bad_rc=$?
  if [[ "$_bad_rc" -ne 0 && ! -e "$_expected_tmp/unknown-$_unknown" ]]; then
    _unknown_rejected=$((_unknown_rejected + 1))
  fi
done
if [[ "$_unknown_rejected" -eq 2 ]]; then
  pass "mdm-expected: unknown ENABLE_/INSTALL_ profile keys fail closed"
else
  fail "mdm-expected: unknown profile key was silently ignored"
fi

_bad_rc=0
"$PYTHON" "$RENDERER" --checkout "$PROJECT_DIR" --output "$_expected_tmp/override-out" \
  --profile minimal --language en --logical-home /Users/test \
  --override INSTALL_SKILLS=true >/dev/null 2>&1 || _bad_rc=$?
if [[ "$_bad_rc" -ne 0 && ! -e "$_expected_tmp/override-out" ]]; then
  pass "mdm-expected: non-allowlisted overrides fail closed"
else
  fail "mdm-expected: non-allowlisted override was accepted"
fi

_fixed_true_rejected=0
for _fixed_key in ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE ENABLE_CODEX_PLUGIN; do
  _bad_rc=0
  "$PYTHON" "$RENDERER" --checkout "$PROJECT_DIR" \
    --output "$_expected_tmp/fixed-$_fixed_key" \
    --profile minimal --language en --logical-home /Users/test \
    --override "$_fixed_key=true" >/dev/null 2>&1 || _bad_rc=$?
  [[ "$_bad_rc" -ne 0 && ! -e "$_expected_tmp/fixed-$_fixed_key" ]] \
    && _fixed_true_rejected=$((_fixed_true_rejected + 1))
done
if [[ "$_fixed_true_rejected" -eq 3 ]]; then
  pass "mdm-expected: self-updaters and user-scope plugins cannot be enabled"
else
  fail "mdm-expected: a fixed-off MDM component accepted true"
fi

_unsafe_parent="$_expected_tmp/unsafe"
mkdir "$_unsafe_parent"
chmod 777 "$_unsafe_parent"
_bad_rc=0
"$PYTHON" "$RENDERER" --checkout "$PROJECT_DIR" --output "$_unsafe_parent/output" \
  --profile minimal --language en --logical-home /Users/test >/dev/null 2>&1 || _bad_rc=$?
if [[ "$_bad_rc" -ne 0 && ! -e "$_unsafe_parent/output" ]]; then
  pass "mdm-expected: group/other-writable output parents are rejected"
else
  fail "mdm-expected: unsafe output parent was accepted"
fi
chmod 700 "$_unsafe_parent"

if ! grep -Eq '(^|[[:space:]])(import|from)[[:space:]]+(subprocess|socket|urllib|requests)' "$RENDERER" \
  && ! grep -Eq 'os\.(system|popen)|subprocess\.' "$RENDERER"; then
  pass "mdm-expected: renderer contains no subprocess or network API dependency"
else
  fail "mdm-expected: renderer contains a forbidden execution/network dependency"
fi

rm -rf "$_expected_tmp"
}

_test_mdm_expected_main
unset -f _test_mdm_expected_main
