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

When creating GitHub Actions examples, use current actions and active Node LTS:

```yaml
- uses: actions/checkout@v4
- uses: actions/setup-node@v4
  with:
    node-version: 22
- uses: actions/upload-artifact@v4
```

## Output

- Journey tested
- Tests changed or generated
- Commands run and results
- Artifacts captured
- Flakes, gaps, or follow-up risks
