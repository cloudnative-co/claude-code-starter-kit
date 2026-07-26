#!/bin/bash
# wizard/runtime-binding.sh - Validate the non-MDM update runtime identity.

_restore_manifest_runtime_config_binding() {
  local manifest="$HOME/.claude/.starter-kit-manifest.json"
  local binding manifest_repo manifest_config project_physical
  local config_parent config_leaf config_parent_physical canonical_config
  local line config_repo="" matches=0

  # An explicit --config remains authoritative. parse_cli_args has already
  # loaded it by the time update restoration runs.
  [[ -z "${WIZARD_CONFIG_FILE:-}" ]] || return 0

  # Existing leaves must be regular files. Never follow a user-controlled
  # manifest symlink while selecting the config setup will later replace.
  [[ -e "$manifest" || -L "$manifest" ]] || return 0
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1

  binding="$(jq -cs '
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
        else null
        end
    else error("invalid manifest")
    end
  ' "$manifest" 2>/dev/null)" || return 1

  # Manifests predating runtime binding keep the historical default config.
  [[ "$binding" != "null" ]] || return 0
  manifest_repo="$(printf '%s' "$binding" | jq -r '.[0]' 2>/dev/null)" \
    || return 1
  manifest_config="$(printf '%s' "$binding" | jq -r '.[1]' 2>/dev/null)" \
    || return 1

  project_physical="$(builtin cd -P "${PROJECT_DIR:-}" 2>/dev/null && pwd -P)" \
    || return 1
  [[ "$manifest_repo" == "$project_physical" ]] || return 1

  # The writer records a physical parent plus a leaf. Reconstruct that exact
  # shape so aliases through symlinked parents or dot segments are rejected.
  config_parent="${manifest_config%/*}"
  config_leaf="${manifest_config##*/}"
  [[ -n "$config_parent" ]] || config_parent="/"
  [[ -n "$config_leaf" && "$config_leaf" != "." && "$config_leaf" != ".." ]] \
    || return 1
  config_parent_physical="$(builtin cd -P "$config_parent" 2>/dev/null && pwd -P)" \
    || return 1
  if [[ "$config_parent_physical" == "/" ]]; then
    canonical_config="/$config_leaf"
  else
    canonical_config="$config_parent_physical/$config_leaf"
  fi
  [[ "$manifest_config" == "$canonical_config" ]] || return 1
  [[ -f "$manifest_config" && ! -L "$manifest_config" ]] || return 1

  # Match the format emitted by save_config exactly once. Any alternative
  # KIT_REPO assignment would make the runtime identity ambiguous.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^KIT_REPO=\"([^\"]+)\"$ ]]; then
      matches=$((matches + 1))
      config_repo="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*KIT_REPO[[:space:]]*= ]]; then
      return 1
    fi
  done < "$manifest_config"
  [[ "$matches" -eq 1 && "$config_repo" == "$manifest_repo" ]] || return 1

  # Assign only after complete validation, preserving UTF-8 and '+' bytes.
  WIZARD_CONFIG_FILE="$manifest_config"
}
