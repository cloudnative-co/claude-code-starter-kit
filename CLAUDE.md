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

# Validate shell scripts
shellcheck setup.sh install.sh uninstall.sh lib/*.sh wizard/wizard.sh

# Clean uninstall (manifest-based)
bash uninstall.sh
```

There are no build steps, tests, or linters configured. All scripts use `set -euo pipefail`.

## Architecture

### Execution Flow

```
install.sh (macOS/Linux: clone repo + bootstrap)
install.ps1 (Windows: WSL2 setup + clone repo via WSL + bootstrap)
  → setup.sh (orchestrator)
      → wizard/wizard.sh (CLI parsing + interactive prompts)
      → lib/detect.sh (OS/WSL/MSYS detection)
      → lib/prerequisites.sh (dependency checks)
      → lib/fonts.sh (cross-platform font install + Windows Terminal auto-config)
      → build_claude_md() — template engine assembles ~/.claude/CLAUDE.md
      → build_settings() — jq merges base JSON + permissions + hook fragments → settings.json
      → deploy files to ~/.claude/{agents,rules,commands,skills,memory}/
      → write_manifest() — tracks deployed files for uninstall
      → Codex MCP setup (if enabled)
```

### Profile System

Three profiles (`profiles/*.conf`) define feature toggles as `VAR=true/false`:
- **minimal** — agents + rules only
- **standard** — adds commands, skills, memory, core hooks, programming fonts
- **full** — everything including Codex MCP, Ghostty (macOS), and programming fonts

### i18n

`load_strings "$LANGUAGE"` sources `i18n/{en,ja}/strings.sh`. All UI text uses `STR_*` variables. CLAUDE.md templates use `{{FEATURE:name}}` markers injected by `lib/template.sh`.

### Hook Fragment Assembly

Each feature in `features/*/` has a `hooks.json` containing Claude Code hook definitions. `build_settings()` conditionally merges enabled features' fragments into `settings.json` via jq deep-merge (`*` operator).

### Cross-Platform Font Installation

`lib/fonts.sh` installs IBM Plex Mono and HackGen NF via platform-specific methods:
- **macOS**: Homebrew cask (`font-ibm-plex-mono`, `font-hackgen-nerd`)
- **Windows (WSL/MSYS)**: `_install_font_windows()` runs PowerShell to download, extract, and register fonts in `%LOCALAPPDATA%\Microsoft\Windows\Fonts` + HKCU registry

After font install on Windows, `_configure_windows_terminal_font()` auto-patches Windows Terminal's `settings.json` (both stable and Preview editions) to set `profiles.defaults.font.face`. Creates `.bak` backup before modifying. Returns exit codes: 0=OK, 2=NOT_FOUND (WT not installed), 1=FAILED — callers fall back to manual hints on non-zero.

### Windows Bootstrap (`install.ps1`)

PowerShell entry point for Windows. Two modes:
- **WSL mode** (default): Ensures WSL2 + Ubuntu installed → runs bash bootstrap inside WSL → shows Windows Terminal guidance
- **Git Bash mode** (`--git-bash`): Fallback for no-admin environments → finds/installs Git for Windows → runs setup via Git Bash

Key helpers: `Test-WslInstalled`, `Test-UbuntuReady`, `Find-UbuntuDistro`, `Find-GitBash`, `Test-WindowsTerminal`.

### Manifest-Based Uninstall

`write_manifest()` records all deployed file paths in `~/.claude/.starter-kit-manifest.json`. `uninstall.sh` reads this manifest and removes only tracked files, preserving user-added content. Uninstall is self-contained (inline platform detection, jq with grep/sed fallback).

## Key Conventions

- **Variable naming**: `ENABLE_*` (feature toggles), `INSTALL_*` (component flags), `STR_*` (i18n strings), `_*` prefixed functions (private/internal)
- **Boolean handling**: `_bool_normalize()` accepts true/1/yes/on → "true". Use `is_true()` for checks.
- **No eval**: All dynamic variable assignment uses `printf -v` and `${!var}` (indirect expansion) to prevent injection.
- **Platform guards for Ghostty**: Use `[[ "$(uname -s)" == "Darwin" ]]`, not `is_wsl`/`is_msys` (WSL detection can be unreliable).
- **Windows interop from WSL/MSYS**: Use `powershell.exe -NoProfile -Command '...'` for Windows-side operations (font install, WT config). Always `tr -d '\r'` on output to strip CRLF.
- **Codex MCP scope**: Always use `claude mcp add -s user` (user scope, not project scope).
- **Timeout portability**: Use `_run_with_timeout` wrapper (macOS lacks `timeout`).
- **Config persistence**: `~/.claude-starter-kit.conf` is sourced as shell code (no JSON parsing needed).

## Adding a New Feature

1. Create `features/new-feature/feature.json` (metadata) and `hooks.json` (hook fragments)
2. Add `ENABLE_NEW_FEATURE=true/false` to each `profiles/*.conf`
3. Add wizard step in `wizard/wizard.sh` with `STR_*` strings in both `i18n/en/strings.sh` and `i18n/ja/strings.sh`
4. Add conditional merge in `build_settings()` in `setup.sh`
5. If hook scripts needed: add to `deploy_hook_scripts()` in `setup.sh`

## Platform Detection

`lib/detect.sh` exports: `OS`, `ARCH`, `DISTRO`, `DISTRO_FAMILY`, `IS_WSL`, `WSL_BUILD`, `WIN_BUILD`.

Helpers: `is_macos()`, `is_linux()`, `is_wsl()`, `is_msys()`, `is_windows()`, `is_apple_silicon()`.

MSYS pattern covers: `MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*`. WSL detection uses `/proc/version` + `WSL_DISTRO_NAME` + `WSLENV` + `WSLInterop` fallbacks.
