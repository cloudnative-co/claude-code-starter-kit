#!/usr/bin/env bash
# tests/run-mdm-tests.sh - Process-isolated runner for MDM unit tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MDM_TEST_BASH="${MDM_TEST_BASH:-${BASH:-/bin/bash}}"
readonly MIN_MDM_TEST_FILES=7
readonly MIN_MDM_ASSERTIONS=270

MDM_TEST_SYSTEM_PYTHON=""
if [[ -x /usr/bin/python3 ]]; then
  MDM_TEST_SYSTEM_PYTHON="$(/usr/bin/python3 -I -B -c \
    'import os, sys; print(os.path.realpath(sys.executable))' 2>/dev/null || true)"
  [[ "$MDM_TEST_SYSTEM_PYTHON" == /* \
    && -x "$MDM_TEST_SYSTEM_PYTHON" \
    && ! -L "$MDM_TEST_SYSTEM_PYTHON" ]] || MDM_TEST_SYSTEM_PYTHON=""
fi

_find_bash4() {
  local candidate major
  for candidate in "${MDM_TEST_BASH4:-}" "$MDM_TEST_BASH" \
    "$(command -v bash 2>/dev/null || true)" \
    /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
    [[ "$candidate" == /* && -x "$candidate" ]] || continue
    major="$("$candidate" -c 'printf "%s" "${BASH_VERSINFO[0]}"' \
      2>/dev/null || true)"
    case "$major" in
      ''|*[!0-9]*) continue ;;
    esac
    if [[ "$major" -ge 4 ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if [[ "$MDM_TEST_BASH" != /* ]] || [[ ! -x "$MDM_TEST_BASH" ]]; then
  printf 'FAIL: MDM_TEST_BASH must be an absolute executable path: %s\n' "$MDM_TEST_BASH" >&2
  exit 1
fi

runner_tmp="$(mktemp -d)"
trap 'rm -rf "$runner_tmp"' EXIT INT TERM

# Prove that a failure inside a subshell reaches the shared sentinel before
# trusting results from the real test files.
probe="$runner_tmp/probe.fail"
TEST_FAILURE_SENTINEL="$probe" "$MDM_TEST_BASH" -c '
  source "$1"
  (fail "runner sentinel probe") >/dev/null
' _ "$SCRIPT_DIR/helpers.sh"
if [[ ! -s "$probe" ]]; then
  printf 'FAIL: MDM failure sentinel did not propagate from a subshell\n' >&2
  exit 1
fi

printf '\n══ MDM Unit Tests (%s) ══\n\n' "$($MDM_TEST_BASH --version | head -1)"

file_count=0
failed_files=0
pass_count=0
for test_file in "$SCRIPT_DIR"/unit/test-mdm-*.sh; do
  [[ -f "$test_file" ]] || continue
  file_count=$((file_count + 1))
  sentinel="$runner_tmp/$(basename "$test_file").fail"
  completion="$runner_tmp/$(basename "$test_file").complete"
  output="$runner_tmp/$(basename "$test_file").out"
  test_bash="$MDM_TEST_BASH"
  printf '── %s ──\n' "$(basename "$test_file")"

  # Most MDM entrypoints support Bash 3.2; tests that source the Bash 4+
  # deployment libraries opt in to a newer child shell explicitly.
  if grep -q '^# MDM_TEST_BASH_MIN=4$' "$test_file"; then
    test_major="$("$test_bash" -c 'printf "%s" "${BASH_VERSINFO[0]}"' \
      2>/dev/null || true)"
    if [[ ! "$test_major" =~ ^[0-9]+$ ]] || [[ "$test_major" -lt 4 ]]; then
      if ! test_bash="$(_find_bash4)"; then
        printf 'FAIL: %s requires Bash 4+, but none was found\n\n' \
          "$(basename "$test_file")"
        failed_files=$((failed_files + 1))
        continue
      fi
    fi
  fi

  rc=0
  # Bash 3.2 can abort a sourced file on an unbound array subscript yet exit
  # zero. Require the command after print_summary to prove full completion.
  set +e
  TEST_FAILURE_SENTINEL="$sentinel" \
    TEST_COMPLETION_SENTINEL="$completion" \
    MDM_SYSTEM_PYTHON_OVERRIDE="$MDM_TEST_SYSTEM_PYTHON" \
    MDM_DETECT_PYTHON_OVERRIDE="$MDM_TEST_SYSTEM_PYTHON" \
    "$test_bash" -c '
    source "$1"
    source "$2"
    print_summary
    : > "$TEST_COMPLETION_SENTINEL"
  ' _ "$SCRIPT_DIR/helpers.sh" "$test_file" >"$output" 2>&1
  rc=$?
  set -e
  cat "$output"

  current_pass="$(grep -c 'PASS' "$output" 2>/dev/null || true)"
  pass_count=$((pass_count + current_pass))
  if [[ "$rc" -ne 0 ]] || [[ -s "$sentinel" ]] \
    || [[ ! -f "$completion" ]] || [[ "$current_pass" -eq 0 ]]; then
    failed_files=$((failed_files + 1))
    nested_failures=0
    completed=no
    [[ -f "$completion" ]] && completed=yes
    if [[ -f "$sentinel" ]]; then
      nested_failures="$(wc -l < "$sentinel" | tr -d ' ')"
    fi
    printf 'FAIL: %s (exit=%s, completed=%s, passes=%s, nested failures=%s)\n' \
      "$(basename "$test_file")" "$rc" "$completed" "$current_pass" \
      "$nested_failures"
  fi
  printf '\n'
done

if [[ "$file_count" -lt "$MIN_MDM_TEST_FILES" ]]; then
  printf 'FAIL: suspiciously few MDM test files ran (%s; minimum=%s)\n' \
    "$file_count" "$MIN_MDM_TEST_FILES" >&2
  exit 1
fi
if [[ "$pass_count" -lt "$MIN_MDM_ASSERTIONS" ]]; then
  printf 'FAIL: suspiciously few MDM assertions ran (%s; minimum=%s)\n' \
    "$pass_count" "$MIN_MDM_ASSERTIONS" >&2
  exit 1
fi
if [[ "$failed_files" -ne 0 ]]; then
  printf 'FAIL: %s/%s MDM test files failed\n' "$failed_files" "$file_count" >&2
  exit 1
fi

printf 'PASS: %s MDM test files, %s assertions\n' "$file_count" "$pass_count"
