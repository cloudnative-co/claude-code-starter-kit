---
name: verification-loop
description: Comprehensive verification system for Claude Code sessions. Use after implementation to validate correctness.
when_to_use: Use when implementation is complete and the user wants verification before handoff, commit, or PR creation.
---

# Verification Loop Skill

A comprehensive verification system for Claude Code sessions.

## When to Use

Invoke this skill:
- After completing a feature or significant code change
- Before creating a PR
- When you want to ensure quality gates pass
- After refactoring

## Verification Phases

Pick the right command for each phase from the project's own configuration (package.json scripts, Makefile, CI workflow, etc.). The commands below are examples, not prescriptions. Summarize long output instead of pasting it verbatim.

### Phase 1: Build Verification
Check that the project builds. Examples: `npm run build`, `cargo check`, `go build ./...`, `shellcheck -S warning *.sh`.

If the build fails, STOP and fix before continuing.

### Phase 2: Type Check
Run the project's type checker if it has one. Examples: `npx tsc --noEmit` (TypeScript), `pyright .` or `mypy .` (Python).

Report all type errors. Fix critical ones before continuing.

### Phase 3: Lint Check
Run the project's linter. Examples: `npm run lint`, `ruff check .`, `shellcheck`.

### Phase 4: Test Suite
Run the project's test suite, with coverage if available. Examples: `npm test -- --coverage`, `pytest --cov`, `bash tests/run-unit-tests.sh`.

Report:
- Total tests: X
- Passed: X
- Failed: X
- Coverage: X% (against the project's target)

### Phase 5: Security Scan
Check for leaked secrets in the changes:
- If a dedicated scanner is available (gitleaks, trufflehog), use it.
- Otherwise, follow the bundled security-review skill.
- At minimum, review the added lines of `git diff` for credentials, tokens, and keys. Do not report PASS based on a repository-wide grep.

Also check for leftover debug output (e.g., `console.log`, `print`) in the changed files.

### Phase 6: Diff Review
```bash
# Show what changed
git diff --stat
git diff HEAD~1 --name-only
```

Review each changed file for:
- Unintended changes
- Missing error handling
- Potential edge cases

## Output Format

After running all phases, produce a verification report:

```
VERIFICATION REPORT
==================

Build:     [PASS/FAIL]
Types:     [PASS/FAIL] (X errors)
Lint:      [PASS/FAIL] (X warnings)
Tests:     [PASS/FAIL] (X/Y passed, Z% coverage)
Security:  [PASS/FAIL] (X issues)
Diff:      [X files changed]

Overall:   [READY/NOT READY] for PR

Issues to Fix:
1. ...
2. ...
```

## Integration with Hooks

This skill complements PostToolUse hooks but provides deeper verification.
Hooks catch issues immediately; this skill provides comprehensive review.
If you need periodic automated re-verification, use a hook or the /loop command; instructions in this skill body cannot schedule themselves.
