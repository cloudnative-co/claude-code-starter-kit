---
description: Run repository verification using the verification-loop skill.
argument-hint: "[quick|full|pre-commit|pre-pr]"
---

# /verify

Mode: `$ARGUMENTS`

Use the `verification-loop` skill as the source of truth for phases and reporting.

## Behavior

- `quick`: run the smallest build/type checks that fit the repository.
- `full` or empty: run build, type/lint, tests, security/log scan, and diff review where available.
- `pre-commit`: run checks relevant before committing.
- `pre-pr`: run full verification plus any PR readiness checks available in the repo.

## Output

Report:

- Overall PASS/FAIL
- Commands run
- Failures with file/line when available
- Skipped checks with reasons
- Residual risk before handoff
