# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **CLAUDE.md ユーザーセクション分離**: kit 管理セクションとユーザーセクションを HTML コメントマーカーで分離。ユーザーは `# User Settings` 以下に自由にカスタム指示を追加可能。update 時は kit セクションのみ更新され、ユーザーセクションは保持される
- **既存 CLAUDE.md のマイグレーション**: マーカーのない既存 CLAUDE.md は、対話モードで既存全体をユーザーセクションに移行し kit セクションを追加。非対話モードではスキップ

### Fixed
- **CLAUDE.md マーカー二重挿入バグを修正**: `_replace_kit_section` の sed ロジックが macOS/GNU sed の range 挙動差でマーカーを重複挿入する問題を awk ベースに書き直して修正
- **GNU sed / GNU awk を prerequisite に追加**: macOS の BSD sed/awk との互換性問題を根本解決。既に GNU 版がインストール済みなら導入をスキップ。`_sed()` / `_awk()` ラッパーで CLAUDE.md section 処理と関連箇所を統一。Linux/WSL でも gawk 等が不足時は自動導入を試行
- **settings.json の snapshot にユーザーカスタマイズが混入する問題を修正**: snapshot に merge 結果ではなく kit 生成版を保存するように変更。次回 update で「ユーザー未変更」と誤判定され permissions 等が kit デフォルトに上書きされる問題を解消
- **Codex MCP セットアップが update 時に毎回確認される問題を修正**: 既にセットアップ済み（CLI + 認証 + MCP 登録）の場合は確認をスキップ。非対話モードでも不要な対話が発生しなくなった
- **settings.json の language に表示名がセットされる問題を修正**: `"日本語"` → `"ja"` に変更。不要な conflict を解消
- **update のスキップファイル表示でサブディレクトリパスが欠落する問題を修正**
- **dry-run 時のメッセージを予告形に差し替え**: 完了形（〜しました）→ 予告形（〜されます）
- **旧 kit 生成 CLAUDE.md のマイグレーション判定改善**: 削除・編集も検出するよう完全一致判定に変更

### Changed
- **Uninstall 時の CLAUDE.md 保護**: uninstall は CLAUDE.md を完全削除せず、kit マーカーセクションのみ除去。ユーザーセクションに内容がある場合はファイルを残す
- **Snapshot 粒度**: CLAUDE.md の snapshot は kit セクションのみ保存。ユーザーセクションの編集が false conflict を起こさなくなった
- **`--dry-run` フラグ**: `setup.sh --dry-run` で install/update の影響範囲を事前プレビュー。デプロイせずにサマリ + settings.json diff を表示。軽量な前提ツール（git, jq, curl）は対話確認付きで導入可、`--non-interactive` では導入せず終了
- **`/update-kit-dry-run` コマンド**: Claude Code 内から update のドライランを直接実行
- **デプロイ前の dry-run 提案**: 既存設定とのバッティングがある場合のみ、デプロイ前に「プレビューしますか？」と確認。結果を見てから続行/中止を選択可能。クリーンインストールでは表示されない
- **外部操作の事前表示**: dry-run 時に Ghostty / fonts / plugins / Codex MCP 等の外部操作を `[WOULD RUN]` としてログ
- **初回インストール時の既存設定保護**: starter kit 未使用だが `~/.claude/settings.json` がある環境では、settings.json を上書きせずマージ。CLAUDE.md やコンテンツディレクトリはディレクトリ単位で上書き/新規のみ/スキップを選択可能
- **Non-interactive fallback**: 非対話モードでは settings.json のみ merge（kit 追加分を採用）、他のファイルは新規のみコピーし既存を保持

### Changed
- **既存ユーザーへの警告メッセージ改善**: 既存 settings.json がある場合は「マージされます」と表示（「上書きされます」ではなく）

## [0.20.4] - 2026-03-24

### Fixed
- **一時ファイルの追跡漏れを修正**: `lib/template.sh`, `lib/fonts.sh`, `lib/json-builder.sh` の `mktemp` で作成した一時ファイルが `_cleanup_tmp` トラップに登録されていなかった問題を修正。`_register_tmp()` ヘルパーを追加し全箇所で一貫して追跡
- **`_dryrun_claudemd_diff()` のマーカーなしガード**: CLAUDE.md にマーカーがない場合に `_extract_kit_section` が失敗して差分表示がスキップされる問題を修正
- **`_run_with_timeout()` の set -e 安全性**: `wait` の非0終了が `set -e` でシェルを中断し終了コードを取得できない問題を修正。watcher サブシェルの kill/wait エラーハンドリングも改善
- **`_save_openai_key()` の stat フォールバック**: パーミッション取得失敗時に警告を表示してデフォルト 600 を使用（API キー保護）
- **`write_manifest()` の kit_version 精度向上**: `git describe --tags --always` でタグなしリポジトリでもハッシュを記録。`kit_commit` フィールドを追加
- **バックアップパスの永続化**: `backup_existing()` で `_BACKUP_TIMESTAMP` をグローバル化し、`~/.claude/.starter-kit-last-backup` にパスを保存。bootstrap マイグレーション時にバックアップパスを表示
- **`build_settings_json()` の echo → printf**: JSON パイプラインで `echo` のバックスラッシュ解釈による破損を防止

## [0.18.0] - 2026-03-24

### Fixed
- **update 時にユーザーカスタマイズが上書きされる問題を修正**: `language` や `permissions` 等をユーザーが変更していた場合、update で kit デフォルトに戻されてしまう問題を修正。競合時はユーザーに確認プロンプトを表示するように変更
- **update 前にバックアップを取得**: `setup.sh --update` 実行時も `~/.claude.backup.<timestamp>` を作成し、merge 失敗時の復旧手段を確保
- **部分失敗後の再実行で設定が消える問題を修正**: スナップショット更新をスクリプト末尾に移動し、途中失敗→再実行でユーザー設定が「未変更」と誤判定される問題を解消
- **初回マイグレーションで全ファイルがスキップされる問題を修正**: `bootstrap_snapshot_from_current` 後もファイル差分を比較し、kit 更新があればユーザーに確認するように改善
- **hook scripts が update 時に無条件上書きされる問題を修正**: `~/.claude/hooks/` 配下も `_update_file()` 経由でユーザー変更を検出・確認するように変更

### Added
- **merge 判定の記憶機能**: 競合解決時に `[RK] Keep & Remember` / `[RU] Use kit's & Remember` を選ぶと、判定が `~/.claude/.starter-kit-merge-prefs.json` に保存され次回以降は自動適用
- **`--reset-prefs` フラグ**: `setup.sh --update --reset-prefs` で保存済み merge 判定をクリアし、次回 update で改めて確認

## [0.17.0] - 2026-03-24

### Changed
- **既存 install の移行を update 経路へ寄せる**: 使える snapshot を持たない古い starter-kit install でも、現在の `~/.claude` から first snapshot を起こして migration update に入るよう改善
- **manifest / snapshot の管理対象を絞り込み**: managed file tracking を starter kit が実際に配布・生成するファイルに限定し、ユーザーが独自追加したファイルまで snapshot に取り込まないよう修正

### Fixed
- **既存 `~/.claude` 再構成前の警告追加**: plain `setup.sh` が backup-and-reconfigure フローに入る前に、既存ユーザーへ明示的に warning を出すよう改善

## [0.16.0] - 2026-03-24

### Fixed
- **Update 復元の堅牢化**: manifest に `COMMIT_ATTRIBUTION` と `ENABLE_NEW_INIT` を保存し、保存済み wizard config が欠けている環境でも update 時の設定復元が崩れにくいよう修正
- **初回 upgrade の復元改善**: saved config に新キーがない古い install でも、現在の `settings.json` を fallback として読んで `COMMIT_ATTRIBUTION` と `ENABLE_NEW_INIT` を復元するよう改善
- **旧 `AGENTS.md` の後始末**: 古い release が `~/.claude` に配置していた `AGENTS.md` を update / uninstall 時に削除し、manifest 更新後も残骸が残らないよう修正

### Removed
- **`~/.claude/AGENTS.md` 配布を廃止**: このスターターキットは Claude Code 向けのため、他エージェント向けファイルを `~/.claude/` に配布する挙動を削除

## [0.15.0] - 2026-03-22

### Added
- **Anthropic Skills マーケットプレイス** ([anthropics/skills](https://github.com/anthropics/skills)) を追加。Anthropic 公式のスキルクリエイター・スキル集をプラグインとして利用可能に
  - `document-skills`: ドキュメント作成・編集スキル（DOCX, PDF, PPTX, XLSX 対応）
  - `example-skills`: クリエイティブ・技術・エンタープライズ向けスキルのサンプル集
  - いずれも Standard / Full プロファイルでデフォルト有効
- プラグイン数: 12個 → 14個（v0.8.0 で削除済みだった community 版 pr-review-toolkit の README ゴーストエントリも併せて削除）
- マーケットプレイス数: 1 → 2（`claude-plugins-official` + `anthropic-agent-skills`）

## [0.14.0] - 2026-03-20

### Changed
- **ステータスライン刷新**: Braille Dots パターン（Python）に全面切り替え。点字文字によるプログレスバーと使用率に応じた緑→赤グラデーションで ctx / 5h / 7d レートリミットを1行表示

### Acknowledgements
- ステータスライン実装は [逆瀬川さん](https://nyosegawa.com/posts/claude-code-statusline-rate-limits/) の記事 "Pattern 5: Braille Dots" を参考にしました。感謝！

## [0.13.1] - 2026-03-18

### Fixed
- **Homebrew インストール**: 対話モードで `NONINTERACTIVE=1` が無条件に設定されていたため sudo プロンプトが表示されず、Homebrew のインストールに失敗する問題を修正

## [0.13.0] - 2026-03-15

### Changed
- **厳選版 v2 リファクタリング**: 「少なく、鋭く」の原則に基づき、付加価値の低い機能を削除
- **Strategic Compact フック強化**: FIC（Frequent Intentional Compaction）早期警告を追加。ツールコール数が閾値の60%に達した時点で `/compact` を推奨
- **Doc Size Guard**: Standard+Full → **Full のみ** に変更（上級者向け機能のため）

### Removed
- `/parallel` コマンド: Claude Code の `--worktree` でネイティブ対応済み
- `/cross-review` コマンド: Codex MCP 前提で利用者限定。`/code-review` で十分
- `sdd-workflow` スキル: 外部フレームワーク依存、スキルとしては中途半端
- `orchestration-pattern` スキル: 教育的内容は README/ブログで説明すべき
- `context-management` スキル: Strategic Compact フック強化でカバー
- `agent-native-design` スキル: 一般論は README で説明すべき
- `daily-practices` ルール: `anti-patterns` ルールと重複
- `doc-freshness-guard` フック: 3日警告は多くのプロジェクトでノイズ

## [0.12.0] - 2026-03-15

### Added
- **Orchestration Pattern スキル** (`orchestration-pattern`): Command → Agent → Skill の3層設計パターンガイド。ワークフロー構築時のリファレンス
- **Prompt Patterns スキル** (`prompt-patterns`): 実践的プロンプトテクニック集（Discovery, Quality Challenge, Efficiency, Debugging, Session Management パターン）
- **Permissions Guide ルール** (`permissions-guide`): dangerously-skip-permissions を使わずにセキュリティを保つ permissions 設定のベストプラクティス
- **Daily Practices ルール** (`daily-practices`): コミット規律、コンテキスト衛生、デバッグアプローチ、Plan Before Execute のガイドライン
- `/handover` コマンドにセッション命名規約（`/rename` パターン）を追記

### Changed
- **エージェント frontmatter 強化**:
  - `planner`, `code-reviewer`, `security-reviewer` に `permissionMode: plan` を追加（レビュー重視）
  - `planner` に `Bash` ツールを追加（プロジェクト状態確認用）
  - `security-reviewer` の tools をレビュー専任に最適化（Write/Edit 除去）
  - `doc-updater` の model を `haiku` に変更（軽量化）
- **スキル frontmatter 修正**: `eval-harness`, `project-guidelines-example`, `verification-loop` に未設定だった YAML frontmatter を追加
- スキル: 14個 → 16個
- ルール: 9種 → 11種

## [0.11.0] - 2026-03-15

### Added
- **AGENTS.md 自動生成**: Claude Code 以外のエージェント（Codex CLI, Cursor, Copilot, Gemini CLI）でも使えるユニバーサルコンテキストファイルを全プロファイルで自動デプロイ
- **Doc Size Guard フック** (`doc-size-guard`): CLAUDE.md / AGENTS.md の行数超過を PostToolUse フックで自動警告・エラー化。壊れたパス参照も検出
  - AGENTS.md: 60行で警告、100行でエラー
  - CLAUDE.md: 150行で警告、300行でエラー
  - Standard / Full プロファイルでデフォルト有効
- **Doc Freshness Guard フック** (`doc-freshness-guard`): git commit 時にドキュメントの `last-validated` 日付をチェックし、古いドキュメントを警告・エラー化。superseded ADR への参照も検出
  - `DOC_FRESHNESS_WARN_DAYS`（デフォルト3日）/ `DOC_FRESHNESS_ERROR_DAYS`（デフォルト5日）で閾値カスタマイズ可能
  - macOS (BSD date) / Linux (GNU date) 両対応
  - Standard / Full プロファイルでデフォルト有効
- **Context Management スキル** (`context-management`): Context Rot 対策と FIC（Frequent Intentional Compaction）のガイダンス。フェーズ切替時の予防的 compact 推奨
- **Agent-Native Design スキル** (`agent-native-design`): AI エージェントが効率的に扱えるコード設計ガイドライン（grep-able 命名、collocated テスト、feature-based 構造等）
- **SDD Workflow スキル** (`sdd-workflow`): 仕様駆動開発（Spec-Driven Development）のワークフローガイダンス。Requirements → Design → Tasks → Implementation の4フェーズ
- **`/research` コマンド**: RPI ワークフローの Research フェーズをコマンド化。コードベースの深い調査を `research.md` に出力（Standard / Full）
- **`/parallel` コマンド**: Git Worktree を使った並列エージェント実行（Multi-Agent Division + Best-of-N 戦略）の支援（Full のみ）
- **`/handover` コマンド**: セッション引き継ぎ用の構造化ドキュメント `HANDOVER.md` を生成。Context Rot 対策（Standard / Full）
- **`/cross-review` コマンド**: Claude と Codex MCP のクロスモデルレビュー。Codex 未設定時はマルチパス自己レビューにフォールバック（Full のみ）
- **Anti-patterns ルール** (`anti-patterns.md`): エージェントの典型的失敗モード防止（幻覚ガード、スコープ逸脱防止、ループ検出、完了整合性チェック等）。全プロファイルで有効

### Changed
- スラッシュコマンド: 14個 → 18個
- フック: 11個 → 13個
- スキル: 11個 → 14個
- ルール: 8種 → 9種
- README（日本語・英語）を新機能数に合わせて更新

## [0.10.0] - 2026-03-11

### Added
- **Safety Net フック** (`safety-net`): [cc-safety-net](https://github.com/kenryu42/claude-code-safety-net) による破壊的コマンドの実行前ブロック
  - `git reset --hard`, `git checkout -- <file>`, `git push --force`, `rm -rf` 等の危険なコマンドを PreToolUse フックで自動検出・ブロック
  - `SAFETY_NET_STRICT=1` を env に設定し、パース不能コマンドも fail-closed（ブロック）にする
  - PreToolUse 配列の先頭に配置し、他のフックより先に実行
  - Standard / Full プロファイルでデフォルト有効
  - 前提条件: `npm install -g cc-safety-net` が別途必要
- **自動アップデート機能** (`auto-update`): SessionStart フックで GitHub の最新バージョンを自動チェック・適用
  - 24時間キャッシュで起動遅延を最小化（キャッシュ内は < 1ms で通過）
  - 新バージョン検出時はバックグラウンドで `git pull` + `setup.sh --update` を実行
  - 3-way merge によりユーザー設定を保持したまま更新
  - ワンライナーインストール（`~/.claude-starter-kit/`）の場合のみ動作
  - Standard / Full プロファイルでデフォルト有効（`ENABLE_AUTO_UPDATE=false` でオプトアウト可能）

## [0.9.0] - 2026-03-10

### Added
- **Update メカニズム**: `install.sh` 再実行時にユーザー設定を保持しつつ kit を更新する仕組み
  - Snapshot 比較方式: デプロイ時のファイルを `~/.claude/.starter-kit-snapshot/` に保存し、次回 update 時に3者比較（snapshot / current / new_kit）
  - `settings.json` の jq ベース3者マージ: 配列（permissions, hooks）はユーザー追加分を保持しつつ kit 新規エントリを追加。スカラー競合は対話的に解決
  - ファイル（agents, rules, skills 等）: ユーザー変更を検出し `[A]ppend / [S]kip / [D]iff` の対話 UI で選択
  - `--non-interactive` 時はユーザー変更ありのファイルをスキップ（安全側）
  - manifest v2 形式: `version`, `kit_version`, `snapshot_dir` フィールドを追加
  - `install.sh` が manifest v2 + snapshot を検出すると自動的に update モード（`setup.sh --update`）に切り替え
  - manifest v1 からの初回実行はフル再セットアップ + snapshot 作成（次回から update 対応）
- 新規ライブラリ: `lib/snapshot.sh`, `lib/merge.sh`, `lib/update.sh`
- i18n: `STR_UPDATE_*` 文字列（英語・日本語）

## [0.8.1] - 2026-03-10

### Fixed
- **permissions 構造バグ**: `deny` と `allowedTools` が `permissions` オブジェクトの外にトップレベルで出力されていた問題を修正（[公式スキーマ](https://json.schemastore.org/claude-code-settings.json) 準拠）
  - `deny` → `permissions.deny` にネスト
  - `allowedTools` → `permissions.allow` にリネーム＋ネスト
  - `settings-base.json` から空の `permissions: {}` を削除（マージ時の上書き防止）
  - Thanks to [@enpipi](https://github.com/enpipi) for reporting!
- **statusline ToS 準拠**: ステータスラインを Anthropic ToS 準拠版に差し替え

## [0.8.0] - 2026-03-07

### Changed
- **ステータスライン刷新**: 簡易スクリプトからリッチ版に置き換え
  - 3行表示: モデル名・コンテキスト%・diff統計・git branch・トークン数・バージョン情報・5h/7dレートリミットバー
  - Haiku probe によるレートリミット取得（360秒キャッシュ）
  - npm registry から最新バージョン取得（1時間キャッシュ）、current/latest 表示・差分時は黄色ハイライト
  - タイムゾーン自動検出（ハードコード `Asia/Tokyo` を廃止）
  - `stat` コマンドの macOS/Linux 両対応フォールバック

### Fixed
- **プラグイン marketplace 登録バグ**: `_compute_selected_plugins()` が非公式 marketplace のプラグインに `@marketplace` 修飾子を付けず、marketplace が登録されない問題を修正
- **pr-review-toolkit 重複**: `claude-plugins-official` と `claude-code-plugins` の両方に登録されていた重複エントリを解消（official 版に統一）

### Removed
- `claude-code-statusline` プラグイン（marketplace 構造に非準拠でインストール不可能だった。機能は features/statusline に統合）
- `claude-code-plugins` marketplace 定義（使用プラグインなし）

## [0.7.0] - 2026-03-06

### Added
- **セキュリティハードニング**: プロンプトインジェクション対策を permissions.json に組み込み
  - deny リストを 57 項目に大幅拡充（ネットワーク exfil、破壊的 git、クレデンシャルアクセス、RC 改ざん）
  - `python3 *` / `node *` / `curl *` / `wget *` / `cat *` を allowedTools から除外（都度確認に変更）
  - git サブコマンドを個別指定（`git:*` → `git status`, `git diff *` 等）
  - `disableBypassPermissionsMode: "disable"` で `--dangerously-skip-permissions` を無効化
  - `enableAllProjectMcpServers: false` でプロジェクト内 MCP サーバーの自動承認を無効化（CVE-2025-59536 対策）
- `rules/security.md` にプロンプトインジェクション防御ルール・疑わしいパターン検知ガイドを追加
- `CLAUDE.md` に Security Hardening セクション（設計判断・既知の限界）を追加
- claude-code-statusline プラグインを全プロファイルに追加
- `.gitignore` に `.env` セキュリティパターンを強化

## [0.6.0] - 2026-02-24

### Added
- **コンパクト前自動コミット機能** (`pre-compact-commit`): コンテキスト圧縮直前に `git add -A && git commit` を自動実行し、作業中の変更消失を防止
- `CLAUDE.md` にマージ改善・feature 追加手順の詳細を反映

## [0.5.0] - 2026-02-23

### Added
- **ステータスライン表示機能** (`statusline`): Claude Code のステータスバーにカスタム情報を表示

### Fixed
- 別ユーザー所有の Homebrew を検出して再インストールする処理を修正
- `uninstall.sh` の未使用 `STR_NO_MANIFEST` 変数を削除

## [0.4.0] - 2026-02-17

### Added
- **マルチマーケットプレイスプラグインサポート**: 同名プラグインが複数のマーケットプレイスに存在する場合、`name@marketplace` 形式で区別
- **非対話ワンライナーインストール**: `--non-interactive` フラグまたは `NONINTERACTIVE=1` 環境変数でウィザードをスキップ
- `CLAUDE.md` にワンライナー・Bash 3 互換・プラグイン追加手順を反映

### Fixed
- ワンライナー実行時の `_setup_args` 未束縛変数エラーを修正 (0.4.1, 2026-02-18)

## [0.3.0] - 2026-02-14

### Security
- **包括的セキュリティレビュー修正**:
  - API キーを `curl --config -` (stdin) 経由で渡すように変更（`ps` 出力への露出防止）
  - 設定ファイルの `source` を廃止し、`_safe_source_config()` による allowlist ベースのパーサーに変更
  - `umask 077` + temp ファイルの自動クリーンアップ (`trap`)
  - `_sanitize_config_value()` で設定値のメタ文字を除去
  - RC ファイル変更時のパーミッション保持 (`stat` + `chmod`)

## [0.2.0] - 2026-02-12

### Added
- **クロスプラットフォームフォントインストール** (`lib/fonts.sh`): IBM Plex Mono と HackGen NF を macOS / Windows に自動インストール
- **Windows Terminal フォント自動設定**: HackGen35 Console NF をデフォルトフォントに設定（バックアップ付き）
- **ShellCheck CI**: GitHub Actions で PR 時に自動実行
- **install.sh 安全ガード**: `_safe_install_dir()` で危険なパスへの `rm -rf` を防止
- Claude CLI の自動インストール機能
- WSL での Windows PATH 汚染による Claude CLI 誤検出を防止

### Fixed
- macOS で Xcode CLT 未インストール時に自動インストールして続行
- macOS で Homebrew 未インストール時に自動インストール
- macOS フォントインストールに直接ダウンロードのフォールバック追加
- Windows フォントインストールのハング防止
- Windows Terminal フォント設定が再実行時にスキップされる問題を修正

### Changed
- 未使用関数 6 個を削除（リファクタリング）

### Documentation
- README に Max 20x プラン推奨、`/init` による作業再開、`--resume` による前回セッション復元の How To を追加
- エディタの説明とインストール手順を README に追加
- `CLAUDE.md` にテンプレートエンジン・プラグインシステム・デプロイターゲットを追記

## [0.2.1] - 2026-02-13

### Fixed
- Ghostty インストール後の Gatekeeper 検疫ブロックを `xattr -d` で防止
- HackGen NF フォントインストール時の Homebrew PATH 解決漏れを修正
- Standard プロファイルで Ghostty セットアップを有効化
- Ghostty 誤検出を修正（`-d` → `-x` でバイナリ存在チェック）
- brew cask レジストリ残存時に Ghostty が実際にインストールされない問題を修正
- brew `node@20` の keg-only PATH 未解決でエラー表示される問題を修正

## [0.1.0] - 2026-02-11

### Added
- **初回リリース**: Claude Code Starter Kit
- **対話型ウィザード** (`wizard/wizard.sh`): 言語・プロファイル・エディタ・フック・プラグインを対話形式で選択
- **3 プロファイル**: Minimal / Standard / Full
- **9 エージェント**: planner, architect, tdd-guide, code-reviewer, security-reviewer, build-error-resolver, e2e-runner, refactor-cleaner, doc-updater
- **8 ルール**: coding-style, git-workflow, hooks, patterns, performance, security, testing, agents
- **14 スラッシュコマンド**: /plan, /tdd, /build-fix, /code-review, /e2e, /verify, /checkpoint 等
- **9 フック**: tmux リマインダー, git push レビュー, doc ブロッカー, prettier, console.log ガード, メモリ永続化, strategic compact, PR 作成ログ
- **プラグイン自動インストール**: `claude plugin install` による一括導入
- **Ghostty ターミナルセットアップ** (macOS): Homebrew cask インストール + HackGen NF フォント + Catppuccin Mocha テーマ
- **Codex MCP セットアップ**: OpenAI API キー検証 → codex login → MCP サーバー登録 → E2E 接続テスト
- **i18n**: 日本語 / English 完全対応
- **Windows サポート**: WSL2 + Windows Terminal（`install.ps1`）および Git Bash（`--git-bash`）
- **マニフェストベースのアンインストール**: デプロイしたファイルのみを安全に削除
- **Claude CLI 自動インストール**: ネイティブインストーラー経由で `~/.local/bin/claude` に導入
- **テンプレートエンジン** (`lib/template.sh`): `{{VAR}}` / `{{FEATURE:name}}` プレースホルダー置換
- **JSON ビルダー** (`lib/json-builder.sh`): settings-base.json + permissions.json + hook fragments の再帰的ディープマージ
- **OS 検出** (`lib/detect.sh`): macOS / Linux / WSL / MSYS の自動判別
- フック・プラグイン選択での全選択/全解除ショートカット (`a`/`n`)
- nvm フォールバック（Homebrew なしの Node.js インストール）
- `CLAUDE.md` をプロジェクトルートに追加

### Documentation
- README を日本語メインに書き換え、初心者向けに大幅改善
- 料金プラン・認証方法・デプロイ環境ガイド・Codex MCP 後付け手順を追記
- スクリーンショットの送り方・エディタのインストール手順を追記
