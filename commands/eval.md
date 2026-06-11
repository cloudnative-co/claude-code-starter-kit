---
description: Define, check, report, or list evals using the eval-harness skill.
argument-hint: "[define|check|report|list] <feature-name>"
---

# /eval

Request: `$ARGUMENTS`

Use the `eval-harness` skill as the source of truth for eval templates, metrics, and reports.

## Subcommands

- `define <feature>`: create or refine the eval definition before implementation.
- `check <feature>`: run or review capability and regression evals.
- `report <feature>`: summarize results, retries, failures, and readiness.
- `list`: show available eval definitions.

## Output

Return the selected subcommand, files consulted or changed, pass/fail status, and next required action.
