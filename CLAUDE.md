# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Code Starter Kit — a shell-based toolkit that bootstraps a complete Claude Code development environment via an interactive wizard. Supports macOS, Linux, WSL, and MSYS/Git Bash on Windows.

## Commands

```bash
# Run setup wizard (interactive)
bash setup.sh

# Non-interactive setup
bash setup.sh --non-interactive --profile=standard --language=en --editor=vscode

# Dry-run (preview changes without modifying files)
bash setup.sh --dry-run
bash setup.sh --update --dry-run

# One-liner install (interactive)
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash

# One-liner install (non-interactive, standard profile + all default plugins)
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash -s -- --non-interactive
NONINTERACTIVE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh)"

# Validate all shell scripts (matches CI severity)
shellcheck -S warning setup.sh install.sh uninstall.sh lib/*.sh wizard/wizard.sh

# Run unit tests
bash tests/run-unit-tests.sh

# Run scenario tests
bash tests/run-scenarios.sh

# Validate a single file
shellcheck lib/ghostty.sh

# Validate plugins.json
jq . config/plugins.json

# Clean uninstall (manifest-based)
bash uninstall.sh

# Update existing installation (auto-detected when re-running install.sh)
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash

# Force update mode explicitly
bash setup.sh --update

# Force full re-setup (ignores existing installation)
bash setup.sh
```

All scripts use `set -euo pipefail`. ShellCheck (severity: warning) runs automatically on PRs via `.github/workflows/shellcheck.yml`. Validation also includes `bash tests/run-unit-tests.sh` and `bash tests/run-scenarios.sh`.

## Architecture

### Execution Flow

```
install.sh (macOS/Linux: clone repo + bootstrap)
  ├── NONINTERACTIVE env or --non-interactive → passes --non-interactive to setup.sh
  └── otherwise → interactive mode with /dev/tty redirect
install.ps1 (Windows: WSL2 setup + clone repo via WSL + bootstrap)
  → setup.sh (orchestrator)
      → wizard/wizard.sh (CLI parsing + interactive prompts)
      → lib/detect.sh (OS/WSL/MSYS detection)
      → lib/prerequisites.sh (dependency checks)
      → lib/deploy.sh (build + deploy functions)
        → build_claude_md() — template engine assembles ~/.claude/CLAUDE.md
        → build_settings_file() — jq merges base JSON + permissions + hook fragments → settings.json
      → deploy files to ~/.claude/{agents,rules,commands,skills,memory}/
      → lib/ghostty.sh (Ghostty install + config, macOS only, if enabled)
      → lib/fonts.sh (cross-platform font install + Windows Terminal auto-config)
      → write_manifest() — tracks deployed files for uninstall
      → _write_snapshot() — saves deployed files for future update comparison
      → plugin marketplace registration + install (multi-marketplace)
      → Codex Plugin setup (if enabled)

install.sh (re-run with manifest v2 + snapshot)
  → setup.sh --update (update mode)
      → _restore_config_from_manifest() — reads settings from manifest
      → run_update() — 3-way merge settings.json, selective file updates
      → _detect_and_write_pending_features() — detect new features, write pending-features.json
      → write_manifest() — updates manifest v2
```

Libraries sourced by `setup.sh` in order: `wizard/wizard.sh`, `lib/colors.sh`, `lib/detect.sh`, `lib/prerequisites.sh`, `lib/features.sh`, `lib/recommendation.sh`, `lib/template.sh`, `lib/json-builder.sh`, `lib/snapshot.sh`, `lib/merge.sh`, `lib/update.sh`, `lib/dryrun.sh`, `lib/deploy.sh`, `lib/ghostty.sh`, `lib/fonts.sh`.

### Profile System

Three profiles (`profiles/*.conf`) define feature toggles as `VAR=true/false`:
- **minimal** — agents + rules only
- **standard** — adds commands, skills, memory, core hooks, Ghostty (macOS), programming fonts
- **full** — everything including Codex Plugin

### i18n

`load_strings "$LANGUAGE"` sources `i18n/{en,ja}/strings.sh`. All UI text uses `STR_*` variables. Each language also has `i18n/{en,ja}/CLAUDE.md.base` as templates for the user's assembled CLAUDE.md.

### Template Engine (`lib/template.sh`)

`build_claude_md()` assembles the user's `~/.claude/CLAUDE.md` in three phases:
1. `process_template()` — replaces `{{VAR}}` placeholders with values from a config file
2. `inject_feature()` — replaces `{{FEATURE:name}}` markers with contents of partial files (feature-specific docs)
3. `remove_unresolved()` — strips any remaining `{{...}}` markers for disabled features

### Plugin System

`config/plugins.json` defines available plugins with profile assignments and a `marketplaces` mapping. Each plugin has a `name`, `marketplace` (defaults to `claude-plugins-official`), `description`, and `profiles` array. The top-level `marketplaces` object maps marketplace short names to GitHub repos (e.g., `"claude-plugins-official": "anthropics/claude-plugins-official"`).

**Multi-marketplace support**: When the same plugin name exists in multiple marketplaces (e.g., `pr-review-toolkit` in both `claude-plugins-official` and `claude-code-plugins`), `_plugin_has_collision()` detects the conflict and `_compute_selected_plugins()` produces qualified `name@marketplace` entries in `SELECTED_PLUGINS`. Bare names without collision remain unqualified for backward compatibility. `_apply_plugins_from_csv()` handles both `name@marketplace` (exact match) and bare names (collision → defaults to `claude-plugins-official`).

Wizard flow: `_load_plugins()` reads the JSON (including `PLUGIN_MARKETPLACES[]` parallel array) → `_init_plugins_for_profile()` pre-selects plugins based on the chosen profile → user can customize in interactive mode (colliding names show `[marketplace]` suffix) → `_compute_selected_plugins()` produces the final `SELECTED_PLUGINS` CSV → `setup.sh` parses `name@marketplace`, registers required marketplaces via `claude plugin marketplace add`, and installs via `claude plugin install`.

### Hook Fragment Assembly

Each feature in `features/*/` has a `hooks.json` containing Claude Code hook definitions and/or top-level settings. `build_settings_file()` (in `lib/deploy.sh`) conditionally merges enabled features' fragments into `settings.json` via a custom jq deep-merge that **concatenates arrays** (so multiple features can add entries to the same hook type like `PreCompact` or `PostCompact`).

**IMPORTANT: Hook types (`SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `Stop`, `Notification`) MUST be nested inside a `"hooks"` key in hooks.json.** Claude Code reads hooks from `settings.json.hooks.*`, not from the top level. Top-level settings keys (`env`, `statusLine`, etc.) remain at the root.

Three fragment styles exist:
- **Inline hooks**: bash commands embedded as escaped JSON strings in `hooks.json` `"command"` fields, nested inside `"hooks"` (e.g., `features/tmux-hooks/hooks.json`)
- **External script hooks**: `hooks.json` references a script path with `__HOME__` token inside `"hooks"`, (e.g., `"hooks": {"PreCompact": [{"hooks": [{"command": "__HOME__/.claude/hooks/memory-persistence/pre-compact.sh"}]}], "PostCompact": [{"hooks": [{"command": "__HOME__/.claude/hooks/memory-persistence/post-compact.sh"}]}]}`). These scripts are deployed by `deploy_hook_scripts()` to `~/.claude/hooks/<feature>/` with `chmod +x`. Both `.sh` and `.py` scripts are supported.
- **Top-level settings**: `hooks.json` can contain any top-level settings key alongside `"hooks"`. The jq deep-merge applies at root level, so `{"statusLine": {...}}` and `{"env": {...}}` merge correctly (e.g., `features/statusline/hooks.json`, `features/safety-net/hooks.json`).

`build_settings_json()` in `lib/json-builder.sh` performs the merge:
1. Deep-merge `settings-base.json` + `permissions.json` via `jq -s '.[0] * .[1]'`
2. Iteratively merge each hook fragment via `merge_deep()` — a recursive jq function that concatenates arrays (e.g., `PreCompact` entries from `memory-persistence` and `pre-compact-commit` coexist) while deep-merging objects and replacing scalars
3. `replace_home_path()` substitutes `__HOME__` → actual `$HOME` in all string values
4. Final `validate_json()` check before writing output

### Ghostty Installation (`lib/ghostty.sh`)

macOS only. The install flow handles several edge cases:

1. **Existing install detection**: Checks `[[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]` (actual binary, not just directory or `command -v`). This prevents false positives from leftover directories, broken symlinks, or unrelated CLI tools.
2. **brew cask stale registry**: After `brew install --cask ghostty`, verifies the binary actually exists. If the cask was registered but the `.app` was deleted, falls back to `brew reinstall --cask ghostty`.
3. **Gatekeeper quarantine**: Always runs `xattr -d com.apple.quarantine /Applications/Ghostty.app` after install (and on re-runs for existing installs) to prevent the "Apple could not verify" dialog on first launch.
4. **HackGen NF font**: Tries brew first, falls back to direct download from GitHub Releases to `~/Library/Fonts/`.

### Cross-Platform Font Installation (`lib/fonts.sh`)

Installs IBM Plex Mono and HackGen NF with layered fallbacks:
- **macOS**: Homebrew cask → direct download (`curl` + `unzip` to `~/Library/Fonts/`)
- **Windows (WSL/MSYS)**: `_is_font_installed_windows()` checks `%LOCALAPPDATA%\Microsoft\Windows\Fonts`; `_install_font_windows()` runs PowerShell to download, extract, and register fonts + HKCU registry.

Windows Terminal font configuration (`_configure_windows_terminal_font()`) runs **independently of font install success** — it checks if HackGen NF font files exist on disk and configures WT regardless of whether fonts were installed in this run or a previous one. Creates `.bak` backup before modifying. Returns exit codes: 0=OK, 2=NOT_FOUND (WT not installed), 1=FAILED.

### Bootstrap Safety (`install.sh`)

`install.sh` validates `INSTALL_DIR` via `_safe_install_dir()` before any `rm -rf` operations. Blocks dangerous paths (`/`, `/home`, `/root`, `$HOME`, system dirs, `/Applications/*`, `/Library/*`) and requires minimum depth of 3 path components. Both `install.sh` and `install.ps1` (WSL + Git Bash embedded scripts) contain identical copies of `_safe_install_dir()` — keep them in sync when modifying.

### Windows Bootstrap (`install.ps1`)

PowerShell entry point for Windows. Two modes:
- **WSL mode** (default): Ensures WSL2 + Ubuntu installed → runs bash bootstrap inside WSL → shows Windows Terminal guidance
- **Git Bash mode** (`--git-bash`): Fallback for no-admin environments → finds/installs Git for Windows → runs setup via Git Bash

### Manifest-Based Uninstall

`write_manifest()` records all deployed file paths in `~/.claude/.starter-kit-manifest.json`. `uninstall.sh` reads this manifest and removes only tracked files, preserving user-added content. Uninstall is self-contained (inline platform detection, jq with grep/sed fallback).

In addition to manifest-tracked files, `uninstall.sh` explicitly removes:
- `~/.claude/.starter-kit-update.lock/` — auto-update lock directory
- `~/.claude/.starter-kit-update-status` — deferred auto-update failure message
- `~/.claude/.starter-kit-snapshot/` — update mechanism snapshot directory

When adding features that create files outside `~/.claude/{agents,rules,commands,skills,memory,hooks}/`, add explicit cleanup to `uninstall.sh`'s "Clean saved config" section.

### Update Mechanism

When `install.sh` detects an existing installation with manifest v2 + snapshot, it automatically switches to update mode (`setup.sh --update`). This preserves user-customized settings while applying kit updates.

**Three-way comparison:** For each kit-managed file, the system compares:
- **Snapshot** (what kit deployed last time)
- **Current** (what's on disk now, possibly user-modified)
- **New kit** (what the updated kit would deploy)

**Decision matrix:**
| Snapshot vs Current | Snapshot vs New Kit | Action |
|---|---|---|
| Same | Different | Overwrite with new kit |
| Different | Same | Keep current (no kit changes) |
| Different | Different | Interactive prompt |

**settings.json merge:** Uses jq-based 3-way merge at the key level. Scalar conflicts and array conflicts prompt the user at the whole-key/whole-array level with `[K]eep yours / [U]se kit's` options. User-added keys (e.g., `mcpServers`) are preserved.

**Merge preference persistence:** When resolving a conflict, users can choose `[RK] Keep & Remember` or `[RU] Use kit's & Remember`. Decisions are stored in `~/.claude/.starter-kit-merge-prefs.json` and applied automatically on subsequent updates. Use `setup.sh --update --reset-prefs` to clear saved decisions, or delete `~/.claude/.starter-kit-merge-prefs.json` manually.

**Update backup:** `setup.sh --update` creates a full backup of `~/.claude` to `~/.claude.backup.<timestamp>` before any merge operations.

**Non-interactive update:** `--non-interactive` skips all prompts, keeping user-modified files and only updating unchanged ones. Saved merge preferences are still applied.

**New feature adoption rule:** When adding a new setting or `ENABLE_*` flag, treat fresh install and update as separate paths. `setup.sh --update` and `/update-kit` must adopt the new feature for existing installs when the key is missing, but must not overwrite an explicit user choice that is already present in saved config or deployed files.

**Update verification rule:** For any new feature, verify all three paths: fresh install, `setup.sh --update` (the same path used by `/update-kit`), and saved config reuse in `wizard/wizard.sh`.

**Snapshot directory:** `~/.claude/.starter-kit-snapshot/` mirrors the structure of `~/.claude/` for kit-managed files only.

**Fresh install with existing files:** When `~/.claude/settings.json` exists but no `.starter-kit-manifest.json` is found, the fresh install path uses `_deploy_fresh_with_existing()` instead of the standard overwrite flow. This calls `_merge_settings_bootstrap()` for settings.json (same merge logic as update mode), and offers per-directory `[O]verwrite all / [N]ew files only / [S]kip` prompts for content directories and hook scripts. Non-interactive mode merges settings.json (adopting kit-only keys, preserving user values) and copies only new files for other directories.

**CLAUDE.md section separation:** The deployed `~/.claude/CLAUDE.md` is divided into two sections by HTML comment markers:
- `<!-- BEGIN STARTER-KIT-MANAGED -->` ... `<!-- END STARTER-KIT-MANAGED -->`: Kit-managed content. Updated by the kit on install/update. Users should not edit this section (edits are treated as conflicts on update).
- Everything after the END marker: User section. Kit never touches this content. Users are free to add any custom instructions here.

Section-aware behavior:
- **Snapshot**: Only the kit section is stored in the snapshot (not the full file). This prevents user section edits from triggering false conflicts.
- **Update**: `_update_claude_md()` in `lib/update.sh` compares kit sections only. User section is always preserved.
- **Migration**: If an existing CLAUDE.md has no markers, the entire content is treated as user content and wrapped into the user section, with the kit section prepended. Non-interactive mode skips migration (structural change requires consent).
- **Uninstall**: Kit section is removed; user section is preserved. If the user section is empty/whitespace-only, the whole file is deleted.
- **Manifest**: `CLAUDE.md` remains a managed file, but kit ownership applies only to the marker section.

Helper functions in `lib/template.sh`: `_has_kit_markers()`, `_extract_kit_section()`, `_extract_user_section()`, `_replace_kit_section()`.

**Dry-run mode:** `--dry-run` previews what install/update would change without deploying any files. Light prerequisites (git, jq, curl) may be installed with user consent in interactive mode; `--non-interactive --dry-run` installs nothing. Heavy tools (Homebrew, Node, etc.) are never installed during dry-run. Implementation in `lib/dryrun.sh`:
- `_dryrun_init()` copies real `~/.claude` into a temp sim dir, then `CLAUDE_DIR` is redirected so the normal flow executes against it
- `_MERGE_INTERACTIVE=false` ensures no prompts are shown
- Sim dir snapshot/manifest are temporary artifacts — discarded after report generation
- Diff/summary comparison basis is always "real `~/.claude` (current) vs sim dir (simulated)"
- External side effects (Ghostty, fonts, shell RC, plugins, Codex Plugin, Claude CLI) are individually guarded and logged as `[WOULD RUN]` entries via `_dryrun_log()`
- After the deploy flow completes in sim dir, `_dryrun_collect_file_changes()` walks the sim dir to find CREATE/MODIFY entries, then `_dryrun_show_results()` displays the grouped summary + settings.json unified diff

### Deploy Targets

`setup.sh` deploys content from this repo to `~/.claude/`:

| Source | Target | Condition |
|--------|--------|-----------|
| `agents/*.md` | `~/.claude/agents/` | `INSTALL_AGENTS=true` |
| `rules/*.md` | `~/.claude/rules/` | `INSTALL_RULES=true` |
| `commands/` | `~/.claude/commands/` | `INSTALL_COMMANDS=true` |
| `skills/` | `~/.claude/skills/` | `INSTALL_SKILLS=true` |
| `memory/` | `~/.claude/memory/` | `INSTALL_MEMORY=true` |
| `features/*/scripts/` | `~/.claude/hooks/<feature>/` | feature-specific |
| assembled CLAUDE.md | `~/.claude/CLAUDE.md` | always |
| `config/AGENTS.md.template` | `~/.claude/AGENTS.md` | always |
| assembled settings.json | `~/.claude/settings.json` | always |

## Key Conventions

- **Prerequisites auto-install**: The main setup flow requires `git`, `jq`, `curl`, GNU `sed`, GNU `awk`, `bash 4+`, `node`, `tmux`, and `gh`. Stage 1 bootstrap (`wizard/wizard.sh`, `lib/colors.sh`, `lib/detect.sh`, `lib/prerequisites.sh`) remains Bash 3.2 compatible so the kit can auto-install or detect Bash 4+ and re-exec before Stage 2 (`declare -A`, `readarray`, etc.). Only show manual install commands after automatic installation fails.
- **Variable naming**: `ENABLE_*` (feature toggles), `INSTALL_*` (component flags), `STR_*` (i18n strings), `_*` prefixed functions (private/internal)
- **Boolean handling**: `_bool_normalize()` accepts true/1/yes/on → "true". Use `is_true()` for checks.
- **No eval**: All dynamic variable assignment uses `printf -v` and `${!var}` (indirect expansion) to prevent injection.
- **Ghostty detection**: Use `[[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]` to detect Ghostty. Never use `-d "/Applications/Ghostty.app"` or `command -v ghostty` (both produce false positives).
- **Platform guards for Ghostty**: Use `[[ "$(uname -s)" == "Darwin" ]]`, not `is_wsl`/`is_msys` (WSL detection can be unreliable).
- **Font install fallback pattern**: Always try brew first, then fall back to direct download (`curl` + `unzip`) so installs succeed without Homebrew.
- **Keg-only brew formulas**: `brew install node@XX` etc. are keg-only (not symlinked into PATH). After install, resolve the bin dir via `brew --prefix <formula>`, export it to `PATH` for the current session, and persist it to the user's shell RC file via `_persist_node_path()`. See `lib/prerequisites.sh`.
- **Homebrew PATH resolution**: Use `_ensure_homebrew` from `lib/prerequisites.sh` (not bare `command -v brew`) when brew is needed. It resolves `/opt/homebrew/bin/brew` and `/usr/local/bin/brew` paths that may not be in PATH during pipe execution (`curl | bash`). After calling `_ensure_homebrew`, always verify with `_brew_is_usable` before running `brew` commands.
- **Windows interop from WSL/MSYS**: Use `powershell.exe -NoProfile -Command '...'` for Windows-side operations (font install, WT config). Always `tr -d '\r'` on output to strip CRLF.
- **Codex Plugin scope**: Always use `claude plugin install codex --scope user` (user scope, not project scope).
- **Timeout portability**: Use `_run_with_timeout` wrapper (macOS lacks `timeout`).
- **Config persistence**: `~/.claude-starter-kit.conf` uses `key="value"` format, parsed by `_safe_source_config()` (allowlisted key=value parser, never sourced as shell code).
- **Temp file hygiene**: `setup.sh` sets `umask 077` at top, tracks temp files in `_SETUP_TMP_FILES` array, and registers `trap _cleanup_tmp EXIT INT TERM` for automatic cleanup.
- **Credential safety**: Pass API keys via `curl --config -` (stdin) to avoid exposing in `ps` output. Never use `curl -H "Authorization: Bearer $key"` directly.
- **Safe config loading**: Never source config files with `. "$file"`. Use `_safe_source_config()` which validates keys against `_CONFIG_ALLOWED_KEYS` allowlist and sanitizes values via `_sanitize_config_value()`.
- **RC file modification**: When modifying shell RC files (`.bashrc`, `.zshrc`), preserve original permissions with `stat` + `chmod` after `mktemp` + `mv` operations (since `umask 077` would change them to 0600).
- **sed delimiter choice**: When using `sed` with `|` delimiter (`s|...|...|`), escape `&`, `\`, and `|` in replacement strings — do NOT escape `/`.
- **Top-level scope in setup.sh**: The plugin install section (after line ~430) runs in global scope, not inside a function. Use `_` prefixed variables (e.g., `_p`, `_p_name`, `_registered_mps`) instead of `local`.
- **NONINTERACTIVE env var**: `install.sh` supports `NONINTERACTIVE=1` (Homebrew convention) to auto-add `--non-interactive` flag for setup.sh.
- **DRY_RUN variable**: `--dry-run` sets `DRY_RUN="true"`. In dry-run mode, `CLAUDE_DIR` is redirected to a temp sim dir so the normal deploy/update flow runs without touching real files. External operations (Ghostty, fonts, shell RC, plugins, Codex Plugin, Claude CLI) are individually guarded and logged as `[WOULD RUN]`. Light prerequisites (git, jq, curl) may be installed with user consent in interactive mode; `--non-interactive --dry-run` installs nothing and aborts if tools are missing. Sim dir snapshot/manifest are temporary artifacts discarded after the summary report. The comparison basis is always "real `~/.claude` vs sim dir result".

## Security Hardening

### Permission Design (config/permissions.json)

The permissions file implements a defense-in-depth strategy against prompt injection and credential exfiltration:

**Removed from permissions.allow (require user confirmation per invocation):**
- `python3 *`, `node *` — Arbitrary code execution enables data exfiltration even when `curl` is denied (CVE context: indirect prompt injection via print/console.log in "example code")
- `curl *`, `wget *` — Direct network exfiltration vectors
- `cat *`, `head *`, `tail *` — Can bypass `Read(.env)` deny rules; use the Read tool instead
- `source *`, `env *`, `export *` — Environment variable access/manipulation

**permissions.deny categories:**
- **Network exfiltration**: curl, wget, nc, ncat, telnet, ssh, scp
- **System escalation**: sudo, su, osascript, security
- **Destructive git**: push --force, push -f, reset --hard, clean -f
- **Credential file access**: `.env*`, `~/.ssh/*`, `~/.aws/*`, `~/.config/gh/*`, `~/.git-credentials`, `~/.netrc`, `~/.npmrc`
- **RC file tampering**: `~/.zshrc`, `~/.bashrc` (Edit/Write denied)
- **Clipboard exfiltration**: pbcopy, pbpaste

**Top-level settings:**
- `enableAllProjectMcpServers: false` — Prevents auto-approval of MCP servers from cloned repos (CVE-2025-59536)
- `disableBypassPermissionsMode: "disable"` — Blocks `--dangerously-skip-permissions`

**Known limitations:**
- Absolute paths (`/Users/xxx/.ssh/`) or variable expansion (`$(echo ~/.ssh/id_rsa)`) can bypass pattern-based deny rules
- MCP Tool Poisoning requires source code review, not just permissions
- Package managers (`npm:*`, `pnpm:*`) remain broadly allowed for development workflow; `npm exec` could theoretically execute arbitrary code

### References

- CVE-2025-59536: Project `.claude/settings.json` MCP server approval bypass
- CVE-2026-21852: `ANTHROPIC_BASE_URL` rewrite for API key theft
- CVE-2025-6514: `mcp-remote` RCE vulnerability
- Qiita: print-based indirect exfiltration via CI/CD logs (no network deny trigger)

## Versioning

- **patch (x.y.Z)**: バグ修正、ドキュメント修正、テスト追加、内部リファクタ（ユーザーの動作が変わらない）
- **minor (x.Y.0)**: 新機能追加、既存機能の動作変更、新 profile 項目、新 hook/command/skill 追加
- **major (X.0.0)**: 破壊的変更（設定フォーマット変更、既存 config の非互換、migration 必須）
- PR の CHANGELOG エントリに `## [x.y.z] - YYYY-MM-DD` を書く。タグはマージ後に切る。
- 複数の変更を含む PR はもっとも影響の大きい変更に合わせる。

## Adding a New Feature

1. Create `features/new-feature/feature.json` (metadata) and `hooks.json` (hook fragments and/or top-level settings). **Hook types MUST be nested inside `"hooks": {}`** — see "Hook Fragment Assembly" above
2. Add `ENABLE_NEW_FEATURE=true/false` to each `profiles/*.conf`
3. In `wizard/wizard.sh`: add variable initialization (`ENABLE_NEW_FEATURE="${ENABLE_NEW_FEATURE:-}"`), add to `_CONFIG_ALLOWED_KEYS`, add to `save_config()`, add confirmation display in `_step_confirm`, add default in `_fill_noninteractive_defaults()`
4. Add `STR_CONFIRM_*` strings in both `i18n/en/strings.sh` and `i18n/ja/strings.sh`
5. If the feature is a hook, add to `HOOK_KEYS` array and `_apply_hooks_csv()` case in `wizard/wizard.sh`, and add `STR_HOOKS_*` strings in both i18n files. Add the hook label to `HOOK_LABELS` arrays in both `_step_hooks()` and `_step_confirm()`
6. Features are auto-collected by `build_settings_file()` in `lib/deploy.sh` via `_FEATURE_ORDER` / `_FEATURE_FLAGS` registry — no manual merge code needed
7. If external scripts needed: add to `deploy_hook_scripts()` in `setup.sh`
8. If the feature creates files outside the standard manifest-tracked directories, add explicit cleanup to `uninstall.sh`
9. Verify update-path adoption. A new key must be checked in all of these paths:
   - fresh install
   - `setup.sh --update` / `/update-kit`
   - saved config reuse in `wizard/wizard.sh`
   Missing keys on older installs should receive the intended default for that profile, but existing explicit user choices must win.
10. Update `CHANGELOG.md` in the same PR when the feature changes user-visible behavior, default presets, commands, docs, generated files, or upgrade behavior. Write the entry directly under the version heading (`## [x.y.z]`) that will be tagged on merge — do not use an `[Unreleased]` section. Follow the existing Keep a Changelog structure and write the entry at the level users will notice.
11. **Feature recommendation**: Ensure `feature.json` has `displayName` and `description` fields for the notification display. If the feature should NOT be recommended (special-case features), verify it is excluded from `_FEATURE_FLAGS` or is handled by `_detect_and_write_pending_features()` exclusion logic.

Multiple features can safely use the same hook type (e.g., `PreCompact`, `PostCompact`) — `merge_deep()` concatenates arrays instead of replacing them.

**Hook ordering matters**: `safety-net` must be the **first** entry in `hook_fragments[]` so its `PreToolUse` entry appears at index 0 (runs before other PreToolUse hooks). When adding new PreToolUse hooks, append after safety-net.

**`build_settings_file()`** in `lib/deploy.sh` is the single unified settings.json builder. It accepts an output path parameter and is called by both fresh install and update paths.

## Adding a New Plugin

1. Add entry to `config/plugins.json` under `plugins[]` with `name`, `marketplace`, `description`, `profiles`
2. If using a new marketplace, add its GitHub repo to `marketplaces` mapping in the same file
3. Verify JSON: `jq . config/plugins.json`
4. If the plugin name already exists in another marketplace, `_plugin_has_collision()` will auto-detect and the wizard will show `[marketplace]` suffix; `_compute_selected_plugins()` will produce `name@marketplace` in the CSV

## Notable Features

### Safety Net (`features/safety-net/`)

PreToolUse hook via [cc-safety-net](https://github.com/kenryu42/claude-code-safety-net). Blocks destructive commands (`git reset --hard`, `rm -rf`, etc.) before execution. Uses `SAFETY_NET_STRICT=1` env (fail-closed for unparseable commands). The `env` key in `hooks.json` is deep-merged into `settings.json` top-level. Requires `npm install -g cc-safety-net` (external dependency, not managed by kit).

### Auto Update (`features/auto-update/`)

SessionStart + SessionEnd hooks that check GitHub for new kit versions on each session boundary. Uses hook-level `async: true` instead of shell `( ... ) &`, and a lock directory at `~/.claude/.starter-kit-update.lock/` to prevent concurrent runs. Only activates for one-liner installs (`~/.claude-starter-kit/.git` must exist). Calls `setup.sh --update` for 3-way merge. `SessionEnd` is best-effort and re-spawns itself detached so end-of-session teardown is less likely to interrupt the update. This flow is verified on Claude Code `2.1.89`; older detected versions fall back to a legacy SessionStart + 24h cache hook. Failed background updates are persisted to `~/.claude/.starter-kit-update-status` and surfaced once on the next hook run.

### Status Line (`features/statusline/`)

Braille Dots pattern status line implemented in Python. Displays model name, context window usage, 5-hour and 7-day rate limits in a single line using braille characters (`⣀⣄⣤⣦⣶⣷⣿`) with green→red gradient coloring based on usage percentage. The `hooks.json` uses `statusLine` top-level key (not a hook type). Script deployed to `~/.claude/hooks/statusline/statusline-command.py`. Requires `python3` in PATH.

### Doc Size Guard (`features/doc-size-guard/`)

PostToolUse hook that validates CLAUDE.md/AGENTS.md file size when the Write tool targets these files. External script at `scripts/check-doc-size.sh`. Thresholds: AGENTS.md warns at 60 lines / errors at 100; CLAUDE.md warns at 150 / errors at 300. Also checks for broken path references in backtick-quoted strings.

### Feature Recommendation (`features/feature-recommendation/`)

SessionStart hook that notifies users about new features available for their profile. Three-state management: enabled (conf `ENABLE_X=true/false`), dismissed (`DISMISSED_FEATURES` CSV in conf), pending (implicit: not in either). `lib/recommendation.sh` provides helpers (`_is_feature_dismissed`, `_add_dismissed_feature`, `_validate_dismissed_features`, `_detect_and_write_pending_features`). Pending features are written to `~/.claude/.starter-kit-pending-features.json` (atomic write, name-only). `check-pending.sh` is self-contained (no `lib/` deps, Bash 3.2 compatible), reads pending JSON and resolves displayName/description from kit repo's `feature.json`. The `/update-kit` command handles interactive review (Claude-side, not shell wizard). Full profile auto-enables all features (no pending). Minimal generates pending but has no SessionStart notification (hook not deployed).

## Platform Detection

`lib/detect.sh` exports: `OS`, `ARCH`, `DISTRO`, `DISTRO_FAMILY`, `IS_WSL`, `WSL_BUILD`, `WIN_BUILD`.

Helpers: `is_macos()`, `is_linux()`, `is_wsl()`, `is_msys()`, `is_windows()`, `is_apple_silicon()`.

MSYS pattern covers: `MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*`. WSL detection uses `/proc/version` + `WSL_DISTRO_NAME` + `WSLENV` + `WSLInterop` fallbacks.

## Learned Rules (auto-generated by cn-memory)

<!-- cn-memory:start -->
<!-- cn-memory:end -->
