# /update-kit-dry-run - Preview Update Changes

Preview what `/update-kit` would change without actually deploying.

## Instructions

Run the following block as one Bash invocation. It uses the same strict,
non-evaluating `KIT_REPO="..."` lookup as `/update-kit`: a valid key in
`~/.claude-starter-kit.conf` selects the checkout, while a legacy config with
no key falls back to `~/.claude-starter-kit`. An invalid explicit key or an
invalid repository stops the preview instead of silently using another path.

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
  printf '%s\n' "Local changes found; review them before previewing" >&2
  exit 1
fi

git -C "$kit_repo_physical" fetch --tags
git -C "$kit_repo_physical" pull --ff-only
(cd "$kit_repo_physical" && bash setup.sh --update --dry-run)
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
   - If they want to cancel: no starter-kit deployment was applied; the selected
     checkout may already have been fast-forwarded, and any prerequisite install
     they explicitly approved remains in place

### Notes

- This is a **deployment preview**: it fetches and fast-forwards the selected
  kit checkout, but deploys no files to `~/.claude`, creates no deployment
  backup, and executes no feature-specific external setup operations. Light
  prerequisites may still be installed with explicit consent. Add
  `--non-interactive` to the final setup command in the validated block when
  prerequisite installation must be disabled.
- The comparison basis is always "current `~/.claude`" vs "what would be deployed".
- Merge preferences (saved `[RK]/[RU]` decisions) are read but never modified.
- The simulation runs in a temporary directory that is cleaned up automatically.
- Custom checkouts come from the validated `KIT_REPO` config entry; only legacy
  configs without that key use `~/.claude-starter-kit`.
- Use this before `/update-kit` to understand the impact, especially after a major kit version bump.
