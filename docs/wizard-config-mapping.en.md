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
| Codex Plugin | `ENABLE_CODEX_PLUGIN` / `--codex-plugin` | Whether to install Codex Plugin and run CLI auth | Codex Plugin setup in `setup.sh` | No |
| New `/init` | `ENABLE_NEW_INIT` / `--new-init` | Enable Claude Code's interactive `/init` flow | `settings.json` `env.CLAUDE_CODE_NEW_INIT` | Yes |
| Editor | `EDITOR_CHOICE` / `--editor` | Whether the git push review hook is enabled (`none` skips the hook fragment entirely) | Hook fragment inclusion, manifest | Indirectly |
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
| `ENABLE_NEW_INIT` | Claude Code's new interactive `/init` mode | `settings.json` `env.CLAUDE_CODE_NEW_INIT` | Defaults to `true` for Minimal, Standard, and Full; Custom asks explicitly |
| `EDITOR_CHOICE` | Gates the git push review hook | Inclusion of `features/git-push-review/hooks.json` | `none` skips the hook fragment entirely. The hook only prints a review reminder to stderr before `git push`; it does not launch an editor or show a diff |
| `COMMIT_ATTRIBUTION` | Claude Code attribution on or off | `settings.json` `attribution.commit`, `attribution.pr` | `false` clears both commit and PR attribution |
| `ENABLE_CODEX_PLUGIN` | Run Codex Plugin setup or skip it | Codex CLI auth and plugin install | A setup action, not a JSON setting |
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
| `INSTALL_MEMORY` | (retired) seed memory is no longer shipped | None | Read as a legacy key and ignored; update removes previously shipped kit files |

## Hook Flag Mapping

These flags are used to merge the corresponding `features/*/hooks.json` fragments into `settings.json`.

| Key | Hook / feature | Main purpose | Included in `settings.json` |
|---|---|---|---|
| `ENABLE_SAFETY_NET` | Safety Net | Block destructive commands | Yes |
| `ENABLE_AUTO_UPDATE` | Auto Update | Check for starter kit updates on session start | Yes |
| `ENABLE_WEB_CONTENT_UPDATE` | Web Content Update | Check web extraction skill dependency updates | Yes |
| `ENABLE_TMUX_HOOKS` | Tmux Reminder | Suggest run_in_background for foreground dev servers (non-blocking) | Yes |
| `ENABLE_GIT_PUSH_REVIEW` | Git Push Review | Pause before push and open a diff | Yes |
| `ENABLE_DOC_BLOCKER` | Doc Blocker | Ask-only guard for slop doc patterns (general docs allowed) | Yes |
| `ENABLE_PRETTIER_HOOKS` | Prettier Auto-format | Format JS / TS edits | Yes |
| `ENABLE_BIOME_HOOKS` | Biome Auto-format | Format and lint JS / TS edits | Yes |
| `ENABLE_CONSOLE_LOG_GUARD` | Console Log Guard | Warn on leftover `console.log` | Yes |
| `ENABLE_MEMORY_PERSISTENCE` | (retired) superseded by native auto-memory | None | Read as a legacy key and ignored |
| `ENABLE_STRATEGIC_COMPACT` | (retired) hook removed; skill remains on-demand | None | Read as a legacy key and ignored |
| `ENABLE_PR_CREATION_LOG` | PR Creation Log | PR creation logging support | Yes |
| `ENABLE_PRE_COMPACT_COMMIT` | Pre-compact Snapshot | Stash tracked changes before compact (opt-in; default false in all profiles) | Yes |
| `ENABLE_STATUSLINE` | Statusline | Statusline feature toggle | Yes |
| `ENABLE_DOC_SIZE_GUARD` | Doc Size Guard | Warn when `CLAUDE.md` / `AGENTS.md` is too large | Yes |
| `ENABLE_NO_FLICKER` | No Flicker | Reduce display flicker | Yes |
| `ENABLE_FEATURE_RECOMMENDATION` | Feature Recommendation | Notify about newly available features | Yes |

## Common Misunderstandings

### `PROFILE` does not appear in the final config

That is expected. `PROFILE` is a preset name used to seed lower-level choices, not a top-level runtime setting.

### `SELECTED_PLUGINS` is not visible in `settings.json`

That is expected. Plugin selection is consumed by the plugin installation flow and stored in the manifest for later reuse.

### `ENABLE_CODEX_PLUGIN` does not show up in `settings.json`

That is expected. It controls whether Codex CLI auth and plugin install are executed, not whether a JSON key is written.
