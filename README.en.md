# Claude Code Starter Kit

[日本語 README](README.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: macOS/Linux/Windows](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows-blue.svg)](#installation)

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
- **Codex MCP** sub-agent integration (optional, requires ChatGPT Plus + OpenAI API key)
- **Non-interactive mode** for CI/automation

## Prerequisites: Claude Account (Paid)

**Claude Code requires a paid Anthropic account.** It does not work with free plans.

### Pricing

| Plan | Price | For | Features |
|------|-------|-----|----------|
| **Pro** | $20/mo | Individuals (starter) | Claude Code access, standard usage |
| **Max (5x)** | $100/mo | Individuals (heavy use) | 5x Pro usage, ideal for extended coding |
| **Max (20x)** | $200/mo | Individuals (power user) | 20x Pro usage, for large-scale projects |
| **Teams** | $30/user/mo | Teams | Shared workspace, admin controls |
| **Enterprise** | Contact sales | Large orgs | SSO, audit logs, custom contracts |

> **Note**: Prices shown are as of 2025. Check [claude.ai/pricing](https://claude.ai/pricing) for current rates.
> Using Codex MCP (OpenAI integration) requires a separate ChatGPT Plus subscription ($20+/mo) and OpenAI API usage fees.

### For individuals

Subscribe to [Claude Pro or Max](https://claude.ai/pricing). Create an account at [claude.ai](https://claude.ai) and upgrade your plan.

### For teams and organizations

Use **Claude for Teams** or **Claude for Enterprise**. If your organization already has a plan, ask your admin to invite you. For cloud provider integration (AWS Bedrock, Google Vertex AI, Microsoft Foundry), see the [third-party integration docs](https://code.claude.com/docs/en/third-party-integrations).

### First-time login

When you run `claude` for the first time, you'll be asked to choose an authentication method:

| Method | Recommended for | Description |
|--------|----------------|-------------|
| **Claude.ai account (OAuth)** (Recommended) | Individuals & teams | Browser opens, log in to claude.ai. Works with Pro/Max/Teams/Enterprise |
| **Anthropic Console (API key)** | Developers preferring per-token billing | Generate a key at [console.anthropic.com](https://console.anthropic.com) |

**If unsure, choose OAuth.** Just log in via browser — no additional setup needed.

## Installation

### One-liner (macOS / Linux / WSL)

```bash
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash
```

### Windows PowerShell (uses WSL2)

Run PowerShell **as Administrator**, then:

```powershell
irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex
```

> **Important**: After setup, use **Windows Terminal + WSL (Ubuntu)** to run `claude`.
> Open Windows Terminal → click the dropdown arrow → select **Ubuntu**.
>
> If admin is unavailable, use Git Bash mode: `powershell -File install.ps1 --git-bash`

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

| Profile | Agents | Rules | Commands | Skills | Hooks | Memory | Codex MCP | Ghostty |
|---------|--------|-------|----------|--------|-------|--------|-----------|---------|
| Minimal | Yes | Yes | - | - | - | - | - | - |
| Standard (Recommended) | Yes | Yes | Yes | Yes | Core | Yes | Optional | - |
| Full | Yes | Yes | Yes | Yes | All | Yes | Yes | macOS only |

- **Minimal**: Lightweight start with just agents and rules
- **Standard**: Best for most teams. Includes commands, skills, core hooks, and memory
- **Full**: Everything enabled including all hooks and Codex MCP sub-agent delegation

## Usage

> **Important: You must restart your terminal after setup.**
> PATH and shell settings added during setup won't take effect until you open a new terminal window. Close your current terminal and open a new one before running `claude`.

After restarting your terminal, start `claude` in your project directory. The installed slash commands and agents are immediately available:

```bash
/plan            # Structured planning
/tdd             # Test-driven development flow
/code-review     # Code review mode
/build-fix       # Fix build errors
/e2e             # End-to-end testing
/verify          # Final verification
/checkpoint      # Record current work as a checkpoint
/refactor-clean  # Find and clean up unused code
/update-docs     # Update documentation to latest state
```

### Deployment: Let Claude Code Set Up Your Infrastructure

Not sure how to deploy your application? Just ask Claude Code — it can guide you through the entire process:

**Deploy to AWS Lambda:**

```
I want to deploy this project to AWS Lambda.
Please set up all necessary config files, IAM roles, and deployment steps.
```

**Deploy to Google Cloud Functions:**

```
I want to deploy this to Google Cloud Functions.
Please set up the required configuration and walk me through the process.
```

**Not sure which platform to use:**

```
I want to run this in production.
Compare AWS Lambda, Google Cloud Functions, and Vercel,
and recommend the best option for this project.
```

Claude Code helps with more than just writing code — it can set up **infrastructure, deployment configs, and CI/CD pipelines** too.

### Sending Screenshots to Claude Code

You can send screenshots directly to Claude Code to show UI bugs, error screens, or layout issues. Claude Code understands images and can fix problems just by seeing them.

**macOS:**

| Step | Action | Description |
|------|--------|-------------|
| 1. Take screenshot | `Cmd + Shift + Ctrl + 4` | Select an area to copy to clipboard |
| 2. Paste into Claude Code | `Ctrl + V` (NOT `Cmd + V`) | Paste while Claude Code prompt is focused |

> **Important**: Use `Ctrl + V` (not `Cmd + V`) to paste screenshots into Claude Code. This is easy to mix up.

**Windows (WSL):**

| Step | Action | Description |
|------|--------|-------------|
| 1. Take screenshot | `Win + Shift + S` | Snipping Tool opens, select area to copy |
| 2. Paste into Claude Code | `Ctrl + V` | Paste in Windows Terminal |

You can also **drag and drop image files** into the terminal to send them to Claude Code.

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

From PowerShell or Terminal:

```bash
wsl -d Ubuntu -- bash -lc '~/.claude-starter-kit/uninstall.sh'
```

**If you cloned manually**, run from the cloned directory:

```bash
cd claude-code-starter-kit
./uninstall.sh
```

Only files deployed by the starter kit (tracked in `~/.claude/.starter-kit-manifest.json`) are removed. User-added files are preserved.

## License

MIT. See [LICENSE](LICENSE).
