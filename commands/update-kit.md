# /update-kit - Manually Update Starter Kit

Manually update the Claude Code Starter Kit to the latest version.

## Instructions

Run the following block as one Bash invocation. It resolves the checkout from
the strict `KIT_REPO="..."` entry in `~/.claude-starter-kit.conf`, without
sourcing or evaluating the config. It validates that the absolute path is the
root of a Git worktree containing this kit, and then updates it. A legacy config
without `KIT_REPO` (or no config) falls back to `~/.claude-starter-kit`.
An invalid explicit `KIT_REPO` is an error — do not
silently fall back to a different checkout.

```bash
set -euo pipefail

config_file="$HOME/.claude-starter-kit.conf"
default_kit_repo="$HOME/.claude-starter-kit"
kit_repo="$default_kit_repo"

if [ -e "$config_file" ] || [ -L "$config_file" ]; then
  if [ -L "$config_file" ] || [ ! -f "$config_file" ] \
    || [ ! -r "$config_file" ]; then
    printf '%s\n' "Invalid starter-kit config: $config_file" >&2
    exit 1
  fi
  kit_repo_count="$(awk '
    /^[[:space:]]*KIT_REPO[[:space:]]*=/ { count++ }
    END { print count + 0 }
  ' "$config_file")" || {
    printf '%s\n' "Could not read starter-kit config" >&2
    exit 1
  }
  if [ "$kit_repo_count" -gt 1 ]; then
    printf '%s\n' "Multiple KIT_REPO entries in starter-kit config" >&2
    exit 1
  fi
  if [ "$kit_repo_count" -eq 1 ]; then
    kit_repo_line="$(awk '
      /^[[:space:]]*KIT_REPO[[:space:]]*=/ { print }
    ' "$config_file")" || exit 1
    if ! printf '%s\n' "$kit_repo_line" \
      | grep -Eq '^KIT_REPO="/[A-Za-z0-9_,.:@/ -]+"$'; then
      printf '%s\n' "Invalid KIT_REPO entry in starter-kit config" >&2
      exit 1
    fi
    kit_repo="${kit_repo_line#KIT_REPO=\"}"
    kit_repo="${kit_repo%\"}"
  fi
fi

kit_repo_physical="$(cd "$kit_repo" 2>/dev/null && pwd -P)" || {
  printf '%s\n' "Starter-kit checkout not found: $kit_repo" >&2
  exit 1
}
repo_top="$(git -C "$kit_repo_physical" rev-parse --show-toplevel 2>/dev/null)" || {
  printf '%s\n' "Not a Git checkout: $kit_repo_physical" >&2
  exit 1
}
repo_top_physical="$(cd "$repo_top" 2>/dev/null && pwd -P)" || exit 1
if [ "$kit_repo_physical" != "$repo_top_physical" ] \
  || [ ! -e "$kit_repo_physical/.git" ] \
  || [ ! -f "$kit_repo_physical/setup.sh" ] \
  || [ ! -f "$kit_repo_physical/lib/features.sh" ] \
  || [ ! -f "$kit_repo_physical/config/plugins.json" ]; then
  printf '%s\n' "KIT_REPO is not a starter-kit repository root" >&2
  exit 1
fi

printf 'Resolved kit repo: %s\n' "$kit_repo_physical"
repo_status="$(git -C "$kit_repo_physical" status --porcelain)" || {
  printf '%s\n' "Could not inspect starter-kit checkout" >&2
  exit 1
}
if [ -n "$repo_status" ]; then
  printf '%s\n' "Local changes found; review them before updating" >&2
  exit 1
fi

previous_version="$(git -C "$kit_repo_physical" describe --tags --abbrev=0 \
  2>/dev/null || printf 'unknown')"
git -C "$kit_repo_physical" fetch --tags
git -C "$kit_repo_physical" pull --ff-only
(cd "$kit_repo_physical" && bash setup.sh --update)
new_version="$(git -C "$kit_repo_physical" describe --tags --abbrev=0 \
  2>/dev/null || printf 'unknown')"
printf 'Starter kit version: %s -> %s\n' "$previous_version" "$new_version"
```

### Pre-flight Checks

Before running the update:
1. **Resolve and validate the checkout** with the block above. Record the
   `Resolved kit repo` path; all catalog reads below must use that exact path.
2. **Check for local changes**. The block stops before `pull` when the checkout
   is dirty. Review the changes with `git -C "<resolved path>" status`; ask the
   user before stashing or discarding anything.
3. **Handle a missing legacy checkout**. If the fallback path does not exist,
   the kit was not installed via the one-liner. Re-install with:
   `curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash`.

### Steps

1. **Before running the update**, the setup script automatically checks for user customizations. If kit-managed files have been modified by the user (snapshot differs from current), a dry-run preview is offered. If no customizations are detected, the update proceeds directly without asking.
2. Run the self-contained update block above.
   - This command uses the same `setup.sh --update` path as the local script, so the same `Step N/M` progress output appears here as well.
3. Report the result to the user:
   - If successful: show the previous and new version printed by the update block
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

Validate `~/.claude/.starter-kit-pending-features.json` before reading any
entry. A symlink, non-regular file, zero-byte file, anything other than exactly
one JSON document, a non-object root, non-array `features` / `plugins`, or a
non-string array entry is invalid.
On invalid input, preserve the file unchanged, stop pending processing, and
report the error; never treat parse failure as an empty list.

```bash
pending_file="$HOME/.claude/.starter-kit-pending-features.json"
if [ -e "$pending_file" ] || [ -L "$pending_file" ]; then
  if [ -L "$pending_file" ] || [ ! -f "$pending_file" ] \
    || ! jq -e -s '
      length == 1
      and (.[0] |
        type == "object"
        and ((has("features") | not) or (.features | type == "array"))
        and ((has("plugins") | not) or (.plugins | type == "array"))
        and all(.features[]?; type == "string")
        and all(.plugins[]?; type == "string")
      )
    ' "$pending_file" >/dev/null; then
    printf '%s\n' "Invalid pending file; preserved unchanged: $pending_file" >&2
    exit 1
  fi
fi
```

If the file does not exist, or the validated file has **both** its `features`
and `plugins` arrays absent or empty, skip this section entirely.

Review features first (Steps 2–4), then plugins (Steps 5–6), then finalize the file (Step 7), regenerate (Step 8) and activate (Step 9).

#### Step 2: Resolve feature flag names

Read `lib/features.sh` under the validated kit repository and find the
`_FEATURE_FLAGS` associative array. Each entry maps feature name to `ENABLE_*`
variable (e.g., `[doc-size-guard]=ENABLE_DOC_SIZE_GUARD`). Build a mapping for
the pending features. This registry — not directory existence — is the feature
allowlist.

#### Step 3: Present each feature to the user

For each feature name in the `features` array (one at a time):

1. Require the name to be an exact key in `_FEATURE_FLAGS`, then read
   `features/<name>/feature.json` under the same validated kit repository to get
   `displayName` and `description`. **If the registry entry or metadata file is
   missing, skip the entry entirely** (do not present it, do not touch the conf)
   and collect the name for the closing note. This rejects special components
   such as `fonts`, `ghostty`, and `codex-plugin`, even though they have metadata.
   Always skip the self-referential `feature-recommendation` entry. Names
   containing `/` or starting with `.` are never valid and must be skipped
   without even attempting the read
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

1. Look up the entry in `config/plugins.json` under the validated kit repository,
   matching the marketplace in **both** cases so this stays exactly as strict as
   the SessionStart gate that produced the entry. A bare `name` means the
   official marketplace and nothing else — `.plugins[] | select(.name ==
   "<name>" and ((.marketplace // "claude-plugins-official") ==
   "claude-plugins-official"))`; for `name@marketplace`, match `.name` and that
   `marketplace`. A bare name that only exists in a non-official marketplace does
   **not** match: the writer never emits that spelling, and accepting it here
   would install from a marketplace nobody chose. **If no entry matches, the
   plugin is not in this kit's catalog — skip it entirely** (do not present it,
   do not add it to `SELECTED_PLUGINS` or `DISMISSED_PLUGINS`) and collect the
   name for the closing note. Adding an unresolvable entry would hand `claude
   plugin install` a target the kit never vetted. Take the `description` from
   the matched entry, not from the pending file.
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

Read `~/.claude-starter-kit.conf` with the Read tool, then use the Edit tool. **Preserve the exact `name@marketplace` spelling** in every CSV — dropping the suffix installs from the wrong marketplace and makes the offer reappear on the next update. **Do not touch `KNOWN_PLUGINS`**: the re-run in Step 8 advances it correctly, and hand-editing it can silently cancel a still-pending offer.

**追加する (choice 1)**: Find the `SELECTED_PLUGINS="..."` line. If the entry is already in the CSV, skip; otherwise append it with a comma separator (e.g., `""` → `"claude-security"`, `"a,b"` → `"a,b,claude-security"`). Replace the line.

**今はいい (choice 2)**: Do nothing. The plugin stays in the pending list for next session.

**今後追加しない (choice 3)**: Find the `DISMISSED_PLUGINS="..."` line (if absent, add one). Append the entry with a comma separator if not already present. Replace/add the line.

#### Step 7: Finalize pending-features.json

Remove every feature that was enabled or dismissed from `.features`, and every plugin that was added or dismissed from `.plugins`. **Also remove every entry you skipped as uncatalogued** — it will never resolve, so leaving it in would repeat the same warning every session and keep the file alive forever. Keep only entries the user chose "今はいい" for. Delete the file **only when both arrays are now empty** (matching how `setup.sh` decides the file is noise).

```bash
# Example: the user resolved feature "doc-size-guard" and plugin
# "claude-security"; keep any others still pending. Add every uncatalogued name
# you skipped to the same select() filters.
pending_file="$HOME/.claude/.starter-kit-pending-features.json"
pending_dir="${pending_file%/*}"
if [ -L "$pending_file" ] || [ ! -f "$pending_file" ]; then
  printf '%s\n' "Invalid pending file; preserved unchanged: $pending_file" >&2
  exit 1
fi
pending_snapshot="$(mktemp "$pending_dir/.starter-kit-pending-features.json.snapshot.XXXXXX")" \
  || exit 1
pending_tmp=""
trap 'rm -f "$pending_snapshot" "$pending_tmp"' EXIT
trap 'exit 1' HUP INT TERM
chmod 600 "$pending_snapshot" || exit 1

if ! jq -e -s '
  if length == 1
    and (.[0] |
      type == "object"
      and ((has("features") | not) or (.features | type == "array"))
      and ((has("plugins") | not) or (.plugins | type == "array"))
      and all(.features[]?; type == "string")
      and all(.plugins[]?; type == "string")
    )
  then .[0]
  else error("invalid pending file")
  end
' "$pending_file" > "$pending_snapshot"; then
  printf '%s\n' "Invalid pending file; preserved unchanged: $pending_file" >&2
  exit 1
fi
pending_tmp="$(mktemp "$pending_dir/.starter-kit-pending-features.json.tmp.XXXXXX")" \
  || exit 1
chmod 600 "$pending_tmp" || exit 1

jq -e '(.features //= []) | (.plugins //= [])
    | .features |= map(select(. != "doc-size-guard"))
    | .plugins  |= map(select(. != "claude-security"))' \
  "$pending_snapshot" > "$pending_tmp" || exit 1

if jq -e '
  ((.features // []) | length == 0)
  and ((.plugins // []) | length == 0)
' "$pending_tmp" >/dev/null; then
  rm -f "$pending_file" || exit 1
else
  mv "$pending_tmp" "$pending_file" || exit 1
fi
rm -f "$pending_snapshot" "$pending_tmp" || exit 1
trap - EXIT HUP INT TERM
```

Finally, if you skipped any uncatalogued entry, tell the user once:

```
pending に未知のエントリがありました（カタログに存在しないためスキップ）: <names>
```

#### Step 8: Regenerate settings.json / install added plugins

If any feature was enabled **or any plugin was added**, rerun the complete,
self-contained update block from **Instructions**. It resolves and validates
the config path again before executing `setup.sh --update`; do not assume a
shell variable from the earlier Bash call is still set.

This re-executes the 3-way merge path (safely regenerating `settings.json` while preserving user additions like `mcpServers`) and, because the plugins you added are now in `SELECTED_PLUGINS`, installs them via `claude plugin install <name@marketplace> --scope user`.

#### Step 9: Activate added plugins

If you added any plugin in Step 6, tell the user to run `/reload-plugins` (or restart Claude Code) — a freshly installed plugin is not active in the current session until then.

### Recovery

If an update goes wrong:
- A backup is automatically created at `~/.claude.backup.<timestamp>` before each update
- The latest backup path is saved in `~/.claude/.starter-kit-last-backup`
- To restore: `BACKUP=$(cat ~/.claude/.starter-kit-last-backup) && mv ~/.claude ~/.claude.broken && cp -a "$BACKUP" ~/.claude`
- To reset saved merge decisions, rerun the self-contained update block with
  its final setup command changed to
  `(cd "$kit_repo_physical" && bash setup.sh --update --reset-prefs)`

### Notes

- This updates the checkout recorded as `KIT_REPO` in
  `~/.claude-starter-kit.conf`. Legacy configs without the key use
  `~/.claude-starter-kit` as a fallback.
- A custom checkout requires no manual `cd`; use the validated config path.
- User-customized settings are preserved via 3-way merge (`setup.sh --update`).
- On older starter-kit installs that do not yet have a usable snapshot, the first `/update-kit` run will bootstrap a snapshot from the current `~/.claude` state and then continue as a migration update instead of falling back to a full re-setup.
- When a conflict is detected between user customizations and kit defaults, the update prompts for resolution. Users can choose `[RK] Keep & Remember` or `[RU] Use kit's & Remember` to save the decision for future updates.
- Saved merge decisions are stored in `~/.claude/.starter-kit-merge-prefs.json`.
  Use the validated reset procedure in **Recovery** rather than a relative path.
- A backup of `~/.claude` is created before every update (`~/.claude.backup.<timestamp>`).
- To preview what an update would change without deploying, run
  `/update-kit-dry-run`. This shows a summary of files that would be created,
  modified, merged, or skipped, plus a diff of settings.json changes and a list
  of external operations (plugins, Ghostty, etc.). Light prerequisites (git,
  jq, curl) may be installed with consent in interactive mode;
  `--non-interactive --dry-run` installs nothing.
- Changes take effect in the **current** session (unlike auto-update which applies next session).
- `/compact` helps reload context, but it is not a full restart. If the update changes settings, hooks, env, MCP configuration, or command discovery, recommend restarting Claude Code as well.
