# /update-kit-dry-run - Preview Update Changes

Preview what `/update-kit` would change without actually deploying.

## Instructions

Run the following command:

```bash
cd ~/.claude-starter-kit && git fetch --tags && git pull && bash setup.sh --update --dry-run
```

### Steps

1. Run the dry-run command above.
   - This uses the same `setup.sh --update --dry-run` path as the local script and is labeled as `Preview Mode` in the output.
2. Report the results to the user:
   - **Files to create**: New files the kit would add
   - **Files to modify**: Existing files that would change
   - **Files to delete**: Files that would be removed (e.g., legacy files)
   - **Files to skip**: User-owned files that would be preserved
   - **External operations**: Actions like plugin installs, shown as `[WOULD RUN]`
   - **settings.json diff**: Unified diff of what would change in settings
3. After showing the summary, let the user know:
   - If they want to proceed: run `/update-kit`
   - If they want to cancel: no action needed, nothing was changed

### Notes

- This is a **read-only preview** — no files are deployed, no backups are created, no external operations are executed.
- The comparison basis is always "current `~/.claude`" vs "what would be deployed".
- Merge preferences (saved `[RK]/[RU]` decisions) are read but never modified.
- The simulation runs in a temporary directory that is cleaned up automatically.
- Use this before `/update-kit` to understand the impact, especially after a major kit version bump.
