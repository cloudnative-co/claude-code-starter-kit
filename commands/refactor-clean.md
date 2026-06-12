# Refactor Clean

Safely identify and remove dead code with test verification:

1. Run dead-code analysis appropriate to the project language
   (e.g. knip/depcheck/ts-prune for JS/TS, vulture for Python,
   deadcode for Go, shellcheck + reference grep for shell).

2. Generate a report (e.g. .reports/dead-code-analysis.md).

3. Categorize findings by severity:
   - SAFE: Test files, unused internal utilities
   - CAUTION: Public APIs / exported interfaces, route handlers, UI components
   - DANGER: Config files, main entry points

4. Verification flow:
   - Run the full test suite once to establish a green baseline
   - Apply SAFE deletions as a batch, one commit per deletion or logical
     group (easy rollback)
   - Run focused tests per batch, then the full suite once at the end
   - On failure, bisect the batch and revert only the offending deletion
   - Handle CAUTION items individually with focused tests
   - DANGER items are report-only — do not delete

5. Show summary of cleaned items

Never delete code without running tests first!
