# /cross-review - Cross-Model Code Review

Request a code review from an alternative AI model for diverse perspectives.

## Instructions

Perform a cross-model review of recent changes to catch blind spots that a single model might miss.

### Steps

1. **Gather the diff**: Collect the current uncommitted changes or the diff of the last N commits.

   ```bash
   git diff  # uncommitted changes
   # or
   git diff HEAD~3..HEAD  # last 3 commits
   ```

2. **Self-review first**: Before delegating, perform your own review identifying:
   - Logic errors
   - Missing edge cases
   - Security concerns
   - Performance issues
   - Style/convention violations

3. **Delegate to Codex (if available)**: If Codex MCP is configured, send the diff to Codex for an independent review:
   - Ask Codex to review the diff for bugs, security issues, and design concerns
   - Codex brings a different model's perspective (GPT vs Claude)

4. **Synthesize**: Combine findings from both reviews:
   - Agreements (high confidence issues)
   - Disagreements (need human judgment)
   - Unique findings from each model

5. **Report**: Present a unified review with severity levels:
   - CRITICAL: Must fix before merge
   - WARNING: Should fix, but not blocking
   - SUGGESTION: Nice to have improvements

### Without Codex MCP

If Codex is not configured, perform a structured self-review using multiple passes:
1. Pass 1: Logic and correctness
2. Pass 2: Security and input validation
3. Pass 3: Performance and resource usage
4. Pass 4: Readability and maintainability

### Notes

- This is most valuable for security-sensitive or complex changes
- Not needed for trivial fixes or formatting changes
- Consider using after `/research` -> `/plan` -> implement cycle
