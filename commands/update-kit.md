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

### Notes

- This updates the kit installed at `~/.claude-starter-kit/` (one-liner install).
- If you cloned the repo elsewhere, `cd` to that directory instead.
- User-customized settings are preserved via 3-way merge (`setup.sh --update`).
- Changes take effect in the **current** session (unlike auto-update which applies next session).
- After updating, suggest the user run `/compact` to load the new configuration cleanly.
