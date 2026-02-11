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
STR_PROFILE_FULL_NO_GHOSTTY="Full - Everything enabled including all hooks and Codex MCP"
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
STR_GHOSTTY_DESC_WINDOWS="Installs Ghostty via winget and deploys an optimized config."
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
STR_DEPLOY_PLUGINS_INSTALLED="Plugin:"
STR_DEPLOY_PLUGINS_ALREADY="Already installed:"
STR_DEPLOY_PLUGINS_FAILED="Failed to install plugin:"
STR_DEPLOY_PLUGINS_SKIP="Skipping plugin install (Claude Code CLI not available)"

# Post-deploy: CLI install
STR_CLI_NOT_FOUND="Claude Code CLI is not installed."
STR_CLI_INSTALL_NOW="Install it now?"
STR_CLI_INSTALL_YES="Yes, install now (native installer)"
STR_CLI_INSTALL_NO="No, I'll install it later"
STR_CLI_INSTALLING="Installing Claude Code CLI..."
STR_CLI_INSTALLED="Claude Code CLI installed"
STR_CLI_INSTALL_FAILED="Installation failed. Install manually:"
STR_CLI_INSTALL_LATER="To install later, run:"
STR_CLI_ALREADY="Claude Code CLI is already installed"
STR_CLI_PATH_WARN="Installation completed but 'claude' not found in PATH. Restart your terminal."

# Post-deploy: WSL hint
STR_WSL_NOTICE="You are running inside WSL."
STR_WSL_IMPORTANT="IMPORTANT: Claude Code runs inside WSL, not in PowerShell."
STR_WSL_HOW_TO="To use Claude Code:"
STR_WSL_STEP1="1. Open a terminal and type: wsl"
STR_WSL_STEP2="2. Navigate to your project: cd /path/to/your/project"
STR_WSL_STEP3="3. Run: claude"

# Post-deploy: WSL final message
STR_FINAL_WSL_NEXT="Claude Code runs inside WSL. To use it:"
STR_FINAL_WSL_STEP1="1. Open a terminal and type: wsl"
STR_FINAL_WSL_STEP2="2. Navigate to your project: cd /path/to/your/project"
STR_FINAL_WSL_STEP3="3. Run: claude"

# Post-deploy: Native Windows (Git Bash)
STR_FINAL_MSYS_NEXT="To start using Claude Code:"
STR_FINAL_MSYS_STEP1="1. Close this Git Bash window and reopen Git Bash"
STR_FINAL_MSYS_STEP1_HINT="   How to open: Right-click desktop > 'Git Bash Here' / or press Windows key > type 'Git Bash'"
STR_FINAL_MSYS_STEP2="2. Navigate to your project: cd ~/Documents/my-project"
STR_FINAL_MSYS_STEP3="3. Run: claude"

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

# Post-deploy: Ghostty final steps
STR_FINAL_GHOSTTY_NEXT="Ghostty has been installed. Next steps:"
STR_FINAL_GHOSTTY_STEP1="1. Search for \"Ghostty\" in Launchpad or Spotlight (Cmd+Space) to launch it"
STR_FINAL_GHOSTTY_STEP2="2. In the Ghostty terminal, navigate to your project directory"
STR_FINAL_GHOSTTY_STEP3="3. Run: claude"
STR_FINAL_GHOSTTY_FONT="HackGen NF font and custom config are already applied"

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
STR_CODEX_API_KEY_ALREADY="OpenAI API key is already configured"
STR_CODEX_API_KEY_VERIFYING="Verifying API key..."
STR_CODEX_API_KEY_VALID="API key verification successful"
STR_CODEX_API_KEY_INVALID="API key verification failed. Please check your key"
STR_CODEX_API_KEY_RETRY="Would you like to re-enter?"
STR_CODEX_API_KEY_RETRY_YES="Yes, re-enter"
STR_CODEX_API_KEY_RETRY_NO="No, configure later"
STR_CODEX_API_KEY_SKIPPED="API key setup skipped. To configure later, run:"
STR_CODEX_LOGIN_RUNNING="Logging in to Codex CLI..."
STR_CODEX_LOGIN_DONE="Codex CLI login successful"
STR_CODEX_LOGIN_ALREADY="Codex CLI is already logged in"
STR_CODEX_LOGIN_FAILED="Codex CLI login failed. Run manually:"
STR_CODEX_MCP_REGISTERING="Registering Codex MCP server with Claude Code..."
STR_CODEX_MCP_REGISTERED="Codex MCP server registered"
STR_CODEX_MCP_ALREADY="Codex MCP server is already registered"
STR_CODEX_MCP_REG_FAILED="Failed to register Codex MCP server. Run manually:"
STR_CODEX_E2E_TESTING="Testing Codex MCP connection..."
STR_CODEX_E2E_SUCCESS="Codex MCP connection test passed"
STR_CODEX_E2E_FAILED="Codex MCP connection test failed. There may be an issue with your API key or connection"
STR_CODEX_E2E_RETRY="Re-enter API key and try again"
STR_CODEX_E2E_SKIP="Configure manually later"
STR_CODEX_E2E_SKIP_HINT="To set up Codex MCP later, run the following:"
STR_CODEX_SETUP_DONE="Codex MCP setup complete"

# Errors
STR_ERR_JQ="jq is required but not installed."
STR_ERR_GIT="git is required but not installed."
STR_ERR_NODE="Node.js >= 18 is recommended (needed for Codex CLI)."
