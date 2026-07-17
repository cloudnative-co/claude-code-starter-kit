#!/usr/bin/env bash
# tests/run-unit-tests.sh - Unit test runner for lib functions
#
# Runs all test-*.sh files in tests/unit/.
# Requires Bash 4+ (features.sh uses declare -A).
set -euo pipefail

# Bail out on Bash 3.x
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "SKIP: Unit tests require Bash 4+ (current: ${BASH_VERSION})" >&2
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared helpers (assertions, pass/fail, etc.)
# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

printf "\n══ Unit Tests ══\n\n"

# Run each test file in the same process (source, not subprocess).
# NOTE: All test files share a single shell process. Functions, globals, and
# sourced libs persist across files. Test files must not depend on a clean
# slate — always stub/reset what they need. Execution order is alphabetical.
# If full isolation is needed in the future, run each file in a subshell.
for test_file in "$SCRIPT_DIR"/unit/test-*.sh; do
  [[ -f "$test_file" ]] || continue
  # MDM tests need Bash 3.2 coverage and process-isolated failure propagation.
  # tests/run-mdm-tests.sh is their single execution path.
  case "$(basename "$test_file")" in
    test-mdm-*.sh) continue ;;
  esac
  printf "── %s ──\n" "$(basename "$test_file")"
  # shellcheck source=/dev/null
  source "$test_file"
  printf "\n"
done

print_summary

# MDM tests require process isolation and must also run under macOS system
# Bash 3.2. Keep them behind the standard unit-test entrypoint so the documented
# local validation command cannot silently omit the MDM suite.
MDM_TEST_BASH="${MDM_TEST_BASH:-/bin/bash}" \
  /bin/bash "$SCRIPT_DIR/run-mdm-tests.sh"
