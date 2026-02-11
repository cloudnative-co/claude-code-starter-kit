# Claude Code Starter Kit

[日本語 README](README.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: macOS/Linux/WSL](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20WSL-blue.svg)](#installation)

One-command setup of a complete Claude Code development environment with an interactive wizard.

> **This kit reproduces the exact Claude Code environment used by Shinji Saito, CEO of Cloud Native Inc. and Chief Information Security Advisor to Japan's Ministry of Education, Culture, Sports, Science and Technology (MEXT).**

## Table of Contents

- [Why This Repo](#why-this-repo)
- [Features](#features)
- [Installation](#installation)
- [Wizard Flow](#wizard-flow)
- [Profiles](#profiles)
- [Usage](#usage)
- [Non-Interactive Mode](#non-interactive-mode)
- [Directory Structure](#directory-structure)
- [Customization](#customization)
- [Uninstall](#uninstall)
- [License](#license)

## Why This Repo

Claude Code Starter Kit bootstraps a consistent, high-quality Claude Code environment in minutes. It ships opinionated agents, rules, commands, skills, hooks, and plugin recommendations so teams can start coding with shared standards immediately.

## Features

- **3 profiles**: Minimal, Standard (recommended), Full
- **9 agents**: planner, architect, tdd-guide, code-reviewer, security-reviewer, build-error-resolver, e2e-runner, refactor-cleaner, doc-updater
- **8 rules**: coding-style, git-workflow, hooks, patterns, performance, security, testing, agents
- **14 slash commands**: /plan, /tdd, /build-fix, /code-review, /e2e, /verify, and more
- **11 skill modules**: backend-patterns, frontend-patterns, security-review, tdd-workflow, and more
- **8 optional hooks**: tmux reminder, git push review, doc blocker, prettier, console.log guard, memory persistence, strategic compact, PR creation log
- **10 plugin recommendations**
- **i18n**: English & Japanese
- **Codex MCP** sub-agent integration (optional, requires a paid ChatGPT plan)
- **Non-interactive mode** for CI/automation

## Installation

### One-liner (macOS / Linux / WSL)

```bash
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash
```

### Windows PowerShell (Administrator)

```powershell
irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex
```

### Manual

```bash
git clone https://github.com/cloudnative-co/claude-code-starter-kit.git
cd claude-code-starter-kit
./setup.sh
```

## Wizard Flow

```
Language → Profile → Codex MCP → Editor → Hooks → Plugins → Commit Attribution → Confirm & Deploy
```

Each step shows numbered options with descriptions. Recommended choices are marked.

## Profiles

| Profile | Agents | Rules | Commands | Skills | Hooks | Memory | Codex MCP |
|---------|--------|-------|----------|--------|-------|--------|-----------|
| Minimal | Yes | Yes | - | - | - | - | - |
| Standard (Recommended) | Yes | Yes | Yes | Yes | Core | Yes | - |
| Full | Yes | Yes | Yes | Yes | All | Yes | Yes |

- **Minimal**: Lightweight start with just agents and rules
- **Standard**: Best for most teams. Includes commands, skills, core hooks, and memory
- **Full**: Everything enabled including all hooks and Codex MCP sub-agent delegation

## Usage

After setup, start `claude` in your project directory. The installed slash commands and agents are immediately available:

```bash
/plan          # Structured planning
/tdd           # Test-driven development flow
/code-review   # Code review mode
/build-fix     # Fix build errors
/e2e           # End-to-end testing
/verify        # Final verification
```

## Non-Interactive Mode

For CI, automation, or scripted setups:

```bash
# Use standard profile with English and VS Code
./setup.sh --non-interactive --profile=standard --language=en --editor=vscode

# Full control over hooks and plugins
./setup.sh --non-interactive \
  --profile=standard \
  --language=en \
  --editor=cursor \
  --codex-mcp=false \
  --commit-attribution=false \
  --hooks=tmux,git-push,prettier,console,memory,compact,pr-log \
  --plugins=security-guidance,commit-commands,pr-review-toolkit

# Reuse a saved config
./setup.sh --non-interactive --config=./my-config.conf
```

## Directory Structure

```
claude-code-starter-kit/
├── install.sh              # One-liner bootstrap (macOS/Linux/WSL)
├── install.ps1             # Windows PowerShell bootstrap
├── setup.sh                # Main setup script (wizard + deploy)
├── uninstall.sh            # Manifest-based clean uninstall
├── lib/                    # Shell libraries
│   ├── colors.sh           # Terminal color helpers
│   ├── detect.sh           # OS/WSL detection
│   ├── prerequisites.sh    # Dependency checks
│   ├── template.sh         # Text template engine
│   └── json-builder.sh     # JSON builder (jq-based)
├── wizard/                 # Interactive wizard
│   ├── wizard.sh           # 8-step wizard logic
│   └── defaults.conf       # Default values
├── config/                 # Configuration templates
│   ├── settings-base.json  # Base settings.json structure
│   ├── permissions.json    # Tool permissions
│   └── plugins.json        # Plugin catalog
├── profiles/               # Profile presets
│   ├── minimal.conf
│   ├── standard.conf
│   └── full.conf
├── features/               # Optional feature modules
│   ├── */feature.json      # Feature metadata
│   └── */hooks.json        # Hook fragments
├── i18n/                   # Internationalization
│   ├── en/                 # English templates & strings
│   └── ja/                 # Japanese templates & strings
├── agents/                 # Agent definitions (9 files)
├── rules/                  # Rule files (8 files)
├── commands/               # Slash commands (14 files)
├── skills/                 # Skill modules (11 dirs)
└── memory/                 # Best practice memory (5 files)
```

## Customization

After installation, you can extend or modify any component:

- **Add an agent**: Create a new `.md` file in `~/.claude/agents/`
- **Add a rule**: Create a new `.md` file in `~/.claude/rules/`
- **Add a command**: Create a new `.md` file in `~/.claude/commands/`
- **Add a skill**: Create a new directory under `~/.claude/skills/` with a `SKILL.md`
- **Modify hooks**: Edit `~/.claude/settings.json` hooks section

To re-apply the starter kit config (e.g., after updating the repo), run `./setup.sh` again. Your previous selections are remembered in `~/.claude-starter-kit.conf`.

## Uninstall

If you installed via the one-liner, the repo is saved at `~/.claude-starter-kit/`.

**Mac / Linux:**

```bash
~/.claude-starter-kit/uninstall.sh
```

**Windows (WSL):**

`.sh` scripts cannot run in PowerShell. Switch to WSL first:

1. Open PowerShell (search "PowerShell" in the Start menu)
2. Type `wsl` and press Enter to switch to the Linux environment
3. Run the uninstall command:

```powershell
wsl
```
```bash
~/.claude-starter-kit/uninstall.sh
```

**If you cloned manually**, run from the cloned directory:

```bash
cd claude-code-starter-kit
./uninstall.sh
```

Only files deployed by the starter kit (tracked in `~/.claude/.starter-kit-manifest.json`) are removed. User-added files are preserved.

## License

MIT. See [LICENSE](LICENSE).
