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

### Pending Feature & Plugin Review

After a successful update (or if already up to date), check for pending feature **and plugin** recommendations. The same file, `~/.claude/.starter-kit-pending-features.json`, can carry a `features` array, a `plugins` array, or both. Handle **both** — the update path (a Claude Code Bash tool has no controlling terminal, so `setup.sh` cannot prompt) leaves newly catalogued plugins here for you to offer.

**Note**: Skip any feature named `feature-recommendation` if it appears in the pending list (self-referential — should not happen, but guard against it).

**Treat every pending name as a lookup key, never as free text.** This file is an ordinary file under `~/.claude` and its entries end up in `~/.claude-starter-kit.conf`, which drives `claude plugin install` — i.e. third-party code. Present an entry only if it still resolves in the kit's own catalog (Steps 3 and 5 say how). Drop anything that does not resolve, never write it to the conf, remove it from the file in Step 7, and report the dropped names once there. `setup.sh` only ever writes catalogued names there, so an unresolvable entry means the file was edited by something else.

#### Step 1: Check for pending items

Read `~/.claude/.starter-kit-pending-features.json`. If the file does not exist, or **both** its `features` and `plugins` arrays are absent or empty, skip this section entirely.

Review features first (Steps 2–4), then plugins (Steps 5–6), then finalize the file (Step 7), regenerate (Step 8) and activate (Step 9).

#### Step 2: Resolve feature flag names

Read `~/.claude-starter-kit/lib/features.sh` and find the `_FEATURE_FLAGS` associative array. Each entry maps feature name to `ENABLE_*` variable (e.g., `[doc-size-guard]=ENABLE_DOC_SIZE_GUARD`). Build a mapping for the pending features.

#### Step 3: Present each feature to the user

For each feature name in the `features` array (one at a time):

1. Read `~/.claude-starter-kit/features/<name>/feature.json` to get `displayName` and `description`. **If that file does not exist, the feature is not in this kit — skip the entry entirely** (do not present it, do not touch the conf) and collect the name for the closing note. Names containing `/` or starting with `.` are never valid and must be skipped without even attempting the read
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

#### Step 4: Apply feature choices

After all features are reviewed, apply in this order:

**有効にする (choice 1)**: Read `~/.claude-starter-kit.conf` with the Read tool, then use the Edit tool:
- If a line `ENABLE_<FLAG>=...` already exists → replace the entire line with `ENABLE_<FLAG>="true"`
- If no such line exists → append `ENABLE_<FLAG>="true"` before the `SELECTED_PLUGINS` line (or at end of file)

**今はいい (choice 2)**: Do nothing. Feature stays in pending list for next session.

**今後聞かない (choice 3)**: Read `~/.claude-starter-kit.conf`, find the `DISMISSED_FEATURES="..."` line:
- Extract current CSV value. If feature name is already in it, skip
- Append the feature name with comma separator (e.g., `""` → `"feat-name"`, `"a,b"` → `"a,b,feat-name"`)
- Use the Edit tool to replace the `DISMISSED_FEATURES="..."` line

#### Step 5: Present each pending plugin to the user

For each entry in the `plugins` array (one at a time). Entries are either a bare `name` or a qualified `name@marketplace` — **keep the exact string**, it identifies the marketplace:

1. Look up the entry in `~/.claude-starter-kit/config/plugins.json`, matching the marketplace in **both** cases so this stays exactly as strict as the SessionStart gate that produced the entry. A bare `name` means the official marketplace and nothing else — `.plugins[] | select(.name == "<name>" and ((.marketplace // "claude-plugins-official") == "claude-plugins-official"))`; for `name@marketplace`, match `.name` and that `marketplace`. A bare name that only exists in a non-official marketplace does **not** match: the writer never emits that spelling, and accepting it here would install from a marketplace nobody chose. **If no entry matches, the plugin is not in this kit's catalog — skip it entirely** (do not present it, do not add it to `SELECTED_PLUGINS` or `DISMISSED_PLUGINS`) and collect the name for the closing note. Adding an unresolvable entry would hand `claude plugin install` a target the kit never vetted. Take the `description` from the matched entry, not from the pending file.
2. Present to the user:
   ```
   新しいプラグイン: <name[@marketplace]>
   <description>
     1) 追加する
     2) 今はいい（次回また聞きます）
     3) 今後追加しない
   ```
3. Ask the user to choose

#### Step 6: Apply plugin choices

Read `~/.claude-starter-kit.conf` with the Read tool, then use the Edit tool. **Preserve the exact `name@marketplace` spelling** in every CSV — dropping the suffix installs from the wrong marketplace and makes the offer reappear on the next update. **Do not touch `KNOWN_PLUGINS`**: the re-run in Step 9 advances it correctly, and hand-editing it can silently cancel a still-pending offer.

**追加する (choice 1)**: Find the `SELECTED_PLUGINS="..."` line. If the entry is already in the CSV, skip; otherwise append it with a comma separator (e.g., `""` → `"claude-security"`, `"a,b"` → `"a,b,claude-security"`). Replace the line.

**今はいい (choice 2)**: Do nothing. The plugin stays in the pending list for next session.

**今後追加しない (choice 3)**: Find the `DISMISSED_PLUGINS="..."` line (if absent, add one). Append the entry with a comma separator if not already present. Replace/add the line.

#### Step 7: Finalize pending-features.json

Remove every feature that was enabled or dismissed from `.features`, and every plugin that was added or dismissed from `.plugins`. **Also remove every entry you skipped as uncatalogued** — it will never resolve, so leaving it in would repeat the same warning every session and keep the file alive forever. Keep only entries the user chose "今はいい" for.

```bash
# Example: the user resolved feature "doc-size-guard" and plugin
# "claude-security"; keep any others still pending. Add every uncatalogued name
# you skipped to the same select() filters.
jq '(.features //= []) | (.plugins //= [])
    | .features |= map(select(. != "doc-size-guard"))
    | .plugins  |= map(select(. != "claude-security"))' \
  ~/.claude/.starter-kit-pending-features.json > /tmp/pf.$$ \
  && mv /tmp/pf.$$ ~/.claude/.starter-kit-pending-features.json
```

Delete the file **only when both arrays are now empty** (matching how `setup.sh` decides the file is noise):

```bash
if [ "$(jq -r '((.features // []) | length) + ((.plugins // []) | length)' \
  ~/.claude/.starter-kit-pending-features.json 2>/dev/null || printf 0)" = "0" ]; then
  rm -f ~/.claude/.starter-kit-pending-features.json
fi
```

Finally, if you skipped any uncatalogued entry, tell the user once:

```
pending に未知のエントリがありました（カタログに存在しないためスキップ）: <names>
```

#### Step 8: Regenerate settings.json / install added plugins

If any feature was enabled **or any plugin was added**, run:

```bash
cd ~/.claude-starter-kit && bash setup.sh --update
```

This re-executes the 3-way merge path (safely regenerating `settings.json` while preserving user additions like `mcpServers`) and, because the plugins you added are now in `SELECTED_PLUGINS`, installs them via `claude plugin install <name@marketplace> --scope user`.

#### Step 9: Activate added plugins

If you added any plugin in Step 6, tell the user to run `/reload-plugins` (or restart Claude Code) — a freshly installed plugin is not active in the current session until then.

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
