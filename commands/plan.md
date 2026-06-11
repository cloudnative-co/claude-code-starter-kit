---
description: Restate requirements, assess risks, and create a step-by-step implementation plan before code changes.
argument-hint: <task>
---

# /plan

Request: `$ARGUMENTS`

Use the `planner` agent to create a plan proportional to the task. Do not write code while planning unless the user explicitly asks to proceed.

## Steps

1. Restate the requested outcome and non-goals.
2. Identify affected files, dependencies, and unknowns.
3. Break the work into small implementation steps.
4. Define the verification strategy.
5. Ask for confirmation only when the next action is ambiguous or risky.

## Output

- Requirements summary
- Proposed steps
- Risks and assumptions
- Tests/checks to run
- Open questions
