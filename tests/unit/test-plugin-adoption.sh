#!/bin/bash
# tests/unit/test-plugin-adoption.sh - Regression tests for lib/plugin-adoption.sh
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded).
#
# The module decides whether a plugin catalogued after someone installed gets
# offered to them. Two properties matter most and are easy to break:
#   - the marker only advances when the user could actually answer, otherwise
#     the background auto-update consumes every offer silently
#   - nothing is installed without an explicit yes

_pa_tmp="$(mktemp -d)"

# Minimal harness: the module needs the plugin registry helpers plus a handful
# of globals the wizard would normally have set.
_pa_load() { # <plugins.json body>
  local body="$1"
  mkdir -p "$_pa_tmp/kit/config"
  printf '%s' "$body" > "$_pa_tmp/kit/config/plugins.json"
}

_pa_run() { # <shell snippet> -> prints snippet output
  bash -c '
    set -uo pipefail
    PROJECT_DIR="'"$_pa_tmp"'/kit"
    _project_dir() { printf "%s" "$PROJECT_DIR"; }
    info() { :; }
    ok() { :; }
    # shellcheck source=/dev/null
    source "'"$PROJECT_DIR"'/wizard/registry.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "'"$PROJECT_DIR"'/lib/plugin-adoption.sh"
    PLUGIN_NAMES=(); PLUGIN_PROFILES=(); PLUGIN_SELECTED=(); PLUGIN_MARKETPLACES=()
    SELECTED_PLUGINS=""; KNOWN_PLUGINS=""; DISMISSED_PLUGINS=""; PROFILE="standard"
    '"$1"'
  ' 2>&1
}

_pa_catalog='{"marketplaces":{"claude-plugins-official":"a/b","other-mp":"c/d"},"plugins":[
  {"name":"alpha","marketplace":"claude-plugins-official","profiles":["standard","full"]},
  {"name":"beta","marketplace":"claude-plugins-official","profiles":["full"]},
  {"name":"gamma","marketplace":"other-mp","profiles":["standard","full"]}
]}'
_pa_load "$_pa_catalog"

# ── profile default set, with the same @marketplace spelling as the wizard ──
#
# The comparison only works if both sides spell entries identically:
# _compute_selected_plugins qualifies non-official marketplaces, so this must
# too, or gamma would look "new" on every single run.
_pa_out="$(_pa_run '_profile_default_plugins standard')"
if [[ "$_pa_out" == "alpha,gamma@other-mp" ]]; then
  pass "plugin-adoption: profile defaults use the wizard's @marketplace spelling"
else
  fail "plugin-adoption: profile defaults should be 'alpha,gamma@other-mp' (got '$_pa_out')"
fi

_pa_out="$(_pa_run 'PROFILE=full; _profile_default_plugins full')"
if [[ "$_pa_out" == "alpha,beta,gamma@other-mp" ]]; then
  pass "plugin-adoption: full profile picks up every catalogued default"
else
  fail "plugin-adoption: full defaults should include beta (got '$_pa_out')"
fi

# ── newcomer computation ───────────────────────────────────────────────────
_pa_out="$(_pa_run '
  SELECTED_PLUGINS="alpha"
  KNOWN_PLUGINS="alpha"
  _compute_new_plugins "alpha,gamma@other-mp"')"
if [[ "$_pa_out" == "gamma@other-mp" ]]; then
  pass "plugin-adoption: a catalogued newcomer is detected"
else
  fail "plugin-adoption: gamma@other-mp should be the only newcomer (got '$_pa_out')"
fi

# Already installed, already declined, and already offered are all answered.
_pa_out="$(_pa_run '
  SELECTED_PLUGINS="alpha"
  DISMISSED_PLUGINS="gamma@other-mp"
  KNOWN_PLUGINS="alpha,gamma@other-mp"
  _compute_new_plugins "alpha,gamma@other-mp"')"
if [[ -z "$_pa_out" ]]; then
  pass "plugin-adoption: selected, dismissed, and known entries are not re-offered"
else
  fail "plugin-adoption: answered entries must not be offered again (got '$_pa_out')"
fi

# Migration: KNOWN_PLUGINS unset means the install predates the mechanism, so
# every default it lacks is owed one offer — this is the only path by which a
# plugin catalogued earlier can still reach an existing user.
_pa_out="$(_pa_run '
  SELECTED_PLUGINS="alpha"
  _compute_new_plugins "alpha,gamma@other-mp"')"
if [[ "$_pa_out" == "gamma@other-mp" ]]; then
  pass "plugin-adoption: an install with no marker gets the one-time catch-up"
else
  fail "plugin-adoption: catch-up should offer gamma@other-mp (got '$_pa_out')"
fi

# A plugin that gains a profile is a newcomer for that profile even though its
# name was already in the catalog — which is why the unit of comparison is the
# profile's default set and not the catalog.
_pa_out="$(_pa_run '
  SELECTED_PLUGINS="alpha,gamma@other-mp"
  KNOWN_PLUGINS="alpha,gamma@other-mp"
  _compute_new_plugins "alpha,beta,gamma@other-mp"')"
if [[ "$_pa_out" == "beta" ]]; then
  pass "plugin-adoption: a plugin newly added to the profile is detected"
else
  fail "plugin-adoption: beta should be detected after joining the profile (got '$_pa_out')"
fi

# ── the marker must not advance when nobody could answer ───────────────────
#
# The auto-update hook runs `setup.sh --update --non-interactive` and is on by
# default for standard/full. If the marker advanced there, the offer would be
# consumed in the background and the interactive update would find nothing.
_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="false"
  SELECTED_PLUGINS="alpha"
  mkdir -p "'"$_pa_tmp"'/home1"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home1" >/dev/null 2>&1
  printf "known=[%s] selected=[%s] dismissed=[%s]" \
    "$KNOWN_PLUGINS" "$SELECTED_PLUGINS" "$DISMISSED_PLUGINS"')"
if [[ "$_pa_out" == "known=[] selected=[alpha] dismissed=[]" ]]; then
  pass "plugin-adoption: a non-interactive run neither installs nor consumes the offer"
else
  fail "plugin-adoption: non-interactive run must leave all three CSVs untouched (got '$_pa_out')"
fi

# ...and it must leave the notification behind so the user still hears about it.
if [[ -f "$_pa_tmp/home1/.starter-kit-pending-features.json" ]] \
  && [[ "$(jq -r '.plugins[0]' "$_pa_tmp/home1/.starter-kit-pending-features.json" 2>/dev/null)" \
        == "gamma@other-mp" ]]; then
  pass "plugin-adoption: a non-interactive run records the SessionStart notification"
else
  fail "plugin-adoption: non-interactive run should write the pending-plugins notification"
fi

# An unreadable terminal is the same situation even when the merge flag says
# interactive — a failed read is not a "no".
_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="true"
  _TTY_INPUT="'"$_pa_tmp"'/definitely-not-a-tty"
  SELECTED_PLUGINS="alpha"
  mkdir -p "'"$_pa_tmp"'/home2"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home2" >/dev/null 2>&1
  printf "known=[%s] dismissed=[%s]" "$KNOWN_PLUGINS" "$DISMISSED_PLUGINS"')"
if [[ "$_pa_out" == "known=[] dismissed=[]" ]]; then
  pass "plugin-adoption: an unreadable terminal is not treated as a decline"
else
  fail "plugin-adoption: unreadable tty must not record answers (got '$_pa_out')"
fi

# A terminal that is readable but yields EOF is the harder case: it clears the
# up-front guard, so the prompt loop starts and the read itself fails. That is
# not an answer — recording it as a decline would bury the offer permanently,
# and advancing the marker would do the same.
_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="true"
  PROFILE="full"
  _TTY_INPUT="/dev/null"
  SELECTED_PLUGINS="alpha"
  mkdir -p "'"$_pa_tmp"'/home6"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home6" >/dev/null 2>&1
  printf "known=[%s] dismissed=[%s] selected=[%s]" \
    "$KNOWN_PLUGINS" "$DISMISSED_PLUGINS" "$SELECTED_PLUGINS"')"
if [[ "$_pa_out" == "known=[] dismissed=[] selected=[alpha]" ]]; then
  pass "plugin-adoption: a readable terminal that EOFs records nothing and keeps the marker"
else
  fail "plugin-adoption: an EOF read must not count as a decline (got '$_pa_out')"
fi

# ...and the offer survives as a notification rather than vanishing.
if [[ "$(jq -r '.plugins | length' \
  "$_pa_tmp/home6/.starter-kit-pending-features.json" 2>/dev/null)" == "2" ]]; then
  pass "plugin-adoption: an interrupted prompt still leaves the notification behind"
else
  fail "plugin-adoption: interrupted prompt should record both unanswered plugins"
fi

# ── answering ──────────────────────────────────────────────────────────────
_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="true"
  printf "y\n" > "'"$_pa_tmp"'/answer-yes"
  _TTY_INPUT="'"$_pa_tmp"'/answer-yes"
  SELECTED_PLUGINS="alpha"
  mkdir -p "'"$_pa_tmp"'/home3"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home3" >/dev/null 2>&1
  printf "selected=[%s] known=[%s]" "$SELECTED_PLUGINS" "$KNOWN_PLUGINS"')"
if [[ "$_pa_out" == "selected=[alpha,gamma@other-mp] known=[alpha,gamma@other-mp]" ]]; then
  pass "plugin-adoption: an explicit yes adds the plugin and advances the marker"
else
  fail "plugin-adoption: yes should add gamma@other-mp and advance the marker (got '$_pa_out')"
fi

_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="true"
  printf "n\n" > "'"$_pa_tmp"'/answer-no"
  _TTY_INPUT="'"$_pa_tmp"'/answer-no"
  SELECTED_PLUGINS="alpha"
  mkdir -p "'"$_pa_tmp"'/home4"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home4" >/dev/null 2>&1
  printf "selected=[%s] dismissed=[%s]" "$SELECTED_PLUGINS" "$DISMISSED_PLUGINS"')"
if [[ "$_pa_out" == "selected=[alpha] dismissed=[gamma@other-mp]" ]]; then
  pass "plugin-adoption: a decline is recorded instead of installing"
else
  fail "plugin-adoption: no should record a dismissal (got '$_pa_out')"
fi

# Anything that is not an explicit yes defaults to no.
_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="true"
  printf "\n" > "'"$_pa_tmp"'/answer-blank"
  _TTY_INPUT="'"$_pa_tmp"'/answer-blank"
  SELECTED_PLUGINS="alpha"
  mkdir -p "'"$_pa_tmp"'/home5"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home5" >/dev/null 2>&1
  printf "selected=[%s]" "$SELECTED_PLUGINS"')"
if [[ "$_pa_out" == "selected=[alpha]" ]]; then
  pass "plugin-adoption: an empty answer defaults to no"
else
  fail "plugin-adoption: blank answer must not install (got '$_pa_out')"
fi

# ── CSV validation ─────────────────────────────────────────────────────────
#
# These CSVs gate an install offer, so a corrupted or hand-edited value is
# cleared rather than acted on. "@" and "." must survive: marketplace names
# use them, unlike DISMISSED_FEATURES' [a-z0-9,-].
_pa_out="$(_pa_run '
  KNOWN_PLUGINS="alpha,gamma@other-mp.v2"
  _validate_plugin_csv KNOWN_PLUGINS
  printf "[%s]" "$KNOWN_PLUGINS"')"
if [[ "$_pa_out" == "[alpha,gamma@other-mp.v2]" ]]; then
  pass "plugin-adoption: @ and . survive CSV validation"
else
  fail "plugin-adoption: qualified names must survive validation (got '$_pa_out')"
fi

_pa_out="$(_pa_run '
  KNOWN_PLUGINS="alpha;rm -rf /"
  _validate_plugin_csv KNOWN_PLUGINS
  printf "[%s]" "$KNOWN_PLUGINS"')"
if [[ "$_pa_out" == "[]" ]]; then
  pass "plugin-adoption: a corrupted CSV is cleared instead of acted on"
else
  fail "plugin-adoption: shell metacharacters must clear the CSV (got '$_pa_out')"
fi

# ── registry wiring ────────────────────────────────────────────────────────
if [[ " $(bash -c '
  source "'"$PROJECT_DIR"'/wizard/registry.sh" >/dev/null 2>&1
  printf "%s" "$_CONFIG_ALLOWED_KEYS"') " == *" KNOWN_PLUGINS "* ]]; then
  pass "plugin-adoption: KNOWN_PLUGINS is in the config allowlist"
else
  fail "plugin-adoption: KNOWN_PLUGINS must be registered in _CONFIG_KEYS"
fi

# KNOWN_PLUGINS must stay OUT of the empty-allowed set: an empty value is never
# persisted, so "absent from the conf" keeps meaning "owed the catch-up".
# Adding it there would write KNOWN_PLUGINS="" on the first non-interactive
# update and silently cancel every existing install's one-time offer.
if ! grep -q '_CONFIG_EMPTY_ALLOWED_KEYS=.*KNOWN_PLUGINS' "$PROJECT_DIR/wizard/wizard.sh"; then
  pass "plugin-adoption: KNOWN_PLUGINS stays out of _CONFIG_EMPTY_ALLOWED_KEYS"
else
  fail "plugin-adoption: KNOWN_PLUGINS in _CONFIG_EMPTY_ALLOWED_KEYS would cancel the catch-up"
fi

# The manifest must stay untouched: MDM validates it by exact key set AND
# byte-exact canonical JSON AND SHA256, so a new key fails MDM installs.
if ! grep -q 'KNOWN_PLUGINS\|DISMISSED_PLUGINS' "$PROJECT_DIR/lib/deploy.sh"; then
  pass "plugin-adoption: state stays in the conf, never the MDM-attested manifest"
else
  fail "plugin-adoption: adding these keys to the manifest breaks MDM installs"
fi

# ── mid-prompt EOF re-notifies only the unanswered plugins (F8) ─────────────
#
# The user answers the first newcomer, then the terminal EOFs on the second.
# The answered one is already in SELECTED_PLUGINS, so the notification left
# behind must list only what is still unanswered — not re-surface an answer.
# A process-substitution fd reproduces "answered then EOF": a plain file would
# reopen on every read and never reach EOF.
_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="true"
  PROFILE="full"
  SELECTED_PLUGINS="alpha"
  exec 9< <(printf "y\n")
  _TTY_INPUT="/dev/fd/9"
  mkdir -p "'"$_pa_tmp"'/home_f8"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home_f8" >/dev/null 2>&1
  printf "pending=[%s] selected=[%s]" \
    "$(jq -r "(.plugins // []) | join(\",\")" "'"$_pa_tmp"'/home_f8/.starter-kit-pending-features.json" 2>/dev/null)" \
    "$SELECTED_PLUGINS"')"
if [[ "$_pa_out" == "pending=[gamma@other-mp] selected=[alpha,beta]" ]]; then
  pass "plugin-adoption: a mid-prompt EOF re-notifies only the still-unanswered plugins"
else
  fail "plugin-adoption: EOF after one answer must drop the answered plugin from the notification (got '$_pa_out')"
fi

# ── the notification is gated on its reader being deployed (F11) ─────────────
#
# ENABLE_FEATURE_RECOMMENDATION gates the SessionStart reader; with it off the
# pending file is an orphan nobody reads, so the writer skips it — but the
# marker must still not advance, so the offer resurfaces next interactive update.
_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="false"
  ENABLE_FEATURE_RECOMMENDATION="false"
  SELECTED_PLUGINS="alpha"
  mkdir -p "'"$_pa_tmp"'/home_f11"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home_f11" >/dev/null 2>&1
  f="skipped"; [[ -f "'"$_pa_tmp"'/home_f11/.starter-kit-pending-features.json" ]] && f="written"
  printf "file=%s known=[%s]" "$f" "$KNOWN_PLUGINS"')"
if [[ "$_pa_out" == "file=skipped known=[]" ]]; then
  pass "plugin-adoption: a disabled recommendation reader skips the orphan notification but keeps the offer"
else
  fail "plugin-adoption: FR=false must skip the pending write and not advance the marker (got '$_pa_out')"
fi

# ...and with the reader enabled the notification is written as before.
_pa_out="$(_pa_run '
  _MERGE_INTERACTIVE="false"
  ENABLE_FEATURE_RECOMMENDATION="true"
  SELECTED_PLUGINS="alpha"
  mkdir -p "'"$_pa_tmp"'/home_f11b"
  _detect_and_offer_new_plugins "'"$_pa_tmp"'/home_f11b" >/dev/null 2>&1
  [[ -f "'"$_pa_tmp"'/home_f11b/.starter-kit-pending-features.json" ]] && printf "written" || printf "skipped"')"
if [[ "$_pa_out" == "written" ]]; then
  pass "plugin-adoption: the notification is written when the recommendation reader is enabled"
else
  fail "plugin-adoption: FR=true must still write the pending notification (got '$_pa_out')"
fi

# ── a legacy bare-official entry survives the name starting to collide (F9) ──
#
# This test swaps in a collision catalog, so it must be LAST — later assertions
# would see the wrong plugin set. If a name that was official-only (stored bare)
# later also appears in another marketplace, its default spelling becomes
# name@claude-plugins-official; canonicalization must still treat the stored
# bare entry as the same plugin so it is not re-offered.
_pa_load '{"marketplaces":{"claude-plugins-official":"a/b","other-mp":"c/d"},"plugins":[
  {"name":"alpha","marketplace":"claude-plugins-official","profiles":["standard"]},
  {"name":"alpha","marketplace":"other-mp","profiles":["standard"]}
]}'
_pa_out="$(_pa_run '
  SELECTED_PLUGINS="alpha"
  KNOWN_PLUGINS="alpha"
  _compute_new_plugins "$(_profile_default_plugins standard)"')"
if [[ "$_pa_out" == "alpha@other-mp" ]]; then
  pass "plugin-adoption: a legacy bare-official entry is not re-offered once its name collides"
else
  fail "plugin-adoption: canonicalization should offer only alpha@other-mp (got '$_pa_out')"
fi

rm -rf "$_pa_tmp"
unset _pa_tmp _pa_out _pa_catalog
