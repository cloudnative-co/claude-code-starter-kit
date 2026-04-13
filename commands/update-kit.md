# /update-kit - Manually Update Starter Kit

Manually update the Claude Code Starter Kit to the latest version.

## Instructions

Run the following command to update the starter kit:

```bash
cd ~/.claude-starter-kit && git fetch --tags && git pull && bash setup.sh --update
```

### Pre-flight Checks

Before running the update:
1. **Check for local changes**: `git -C ~/.claude-starter-kit status --porcelain`
   - If output is non-empty, stash or discard changes first: `cd ~/.claude-starter-kit && git stash -u`
2. **Verify the kit repo exists**: `ls ~/.claude-starter-kit/.git`
   - If not found, the kit was not installed via the one-liner. Re-install with: `curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash`

### Steps

1. **Before running the update**, the setup script automatically checks for user customizations. If kit-managed files have been modified by the user (snapshot differs from current), a dry-run preview is offered. If no customizations are detected, the update proceeds directly without asking.
2. Run the update command above.
   - This command uses the same `setup.sh --update` path as the local script, so the same `Step N/M` progress output appears here as well.
3. Report the result to the user:
   - If successful: show the previous and new version (`git describe --tags --abbrev=0`)
   - If the kit is already up to date: report "Already on the latest version"
   - If it fails: show the error and suggest manual steps
4. After a successful update, tell the user how to reload the new configuration:
   - Always suggest `/compact` to refresh the current session cleanly.
   - Also mention that some changes may require starting a new Claude Code session or opening a new terminal, especially settings/env changes, hook updates, MCP-related changes, or newly added slash commands.

### Pending Feature Review

After a successful update (or if already up to date), check for pending feature recommendations.

**Note**: Always use the Read tool (not `cat`) to read files, and the Edit tool to modify `~/.claude-starter-kit.conf`. Skip any feature named `feature-recommendation` if it appears in the pending list (self-referential — should not happen, but guard against it).

#### Step 1: Check for pending features

Read `~/.claude/.starter-kit-pending-features.json`. If the file does not exist or is empty, skip this section entirely.

#### Step 2: Resolve feature flag names

Read `~/.claude-starter-kit/lib/features.sh` and find the `_FEATURE_FLAGS` associative array. Each entry maps feature name to `ENABLE_*` variable (e.g., `[doc-size-guard]=ENABLE_DOC_SIZE_GUARD`). Build a mapping for the pending features.

#### Step 3: Present each feature to the user

For each feature name in the `features` array (one at a time):

1. Read `~/.claude-starter-kit/features/<name>/feature.json` to get `displayName` and `description`
2. If `feature.json` has a non-empty `conflicts` array, check if any conflicting features are currently enabled. If so, mention the conflict to the user
3. Present to the user:
   ```
   新機能: <displayName>
   <description>
     1) 有効にする
     2) 今はいい（次回また聞きます）
     3) 今後聞かない
   ```
4. Ask the user to choose

#### Step 4: Apply choices

After all features are reviewed, apply in this order:

**有効にする (choice 1)**: Read `~/.claude-starter-kit.conf` with the Read tool, then use the Edit tool:
- If a line `ENABLE_<FLAG>=...` already exists → replace the entire line with `ENABLE_<FLAG>="true"`
- If no such line exists → append `ENABLE_<FLAG>="true"` before the `SELECTED_PLUGINS` line (or at end of file)

**今はいい (choice 2)**: Do nothing. Feature stays in pending list for next session.

**今後聞かない (choice 3)**: Read `~/.claude-starter-kit.conf`, find the `DISMISSED_FEATURES="..."` line:
- Extract current CSV value. If feature name is already in it, skip
- Append the feature name with comma separator (e.g., `""` → `"feat-name"`, `"a,b"` → `"a,b,feat-name"`)
- Use the Edit tool to replace the `DISMISSED_FEATURES="..."` line

#### Step 5: Update pending-features.json

Remove features that were enabled (choice 1) or dismissed (choice 3) from the `features` array. Keep features where the user chose "今はいい" (choice 2).

```bash
# Example: remove "doc-size-guard" from pending, keep the rest
jq '.features |= map(select(. != "doc-size-guard"))' \
  ~/.claude/.starter-kit-pending-features.json > /tmp/pf.$$ \
  && mv /tmp/pf.$$ ~/.claude/.starter-kit-pending-features.json
```

If the `features` array is now empty, delete the file: `rm -f ~/.claude/.starter-kit-pending-features.json`

#### Step 6: Regenerate settings.json

If any features were enabled (choice 1), run:

```bash
cd ~/.claude-starter-kit && bash setup.sh --update
```

This re-executes the 3-way merge path, safely regenerating `settings.json` while preserving user additions like `mcpServers`.

### Recovery

If an update goes wrong:
- A backup is automatically created at `~/.claude.backup.<timestamp>` before each update
- The latest backup path is saved in `~/.claude/.starter-kit-last-backup`
- To restore: `BACKUP=$(cat ~/.claude/.starter-kit-last-backup) && mv ~/.claude ~/.claude.broken && cp -a "$BACKUP" ~/.claude`
- To reset saved merge decisions: `bash setup.sh --update --reset-prefs`

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
