# /update-kit-dry-run - Preview Update Changes

Preview what `/update-kit` would change without actually deploying.

## Instructions

Run the following block as one Bash invocation. It uses the same strict,
non-evaluating manifest/config lookup as `/update-kit`: a current non-MDM
manifest binds the checkout to the exact config used at install time, while a
legacy or MDM manifest uses `~/.claude-starter-kit.conf`. A legacy config with
no `KIT_REPO` key falls back to `~/.claude-starter-kit`. An invalid explicit
binding, key, or repository stops the preview instead of silently using another
path.

```bash
set -euo pipefail

default_config_file="$HOME/.claude-starter-kit.conf"
config_file="$default_config_file"
default_kit_repo="$HOME/.claude-starter-kit"
kit_repo="$default_kit_repo"
manifest_file="$HOME/.claude/.starter-kit-manifest.json"
manifest_bound=false

if [ -e "$manifest_file" ] || [ -L "$manifest_file" ]; then
  if [ -L "$manifest_file" ] || [ ! -f "$manifest_file" ]; then
    printf '%s\n' "Invalid starter-kit manifest: $manifest_file" >&2
    exit 1
  fi
  manifest_binding="$(jq -cse '
    if length == 1 and (.[0] | type == "object") then
      .[0]
      | if (has("kit_repo") or has("config_file")) then
          if (has("kit_repo") and has("config_file")
            and (.mdm_managed == false)
            and ((.kit_repo | type) == "string")
            and ((.config_file | type) == "string")
            and (.kit_repo | startswith("/"))
            and (.config_file | startswith("/"))
            and ((.kit_repo | test("[\\x00-\\x1f\\x7f]")) | not)
            and ((.config_file | test("[\\x00-\\x1f\\x7f]")) | not))
          then [.kit_repo, .config_file]
          else error("invalid runtime binding")
          end
        else []
        end
    else error("invalid manifest")
    end
  ' "$manifest_file" 2>/dev/null)" || {
    printf '%s\n' "Invalid starter-kit manifest binding" >&2
    exit 1
  }
  if [ "$manifest_binding" != "[]" ]; then
    kit_repo="$(printf '%s' "$manifest_binding" | jq -r '.[0]')" || exit 1
    config_file="$(printf '%s' "$manifest_binding" | jq -r '.[1]')" || exit 1
    manifest_bound=true
  fi
fi

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
    if [ "${kit_repo_line#KIT_REPO=\"}" = "$kit_repo_line" ] \
      || [ "${kit_repo_line%\"}" = "$kit_repo_line" ]; then
      printf '%s\n' "Invalid KIT_REPO entry in starter-kit config" >&2
      exit 1
    fi
    config_kit_repo="${kit_repo_line#KIT_REPO=\"}"
    config_kit_repo="${config_kit_repo%\"}"
    case "$config_kit_repo" in
      /*) ;;
      *)
        printf '%s\n' "Invalid KIT_REPO entry in starter-kit config" >&2
        exit 1
        ;;
    esac
    case "$config_kit_repo" in
      *'"'*)
        printf '%s\n' "Invalid KIT_REPO entry in starter-kit config" >&2
        exit 1
        ;;
    esac
    if printf '%s' "$config_kit_repo" | LC_ALL=C grep -q '[[:cntrl:]]'; then
      printf '%s\n' "Invalid KIT_REPO entry in starter-kit config" >&2
      exit 1
    fi
    if [ "$manifest_bound" = true ] && [ "$config_kit_repo" != "$kit_repo" ]; then
      printf '%s\n' "Manifest binding does not match starter-kit config" >&2
      exit 1
    fi
    kit_repo="$config_kit_repo"
  elif [ "$manifest_bound" = true ]; then
    printf '%s\n' "Manifest-bound config has no KIT_REPO entry" >&2
    exit 1
  fi
elif [ "$manifest_bound" = true ]; then
  printf '%s\n' "Manifest-bound config not found: $config_file" >&2
  exit 1
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
printf 'Resolved config file: %s\n' "$config_file"
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
setup_args=(--update --dry-run)
if [ "$manifest_bound" = true ]; then
  setup_args+=("--config=$config_file")
fi
(cd "$kit_repo_physical" && bash setup.sh "${setup_args[@]}")
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
- Custom checkouts come from the validated manifest-bound config's `KIT_REPO`
  entry; legacy and MDM installs use the default config, and only legacy configs
  without that key use `~/.claude-starter-kit`.
- Use this before `/update-kit` to understand the impact, especially after a major kit version bump.
