# Wizard Config Mapping

This document explains where each interactive wizard choice or non-interactive CLI flag is applied during setup.

There are three broad categories of config in this starter kit.

1. Values written directly into generated files such as `settings.json` or `CLAUDE.md`
2. Values used by deployment or extra setup steps
3. Values stored mainly for presets, manifests, or future re-runs

Not every saved value is supposed to appear in `settings.json`. In particular, `PROFILE` and `INSTALL_*` mostly control defaults and file deployment rather than final JSON output.

## Wizard Steps

| Step | Saved key / CLI | What it controls | Main destination | Visible in `settings.json` |
|---|---|---|---|---|
| Language | `LANGUAGE` / `--language` | UI language and generated language settings | `settings.json`, `CLAUDE.md`, i18n loading | Yes |
| Profile | `PROFILE` / `--profile` | Preset bundle for other defaults | wizard initialization, manifest | No |
| Codex MCP | `ENABLE_CODEX_MCP` / `--codex-mcp` | Whether to run Codex CLI auth and Claude MCP registration | Codex MCP setup in `setup.sh` | No |
| Editor | `EDITOR_CHOICE` / `--editor` | Editor command for the git push review hook | Hook template substitution, manifest | Indirectly |
| Ghostty | `ENABLE_GHOSTTY_SETUP` / `--ghostty` | Extra Ghostty setup | Ghostty setup flow | No |
| Hooks | `ENABLE_*` / `--hooks` | Which hooks are enabled | Hook fragments merged into `settings.json` | Yes |
| Plugins | `SELECTED_PLUGINS` / `--plugins` | Recommended Claude Code plugins to install | Plugin install flow, manifest | No |
| Claude Code attribution | `COMMIT_ATTRIBUTION` / `--commit-attribution` | Claude Code attribution in commits and PRs | `settings.json` `attribution` | Yes |
| Confirm & Deploy | `WIZARD_RESULT` | Save only, deploy now, or cancel | Execution flow control | No |

## Core Selection Mapping

| Key | Purpose | Main destination | Notes |
|---|---|---|---|
| `LANGUAGE` | UI and generated file language | `settings.json`, `CLAUDE.md`, i18n | Currently written as `English` or `日本語` |
| `PROFILE` | Minimal / Standard / Full / Custom preset | Wizard defaults, manifest | Expanded into lower-level flags during setup |
| `EDITOR_CHOICE` | Editor command for git push review | `features/git-push-review/hooks.json` | Use `none` if you do not want editor integration |
| `COMMIT_ATTRIBUTION` | Claude Code attribution on or off | `settings.json` `attribution.commit`, `attribution.pr` | `false` clears both commit and PR attribution |
| `ENABLE_CODEX_MCP` | Run Codex MCP setup or skip it | Codex CLI auth and `claude mcp add` | A setup action, not a JSON setting |
| `ENABLE_GHOSTTY_SETUP` | Optional Ghostty setup | Ghostty install/config flow | Disabled automatically outside macOS |
| `ENABLE_FONTS_SETUP` | Programming font installation | Font setup flow | Changes the environment, not generated JSON |
| `SELECTED_PLUGINS` | Recommended plugin selection | Plugin install flow, manifest | Supports `name@marketplace` |

## Content Installation Flags

| Key | What it deploys | Main destination | Behavior during update |
|---|---|---|---|
| `INSTALL_AGENTS` | `~/.claude/agents/` | Initial copy, update | Synced only when enabled |
| `INSTALL_RULES` | `~/.claude/rules/` | Initial copy, update | Same |
| `INSTALL_COMMANDS` | `~/.claude/commands/` | Initial copy, update | Same |
| `INSTALL_SKILLS` | `~/.claude/skills/` | Initial copy, update | Same |
| `INSTALL_MEMORY` | `~/.claude/memory/` | Initial copy, update | Same |

## Hook Flag Mapping

These flags are used to merge the corresponding `features/*/hooks.json` fragments into `settings.json`.

| Key | Hook / feature | Main purpose | Included in `settings.json` |
|---|---|---|---|
| `ENABLE_SAFETY_NET` | Safety Net | Block destructive commands | Yes |
| `ENABLE_AUTO_UPDATE` | Auto Update | Check for starter kit updates on session start | Yes |
| `ENABLE_TMUX_HOOKS` | Tmux Reminder | Encourage tmux for long-running work | Yes |
| `ENABLE_GIT_PUSH_REVIEW` | Git Push Review | Pause before push and open a diff | Yes |
| `ENABLE_DOC_BLOCKER` | Doc Blocker | Prevent unnecessary `.md` / `.txt` files | Yes |
| `ENABLE_PRETTIER_HOOKS` | Prettier Auto-format | Format JS / TS edits | Yes |
| `ENABLE_CONSOLE_LOG_GUARD` | Console Log Guard | Warn on leftover `console.log` | Yes |
| `ENABLE_MEMORY_PERSISTENCE` | Memory Persistence | Persist important knowledge | Yes |
| `ENABLE_STRATEGIC_COMPACT` | Strategic Compact | Compact suggestion support | Yes |
| `ENABLE_PR_CREATION_LOG` | PR Creation Log | PR creation logging support | Yes |
| `ENABLE_PRE_COMPACT_COMMIT` | Pre-compact Commit | Commit helper before compact | Yes |
| `ENABLE_STATUSLINE` | Statusline | Statusline feature toggle | Yes |
| `ENABLE_DOC_SIZE_GUARD` | Doc Size Guard | Warn when `CLAUDE.md` / `AGENTS.md` is too large | Yes |

## Common Misunderstandings

### `PROFILE` does not appear in the final config

That is expected. `PROFILE` is a preset name used to seed lower-level choices, not a top-level runtime setting.

### `SELECTED_PLUGINS` is not visible in `settings.json`

That is expected. Plugin selection is consumed by the plugin installation flow and stored in the manifest for later reuse.

### `ENABLE_CODEX_MCP` does not show up in `settings.json`

That is expected. It controls whether Codex CLI auth and Claude MCP registration are executed, not whether a JSON key is written.

