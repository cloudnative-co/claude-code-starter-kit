#!/bin/bash
# tests/unit/test-helpers-run-setup.sh - run_setup / run_setup_update diagnostics
#
# Sourced by run-unit-tests.sh (helpers.sh already loaded). Uses a fake
# setup.sh under a private PROJECT_DIR so nothing real is deployed.

_hrs_tmp="$(mktemp -d)"
mkdir -p "$_hrs_tmp/project"
cat > "$_hrs_tmp/project/setup.sh" <<'EOF'
#!/bin/bash
for i in 1 2 3 4 5; do printf 'line %s\n' "$i"; done
printf 'args: %s\n' "$*" >&2
exit "${HRS_FAKE_RC:-0}"
EOF

{
  test_name="helpers: run_setup replays setup.sh output on stdout and prints a failure tail on fd 3"
  _hrs_rc=0
  (
    # shellcheck disable=SC2034 # read by run_setup / run_setup_update
    PROJECT_DIR="$_hrs_tmp/project"
    _TEST_SETUP_LOG_TAIL=3
    export HRS_FAKE_RC=7
    run_setup --profile=minimal \
      >"$_hrs_tmp/stdout" 2>"$_hrs_tmp/stderr" 3>"$_hrs_tmp/fd3"
  ) || _hrs_rc=$?
  if [[ "$_hrs_rc" -eq 7 ]] \
    && grep -q '^line 1$' "$_hrs_tmp/stdout" \
    && grep -q '^args: --non-interactive --language=en --profile=minimal$' \
      "$_hrs_tmp/stdout" \
    && [[ ! -s "$_hrs_tmp/stderr" ]] \
    && grep -q 'setup.sh exited 7: --non-interactive --language=en --profile=minimal' \
      "$_hrs_tmp/fd3" \
    && grep -q '| line 4$' "$_hrs_tmp/fd3" \
    && grep -q '| args: ' "$_hrs_tmp/fd3" \
    && ! grep -q 'line 1' "$_hrs_tmp/fd3"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="helpers: run_setup stays quiet on fd 3 when setup.sh succeeds"
  rm -f "$_hrs_tmp/stdout" "$_hrs_tmp/stderr" "$_hrs_tmp/fd3"
  _hrs_rc=0
  (
    # shellcheck disable=SC2034 # read by run_setup / run_setup_update
    PROJECT_DIR="$_hrs_tmp/project"
    export HRS_FAKE_RC=0
    run_setup --profile=minimal \
      >"$_hrs_tmp/stdout" 2>"$_hrs_tmp/stderr" 3>"$_hrs_tmp/fd3"
  ) || _hrs_rc=$?
  if [[ "$_hrs_rc" -eq 0 ]] \
    && grep -q '^line 5$' "$_hrs_tmp/stdout" \
    && [[ ! -s "$_hrs_tmp/stderr" ]] \
    && [[ ! -s "$_hrs_tmp/fd3" ]]; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

{
  test_name="helpers: run_setup_update passes --update --non-interactive and keeps the caller's output capture intact"
  rm -f "$_hrs_tmp/stdout" "$_hrs_tmp/fd3"
  _hrs_rc=0
  _hrs_out=""
  (
    # shellcheck disable=SC2034 # read by run_setup / run_setup_update
    PROJECT_DIR="$_hrs_tmp/project"
    export HRS_FAKE_RC=3
    # The same shape scenarios use: capture the output while fd 3 goes elsewhere.
    _out="$(run_setup_update --dry-run 2>&1 3>"$_hrs_tmp/fd3")" || _rc=$?
    printf '%s' "$_out" > "$_hrs_tmp/stdout"
    exit "${_rc:-0}"
  ) || _hrs_rc=$?
  if [[ "$_hrs_rc" -eq 3 ]] \
    && grep -q '^args: --update --non-interactive --dry-run$' "$_hrs_tmp/stdout" \
    && ! grep -q 'setup.sh exited' "$_hrs_tmp/stdout" \
    && grep -q 'setup.sh exited 3: --update --non-interactive --dry-run' \
      "$_hrs_tmp/fd3"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
}

rm -rf "$_hrs_tmp"
unset _hrs_tmp _hrs_rc _hrs_out
