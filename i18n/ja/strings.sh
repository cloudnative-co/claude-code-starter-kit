#!/bin/bash
# 日本語ウィザード文字列

# Banner
STR_BANNER="Claude Code スターターキット"
STR_BANNER_SUB="インタラクティブ環境セットアップ"

# Step 2: Profile
STR_PROFILE_TITLE="構成プロファイルを選択してください："
STR_PROFILE_MINIMAL="Minimal - エージェント + ルールのみ（軽量）"
STR_PROFILE_STANDARD="Standard - エージェント + ルール + コマンド + スキル + 基本フック"
STR_PROFILE_FULL="Full - 全機能有効（全フック + Codex MCP 含む）"
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

# Deploy
STR_DEPLOY_START="Claude Code 設定をデプロイ中..."
STR_DEPLOY_BACKUP="既存の設定をバックアップ中..."
STR_DEPLOY_DONE="デプロイ完了！"
STR_DEPLOY_PLUGINS_HINT="プラグインをインストールするには 'claude' を起動して以下を実行："

# Errors
STR_ERR_JQ="jq が必要ですがインストールされていません。"
STR_ERR_GIT="git が必要ですがインストールされていません。"
STR_ERR_NODE="Node.js >= 18 が必要です。"
