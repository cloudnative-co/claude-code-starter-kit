# Build and Fix

Fix build errors by root cause, in batches:

1. Detect the project's build command (package.json scripts, Makefile,
   pyproject.toml, etc.) and run it.

2. Parse error output and group errors by root cause:
   - A changed type/interface, a renamed symbol, or a missing dependency
     often explains many downstream errors at once.

3. Fix related errors as a batch. After each batch, re-check with the
   fastest available verification (e.g. `tsc --noEmit`, incremental build,
   affected-package build) instead of a full rebuild.

4. Run the full build once at the end to confirm.

5. Stop if:
   - The error count is increasing, or fixes are going in circles
   - Same error persists after 3 attempts
   - User requests pause

6. Show summary:
   - Errors fixed
   - Errors remaining
   - New errors introduced
