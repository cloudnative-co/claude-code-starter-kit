---
description: Generate, run, or triage end-to-end tests with the e2e-runner agent.
argument-hint: <journey-or-test-task>
---

# /e2e

Request: `$ARGUMENTS`

Use the `e2e-runner` agent and the repository's existing browser test setup.

## Steps

1. Identify the critical user journey and required state.
2. Reuse existing fixtures, selectors, and page objects when available.
3. Add or update only the tests needed for the requested behavior.
4. Capture screenshots, traces, or videos when they aid diagnosis.
5. Run the narrow test first, then the related suite if practical.

## CI Baseline

When creating GitHub Actions examples, check and use the latest major
versions of actions and the active Node LTS at generation time; if the
repository already has `.github/workflows/`, treat those as the current
baseline instead of hardcoding versions.

## Output

- Journey tested
- Tests changed or generated
- Commands run and results
- Artifacts captured
- Flakes, gaps, or follow-up risks
