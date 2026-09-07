#!/bin/bash
# tests/unit/test-native-file-tools.sh - native-file-tools feature (Bash-first steer opt-out)
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).
#
# Background: Claude Code 2.1.261 injects a "Bash-first" steer into auto /
# bypassPermissions sessions (feature flag CLAUDE_CODE_THRIFTY_SONIC). Under
# that steer the model reads and edits files with cat/sed/heredocs instead of
# Read/Edit/Write, so the kit's Edit|Write hooks (prettier/biome/doc-blocker/
# doc-size-guard), path-scoped rules and nested CLAUDE.md never fire. The
# feature ships env.CLAUDE_CODE_THRIFTY_SONIC="0" through the normal feature
# fragment mechanism so it stays removable.

_nft_feature_dir="$PROJECT_DIR/features/native-file-tools"

# Build settings.json exactly as deploy does, in a throwaway subshell so the
# shared unit-test process is not polluted with deploy globals.
# Usage: _nft_build_settings <profile> <out-file> [KEY=value ...]
_nft_build_settings() {
  local profile="$1" out="$2"
  shift 2
  (
    set -euo pipefail
    source "$PROJECT_DIR/lib/colors.sh"
    source "$PROJECT_DIR/lib/detect.sh"
    source "$PROJECT_DIR/lib/prerequisites.sh"
    # shellcheck disable=SC1090 # profile confs are plain KEY=value lines
    source "$PROJECT_DIR/profiles/$profile.conf"
    local _pair
    for _pair in "$@"; do
      printf -v "${_pair%%=*}" '%s' "${_pair#*=}"
    done
    LANGUAGE="en"
    # shellcheck disable=SC2034 # consumed by lib/features.sh + lib/deploy.sh
    KIT_MDM_MANAGED=false
    declare -a _SETUP_TMP_FILES=()
    source "$PROJECT_DIR/lib/template.sh"
    source "$PROJECT_DIR/lib/features.sh"
    source "$PROJECT_DIR/lib/json-builder.sh"
    source "$PROJECT_DIR/lib/snapshot.sh"
    source "$PROJECT_DIR/lib/merge.sh"
    source "$PROJECT_DIR/lib/dryrun.sh"
    source "$PROJECT_DIR/lib/deploy.sh"
    build_settings_file "$out" >/dev/null 2>&1
  )
}

{
  test_name="native-file-tools: hooks.json injects CLAUDE_CODE_THRIFTY_SONIC=0 as a plain env fragment"
  if jq -e '.env.CLAUDE_CODE_THRIFTY_SONIC == "0" and (.env | length == 1) and (has("hooks") | not)' \
      "$_nft_feature_dir/hooks.json" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: feature.json declares profile defaults (minimal off, standard/full on) and display metadata"
  if jq -e '.name == "native-file-tools"
      and (.displayName | type == "string" and length > 0)
      and (.description | test("THRIFTY_SONIC"))
      and .profiles.minimal == false and .profiles.standard == true and .profiles.full == true' \
      "$_nft_feature_dir/feature.json" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: feature registry maps native-file-tools to ENABLE_NATIVE_FILE_TOOLS without scripts"
  # `set -e` is inert inside an `if ( ... )` condition, so every assertion
  # must exit explicitly; otherwise only the last command's status counts.
  if (
    set -euo pipefail
    source "$PROJECT_DIR/lib/features.sh"
    [[ "${_FEATURE_FLAGS[native-file-tools]:-}" == "ENABLE_NATIVE_FILE_TOOLS" ]] || exit 1
    [[ " ${_FEATURE_ORDER[*]} " == *" native-file-tools "* ]] || exit 1
    [[ -z "${_FEATURE_HAS_SCRIPTS[native-file-tools]:-}" ]] || exit 1
    [[ ! -d "$_nft_feature_dir/scripts" ]] || exit 1
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: profiles and wizard defaults declare ENABLE_NATIVE_FILE_TOOLS as designed"
  if grep -q '^ENABLE_NATIVE_FILE_TOOLS=false$' "$PROJECT_DIR/profiles/minimal.conf" \
    && grep -q '^ENABLE_NATIVE_FILE_TOOLS=true$' "$PROJECT_DIR/profiles/standard.conf" \
    && grep -q '^ENABLE_NATIVE_FILE_TOOLS=true$' "$PROJECT_DIR/profiles/full.conf" \
    && grep -q '^ENABLE_NATIVE_FILE_TOOLS="true"$' "$PROJECT_DIR/wizard/defaults.conf"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: wizard registry exposes the config key, the native-tools hook token and a label"
  if (
    set -euo pipefail
    source "$PROJECT_DIR/i18n/en/strings.sh"
    source "$PROJECT_DIR/wizard/registry.sh"
    [[ " ${_CONFIG_KEYS[*]} " == *" ENABLE_NATIVE_FILE_TOOLS "* ]] || exit 1
    _idx=""
    for _i in "${!HOOK_KEYS[@]}"; do
      [[ "${HOOK_KEYS[$_i]}" == "ENABLE_NATIVE_FILE_TOOLS" ]] && _idx="$_i"
    done
    [[ -n "$_idx" ]] || exit 1
    [[ "${HOOK_TOKENS[$_idx]:-}" == "native-tools" ]] || exit 1
    _init_hook_labels
    [[ -n "${HOOK_LABELS[$_idx]:-}" ]] || exit 1
    [[ "${HOOK_LABELS[$_idx]}" == *"THRIFTY_SONIC"* ]] || exit 1
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: i18n strings exist in both languages"
  if grep -q '^STR_HOOKS_NATIVE_FILE_TOOLS=' "$PROJECT_DIR/i18n/en/strings.sh" \
    && grep -q '^STR_HOOKS_NATIVE_FILE_TOOLS=' "$PROJECT_DIR/i18n/ja/strings.sh" \
    && grep -q '^STR_CONFIRM_NATIVE_FILE_TOOLS=' "$PROJECT_DIR/i18n/en/strings.sh" \
    && grep -q '^STR_CONFIRM_NATIVE_FILE_TOOLS=' "$PROJECT_DIR/i18n/ja/strings.sh"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ── Regression: kit-built settings.json must disable the Bash-first steer ──
# Before the fix, a Standard/Full settings.json carried no
# CLAUDE_CODE_THRIFTY_SONIC entry, so auto-mode sessions on Fable 5.1 used
# cat/sed/heredocs for every file operation and the Edit|Write hooks never ran
# (reproduced with real Claude Code 2.1.261 sessions; see
# tests/manual/bash-first-steer/).

_nft_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_nft_tmp")

{
  test_name="native-file-tools: standard and full settings.json set env.CLAUDE_CODE_THRIFTY_SONIC to \"0\""
  _nft_ok=true
  for _nft_profile in standard full; do
    _nft_build_settings "$_nft_profile" "$_nft_tmp/$_nft_profile.json" || _nft_ok=false
    jq -e '.env.CLAUDE_CODE_THRIFTY_SONIC == "0"' "$_nft_tmp/$_nft_profile.json" >/dev/null 2>&1 || _nft_ok=false
  done
  if [[ "$_nft_ok" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: minimal settings.json leaves CLAUDE_CODE_THRIFTY_SONIC unset"
  if _nft_build_settings minimal "$_nft_tmp/minimal.json" \
    && jq -e '(.env // {}) | has("CLAUDE_CODE_THRIFTY_SONIC") | not' "$_nft_tmp/minimal.json" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: an explicit ENABLE_NATIVE_FILE_TOOLS=false drops the env key from a standard build"
  if _nft_build_settings standard "$_nft_tmp/standard-off.json" ENABLE_NATIVE_FILE_TOOLS=false \
    && jq -e '(.env // {}) | has("CLAUDE_CODE_THRIFTY_SONIC") | not' "$_nft_tmp/standard-off.json" >/dev/null 2>&1 \
    && jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"' "$_nft_tmp/standard-off.json" >/dev/null 2>&1; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# ── Update path: older installs get the profile default, explicit choices win ──

# Usage: _nft_restore <manifest-json> <saved-conf-body|""> → prints ENABLE_NATIVE_FILE_TOOLS
# shellcheck disable=SC2034 # globals below are consumed by the sourced wizard
_nft_restore() {
  local manifest_json="$1" conf_body="$2"
  (
    set -euo pipefail
    _home="$(mktemp -d)"
    trap 'rm -rf "$_home"' EXIT
    export HOME="$_home"
    mkdir -p "$HOME/.claude"
    printf '%s\n' "$manifest_json" > "$HOME/.claude/.starter-kit-manifest.json"
    STR_ENABLED="Enabled"; STR_DISABLED="Disabled"
    source "$PROJECT_DIR/wizard/wizard.sh"
    # wizard.sh resets WIZARD_CONFIG_FILE while loading, so point it at the
    # saved conf only afterwards (same order as setup.sh: source, then parse).
    WIZARD_CONFIG_FILE="$HOME/test.conf"
    if [[ -n "$conf_body" ]]; then printf '%s\n' "$conf_body" > "$WIZARD_CONFIG_FILE"; fi
    PROFILE=""; LANGUAGE=""; EDITOR_CHOICE=""; SELECTED_PLUGINS=""
    COMMIT_ATTRIBUTION=""; ENABLE_NEW_INIT=""; ENABLE_NATIVE_FILE_TOOLS=""
    _CLI_OVERRIDES=()
    _restore_config_from_manifest >/dev/null 2>&1
    printf '%s' "${ENABLE_NATIVE_FILE_TOOLS:-}"
  )
}

{
  test_name="native-file-tools: update of an older standard install enables the feature (profile default)"
  if [[ "$(_nft_restore '{"profile":"standard","language":"en","editor":"none","plugins":""}' 'ENABLE_SAFETY_NET="true"')" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: update of an older minimal install keeps the feature off"
  if [[ "$(_nft_restore '{"profile":"minimal","language":"en","editor":"none","plugins":""}' 'INSTALL_RULES="true"')" == "false" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: update of an older custom install fills the intended default (true)"
  if [[ "$(_nft_restore '{"profile":"custom","language":"en","editor":"none","plugins":""}' 'ENABLE_TMUX_HOOKS="true"')" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: a saved explicit ENABLE_NATIVE_FILE_TOOLS=false survives update on every profile"
  _nft_ok=true
  for _nft_profile in standard full custom; do
    [[ "$(_nft_restore "{\"profile\":\"$_nft_profile\",\"language\":\"en\",\"editor\":\"none\",\"plugins\":\"\"}" 'ENABLE_NATIVE_FILE_TOOLS="false"')" == "false" ]] || _nft_ok=false
  done
  if [[ "$_nft_ok" == "true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# Interactive wizard, "reuse saved config" branch: fill_missing_profile_defaults
# is the only default fill on that path, and custom has no profile conf.
# Usage: _nft_reuse_fill <profile> <preset-value> → prints ENABLE_NATIVE_FILE_TOOLS
# shellcheck disable=SC2034 # globals consumed by the sourced wizard
_nft_reuse_fill() {
  local profile="$1" preset="$2"
  (
    set -euo pipefail
    STR_ENABLED="Enabled"; STR_DISABLED="Disabled"
    source "$PROJECT_DIR/wizard/wizard.sh"
    ENABLE_NATIVE_FILE_TOOLS="$preset"
    ENABLE_AGENT_TEAMS=""
    PROFILE="$profile"
    fill_missing_profile_defaults "$profile" >/dev/null 2>&1
    printf '%s|%s' "${ENABLE_NATIVE_FILE_TOOLS:-}" "${ENABLE_AGENT_TEAMS:-}"
  )
}

{
  test_name="native-file-tools: saved-config reuse on a custom profile fills native-file-tools and agent-teams (true)"
  if [[ "$(_nft_reuse_fill custom "")" == "true|true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: saved-config reuse keeps an explicit false and honours the minimal profile default"
  if [[ "$(_nft_reuse_fill custom false)" == "false|true" ]] \
    && [[ "$(_nft_reuse_fill minimal "")" == "false|true" ]] \
    && [[ "$(_nft_reuse_fill standard "")" == "true|true" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

# Non-interactive fresh install with --profile=custom (no profile conf): the
# default fill must give the key its intended value, and an explicit CLI/conf
# value must survive.
# Usage: _nft_noninteractive_fill <preset-value> → prints ENABLE_NATIVE_FILE_TOOLS
# shellcheck disable=SC2034 # globals consumed by the sourced wizard
_nft_noninteractive_fill() {
  local preset="$1"
  (
    set -euo pipefail
    STR_ENABLED="Enabled"; STR_DISABLED="Disabled"
    source "$PROJECT_DIR/wizard/wizard.sh"
    PROFILE="custom"; LANGUAGE="en"; EDITOR_CHOICE="none"
    SELECTED_PLUGINS=""; _SELECTED_PLUGINS_EXPLICIT="true"
    ENABLE_NATIVE_FILE_TOOLS="$preset"
    _CLI_OVERRIDES=()
    _fill_noninteractive_defaults >/dev/null 2>&1
    printf '%s' "${ENABLE_NATIVE_FILE_TOOLS:-}"
  )
}

{
  test_name="native-file-tools: non-interactive custom fresh install defaults the key to true and keeps an explicit false"
  if [[ "$(_nft_noninteractive_fill "")" == "true" ]] \
    && [[ "$(_nft_noninteractive_fill false)" == "false" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="native-file-tools: --hooks CSV token native-tools toggles the key"
  if (
    set -euo pipefail
    # shellcheck disable=SC2034 # consumed by wizard.sh label helpers
    STR_ENABLED="Enabled"
    # shellcheck disable=SC2034
    STR_DISABLED="Disabled"
    source "$PROJECT_DIR/wizard/wizard.sh"
    _apply_hooks_csv "native-tools"
    [[ "${ENABLE_NATIVE_FILE_TOOLS:-}" == "true" ]] || exit 1
    _apply_hooks_csv "safety-net"
    [[ "${ENABLE_NATIVE_FILE_TOOLS:-}" == "false" ]] || exit 1
  ); then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

rm -rf "$_nft_tmp"
unset _nft_ok _nft_profile _nft_tmp
