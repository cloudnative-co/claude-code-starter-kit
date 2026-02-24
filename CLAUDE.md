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

# One-liner install (interactive)
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash

# One-liner install (non-interactive, standard profile + all default plugins)
curl -fsSL <url>/install.sh | bash -s -- --non-interactive
NONINTERACTIVE=1 bash -c "$(curl -fsSL <url>/install.sh)"

# Validate all shell scripts (matches CI severity)
shellcheck -S warning setup.sh install.sh uninstall.sh lib/*.sh wizard/wizard.sh

# Validate a single file
shellcheck lib/ghostty.sh

# Validate plugins.json
jq . config/plugins.json

# Clean uninstall (manifest-based)
bash uninstall.sh
```

All scripts use `set -euo pipefail`. ShellCheck (severity: warning) runs automatically on PRs via `.github/workflows/shellcheck.yml`. There is no traditional test suite (jest, pytest, etc.) — validation is ShellCheck CI only.

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
      → build_claude_md() — template engine assembles ~/.claude/CLAUDE.md
      → build_settings() — jq merges base JSON + permissions + hook fragments → settings.json
      → deploy files to ~/.claude/{agents,rules,commands,skills,memory}/
      → lib/ghostty.sh (Ghostty install + config, macOS only, if enabled)
      → lib/fonts.sh (cross-platform font install + Windows Terminal auto-config)
      → write_manifest() — tracks deployed files for uninstall
      → plugin marketplace registration + install (multi-marketplace)
      → Codex MCP setup (if enabled)
```

Libraries sourced by `setup.sh` in order: `wizard/wizard.sh`, `lib/colors.sh`, `lib/detect.sh`, `lib/prerequisites.sh`, `lib/template.sh`, `lib/json-builder.sh`, `lib/ghostty.sh`, `lib/fonts.sh`.

### Profile System

Three profiles (`profiles/*.conf`) define feature toggles as `VAR=true/false`:
- **minimal** — agents + rules only
- **standard** — adds commands, skills, memory, core hooks, Ghostty (macOS), programming fonts
- **full** — everything including Codex MCP

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

Each feature in `features/*/` has a `hooks.json` containing Claude Code hook definitions. `build_settings()` conditionally merges enabled features' fragments into `settings.json` via a custom jq deep-merge that **concatenates arrays** (so multiple features can add entries to the same hook type like `PreCompact`).

Three fragment styles exist:
- **Inline hooks**: bash commands embedded as escaped JSON strings in `hooks.json` `"command"` fields (e.g., `features/tmux-hooks/hooks.json`)
- **External script hooks**: `hooks.json` references a script path with `__HOME__` token (e.g., `"command": "__HOME__/.claude/hooks/memory-persistence/pre-compact.sh"`). These scripts are deployed by `deploy_hook_scripts()` to `~/.claude/hooks/<feature>/` with `chmod +x`.
- **Top-level settings**: `hooks.json` can contain any top-level settings key (not just hooks). The jq deep-merge applies at root level, so `{"statusLine": {...}}` merges correctly (e.g., `features/statusline/hooks.json`).

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
| assembled settings.json | `~/.claude/settings.json` | always |

## Key Conventions

- **Bash 3.2 compatibility is mandatory** (macOS default). No associative arrays (`declare -A`), no `readarray`/`mapfile`, no `${var,,}` case conversion. Use indexed arrays with parallel arrays for key-value patterns (e.g., `PLUGIN_NAMES[]` + `PLUGIN_MARKETPLACES[]`).
- **Variable naming**: `ENABLE_*` (feature toggles), `INSTALL_*` (component flags), `STR_*` (i18n strings), `_*` prefixed functions (private/internal)
- **Boolean handling**: `_bool_normalize()` accepts true/1/yes/on → "true". Use `is_true()` for checks.
- **No eval**: All dynamic variable assignment uses `printf -v` and `${!var}` (indirect expansion) to prevent injection.
- **Ghostty detection**: Use `[[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]` to detect Ghostty. Never use `-d "/Applications/Ghostty.app"` or `command -v ghostty` (both produce false positives).
- **Platform guards for Ghostty**: Use `[[ "$(uname -s)" == "Darwin" ]]`, not `is_wsl`/`is_msys` (WSL detection can be unreliable).
- **Font install fallback pattern**: Always try brew first, then fall back to direct download (`curl` + `unzip`) so installs succeed without Homebrew.
- **Keg-only brew formulas**: `brew install node@XX` etc. are keg-only (not symlinked into PATH). After install, resolve the bin dir via `brew --prefix <formula>`, export it to `PATH` for the current session, and persist it to the user's shell RC file via `_persist_node_path()`. See `lib/prerequisites.sh`.
- **Homebrew PATH resolution**: Use `_ghostty_ensure_brew` (not bare `command -v brew`) when brew is needed. It resolves `/opt/homebrew/bin/brew` and `/usr/local/bin/brew` paths that may not be in PATH during pipe execution (`curl | bash`).
- **Windows interop from WSL/MSYS**: Use `powershell.exe -NoProfile -Command '...'` for Windows-side operations (font install, WT config). Always `tr -d '\r'` on output to strip CRLF.
- **Codex MCP scope**: Always use `claude mcp add -s user` (user scope, not project scope).
- **Timeout portability**: Use `_run_with_timeout` wrapper (macOS lacks `timeout`).
- **Config persistence**: `~/.claude-starter-kit.conf` uses `key="value"` format, parsed by `_safe_source_config()` (allowlisted key=value parser, never sourced as shell code).
- **Temp file hygiene**: `setup.sh` sets `umask 077` at top, tracks temp files in `_SETUP_TMP_FILES` array, and registers `trap _cleanup_tmp EXIT INT TERM` for automatic cleanup.
- **Credential safety**: Pass API keys via `curl --config -` (stdin) to avoid exposing in `ps` output. Never use `curl -H "Authorization: Bearer $key"` directly.
- **Safe config loading**: Never source config files with `. "$file"`. Use `_safe_source_config()` which validates keys against `_CONFIG_ALLOWED_KEYS` allowlist and sanitizes values via `_sanitize_config_value()`.
- **RC file modification**: When modifying shell RC files (`.bashrc`, `.zshrc`), preserve original permissions with `stat` + `chmod` after `mktemp` + `mv` operations (since `umask 077` would change them to 0600).
- **sed delimiter choice**: When using `sed` with `|` delimiter (`s|...|...|`), escape `&`, `\`, and `|` in replacement strings — do NOT escape `/`.
- **Top-level scope in setup.sh**: The plugin install section (after line ~430) runs in global scope, not inside a function. Use `_` prefixed variables (e.g., `_p`, `_p_name`, `_registered_mps`) instead of `local`.
- **NONINTERACTIVE env var**: `install.sh` supports `NONINTERACTIVE=1` (Homebrew convention) to auto-add `--non-interactive` flag for setup.sh.

## Adding a New Feature

1. Create `features/new-feature/feature.json` (metadata) and `hooks.json` (hook fragments or top-level settings)
2. Add `ENABLE_NEW_FEATURE=true/false` to each `profiles/*.conf`
3. In `wizard/wizard.sh`: add variable initialization (`ENABLE_NEW_FEATURE="${ENABLE_NEW_FEATURE:-}"`), add to `_CONFIG_ALLOWED_KEYS`, add to `save_config()`, add confirmation display in `_step_confirm`, add default in `_fill_noninteractive_defaults()`
4. Add `STR_CONFIRM_*` strings in both `i18n/en/strings.sh` and `i18n/ja/strings.sh`
5. If the feature is a hook, add to `HOOK_KEYS` array and `_apply_hooks_csv()` case in `wizard/wizard.sh`, and add `STR_HOOKS_*` strings in both i18n files. Add the hook label to `HOOK_LABELS` arrays in both `_step_hooks()` and `_step_confirm()`
6. Add conditional merge in `build_settings()` in `setup.sh`
7. If external scripts needed: add to `deploy_hook_scripts()` in `setup.sh`

Multiple features can safely use the same hook type (e.g., `PreCompact`) — `merge_deep()` concatenates arrays instead of replacing them.

## Adding a New Plugin

1. Add entry to `config/plugins.json` under `plugins[]` with `name`, `marketplace`, `description`, `profiles`
2. If using a new marketplace, add its GitHub repo to `marketplaces` mapping in the same file
3. Verify JSON: `jq . config/plugins.json`
4. If the plugin name already exists in another marketplace, `_plugin_has_collision()` will auto-detect and the wizard will show `[marketplace]` suffix; `_compute_selected_plugins()` will produce `name@marketplace` in the CSV

## Platform Detection

`lib/detect.sh` exports: `OS`, `ARCH`, `DISTRO`, `DISTRO_FAMILY`, `IS_WSL`, `WSL_BUILD`, `WIN_BUILD`.

Helpers: `is_macos()`, `is_linux()`, `is_wsl()`, `is_msys()`, `is_windows()`, `is_apple_silicon()`.

MSYS pattern covers: `MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*`. WSL detection uses `/proc/version` + `WSL_DISTRO_NAME` + `WSLENV` + `WSLInterop` fallbacks.
