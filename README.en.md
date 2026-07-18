# Claude Code Starter Kit

[日本語 README](README.md) | [Changelog](CHANGELOG.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: macOS/Windows](https://img.shields.io/badge/Platform-macOS%20%7C%20Windows-blue.svg)](#installation)

One-command setup of a complete Claude Code development environment with an interactive wizard.

> **This kit reproduces the exact Claude Code environment used by Shinji Saito, CEO of Cloud Native Inc. and Chief Information Security Advisor to Japan's Ministry of Education, Culture, Sports, Science and Technology (MEXT).**

## Quick Start

**Mac:**

```bash
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash
```

**Windows (run PowerShell as Administrator):**

```powershell
irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex
```

> Restart your terminal after install, then run `claude`. See [Installation](#installation) for details.

---

## Table of Contents

- [Why This Repo](#why-this-repo)
- [Features](#features)
- [Installation](#installation)
- [Wizard Flow](#wizard-flow)
- [Wizard Config Mapping](docs/wizard-config-mapping.en.md)
- [Profiles](#profiles)
- [Usage](#usage)
- [Non-Interactive Mode](#non-interactive-mode)
- [MDM Deployment (macOS)](docs/mdm/README.md)
- [Directory Structure](#directory-structure)
- [Customization](#customization)
- [Uninstall](#uninstall)
- [Changelog](#changelog)
- [License](#license)

## Why This Repo

Claude Code Starter Kit bootstraps a consistent, high-quality Claude Code environment in minutes. It ships opinionated agents, rules, commands, skills, hooks, and plugin recommendations so teams can start coding with shared standards immediately.

## Features

- **3 profiles**: Minimal, Standard (recommended), Full
- **9 agents**: planner, architect, tdd-guide, code-reviewer, security-reviewer, build-error-resolver, e2e-runner, refactor-cleaner, doc-updater
- **8 rules**: coding-style, git-workflow, performance, security, testing, agents, anti-patterns, permissions-guide
- **21 slash commands**: /plan, /tdd, /build-fix, /e2e, /verify, /research, /web-article, /oss-analyze, /web-source-review, /handover, /update-kit, and more
- **12 skill modules**: backend-patterns, frontend-patterns, security-review, tdd-workflow, prompt-patterns, and more
- **11 optional hooks/settings**: safety net (cc-safety-net), auto update, web content update, tmux reminder, doc blocker, Prettier or Biome formatting, PR creation log, pre-compact snapshot (opt-in), statusline, doc size guard, feature recommendation
- **14 plugins** from multiple marketplaces: security-guidance, commit-commands, pr-review-toolkit, feature-dev, code-review, claude-md-management, superpowers, code-simplifier, document-skills, example-skills, typescript-lsp, gopls-lsp, pyright-lsp, rust-analyzer-lsp
- **i18n**: English & Japanese
- **Codex Plugin** sub-agent integration (optional, supports ChatGPT sign-in or OpenAI API key auth)
- **Non-interactive mode** for CI/automation

## Prerequisites

Missing or unsupported prerequisites are installed or upgraded automatically when possible: `git`, `jq`, `curl`, GNU `sed`, GNU `awk`, `bash 4+`, Node.js `22.19+`, `tmux`, and `gh`. On macOS, the kit also detects the system Bash 3.2 limitation, installs Bash 4+ when needed, and re-execs automatically. If automatic installation fails, setup exits with an error and shows the manual commands.

### Claude Account (Paid)

**Claude Code requires a paid Anthropic account.** It does not work with free plans.

### Pricing

| Plan | Price | For | Features |
|------|-------|-----|----------|
| **Pro** | $20/mo | Individuals (starter) | Claude Code access, standard usage |
| **Max (5x)** | $100/mo | Individuals (heavy use) | 5x Pro usage, ideal for extended coding |
| **Max (20x)** | $200/mo | Individuals (power user) | 20x Pro usage, for large-scale projects |
| **Teams Standard** | $25/user/mo | Teams | Shared workspace, admin controls, SSO (SAML) |
| **Teams Premium** | $150/user/mo | Teams (advanced) | All Standard features + higher usage limits |
| **Enterprise** | Contact sales | Large orgs | Custom contracts, audit logs, advanced security |

> **Note**: Prices shown are as of March 2026. Check [claude.com/pricing](https://claude.com/pricing) for current rates.
> Using Codex Plugin (OpenAI integration) requires either an eligible ChatGPT plan for Codex sign-in, or OpenAI API key authentication with OpenAI API usage fees.

> **Linux**: This kit is designed for macOS and Windows. If you want to use it on Linux, adjustments may be needed depending on your distribution (Ubuntu, Fedora, etc.) and desktop environment (GNOME, KDE, etc.). Try the one-liner or manual installation method.

### For individuals

Subscribe to [Claude Pro or Max](https://claude.com/pricing). Create an account at [claude.ai](https://claude.ai) and upgrade your plan.

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

### One-liner (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash
```

**Non-interactive one-liner** (skips wizard, uses Standard profile defaults):

```bash
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash -s -- --non-interactive
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
Language → Profile → Codex Plugin → New /init → Editor → Ghostty → Fonts → Hooks → Plugins → Claude Code Attribution → Confirm & Deploy
```

Each step shows numbered options with descriptions. Recommended choices are marked.

> **About the Editor step**: The wizard asks which code editor you use, purely to record your environment in the saved config. **If you don't have an editor installed or aren't sure, choose "None"** — Claude Code works entirely in the terminal and does not require an editor.

> **Want to know where each choice is applied?** See [Wizard Config Mapping](docs/wizard-config-mapping.en.md). It explains which values are written to `settings.json`, which are used only during setup, and which act as presets.
>
> **About the new /init mode**: Minimal, Standard, and Full enable Claude Code's new interactive `/init` mode by default. Custom asks whether you want to enable it.

### Editor Setup (Optional)

A code editor is a dedicated application for writing and editing code. Claude Code runs in the terminal and doesn't require one.

**Recommended: [VS Code](https://code.visualstudio.com/)** (free, by Microsoft)
- **macOS**: Download from [code.visualstudio.com](https://code.visualstudio.com/), then run `Cmd + Shift + P` → "Shell Command: Install 'code' command in PATH"
- **Windows**: Download and run the installer from [code.visualstudio.com](https://code.visualstudio.com/)

Other supported editors: [Cursor](https://www.cursor.com/) (AI-native), [Zed](https://zed.dev/) (fast & lightweight), [Neovim](https://neovim.io/) (advanced, terminal-based).

## Profiles

| Profile | Agents | Rules | Commands | Skills | Hooks | Plugins | Codex Plugin | Ghostty |
|---|---|---|---|---|---|---|---|---|
| Minimal | Yes | Yes | - | - | - | - | - | - |
| Standard (Recommended) | Yes | Yes | Yes | Yes | Core | 5 | Optional | - |
| Full | Yes | Yes | Yes | Yes | All | 14 | Yes | macOS only |

- **Minimal**: Lightweight start with just agents and rules
- **Standard**: Best for most teams. Includes commands, skills, and core hooks
- **Full**: Everything enabled including all hooks and Codex Plugin sub-agent delegation

### Web Content Extraction Skill

When reading a URL, official docs, a blog/news article, or an OSS page, this executable skill **extracts the main content with [Defuddle](https://github.com/kepano/defuddle) into Markdown/JSON instead of reading raw HTML** (installed in Standard / Full). The `/web-article`, `/oss-analyze`, and `/web-source-review` commands and the CLAUDE.md standard rule rely on it.

- **Requires Node.js 22.19+** (tested on 22/24). Setup attempts an automatic install or upgrade when needed and fails before deployment if the minimum cannot be met. `npm ci --omit=dev` runs automatically on deploy.
- **Security**: layered SSRF defense (http(s) only, internal/private IPs rejected, connection IP pinned, each redirect hop re-validated), a non-fetching DOM (no external sub-resource fetch, no script execution), and CJK-aware, decompression-bomb-guarded PDF extraction. Set `ALLOW_PRIVATE_URLS=true` for internal URLs in development only.
- **Opt-in dependency auto-update**: the `web-content-update` hook updates the skill's deps (defuddle/jsdom/pdfjs-dist/undici) on SessionStart (24h throttle, test gate + rollback). **Enabled by default in Full only**; opt-in in Standard. Manual update: `npm run update:deps`.

### Hooks

Hooks are automated safety checks that run automatically when Claude Code executes commands or edits files.

| Hook | Description |
|---|---|
| **Safety Net** | Helps prevent accidental destructive git/filesystem commands (`git reset --hard`, `rm -rf`, `git push --force`, etc.) before execution |
| **Auto Update** | Checks for starter kit updates on session start and applies them in the background |
| Tmux Reminder | Suggests run_in_background for foreground dev servers (non-blocking) |
| Doc Blocker | Asks for confirmation only on ad-hoc SUMMARY/REPORT style docs (general docs pass) |
| Prettier Auto-format | Formats JS/TS files after edits |
| Biome Auto-format | Formats and lints JS/TS files after edits (Full uses Biome instead of Prettier) |
| PR Creation Log | Logs PR URL after creation |
| Pre-compact Snapshot | Stashes tracked changes before context compaction (opt-in) |
| Doc Size Guard | Warns when CLAUDE.md/AGENTS.md exceeds size-hygiene targets (non-blocking; Full only) |
| Web Content Update | Auto-updates the web-content-extraction skill's deps on session start (opt-in; default in Full only) |
| Feature Recommendation | Notifies about newly available features for the selected profile |

#### Safety Net

[cc-safety-net](https://github.com/kenryu42/cc-safety-net) intercepts Bash commands via a PreToolUse hook to help prevent *accidental* destructive operations (a footgun guard, not a security boundary). It matches on command string patterns only, so it is not designed to resist deliberate bypass or prompt injection.

Blocked commands include:
- `git reset --hard` — discards uncommitted changes
- `git checkout -- <file>` — discards file changes
- `git push --force` — overwrites remote history
- `rm -rf` — irreversible file/directory deletion

STRICT mode (`CC_SAFETY_NET_STRICT=1`) is enabled by default, causing unparseable commands to be blocked (fail-closed).

> **Enabled by default in Standard / Full profiles.** Setup auto-installs `cc-safety-net` via npm when it is missing (with `--ignore-scripts`, so no lifecycle scripts run). If automatic installation fails, run `npm install -g --ignore-scripts cc-safety-net` manually.

#### Auto Update

Automatically checks for new starter kit releases on GitHub on both `SessionStart` and `SessionEnd`.

- **Every-session checks**: Checks at both session start and session end
- **Background execution**: Hooks run asynchronously, so the session is not blocked
- **Lock-based deduplication**: A running auto-update prevents duplicate concurrent runs
- **Settings preserved**: 3-way merge keeps your customizations intact
- **One-liner installs only**: Only works when the kit is installed at `~/.claude-starter-kit/`
- **SessionEnd is best-effort**: abrupt termination may skip the end-of-session check
- **Compatibility**: Verified on Claude Code `2.1.89`. When an older Claude Code is detected, the kit falls back to the legacy `SessionStart` + 24h cache hook
- **Dirty check**: If the kit repo has local changes, auto-update skips and suggests `git stash`
- **Recovery info**: If the update fails, the hook prints the backup path and restore command
- **Failure carry-over**: Background update failures are saved once and surfaced on the next hook run

> **Enabled by default in Standard / Full profiles.** Disable with `ENABLE_AUTO_UPDATE=false` in the hooks selection.

## Usage

> **Important: You must restart your terminal after setup.**
> PATH and shell settings added during setup won't take effect until you open a new terminal window. Close your current terminal and open a new one before running `claude`.

After restarting your terminal, start `claude` in your project directory. The installed slash commands and agents are immediately available:

```bash
/plan            # Structured planning
/tdd             # Test-driven development flow
/build-fix       # Fix build errors
/e2e             # End-to-end testing
/verify          # Final verification
/checkpoint      # Record current work as a checkpoint
/refactor-clean  # Find and clean up unused code
/update-docs     # Update documentation to latest state
/research        # Deep codebase investigation (RPI workflow)
/web-article     # Extract a URL with Defuddle and summarize the article
/oss-analyze     # Analyze an OSS repo/doc URL for tech + adoption decisions
/web-source-review # Evaluate a URL's credibility as an information source
/handover        # Structured session handover document
/audit-config    # Audit personal config for outdated model-babysitting instructions
/update-kit      # Manually update starter kit to latest version
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
# One-liner non-interactive install (Standard profile + all default plugins)
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash -s -- --non-interactive

# Or use NONINTERACTIVE env var (same convention as Homebrew)
NONINTERACTIVE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh)"

# Use standard profile with English and VS Code
./setup.sh --non-interactive --profile=standard --language=en --editor=vscode

# Full control over hooks and plugins (use name@marketplace for disambiguation)
./setup.sh --non-interactive \
  --profile=standard \
  --language=en \
  --editor=cursor \
  --new-init=true \
  --codex-plugin=false \
  --commit-attribution=false \
  --hooks=safety-net,auto-update,tmux,prettier,pr-log,pre-commit,agent-teams \
  --plugins=security-guidance,commit-commands,pr-review-toolkit,document-skills@anthropic-agent-skills

# Reuse a saved config
./setup.sh --non-interactive --config=./my-config.conf
```

> **Plugin naming**: When the same plugin name exists in multiple marketplaces, use `name@marketplace` format. Plugins without name conflicts can be specified by name alone, and the qualified form also works without a conflict (e.g., `document-skills@anthropic-agent-skills`). The current default plugins have no name collisions; the registered marketplaces are `claude-plugins-official` and `anthropic-agent-skills`.
>
> **Notes**:
> - `--profile` selects a preset bundle of lower-level flags rather than a single final runtime key
> - `--new-init=true` enables Claude Code's new interactive `/init` flow
> - `--commit-attribution=false` disables Claude Code attribution in both commits and PRs
> - For full mapping details, see [Wizard Config Mapping](docs/wizard-config-mapping.en.md)

> **Customizing CLAUDE.md**:
> - `~/.claude/CLAUDE.md` is split into a kit-managed section (`<!-- BEGIN STARTER-KIT-MANAGED -->` ... `<!-- END STARTER-KIT-MANAGED -->`) and a user section (`# User Settings`)
> - Add your custom instructions in the user section. Updates only touch the kit section; your content is preserved
> - If your existing CLAUDE.md has no markers, an interactive migration is offered on first update
>
> **Existing users**:
> - If you already use this starter kit, prefer `/update-kit` or `./setup.sh --update`. Conflicts are resolved interactively with `[RK]/[RU]` remember options. Use `--reset-prefs` to clear saved decisions.
> - **First-time kit users with existing `~/.claude/settings.json`**: settings.json is merged (not overwritten), and other files are confirmed per-directory.
> - `--non-interactive` is intended for CI/automation. Interactive mode is recommended for existing users.
> - A backup is automatically created at `~/.claude.backup.<timestamp>` before every update or first install with existing files.
> - `setup.sh --update` and `/update-kit` now show `Step N/M` progress so long-running phases such as settings merges no longer look stalled.
> - **Dirty check**: If the kit repo has local changes, update is blocked with a `git stash` hint (applies to auto-update, install.sh, and /update-kit).
> - **Auto-update**: SessionStart and SessionEnd hooks now check on every session boundary and run asynchronously. `~/.claude/.starter-kit-update.lock` prevents overlapping updates.
> - **Recovery**: If an update fails, backup path and restore commands are shown. The latest backup path is saved in `~/.claude/.starter-kit-last-backup`.
>
> **Dry-run (preview before deploying)**:
> - Use `/update-kit-dry-run` or `bash setup.sh --update --dry-run` to preview what an update would change. Shows files to create/modify/delete/skip, a settings.json diff, and external operations as `[WOULD RUN]`.
> - During interactive install/update, if existing settings could be affected, you'll be asked "Would you like to preview changes?" automatically. Clean-slate installs skip this prompt.
> - Dry-run output is labeled as `Preview Mode`, making it easier to distinguish from the actual update run.
> - `--non-interactive --dry-run` installs nothing and exits immediately.

## MDM Deployment (macOS)

This kit can deploy the Claude Code CLI and starter kit to managed devices running macOS 13.5 or later without end-user prompts through MDM (Jamf, Intune, Workspace ONE, Ivanti, and others). The default zero-touch workflow assumes Xcode Command Line Tools have already been delivered as an MDM package baseline. Production remediation requires root, a pinned lowercase 40-character commit SHA, and a trusted two-file bundle containing `mdm/install-mdm.sh` plus `mdm/render-expected.py` from the same release. The static renderer defines present and absent paths, required runtime components, and the desired policy. A root-owned schema-v3 receipt containing the policy SHA-256, bound UID/GeneratedUID, and the runtime component manifest path/hash is issued only after postconditions pass.

`settings.json` is fully MDM-managed, while the `CLAUDE.md` user section and unrelated user-created files are preserved. Auto-update, the web updater, regular marketplace plugins, and the Codex Plugin are always disabled under MDM; Ghostty and fonts remain explicit opt-ins. A global remediation lock, root history bound to the account UID and GeneratedUID, and a dedicated one-generation backup protect reruns. Production detection is root-only and requires both the expected commit and expected policy SHA-256. See [`docs/mdm/README.md`](docs/mdm/README.md) for the full contract and the still-unverified root end-to-end path from real MDM products. **That guide is currently Japanese-only, and the implementation currently supports only macOS 13.5 or later**.

## Directory Structure

```
claude-code-starter-kit/
├── install.sh              # One-liner bootstrap (macOS/Linux/WSL)
├── install.ps1             # Windows PowerShell bootstrap
├── setup.sh                # Main setup script (wizard + deploy)
├── uninstall.sh            # Manifest-based clean uninstall
├── lib/                    # Shared shell libraries (detect, deploy, update, merge, etc.)
├── mdm/                    # macOS MDM installer, renderer, and detector
├── wizard/                 # Interactive wizard
│   ├── wizard.sh           # Wizard entrypoint and config restore
│   ├── registry.sh         # Hook/plugin registries and CLI parsing
│   ├── steps.sh            # Display helpers and interactive steps
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
├── commands/               # Slash commands (21 files)
└── skills/                 # Skill modules (12 dirs)
```

## Customization

After installation, you can extend or modify any component:

- **Add an agent**: Create a new `.md` file in `~/.claude/agents/`
- **Add a rule**: Create a new `.md` file in `~/.claude/rules/` (for personal always-loaded preferences, `user-*.md` is recommended — the kit reserves that namespace and never ships such files, so updates can never collide with yours)
- **Add a command**: Create a new `.md` file in `~/.claude/commands/`
- **Add a skill**: Create a new directory under `~/.claude/skills/` with a `SKILL.md`
- **Modify hooks**: Edit `~/.claude/settings.json` hooks section

For new skills, start with this minimal frontmatter:

- `name`: Skill name, usually matching the directory name
- `description`: One-line summary
- `when_to_use`: Auto-discovery trigger starting with `Use when...`

Only add these when they are truly needed:

- `argument-hint`: Autocomplete hint for skills that really take arguments
- `user-invocable: false`: For background knowledge or hook-driven skills that should stay out of the `/` menu

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

## Development

Shell scripts are statically analyzed with [ShellCheck](https://www.shellcheck.net/). It runs automatically via GitHub Actions on PRs. To run locally:

```bash
shellcheck -S warning setup.sh install.sh uninstall.sh lib/*.sh wizard/*.sh \
  mdm/*.sh tests/run-*.sh tests/unit/test-mdm-*.sh
```

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for a detailed history of changes.

## Acknowledgements

- The Braille Dots status line pattern is inspired by [Nyosegawa's article](https://nyosegawa.com/posts/claude-code-statusline-rate-limits/)

## License

MIT. See [LICENSE](LICENSE).
