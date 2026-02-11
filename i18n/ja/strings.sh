#!/bin/bash
# 日本語ウィザード文字列

# Banner
STR_BANNER="Claude Code スターターキット"
STR_BANNER_SUB="インタラクティブ環境セットアップ"

# Step 2: Profile
STR_PROFILE_TITLE="構成プロファイルを選択してください："
STR_PROFILE_MINIMAL="Minimal - エージェント + ルールのみ（軽量）"
STR_PROFILE_STANDARD="Standard - エージェント + ルール + コマンド + スキル + 基本フック"
STR_PROFILE_FULL="Full - 全機能有効（全フック + Codex MCP + Ghostty セットアップ含む）"
STR_PROFILE_FULL_NO_GHOSTTY="Full - 全機能有効（全フック + Codex MCP）"
STR_PROFILE_CUSTOM="Custom - 個別にコンポーネントを選択"

# Step 3: Codex MCP
STR_CODEX_TITLE="OpenAI Codex MCP をサブエージェントとして使用しますか？"
STR_CODEX_YES="はい - CLAUDE.md に Codex MCP 委譲ルールを追加"
STR_CODEX_NO="いいえ - スキップ（後から追加可能）"

# Step 4: Editor
STR_EDITOR_TITLE="使用しているエディタを選択してください（git push レビューフック用）："
STR_EDITOR_VSCODE="VS Code"
STR_EDITOR_CURSOR="Cursor"
STR_EDITOR_ZED="Zed"
STR_EDITOR_NEOVIM="Neovim"
STR_EDITOR_NONE="なし / エディタ連携をスキップ"

# Step 4.5: Ghostty
STR_GHOSTTY_TITLE="Ghostty ターミナルエミュレータをセットアップしますか？"
STR_GHOSTTY_DESC="Homebrew 経由で Ghostty と HackGen NF フォントをインストールし、最適化された設定を配置します。"
STR_GHOSTTY_DESC_WINDOWS="winget 経由で Ghostty をインストールし、最適化された設定を配置します。"
STR_GHOSTTY_YES="はい - Ghostty + HackGen NF フォントをインストールして設定を配置"
STR_GHOSTTY_NO="いいえ - Ghostty セットアップをスキップ"
STR_GHOSTTY_ALREADY_INSTALLED="Ghostty はインストール済みです"
STR_GHOSTTY_FONT_ALREADY="HackGen NF フォントはインストール済みです"
STR_GHOSTTY_CONFIG_DEPLOYED="Ghostty 設定を配置しました"
STR_GHOSTTY_CONFIG_BACKED_UP="既存の Ghostty 設定をバックアップしました："
STR_GHOSTTY_SKIP_PLATFORM="このプラットフォームでは Ghostty の自動インストールに対応していません。詳細: https://ghostty.org/"
STR_CONFIRM_GHOSTTY="Ghostty"

# Step 5: Hooks
STR_HOOKS_TITLE="有効にするフックを選択してください（番号をスペース区切りで入力）："
STR_HOOKS_TMUX="Tmux リマインダー - 長時間コマンドに tmux を提案"
STR_HOOKS_GIT_PUSH="Git Push レビュー - push 前に一時停止してレビュー"
STR_HOOKS_DOC_BLOCK="ドキュメントブロッカー - 不要な .md/.txt ファイルの作成を防止"
STR_HOOKS_PRETTIER="Prettier 自動フォーマット - JS/TS ファイルを編集後にフォーマット"
STR_HOOKS_CONSOLE="Console.log ガード - console.log の警告"
STR_HOOKS_MEMORY="メモリ永続化 - セッション状態の保存/復元"
STR_HOOKS_COMPACT="戦略的コンパクト - 論理的なタイミングで /compact を提案"
STR_HOOKS_PR_LOG="PR 作成ログ - PR 作成後に URL をログ"

# Step 6: Plugins
STR_PLUGINS_TITLE="インストールするプラグインを選択してください（番号をスペース区切りで入力）："
STR_PLUGINS_NOTE="注意: プラグインはセットアップ後に Claude Code セッション内でインストールします。"

# Step 7: Commit attribution
STR_COMMIT_TITLE="コミットメッセージの帰属表示："
STR_COMMIT_YES="'Co-Authored-By: Claude' をコミットに含める"
STR_COMMIT_NO="帰属表示なし（クリーンなコミット）"

# Step 8: Confirm
STR_CONFIRM_TITLE="設定サマリー"
STR_CONFIRM_LANGUAGE="言語"
STR_CONFIRM_PROFILE="プロファイル"
STR_CONFIRM_CODEX="Codex MCP"
STR_CONFIRM_EDITOR="エディタ"
STR_CONFIRM_HOOKS="フック"
STR_CONFIRM_PLUGINS="プラグイン"
STR_CONFIRM_COMMIT="帰属表示"
STR_CONFIRM_DEPLOY="~/.claude にデプロイしますか？"
STR_CONFIRM_YES="はい、今すぐデプロイ"
STR_CONFIRM_EDIT="設定を変更（ウィザードを再実行）"
STR_CONFIRM_SAVE="設定を保存して終了（後でデプロイ）"
STR_CONFIRM_CANCEL="キャンセル"

# General
STR_ENABLED="有効"
STR_DISABLED="無効"
STR_YES="はい"
STR_NO="いいえ"
STR_NONE="なし"
STR_SELECTED="選択済み"
STR_CHOICE="選択"
STR_DEFAULT="デフォルト"
STR_RECOMMENDED="推奨"
STR_TOGGLE_HINT="番号=切替, a=全選択, n=全解除, Enter=確定"

# Saved config detection
STR_SAVED_CONFIG_FOUND="前回の設定が見つかりました。"
STR_SAVED_CONFIG_REUSE="前回の設定を使用する（確認画面へ）"
STR_SAVED_CONFIG_FRESH="最初からやり直す（すべて再設定）"

# Deploy
STR_DEPLOY_START="Claude Code 設定をデプロイ中..."
STR_DEPLOY_BACKUP="既存の設定をバックアップ中..."
STR_DEPLOY_DONE="デプロイ完了！"
STR_DEPLOY_PLUGINS_HINT="プラグインをインストールするには 'claude' を起動して以下を実行："
STR_DEPLOY_PLUGINS_INSTALLING="プラグインをインストール中..."
STR_DEPLOY_PLUGINS_INSTALLED="プラグイン："
STR_DEPLOY_PLUGINS_ALREADY="インストール済み："
STR_DEPLOY_PLUGINS_FAILED="プラグインのインストールに失敗："
STR_DEPLOY_PLUGINS_SKIP="プラグインのインストールをスキップ（Claude Code CLI が利用不可）"

# Post-deploy: CLI install
STR_CLI_NOT_FOUND="Claude Code CLI がインストールされていません。"
STR_CLI_INSTALL_NOW="今すぐインストールしますか？"
STR_CLI_INSTALL_YES="はい（ネイティブインストーラーを実行）"
STR_CLI_INSTALL_NO="いいえ（後でインストール）"
STR_CLI_INSTALLING="Claude Code CLI をインストール中..."
STR_CLI_INSTALLED="Claude Code CLI をインストールしました"
STR_CLI_INSTALL_FAILED="インストールに失敗しました。手動でインストールしてください："
STR_CLI_INSTALL_LATER="後でインストールするには以下を実行："
STR_CLI_ALREADY="Claude Code CLI はインストール済みです"
STR_CLI_PATH_WARN="インストールは完了しましたが 'claude' が PATH に見つかりません。ターミナルを再起動してください。"

# Post-deploy: WSL hint
STR_WSL_NOTICE="WSL 環境で実行しています。"
STR_WSL_IMPORTANT="重要: Claude Code は WSL 内で実行してください（PowerShell ではありません）。"
STR_WSL_HOW_TO="Claude Code の使い方："
STR_WSL_STEP1="1. ターミナルを開いて wsl と入力"
STR_WSL_STEP2="2. プロジェクトに移動: cd /path/to/your/project"
STR_WSL_STEP3="3. 実行: claude"

# Post-deploy: WSL final message
STR_FINAL_WSL_NEXT="Claude Code は WSL 内で実行します。使い方："
STR_FINAL_WSL_STEP1="1. Windows Terminal を開き、ドロップダウンから Ubuntu を選択"
STR_FINAL_WSL_STEP2="2. プロジェクトに移動: cd /path/to/your/project"
STR_FINAL_WSL_STEP3="3. 実行: claude"

# Post-deploy: Native Windows (Git Bash)
STR_FINAL_MSYS_NEXT="Claude Code を使い始めるには："
STR_FINAL_MSYS_STEP1="1. この Git Bash ウィンドウを閉じて、もう一度 Git Bash を開く"
STR_FINAL_MSYS_STEP1_HINT="   開き方: デスクトップを右クリック →「Git Bash Here」/ または Windows キー →「Git Bash」と入力"
STR_FINAL_MSYS_STEP2="2. 作業フォルダに移動: cd ~/Documents/my-project"
STR_FINAL_MSYS_STEP3="3. 実行: claude"

# Final message
STR_FINAL_TITLE="セットアップ完了！"
STR_FINAL_NEXT="Claude Code を使い始めるには："
STR_FINAL_STEP1="1. ターミナルを再起動（または新しいタブを開く）"
STR_FINAL_STEP2="2. プロジェクトディレクトリに移動"
STR_FINAL_STEP3="3. 実行: claude"
STR_FINAL_ENJOY="Happy coding!"
STR_FINAL_INCOMPLETE_TITLE="セットアップは一部完了です"
STR_FINAL_INCOMPLETE_GHOSTTY="以下のコンポーネントはインストールできませんでした（Homebrew が必要です）："
STR_FINAL_INCOMPLETE_HINT="管理者権限のあるアカウントで Homebrew をインストールしてから、再度セットアップを実行してください："
STR_FINAL_INCOMPLETE_BREW="Homebrew のインストール："
STR_FINAL_INCOMPLETE_RERUN="再セットアップ："

# Post-deploy: Ghostty final steps
STR_FINAL_GHOSTTY_NEXT="Ghostty がインストールされました。次のステップ："
STR_FINAL_GHOSTTY_STEP1="1. Launchpad または Spotlight（⌘+Space）で「Ghostty」と検索して起動"
STR_FINAL_GHOSTTY_STEP2="2. Ghostty のターミナル上でプロジェクトディレクトリに移動"
STR_FINAL_GHOSTTY_STEP3="3. 実行: claude"
STR_FINAL_GHOSTTY_FONT="HackGen NF フォントとカスタム設定が適用済みです"

# Post-deploy: Codex MCP setup
STR_CODEX_SETUP_TITLE="Codex MCP のセットアップ"
STR_CODEX_SETUP_NOTE="※ Codex MCP には ChatGPT の有料プラン（Plus 以上）と OpenAI API キーが必要です"
STR_CODEX_CLI_INSTALLING="Codex CLI をインストール中..."
STR_CODEX_CLI_INSTALLED="Codex CLI をインストールしました"
STR_CODEX_CLI_ALREADY="Codex CLI はインストール済みです"
STR_CODEX_CLI_FAILED="Codex CLI のインストールに失敗しました。後で手動でインストールしてください："
STR_CODEX_API_KEY_PROMPT="OpenAI API キーを入力する（sk-... で始まるキー）"
STR_CODEX_API_KEY_SKIP="スキップ（後で設定する）"
STR_CODEX_API_KEY_HINT="API キーは https://platform.openai.com/api-keys で取得できます"
STR_CODEX_API_KEY_SAVED="OpenAI API キーを設定しました"
STR_CODEX_API_KEY_ALREADY="OpenAI API キーは設定済みです"
STR_CODEX_API_KEY_VERIFYING="API キーを検証中..."
STR_CODEX_API_KEY_VALID="API キーの検証に成功しました"
STR_CODEX_API_KEY_INVALID="API キーの検証に失敗しました。キーが正しいか確認してください"
STR_CODEX_API_KEY_RETRY="再入力しますか？"
STR_CODEX_API_KEY_RETRY_YES="はい、再入力する"
STR_CODEX_API_KEY_RETRY_NO="いいえ、後で設定する"
STR_CODEX_API_KEY_SKIPPED="API キーの設定をスキップしました。後で以下を実行してください："
STR_CODEX_LOGIN_RUNNING="Codex CLI にログイン中..."
STR_CODEX_LOGIN_DONE="Codex CLI のログインに成功しました"
STR_CODEX_LOGIN_ALREADY="Codex CLI はログイン済みです"
STR_CODEX_LOGIN_FAILED="Codex CLI のログインに失敗しました。手動で実行してください："
STR_CODEX_MCP_REGISTERING="Codex MCP サーバーを Claude Code に登録中..."
STR_CODEX_MCP_REGISTERED="Codex MCP サーバーを登録しました"
STR_CODEX_MCP_ALREADY="Codex MCP サーバーは登録済みです"
STR_CODEX_MCP_REG_FAILED="Codex MCP サーバーの登録に失敗しました。手動で実行してください："
STR_CODEX_E2E_TESTING="Codex MCP の接続テスト中..."
STR_CODEX_E2E_SUCCESS="Codex MCP の接続テストに成功しました"
STR_CODEX_E2E_FAILED="Codex MCP の接続テストに失敗しました。API キーまたは接続に問題がある可能性があります"
STR_CODEX_E2E_RETRY="API キーを再入力してもう一度試す"
STR_CODEX_E2E_SKIP="後で手動で設定する"
STR_CODEX_E2E_SKIP_HINT="後で以下を実行して Codex MCP を設定してください："
STR_CODEX_SETUP_DONE="Codex MCP のセットアップが完了しました"

# Errors
STR_ERR_JQ="jq が必要ですがインストールされていません。"
STR_ERR_GIT="git が必要ですがインストールされていません。"
STR_ERR_NODE="Node.js >= 18 を推奨（Codex CLI に必要）。"
