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
STR_PROFILE_FULL="Full - Everything enabled including all hooks, Codex MCP, and Ghostty setup"
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

# Step 4.5: Ghostty
STR_GHOSTTY_TITLE="Set up Ghostty terminal emulator?"
STR_GHOSTTY_DESC="Installs Ghostty and HackGen NF font via Homebrew, then deploys an optimized config."
STR_GHOSTTY_YES="Yes - Install Ghostty + HackGen NF font and deploy config"
STR_GHOSTTY_NO="No - Skip Ghostty setup"
STR_GHOSTTY_ALREADY_INSTALLED="Ghostty is already installed"
STR_GHOSTTY_FONT_ALREADY="HackGen NF font is already installed"
STR_GHOSTTY_CONFIG_DEPLOYED="Ghostty config deployed"
STR_GHOSTTY_CONFIG_BACKED_UP="Backed up existing Ghostty config to"
STR_GHOSTTY_SKIP_PLATFORM="Ghostty auto-install not supported on this platform. See: https://ghostty.org/"
STR_CONFIRM_GHOSTTY="Ghostty"

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
STR_TOGGLE_HINT="Numbers=toggle, a=all, n=none, Enter=confirm"

# Saved config detection
STR_SAVED_CONFIG_FOUND="Previous configuration found."
STR_SAVED_CONFIG_REUSE="Use previous settings (go to confirmation)"
STR_SAVED_CONFIG_FRESH="Start fresh (reconfigure everything)"

# Deploy
STR_DEPLOY_START="Deploying Claude Code configuration..."
STR_DEPLOY_BACKUP="Backing up existing config..."
STR_DEPLOY_DONE="Deployment complete!"
STR_DEPLOY_PLUGINS_HINT="To install plugins, run 'claude' and use:"
STR_DEPLOY_PLUGINS_INSTALLING="Installing plugins..."
STR_DEPLOY_PLUGINS_INSTALLED="Installed plugin:"
STR_DEPLOY_PLUGINS_FAILED="Failed to install plugin:"
STR_DEPLOY_PLUGINS_SKIP="Skipping plugin install (Claude Code CLI not available)"

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

# Final message
STR_FINAL_TITLE="All done!"
STR_FINAL_NEXT="To start using Claude Code:"
STR_FINAL_STEP1="1. Restart your terminal (or open a new tab)"
STR_FINAL_STEP2="2. Navigate to your project directory"
STR_FINAL_STEP3="3. Run: claude"
STR_FINAL_ENJOY="Happy coding!"
STR_FINAL_INCOMPLETE_TITLE="Setup partially complete"
STR_FINAL_INCOMPLETE_GHOSTTY="The following components could not be installed (Homebrew is required):"
STR_FINAL_INCOMPLETE_HINT="Install Homebrew with an admin account, then re-run setup:"
STR_FINAL_INCOMPLETE_BREW="Install Homebrew:"
STR_FINAL_INCOMPLETE_RERUN="Re-run setup:"

# Post-deploy: Ghostty hint
STR_GHOSTTY_HINT_TITLE="Using Ghostty Terminal"
STR_GHOSTTY_HINT_OPEN="To launch Ghostty:"
STR_GHOSTTY_HINT_STEP1="1. Search for \"Ghostty\" in Launchpad or Spotlight (Cmd+Space)"
STR_GHOSTTY_HINT_STEP2="2. You can use Ghostty as your main terminal from now on"
STR_GHOSTTY_HINT_FONT="HackGen NF font is configured (programming Nerd Font)"

# Post-deploy: Codex MCP setup
STR_CODEX_SETUP_TITLE="Codex MCP Setup"
STR_CODEX_SETUP_NOTE="Note: Codex MCP requires a paid ChatGPT plan (Plus or higher) and an OpenAI API key"
STR_CODEX_CLI_INSTALLING="Installing Codex CLI..."
STR_CODEX_CLI_INSTALLED="Codex CLI installed"
STR_CODEX_CLI_ALREADY="Codex CLI is already installed"
STR_CODEX_CLI_FAILED="Failed to install Codex CLI. Install it manually later:"
STR_CODEX_API_KEY_PROMPT="Enter your OpenAI API key (starts with sk-...):"
STR_CODEX_API_KEY_SKIP="Skip (configure later)"
STR_CODEX_API_KEY_HINT="Get your API key at https://platform.openai.com/api-keys"
STR_CODEX_API_KEY_SAVED="OpenAI API key configured"
STR_CODEX_API_KEY_SKIPPED="API key setup skipped. To configure later, run:"
STR_CODEX_SETUP_DONE="Codex MCP setup complete"

# Errors
STR_ERR_JQ="jq is required but not installed."
STR_ERR_GIT="git is required but not installed."
STR_ERR_NODE="Node.js >= 18 is required."
