#!/bin/bash
# English wizard strings

# Banner
STR_BANNER="Claude Code Starter Kit"
STR_BANNER_SUB="Interactive Environment Setup"

# Step 1: Language (shown before strings are loaded)

# Step 2: Profile
STR_PROFILE_TITLE="Choose a configuration profile:"
STR_PROFILE_MINIMAL="Minimal - Agents + rules only (lightweight)"
STR_PROFILE_STANDARD="Standard - Agents + rules + commands + skills + core hooks"
STR_PROFILE_FULL="Full - Everything enabled including all hooks and Codex MCP"
STR_PROFILE_CUSTOM="Custom - Choose individual components"

# Step 3: Codex MCP
STR_CODEX_TITLE="Do you use OpenAI Codex MCP as a sub-agent?"
STR_CODEX_YES="Yes - Include Codex MCP delegation rules in CLAUDE.md"
STR_CODEX_NO="No - Skip (you can add this later)"

# Step 4: Editor
STR_EDITOR_TITLE="Which editor do you use? (for git push review hook)"
STR_EDITOR_VSCODE="VS Code"
STR_EDITOR_CURSOR="Cursor"
STR_EDITOR_ZED="Zed"
STR_EDITOR_NEOVIM="Neovim"
STR_EDITOR_NONE="None / Skip editor integration"

# Step 5: Hooks
STR_HOOKS_TITLE="Select hooks to enable (enter numbers separated by spaces):"
STR_HOOKS_TMUX="Tmux Reminder - Suggest tmux for long-running commands"
STR_HOOKS_GIT_PUSH="Git Push Review - Pause before git push for review"
STR_HOOKS_DOC_BLOCK="Doc Blocker - Block creation of random .md/.txt files"
STR_HOOKS_PRETTIER="Prettier Auto-format - Format JS/TS files after edits"
STR_HOOKS_CONSOLE="Console.log Guard - Warn about console.log statements"
STR_HOOKS_MEMORY="Memory Persistence - Save/restore session state"
STR_HOOKS_COMPACT="Strategic Compact - Suggest /compact at logical intervals"
STR_HOOKS_PR_LOG="PR Creation Log - Log PR URL after creation"

# Step 6: Plugins
STR_PLUGINS_TITLE="Select plugins to install (enter numbers separated by spaces):"
STR_PLUGINS_NOTE="Note: Plugins are installed inside a Claude Code session after setup."

# Step 7: Commit attribution
STR_COMMIT_TITLE="Commit message attribution:"
STR_COMMIT_YES="Include 'Co-Authored-By: Claude' in commits"
STR_COMMIT_NO="No attribution (clean commits)"

# Step 8: Confirm
STR_CONFIRM_TITLE="Configuration Summary"
STR_CONFIRM_LANGUAGE="Language"
STR_CONFIRM_PROFILE="Profile"
STR_CONFIRM_CODEX="Codex MCP"
STR_CONFIRM_EDITOR="Editor"
STR_CONFIRM_HOOKS="Hooks"
STR_CONFIRM_PLUGINS="Plugins"
STR_CONFIRM_COMMIT="Attribution"
STR_CONFIRM_DEPLOY="Deploy to ~/.claude?"
STR_CONFIRM_YES="Yes, deploy now"
STR_CONFIRM_EDIT="Edit settings (re-run wizard)"
STR_CONFIRM_SAVE="Save config and exit (deploy later)"
STR_CONFIRM_CANCEL="Cancel"

# General
STR_ENABLED="enabled"
STR_DISABLED="disabled"
STR_YES="Yes"
STR_NO="No"
STR_NONE="None"
STR_SELECTED="selected"
STR_CHOICE="Choice"
STR_DEFAULT="default"
STR_RECOMMENDED="Recommended"

# Deploy
STR_DEPLOY_START="Deploying Claude Code configuration..."
STR_DEPLOY_BACKUP="Backing up existing config..."
STR_DEPLOY_DONE="Deployment complete!"
STR_DEPLOY_PLUGINS_HINT="To install plugins, run 'claude' and use:"

# Post-deploy: CLI install
STR_CLI_NOT_FOUND="Claude Code CLI is not installed."
STR_CLI_INSTALL_NOW="Install it now? (requires npm)"
STR_CLI_INSTALL_YES="Yes, install now (npm install -g @anthropic-ai/claude-code)"
STR_CLI_INSTALL_NO="No, I'll install it later"
STR_CLI_INSTALLING="Installing Claude Code CLI..."
STR_CLI_INSTALLED="Claude Code CLI installed"
STR_CLI_INSTALL_LATER="To install later, run:"
STR_CLI_ALREADY="Claude Code CLI is already installed"
STR_CLI_NPM_MISSING="npm is not available. Please install Node.js first, then run:"
STR_CLI_PATH_WARN="Installation completed but 'claude' not found in PATH. Restart your terminal."

# Post-deploy: WSL hint
STR_WSL_NOTICE="You are running inside WSL."
STR_WSL_IMPORTANT="IMPORTANT: Claude Code runs inside WSL, not in PowerShell."
STR_WSL_HOW_TO="To use Claude Code:"
STR_WSL_STEP1="1. Open a terminal and type: wsl"
STR_WSL_STEP2="2. Navigate to your project: cd /path/to/your/project"
STR_WSL_STEP3="3. Run: claude"

# Errors
STR_ERR_JQ="jq is required but not installed."
STR_ERR_GIT="git is required but not installed."
STR_ERR_NODE="Node.js >= 18 is required."
