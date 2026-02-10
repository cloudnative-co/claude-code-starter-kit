# Claude Code Starter Kit

[English README](README.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: macOS/Linux/WSL](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20WSL-blue.svg)](#インストール)

Claude Code の開発環境を、対話型ウィザードでワンコマンドセットアップできるスターターキットです。

## 目次

- [このリポジトリについて](#このリポジトリについて)
- [主な機能](#主な機能)
- [インストール](#インストール)
- [ウィザードの流れ](#ウィザードの流れ)
- [プロファイル](#プロファイル)
- [使い方](#使い方)
- [非対話モード](#非対話モード)
- [ディレクトリ構成](#ディレクトリ構成)
- [カスタマイズ](#カスタマイズ)
- [アンインストール](#アンインストール)
- [ライセンス](#ライセンス)

## このリポジトリについて

Claude Code Starter Kit は、チームで統一された高品質な Claude Code 環境を数分で構築するためのテンプレートです。エージェント、ルール、コマンド、スキル、フック、プラグイン推奨を一式同梱しており、共通のコーディング基準ですぐに開発を始められます。

## 主な機能

- **3つのプロファイル**: Minimal、Standard（推奨）、Full
- **9種のエージェント**: planner, architect, tdd-guide, code-reviewer, security-reviewer, build-error-resolver, e2e-runner, refactor-cleaner, doc-updater
- **8種のルール**: coding-style, git-workflow, hooks, patterns, performance, security, testing, agents
- **14個のスラッシュコマンド**: /plan, /tdd, /build-fix, /code-review, /e2e, /verify 等
- **11個のスキルモジュール**: backend-patterns, frontend-patterns, security-review, tdd-workflow 等
- **8個の任意フック**: tmux リマインダー、git push レビュー、doc ブロッカー、prettier、console.log ガード、メモリ永続化、strategic compact、PR 作成ログ
- **10個のプラグイン推奨**
- **多言語対応**: 英語・日本語
- **Codex MCP** サブエージェント統合（任意）
- **非対話モード**: CI/自動化対応

## インストール

### ワンライナー（macOS / Linux / WSL）

```bash
curl -fsSL https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.sh | bash
```

### Windows PowerShell（管理者権限）

```powershell
irm https://raw.githubusercontent.com/cloudnative-co/claude-code-starter-kit/main/install.ps1 | iex
```

### 手動インストール

```bash
git clone https://github.com/cloudnative-co/claude-code-starter-kit.git
cd claude-code-starter-kit
./setup.sh
```

## ウィザードの流れ

```
言語選択 → プロファイル → Codex MCP → エディタ → フック → プラグイン → コミット帰属 → 確認・デプロイ
```

各ステップで番号付きの選択肢が表示されます。推奨値にはマークが付きます。

## プロファイル

| プロファイル | Agents | Rules | Commands | Skills | Hooks | Memory | Codex MCP |
|------------|--------|-------|----------|--------|-------|--------|-----------|
| Minimal | Yes | Yes | - | - | - | - | - |
| Standard（推奨） | Yes | Yes | Yes | Yes | 主要 | Yes | - |
| Full | Yes | Yes | Yes | Yes | 全部 | Yes | Yes |

- **Minimal**: 軽量スタート。エージェントとルールのみ
- **Standard**: ほとんどのチームに最適。コマンド、スキル、主要フック、メモリを含む
- **Full**: 全機能有効。全フックと Codex MCP サブエージェント委譲を含む

## 使い方

セットアップ後、プロジェクトディレクトリで `claude` を起動すると、スラッシュコマンドとエージェントがすぐに使えます：

```bash
/plan          # 構造化された計画立案
/tdd           # テスト駆動開発フロー
/code-review   # コードレビューモード
/build-fix     # ビルドエラー修正
/e2e           # E2E テスト
/verify        # 最終検証
```

## 非対話モード

CI、自動化、スクリプトからのセットアップに対応：

```bash
# Standard プロファイルで日本語・VS Code
./setup.sh --non-interactive --profile=standard --language=ja --editor=vscode

# フックとプラグインを細かく指定
./setup.sh --non-interactive \
  --profile=standard \
  --language=ja \
  --editor=cursor \
  --codex-mcp=false \
  --commit-attribution=false \
  --hooks=tmux,git-push,prettier,console,memory,compact,pr-log \
  --plugins=security-guidance,commit-commands,pr-review-toolkit

# 保存済み設定ファイルを再利用
./setup.sh --non-interactive --config=./my-config.conf
```

## ディレクトリ構成

```
claude-code-starter-kit/
├── install.sh              # ワンライナーブートストラップ
├── install.ps1             # Windows PowerShell ブートストラップ
├── setup.sh                # メインセットアップ（ウィザード + デプロイ）
├── uninstall.sh            # マニフェストベースのクリーンアンインストール
├── lib/                    # シェルライブラリ
│   ├── colors.sh           # ターミナルカラーヘルパー
│   ├── detect.sh           # OS/WSL 検出
│   ├── prerequisites.sh    # 依存関係チェック
│   ├── template.sh         # テキストテンプレートエンジン
│   └── json-builder.sh     # JSON ビルダー（jq ベース）
├── wizard/                 # 対話型ウィザード
│   ├── wizard.sh           # 8ステップのウィザードロジック
│   └── defaults.conf       # デフォルト値
├── config/                 # 設定テンプレート
│   ├── settings-base.json  # settings.json のベース構造
│   ├── permissions.json    # ツール権限設定
│   └── plugins.json        # プラグインカタログ
├── profiles/               # プロファイルプリセット
│   ├── minimal.conf
│   ├── standard.conf
│   └── full.conf
├── features/               # オプション機能モジュール
│   ├── */feature.json      # 機能メタデータ
│   └── */hooks.json        # フックフラグメント
├── i18n/                   # 多言語対応
│   ├── en/                 # 英語テンプレート・文字列
│   └── ja/                 # 日本語テンプレート・文字列
├── agents/                 # エージェント定義（9ファイル）
├── rules/                  # ルールファイル（8ファイル）
├── commands/               # スラッシュコマンド（14ファイル）
├── skills/                 # スキルモジュール（11ディレクトリ）
└── memory/                 # ベストプラクティスメモリ（5ファイル）
```

## カスタマイズ

インストール後、各コンポーネントを自由に拡張・変更できます：

- **エージェント追加**: `~/.claude/agents/` に `.md` ファイルを作成
- **ルール追加**: `~/.claude/rules/` に `.md` ファイルを作成
- **コマンド追加**: `~/.claude/commands/` に `.md` ファイルを作成
- **スキル追加**: `~/.claude/skills/` に `SKILL.md` を含むディレクトリを作成
- **フック変更**: `~/.claude/settings.json` の hooks セクションを編集

リポジトリを更新した後に設定を再適用するには、`./setup.sh` を再実行してください。前回の選択は `~/.claude-starter-kit.conf` に保存されています。

## アンインストール

```bash
./uninstall.sh
```

スターターキットがデプロイしたファイル（`~/.claude/.starter-kit-manifest.json` で追跡）のみが削除されます。ユーザーが手動で追加したファイルは保護されます。

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
