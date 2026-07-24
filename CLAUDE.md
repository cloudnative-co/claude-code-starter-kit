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

# Validate every tracked shell script exactly as CI does (one file per run)
git ls-files -z '*.sh' | xargs -0 -n 1 shellcheck -S warning

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
      → wizard/wizard.sh (globals/config + module loading)
        → wizard/registry.sh (plugin/hook registry + CLI parsing)
        → wizard/steps.sh (display helpers + interactive prompts)
      → lib/detect.sh (OS/WSL/MSYS detection)
      → lib/prerequisites.sh (dependency checks)
      → lib/deploy.sh (build + deploy functions)
        → build_claude_md() — template engine assembles ~/.claude/CLAUDE.md
        → build_settings_file() — jq merges base JSON + permissions + hook fragments → settings.json
      → deploy files to ~/.claude/{agents,rules,commands,skills}/
      → lib/ghostty.sh (Ghostty install + config, macOS only, if enabled)
      → lib/fonts.sh (cross-platform font install + Windows Terminal auto-config)
      → write_manifest() — tracks deployed files for uninstall
      → _write_snapshot() — saves deployed files for future update comparison
      → plugin marketplace registration + install (multi-marketplace)
      → Codex Plugin setup (if enabled)

install.sh (re-run with existing manifest)
  → setup.sh --update (update mode)
      → _restore_config_from_manifest() — reads settings from manifest
      → run_update() — 3-way merge settings.json, selective file updates
      → _detect_and_write_pending_features() — detect new features, write pending-features.json
      → write_manifest() — updates manifest v2
```

Libraries sourced by `setup.sh` in two stages. `setup_stage1()` (Bash 3.2 compatible) sources in order: `wizard/wizard.sh` (then `parse_cli_args`), `lib/colors.sh`, `lib/detect.sh`, `lib/prerequisites.sh`, and re-execs into Bash 4+ if needed. `setup_source_stage2()` (Bash 4+ required) then sources in order: `lib/features.sh`, `lib/recommendation.sh`, `lib/progress.sh`, `lib/template.sh`, `lib/json-builder.sh`, `lib/snapshot.sh`, `lib/merge.sh`, `lib/update.sh`, `lib/dryrun.sh`, `lib/deploy.sh`, `lib/ghostty.sh`, `lib/fonts.sh`, `lib/codex-setup.sh` (always sourced — `install_selected_plugins()` uses its helpers even in dry-run).

### Profile System

Three profiles (`profiles/*.conf`) define feature toggles as `VAR=true/false`:
- **minimal** — agents + rules only
- **standard** — adds commands, skills, core hooks, Ghostty (macOS), programming fonts
- **full** — everything including Codex Plugin

### i18n

`load_strings "$LANGUAGE"` sources `i18n/{en,ja}/strings.sh`. All UI text uses `STR_*` variables. Each language also has `i18n/{en,ja}/CLAUDE.md.base` as templates for the user's assembled CLAUDE.md.

### Template Engine (`lib/template.sh`)

`build_claude_md()` assembles the user's `~/.claude/CLAUDE.md` in two phases:
1. `inject_feature()` — replaces `{{FEATURE:name}}` markers with contents of partial files (feature-specific docs)
2. `remove_unresolved()` — strips any remaining `{{...}}` markers for disabled features

### Plugin System

`config/plugins.json` defines available plugins with profile assignments and a `marketplaces` mapping. Each plugin has a `name`, `marketplace` (defaults to `claude-plugins-official`), `description`, and `profiles` array. The top-level `marketplaces` object maps marketplace short names to GitHub repos (e.g., `"claude-plugins-official": "anthropics/claude-plugins-official"`).

**Multi-marketplace support**: When the same plugin name exists in multiple marketplaces, `_plugin_has_collision()` detects the conflict and `_compute_selected_plugins()` produces qualified `name@marketplace` entries in `SELECTED_PLUGINS`. The marketplaces currently defined in `config/plugins.json` are `claude-plugins-official` and `anthropic-agent-skills`; no default plugin names collide today. Bare names without collision remain unqualified for backward compatibility. `_apply_plugins_from_csv()` handles both `name@marketplace` (exact match) and bare names (collision → defaults to `claude-plugins-official`).

Wizard flow: `_load_plugins()` reads the JSON (including `PLUGIN_MARKETPLACES[]` parallel array) → `_init_plugins_for_profile()` pre-selects plugins based on the chosen profile → user can customize in interactive mode (colliding names show `[marketplace]` suffix) → `_compute_selected_plugins()` produces the final `SELECTED_PLUGINS` CSV → `setup.sh` parses `name@marketplace`, registers required marketplaces via `claude plugin marketplace add`, and installs via `claude plugin install`.

### Hook Fragment Assembly

Each feature in `features/*/` has a `hooks.json` containing Claude Code hook definitions and/or top-level settings. `build_settings_file()` (in `lib/deploy.sh`) conditionally merges enabled features' fragments into `settings.json` via a custom jq deep-merge that **concatenates arrays** (so multiple features can add entries to the same hook type like `PreCompact` or `PostCompact`).

**IMPORTANT: Hook types (`SessionStart`, `SessionEnd`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `Stop`, `Notification`) MUST be nested inside a `"hooks"` key in hooks.json.** Claude Code reads hooks from `settings.json.hooks.*`, not from the top level. Top-level settings keys (`env`, `statusLine`, etc.) remain at the root.

Three fragment styles exist:
- **Inline hooks**: bash commands embedded as escaped JSON strings in `hooks.json` `"command"` fields, nested inside `"hooks"` (e.g., `features/pre-compact-commit/hooks.json`)
- **External script hooks**: `hooks.json` references a script path with `__HOME__` token inside `"hooks"`, (e.g., `"hooks": {"PostToolUse": [{"hooks": [{"command": "__HOME__/.claude/hooks/doc-size-guard/check-doc-size.sh"}]}]}`). These scripts are deployed by `deploy_hook_scripts()` to `~/.claude/hooks/<feature>/` with `chmod +x`. Both `.sh` and `.py` scripts are supported.
- **Top-level settings**: `hooks.json` can contain any top-level settings key alongside `"hooks"`. The jq deep-merge applies at root level, so `{"statusLine": {...}}` and `{"env": {...}}` merge correctly (e.g., `features/statusline/hooks.json`, `features/safety-net/hooks.json`).

`build_settings_json()` in `lib/json-builder.sh` performs the merge:
1. Deep-merge `settings-base.json` + `permissions.json` via `jq -s '.[0] * .[1]'`
2. Iteratively merge each hook fragment via `merge_deep()` — a recursive jq function that concatenates arrays (e.g., multiple features can append `PreToolUse` or `SessionStart` entries) while deep-merging objects and replacing scalars
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

`install.sh` validates `INSTALL_DIR` via `_safe_install_dir()` before any `rm -rf` operations. Requires an absolute path, strips ALL trailing slashes (so `$HOME//` cannot bypass the `$HOME` check), blocks dangerous paths (`/`, `/home`, `/root`, `$HOME`, system dirs, `/Applications/*`, `/Library/*`), and requires minimum depth of 3 path components. Four copies exist — `install.sh`, `install.ps1` (WSL + Git Bash embedded scripts), and `uninstall.sh` — and `_clone_to_temp_and_swap()` has three (`install.sh` + both `install.ps1` embeds). All copies MUST stay normalized-identical: `tests/unit/test-install-bootstrap.sh` extracts and compares the function bodies in CI, so a one-sided edit fails the build.

### Windows Bootstrap (`install.ps1`)

PowerShell entry point for Windows. Two modes:
- **WSL mode** (default): Ensures WSL2 + Ubuntu installed → runs bash bootstrap inside WSL → shows Windows Terminal guidance
- **Git Bash mode** (`--git-bash`): Fallback for no-admin environments → finds/installs Git for Windows → runs setup via Git Bash

### Manifest-Based Uninstall

`write_manifest()` records deployed files plus `cleanup_paths` in `~/.claude/.starter-kit-manifest.json`. `uninstall.sh` is self-contained and removes manifest-declared kit files/artifacts while preserving user-added content. Features that create runtime artifacts outside the standard managed trees must add those paths to `cleanup_paths_json()`.

### Update Mechanism

If `install.sh` sees an existing manifest, it always adds `setup.sh --update`. With manifest v2 + snapshot it runs the normal update; otherwise it bootstraps a snapshot/migration update. Updates compare snapshot/current/new-kit for kit-managed files, preserve user-added settings, and apply saved merge preferences from `~/.claude/.starter-kit-merge-prefs.json`.

Rules to remember: verify fresh install, `setup.sh --update`/`/update-kit`, and saved config reuse for any new `ENABLE_*`; do not overwrite explicit user choices. Legacy `~/.claude/AGENTS.md` is removed during update/uninstall because the kit no longer deploys it.

`CLAUDE.md` is marker-managed: only the kit section between `BEGIN/END STARTER-KIT-MANAGED` is snapshotted/updated, while the user section is preserved. `--dry-run` redirects `CLAUDE_DIR` to a temp simulation dir, disables merge prompts, logs external side effects as `[WOULD RUN]`, and compares real `~/.claude` with the simulated result.

### Deploy Targets

`setup.sh` deploys content from this repo to `~/.claude/`:

| Source | Target | Condition |
|--------|--------|-----------|
| `agents/*.md` | `~/.claude/agents/` | `INSTALL_AGENTS=true` |
| `rules/*.md` | `~/.claude/rules/` | `INSTALL_RULES=true` |
| `commands/` | `~/.claude/commands/` | `INSTALL_COMMANDS=true` |
| `skills/` | `~/.claude/skills/` | `INSTALL_SKILLS=true` |
| `features/*/scripts/` | `~/.claude/hooks/<feature>/` | feature-specific |
| assembled CLAUDE.md | `~/.claude/CLAUDE.md` | always |
| assembled settings.json | `~/.claude/settings.json` | always |

## Key Conventions

- **Prerequisites auto-install**: The main setup flow requires `git`, `jq`, `curl`, GNU `sed`, GNU `awk`, `bash 4+`, `node`, `tmux`, and `gh`. Stage 1 bootstrap (`wizard/wizard.sh`, `lib/colors.sh`, `lib/detect.sh`, `lib/prerequisites.sh`) remains Bash 3.2 compatible so the kit can auto-install or detect Bash 4+ and re-exec before Stage 2 (`declare -A`, `readarray`, etc.). Only show manual install commands after automatic installation fails.
- **Variable naming**: `ENABLE_*` (feature toggles), `INSTALL_*` (component flags), `STR_*` (i18n strings), `_*` prefixed functions (private/internal)
- **Reserved user namespace**: the kit MUST NOT ship files matching `rules/user-*.md` (or `user-*` trees under other managed dirs). Users place personal always-loaded rules there; `_update_file()` would silently overwrite a same-named user file on update because a kit-new file has no snapshot baseline.
- **Boolean handling**: `_bool_normalize()` accepts true/1/yes/on → "true". Use `is_true()` for checks.
- **No eval**: All dynamic variable assignment uses `printf -v` and `${!var}` (indirect expansion) to prevent injection.
- **Ghostty detection**: Use `[[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]` to detect Ghostty. Never use `-d "/Applications/Ghostty.app"` or `command -v ghostty` (both produce false positives).
- **Platform guards for Ghostty**: Use `[[ "$(uname -s)" == "Darwin" ]]`, not `is_wsl`/`is_msys` (WSL detection can be unreliable).
- **Font install fallback pattern**: Always try brew first, then fall back to direct download (`curl` + `unzip`) so installs succeed without Homebrew.
- **Keg-only brew formulas**: `brew install node@XX` etc. are keg-only (not symlinked into PATH). After install, resolve the bin dir via `brew --prefix <formula>` and persist it with `_add_to_path_now_and_persist()`.
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
- **Plugin install in setup.sh**: Plugin marketplace registration + install live in `install_selected_plugins()` (a normal function — use `local` variables). Failures must surface the captured CLI output via `warn`, never fail silently.
- **NONINTERACTIVE env var**: `install.sh` supports `NONINTERACTIVE=1` (Homebrew convention) to auto-add `--non-interactive` flag for setup.sh.
- **DRY_RUN variable**: `--dry-run` sets `DRY_RUN="true"`. In dry-run mode, `CLAUDE_DIR` is redirected to a temp sim dir so the normal deploy/update flow runs without touching real files. External operations (Ghostty, fonts, shell RC, plugins, Codex Plugin, Claude CLI) are individually guarded and logged as `[WOULD RUN]`. Light prerequisites (git, jq, curl) may be installed with user consent in interactive mode; `--non-interactive --dry-run` installs nothing and aborts if tools are missing. Sim dir snapshot/manifest are temporary artifacts discarded after the summary report. The comparison basis is always "real `~/.claude` vs sim dir result".

## Security Hardening

`config/permissions.json` keeps high-risk tools out of `permissions.allow` so code execution, network fetches, environment reads, and raw file dumps require confirmation. Deny rules cover network exfiltration, escalation, destructive git, credential files, shell RC edits, and clipboard exfiltration. Top-level settings keep project MCP auto-approval off and disable bypass-permissions mode. Treat permissions as a guardrail, not a substitute for reviewing MCP/tool code.

## Versioning

- **patch (x.y.Z)**: バグ修正、ドキュメント修正、テスト追加、内部リファクタ（ユーザーの動作が変わらない）
- **minor (x.Y.0)**: 新機能追加、既存機能の動作変更、新 profile 項目、新 hook/command/skill 追加
- **major (X.0.0)**: 破壊的変更（設定フォーマット変更、既存 config の非互換、migration 必須）
- PR の CHANGELOG エントリに `## [x.y.z] - YYYY-MM-DD` を書く。タグはマージ後に切る。
- 複数の変更を含む PR はもっとも影響の大きい変更に合わせる。

## Adding a New Feature

1. Create `features/new-feature/feature.json` (metadata) and `hooks.json` (hook fragments and/or top-level settings). **Hook types MUST be nested inside `"hooks": {}`** — see "Hook Fragment Assembly" above
2. Add `ENABLE_NEW_FEATURE=true/false` to each `profiles/*.conf`
3. Add variable initialization in `wizard/wizard.sh` (`ENABLE_NEW_FEATURE="${ENABLE_NEW_FEATURE:-}"`) and append the key to `_CONFIG_KEYS` in `wizard/registry.sh` — `_CONFIG_ALLOWED_KEYS` / `_CONFIG_SAVE_KEYS` are generated from that registry (no manual `save_config()` edit). Read-only legacy keys go in `_CONFIG_LEGACY_KEYS`
4. Add `STR_CONFIRM_*` strings in both `i18n/en/strings.sh` and `i18n/ja/strings.sh`
5. In `wizard/steps.sh`: add confirmation display in `_step_confirm()` and the non-interactive default in `_fill_noninteractive_defaults()`
6. If the feature is a hook, add to `HOOK_KEYS` / `HOOK_TOKENS` in `wizard/registry.sh`, add `STR_HOOKS_*` strings in both i18n files, and add the hook label to `HOOK_LABELS`
7. Features are auto-collected by `build_settings_file()` in `lib/deploy.sh` via `_FEATURE_ORDER` / `_FEATURE_FLAGS` registry — no manual merge code needed
8. If external scripts needed: add `[name]=true` to `_FEATURE_HAS_SCRIPTS` in `lib/features.sh` — fresh deploy (`deploy_hook_scripts()`), update deploy (`_update_hook_scripts()`), and manifest/snapshot tracking (`collect_managed_target_files()`) all iterate `_FEATURE_SCRIPT_ORDER` × `_FEATURE_HAS_SCRIPTS`. A feature ever excluded from `_FEATURE_ORDER` (settings fragment special-cased) must be appended to `_FEATURE_SCRIPT_ORDER` so its scripts still flow through all three paths (no such feature exists currently — the two lists are identical)
9. If the feature creates files outside the standard manifest-tracked directories, add explicit cleanup to `uninstall.sh`
10. Verify update-path adoption. A new key must be checked in all of these paths:
   - fresh install
   - `setup.sh --update` / `/update-kit`
   - saved config reuse in `wizard/wizard.sh`
   Missing keys on older installs should receive the intended default for that profile, but existing explicit user choices must win.
11. Run the MDM expected-state parity suite (`tests/run-mdm-tests.sh`). Registry-backed features are discovered automatically; update `mdm/render-expected.py` only when adding a new source shape, special partial, root output, or override that its static allowlist does not already model, and extend the parity fixture in the same change.
12. Update `CHANGELOG.md` in the same PR when the feature changes user-visible behavior, default presets, commands, docs, generated files, or upgrade behavior. Write the entry directly under the version heading (`## [x.y.z]`) that will be tagged on merge — do not use an `[Unreleased]` section. Follow the existing Keep a Changelog structure and write the entry at the level users will notice.
13. **Feature recommendation**: Ensure `feature.json` has `displayName` and `description` fields for the notification display. If the feature should NOT be recommended (special-case features), verify it is excluded from `_FEATURE_FLAGS` or is handled by `_detect_and_write_pending_features()` exclusion logic.

Multiple features can safely use the same hook type (e.g., `PreCompact`, `PostCompact`) — `merge_deep()` concatenates arrays instead of replacing them.

**Hook authoring conventions** (formerly distributed as `rules/hooks.md`): treat hook stdout/stderr as user-visible control surfaces and keep output concise; prefer external hook scripts over inline JSON shell when logic is nontrivial; filter by matcher first, then validate the real tool input schema inside the script. New hooks.json fragments and permissions.json changes need a regression test under `tests/unit/` (follow the `test-hook-fixtures.sh` style).

**Hook ordering matters**: `safety-net` must be the **first** entry in `hook_fragments[]` so its `PreToolUse` entry appears at index 0 (runs before other PreToolUse hooks). When adding new PreToolUse hooks, append after safety-net.

**`build_settings_file()`** in `lib/deploy.sh` is the single unified settings.json builder. It accepts an output path parameter and is called by both fresh install and update paths.

## Adding a New Plugin

1. Add entry to `config/plugins.json` under `plugins[]` with `name`, `marketplace`, `description`, `profiles`
2. If using a new marketplace, add its GitHub repo to `marketplaces` mapping in the same file
3. Verify JSON: `jq . config/plugins.json`
4. If the plugin name already exists in another marketplace, `_plugin_has_collision()` will auto-detect and the wizard will show `[marketplace]` suffix; `_compute_selected_plugins()` will produce `name@marketplace` in the CSV
5. Update the hardcoded plugin counts and lists no test enforces: `README.md` (profile table, plugin section heading, plugin table row) and `README.en.md` (feature bullet, profile table). When the plugin carries operational caveats a user needs *before* running it (execution prerequisites, output residue, cost/consent, coverage limits), sync those to `README.en.md` too — not just the counts. `.github/instructions/review.instructions.md` treats `README.en.md` prerequisites as a review gate
6. Adding to `standard` also has to clear the `standard_count -le 5` cap in `tests/unit/test-context-budget.sh`; `full`-only entries need no test change
7. Update `CHANGELOG.md` — a changed default plugin set is user-visible behavior, so bump minor
8. Existing installs never pick up a new catalog entry: update restores `SELECTED_PLUGINS` from the manifest, and plugins are outside feature recommendation. State the manual `/plugin install <name>@<marketplace>` step in CHANGELOG/README rather than assuming reach
9. MDM is unaffected — managed mode forces `SELECTED_PLUGINS=""` and `mdm/render-expected.py` never reads `config/plugins.json`. Enabling plugins *under* MDM would be a different change: `claude plugin install` writes `enabledPlugins` into the byte-attested `settings.json`

## Notable Features

- **Safety Net**: `cc-safety-net` PreToolUse hook helps prevent *accidental* destructive shell/git operations (string-pattern matching only; not a defense against deliberate bypass or prompt injection) and sets both canonical and legacy strict env names for fail-closed compatibility.
- **Auto Update**: async SessionStart/SessionEnd update checks with lock/status files; older Claude versions use the legacy cache hook.
- **Status Line**: Python statusLine command showing model, context usage, and 5h/7d rate limits.
- **Doc Size Guard**: non-blocking size-hygiene warning when CLAUDE.md/AGENTS.md exceeds line targets after Write.
- **Feature Recommendation**: writes pending feature names and notifies via SessionStart for enabled profiles.

## Platform Detection

`lib/detect.sh` exports: `OS`, `ARCH`, `DISTRO`, `DISTRO_FAMILY`, `IS_WSL`, `WSL_BUILD`.

Helpers: `is_macos()`, `is_linux()`, `is_wsl()`, `is_msys()`.

MSYS pattern covers: `MSYS_NT*|MINGW*_NT*|CLANG*_NT*|UCRT*_NT*`. WSL detection uses `/proc/version` + `WSL_DISTRO_NAME` + `WSLENV` + `WSLInterop` fallbacks.

## Learned Rules (auto-generated by cn-memory)

<!-- cn-memory:start -->
<!-- cn-memory:end -->
