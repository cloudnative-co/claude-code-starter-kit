#!/bin/bash
# Keep every unqualified MDM-test temporary object under the runner-owned root.
set -euo pipefail

[[ "${MDM_TEST_TMP_ROOT:-}" == /* && -d "$MDM_TEST_TMP_ROOT" \
  && ! -L "$MDM_TEST_TMP_ROOT" ]] || exit 2

_mdm_runner_mktemp() {
  if [[ "$#" -eq 0 ]]; then
    builtin command /usr/bin/mktemp \
      "$MDM_TEST_TMP_ROOT/mdm-test.XXXXXX"
  elif [[ "$#" -eq 1 && "$1" == -d ]]; then
    builtin command /usr/bin/mktemp -d \
      "$MDM_TEST_TMP_ROOT/mdm-test.XXXXXX"
  elif [[ "$#" -eq 1 && "$1" != -* ]]; then
    _mdm_runner_template_is_safe "$1" || return 2
    builtin command /usr/bin/mktemp "$1"
  elif [[ "$#" -eq 2 && "$1" == -d && "$2" != -* ]]; then
    _mdm_runner_template_is_safe "$2" || return 2
    builtin command /usr/bin/mktemp -d "$2"
  else
    return 2
  fi
}

_mdm_runner_template_is_safe() { # <explicit-template>
  local _template="$1" _parent _canonical_parent
  [[ -n "${_mdm_test_tmp_root_canonical:-}" \
    && "$_template" == "$_mdm_test_tmp_root_canonical"/* ]] || return 1
  _parent="${_template%/*}"
  [[ -d "$_parent" && ! -L "$_parent" ]] || return 1
  _canonical_parent="$(cd -P "$_parent" && /bin/pwd -P)" || return 1
  [[ "$_canonical_parent" == "$_parent" \
    && ( "$_canonical_parent" == "$_mdm_test_tmp_root_canonical" \
      || "$_canonical_parent" == "$_mdm_test_tmp_root_canonical"/* ) ]]
}
mktemp() { _mdm_runner_mktemp "$@"; }
function /usr/bin/mktemp { _mdm_runner_mktemp "$@"; }

if [[ "${1:-}" == --timeout-probe && "$#" -eq 1 ]]; then
  [[ "${MDM_WRAPPER_RECORD:-}" == /* \
    && -d "${MDM_WRAPPER_RECORD%/*}" ]] || exit 2
  trap '' HUP INT TERM
  _mdm_probe_tmp="$(mktemp -d)"
  printf '%s\n' "$_mdm_probe_tmp" > "$MDM_WRAPPER_RECORD"
  while :; do /bin/sleep 1; done
fi

[[ "$#" -eq 4 ]] || exit 2
_mdm_test_helper="$1"
_mdm_test_file="$2"
readonly _MDM_RUNNER_COMPLETION_SENTINEL="$3"
readonly _MDM_RUNNER_RESULT_FILE="$4"
_MDM_RUNNER_ASSERTION_LEDGER="${TEST_ASSERTION_LEDGER:-}"
unset TEST_ASSERTION_FD
_mdm_test_tmp_root_canonical="$(cd -P "$MDM_TEST_TMP_ROOT" && pwd -P)" \
  || exit 2
readonly _mdm_test_tmp_root_canonical
TMPDIR="$_mdm_test_tmp_root_canonical"
export TMPDIR

_mdm_output_path_is_safe() {
  local _path="$1"
  local _parent _canonical_parent
  [[ "$_path" == /* \
    && "$_path" == "$MDM_TEST_TMP_ROOT"/* \
    && ! -e "$_path" && ! -L "$_path" ]] || return 1
  _parent="${_path%/*}"
  [[ -d "$_parent" && ! -L "$_parent" ]] || return 1
  _canonical_parent="$(cd -P "$_parent" && pwd -P)" || return 1
  [[ "$_canonical_parent" == "$_parent" \
    && ( "$_canonical_parent" == "$_mdm_test_tmp_root_canonical" \
      || "$_canonical_parent" == "$_mdm_test_tmp_root_canonical"/* ) ]]
}

[[ "$_mdm_test_helper" == /* && -f "$_mdm_test_helper" \
  && ! -L "$_mdm_test_helper" && -r "$_mdm_test_helper" \
  && "$_mdm_test_file" == /* && -f "$_mdm_test_file" \
  && ! -L "$_mdm_test_file" && -r "$_mdm_test_file" \
  && "$MDM_TEST_TMP_ROOT" == "$_mdm_test_tmp_root_canonical" \
  && "$_MDM_RUNNER_COMPLETION_SENTINEL" != "$_MDM_RUNNER_RESULT_FILE" ]] \
  || exit 2
_mdm_output_path_is_safe "$_MDM_RUNNER_COMPLETION_SENTINEL" || exit 2
_mdm_output_path_is_safe "$_MDM_RUNNER_RESULT_FILE" || exit 2
if [[ -n "${_MDM_RUNNER_ASSERTION_LEDGER:-}" ]]; then
  _mdm_output_path_is_safe "$_MDM_RUNNER_ASSERTION_LEDGER" || exit 2
  set -o noclobber
  # Product code legitimately uses low descriptors including fd 9. Keep the
  # runner-only ledger on a high descriptor so sourced tests cannot clobber it.
  { exec 99> "$_MDM_RUNNER_ASSERTION_LEDGER"; } 2>/dev/null || exit 2
  set +o noclobber
  TEST_ASSERTION_FD=99
  export TEST_ASSERTION_FD
  readonly TEST_ASSERTION_FD
fi

_MDM_TEST_REACHED_END=false
_MDM_TEST_FINAL_MARKER_LINE="$(LC_ALL=C /usr/bin/awk '
  NF { value = $0; line = NR }
  END {
    if (value != "mdm_test_reached_end") exit 1
    print line
  }
' "$_mdm_test_file")" || exit 2
readonly _MDM_TEST_FINAL_MARKER_LINE
mdm_test_reached_end() {
  local _caller_file="${BASH_SOURCE[1]:-}"
  local _caller_line="${BASH_LINENO[0]:-}"
  [[ "$_caller_file" == "$_mdm_test_file" \
    && "$_caller_line" == "$_MDM_TEST_FINAL_MARKER_LINE" ]] || return 1
  _MDM_TEST_REACHED_END=true
}

# shellcheck source=/dev/null
source "$_mdm_test_helper"
# shellcheck source=/dev/null
source "$_mdm_test_file"
[[ "$_MDM_TEST_REACHED_END" == true ]] || exit 2
_MDM_RESULT_TOTAL="${_TEST_COUNT:-}"
_MDM_RESULT_PASS="${_TEST_PASS:-}"
_MDM_RESULT_FAIL="${_TEST_FAIL:-}"
_MDM_RESULT_SKIP="${_TEST_SKIP:-}"
if [[ -n "$_MDM_RUNNER_ASSERTION_LEDGER" ]]; then
  exec 99>&-
  _MDM_LEDGER_RESULT="$(LC_ALL=C /usr/bin/awk '
    BEGIN { total = passed = failed = skipped = 0 }
    $0 == "pass" { total++; passed++; next }
    $0 == "fail" { total++; failed++; next }
    $0 == "skip" { total++; skipped++; next }
    { exit 1 }
    END {
      if (total < 1) exit 1
      printf "%d|%d|%d|%d", total, passed, failed, skipped
    }
  ' "$_MDM_RUNNER_ASSERTION_LEDGER")" || exit 2
  IFS='|' read -r _MDM_RESULT_TOTAL _MDM_RESULT_PASS \
    _MDM_RESULT_FAIL _MDM_RESULT_SKIP <<< "$_MDM_LEDGER_RESULT"
  [[ "$_MDM_RESULT_PASS" -ge "${_TEST_PASS:-0}" \
    && "$_MDM_RESULT_FAIL" -ge "${_TEST_FAIL:-0}" \
    && "$_MDM_RESULT_SKIP" -ge "${_TEST_SKIP:-0}" ]] || exit 2
  printf "\n── Results ──\n"
  printf "  Total: %d  Pass: %d  Fail: %d  Skip: %d\n\n" \
    "$_MDM_RESULT_TOTAL" "$_MDM_RESULT_PASS" \
    "$_MDM_RESULT_FAIL" "$_MDM_RESULT_SKIP"
else
  print_summary
fi
[[ "${_TEST_COUNT:-}" =~ ^[0-9]+$ \
  && "${_TEST_PASS:-}" =~ ^[0-9]+$ \
  && "${_TEST_FAIL:-}" =~ ^[0-9]+$ \
  && "${_TEST_SKIP:-}" =~ ^[0-9]+$ \
  && "$((_TEST_PASS + _TEST_FAIL + _TEST_SKIP))" -eq "$_TEST_COUNT" ]] \
  || exit 2
set -o noclobber
builtin printf '%s|%s|%s|%s\n' \
  "$_MDM_RESULT_TOTAL" "$_MDM_RESULT_PASS" \
  "$_MDM_RESULT_FAIL" "$_MDM_RESULT_SKIP" \
  > "$_MDM_RUNNER_RESULT_FILE"
: > "$_MDM_RUNNER_COMPLETION_SENTINEL"
