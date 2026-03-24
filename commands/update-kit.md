# /update-kit - Manually Update Starter Kit

Manually update the Claude Code Starter Kit to the latest version.

## Instructions

Run the following command to update the starter kit:

```bash
cd ~/.claude-starter-kit && git fetch --tags && git pull && bash setup.sh --update
```

### Steps

1. Run the update command above.
2. Report the result to the user:
   - If successful: show the previous and new version (`git describe --tags --abbrev=0`)
   - If the kit is already up to date: report "Already on the latest version"
   - If it fails: show the error and suggest manual steps
3. After a successful update, tell the user how to reload the new configuration:
   - Always suggest `/compact` to refresh the current session cleanly.
   - Also mention that some changes may require starting a new Claude Code session or opening a new terminal, especially settings/env changes, hook updates, MCP-related changes, or newly added slash commands.

### Notes

- This updates the kit installed at `~/.claude-starter-kit/` (one-liner install).
- If you cloned the repo elsewhere, `cd` to that directory instead.
- User-customized settings are preserved via 3-way merge (`setup.sh --update`).
- On older starter-kit installs that do not yet have a usable snapshot, the first `/update-kit` run will bootstrap a snapshot from the current `~/.claude` state and then continue as a migration update instead of falling back to a full re-setup.
- When a conflict is detected between user customizations and kit defaults, the update prompts for resolution. Users can choose `[RK] Keep & Remember` or `[RU] Use kit's & Remember` to save the decision for future updates.
- Saved merge decisions are stored in `~/.claude/.starter-kit-merge-prefs.json`. To reset all saved decisions, run `setup.sh --update --reset-prefs`.
- A backup of `~/.claude` is created before every update (`~/.claude.backup.<timestamp>`).
- To preview what an update would change without deploying, run `setup.sh --update --dry-run`. This shows a summary of files that would be created, modified, merged, or skipped, plus a diff of settings.json changes and a list of external operations (plugins, Ghostty, etc.). Light prerequisites (git, jq, curl) may be installed with consent in interactive mode; `--non-interactive --dry-run` installs nothing.
- Changes take effect in the **current** session (unlike auto-update which applies next session).
- `/compact` helps reload context, but it is not a full restart. If the update changes settings, hooks, env, MCP configuration, or command discovery, recommend restarting Claude Code as well.
