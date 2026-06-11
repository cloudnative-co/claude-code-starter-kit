---
description: Drive a focused test-first implementation with the tdd-guide agent.
argument-hint: <behavior-or-bug>
---

# /tdd

Request: `$ARGUMENTS`

Use the `tdd-guide` agent for the workflow. Keep the session focused on the requested behavior.

## Steps

1. Define the expected behavior or bug regression in one sentence.
2. Add the smallest failing test that proves the contract.
3. Implement the minimum code needed to pass.
4. Refactor only after the test is green.
5. Run the narrow test first, then broader relevant checks.

## Output

- Behavior covered
- Tests added or changed
- Implementation files changed
- Commands run and results
- Remaining gaps or risks
