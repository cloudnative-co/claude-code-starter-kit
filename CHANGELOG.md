# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.43.1] - 2026-04-03

### Fixed
- **legacy 24h キャッシュが auto-update の hook スクリプト差し替えを阻害する問題を修正**: `setup.sh --update` 実行時に旧版 auto-update.sh が使用する `~/.claude/.starter-kit-update-cache` を削除するよう変更。v0.43.0 の `kit_owned` 修正が実際に適用されるために必要な前提条件

## [0.43.0] - 2026-04-03

### Changed
- **bootstrapped snapshot 環境での hook スクリプト更新動作を変更**: `_update_file()` に `kit_owned` フラグを追加。bootstrapped snapshot（初回 update 等ベースラインが存在しない状態）で `setup.sh --update` を実行した際、hook スクリプト（auto-update, statusline 等）の kit 管理ファイルが interactive/non-interactive を問わず最新版に差し替わるよう変更。これにより auto-update hook が自身を更新できない問題を解消

## [0.42.0] - 2026-04-03

### Added
- **No Flicker モード**: Claude Code の実験的フリッカー防止レンダラー (`CLAUDE_CODE_NO_FLICKER=1`) を feature toggle として追加。full プロファイルで有効、minimal/standard では無効

## [0.41.0] - 2026-04-01

### Changed
- **PR creation hook を限定実行へ最適化**: `pr-creation-log` に hook-level `if` と `async` を導入し、`gh pr create` 以外の Bash 実行では hook を起動しないよう変更
- **PR creation hook の shell を簡素化**: shell 内の `gh pr create` 再判定を削除し、PR URL 抽出だけに責務を絞って後処理を軽量化
- **旧版 Claude Code へ安全にフォールバック**: `2.1.89` 未満では `pr-creation-log` を legacy hook 形状で生成し、`if` / `async` 非対応環境でも従来挙動を維持

## [0.40.0] - 2026-04-01

### Changed
- **skill frontmatter を限定強化**: 同梱 skill すべてに `when_to_use` を追加し、Claude Code が起動条件を判断しやすい形に整理
- **背景 skill を slash menu から除外**: `continuous-learning` に `user-invocable: false` を追加し、hook 連携前提の skill を前面に出さないよう調整
- **skill 作成ガイドを明文化**: README と architecture 文書に、starter-kit が推奨する最小 frontmatter セット (`name` / `description` / `when_to_use`) と `argument-hint` / `user-invocable` の使い分けを追記

## [0.39.0] - 2026-04-01

### Changed
- **auto-update を session 境界の async 実行へ移行**: `SessionStart` に加えて `SessionEnd` でも毎回更新確認を行い、hook-level `async: true` で非同期実行するよう変更
- **24時間キャッシュを廃止**: Claude Code `2.1.89+` では 24h TTL をやめ、`~/.claude/.starter-kit-update.lock/` による重複実行防止へ移行
- **更新確認の頻度を変更**: Claude Code `2.1.89+` では 24h に 1 回ではなく、session 境界ごとに `git fetch --tags --quiet` を試みるよう変更
- **auto-update の健全性チェックを拡張**: update 完了後の health check が `SessionStart` と `SessionEnd` の両 hook 登録を確認するよう変更
- **旧版 Claude Code へ安全にフォールバック**: `2.1.89` 未満を検出した場合は `SessionStart` のみの旧 auto-update hook を生成するよう変更
- **非同期失敗を次回へ持ち越し**: バックグラウンド更新失敗を `~/.claude/.starter-kit-update-status` に保存し、次回 hook 実行時に 1 回だけ警告するよう変更

### Compatibility
- Claude Code `2.1.89` で確認
- auto-update は引き続き one-liner install (`~/.claude-starter-kit/.git` が存在する環境) のみで有効
- 旧版 Claude Code を検出した場合は `SessionStart` + 24h cache の旧 hook へフォールバック

## [0.38.0] - 2026-04-01

### Added
- **PostCompact hook による compact 完了通知**: `memory-persistence` に `PostCompact` を追加し、compact 後に session notes / learned context の再利用フローを案内する軽量メッセージを表示

### Changed
- **compact フロー文書を更新**: `CLAUDE.md` と `memory/context-engineering.md` に `PostCompact` を含む compact 前後の役割分担を追記
- **検証導線を更新**: ローカル検証手順に unit / scenario test を追加し、`PostCompact` は Claude Code `2.1.89` で確認済み・旧版では無視される可能性がある旨を明記

## [0.37.3] - 2026-03-31

### Added
- **自動更新ヘルスチェック**: `setup.sh --update` および `/update-kit` の完了時に auto-update が正しく動作しているかチェックし、問題があれば警告を表示。SessionStart hook の登録状態、Git リポジトリの存在、リモートとのバージョン差異を検証する

## [0.37.2] - 2026-03-31

### Fixed
- **Codex login status の stderr 出力を許容**: `codex login status` が stdout ではなく stderr に状態を出す環境でも `_codex_login_status` が正しく認証済みと判定できるよう修正

## [0.37.1] - 2026-03-31

### Fixed
- **Codex MCP cleanup の検出漏れを修正**: `claude mcp list/remove` の user-scope 固定をやめ、`~/.claude.json` 側など user 固定で見えない legacy Codex MCP も plugin 移行時に cleanup できるよう修正
- **macOS の timeout fallback で login 判定が空になる不具合を修正**: `_run_with_timeout` が stdout/stderr を保持するようにし、`codex login status` の結果を command substitution で正しく受け取れるよう修正

## [0.37.0] - 2026-03-31

### Changed
- **update / dry-run の進捗表示を改善**: `setup.sh --update` と `/update-kit` 系の更新で `Step N/M` 表示を追加し、長い処理の途中経過が見えるよう改善
- **settings.json merge の要約を追加**: 3-way merge 完了時に keep-user / kit-update / conflicts などの集計を表示し、quiet mode でも何が起きたか把握しやすく改善
- **preview 実行の見分けを改善**: dry-run 子プロセスを `Preview Mode` として明示し、対話モードのプレビュー起動前後にも案内を追加

## [0.36.0] - 2026-03-31

### Changed
- **前提ツールの自動導入を統一**: `git` `jq` `curl` GNU `sed` GNU `awk` `bash 4+` `node` `tmux` `gh` を、未導入時に自動インストールを試みる挙動に統一
- **Bash 4+ 更新導線を改善**: macOS の Bash 3.2 環境では Bash 4+ の自動導入を試した上で re-exec し、失敗時のみ手動コマンドを案内
- **セットアップ失敗条件を明確化**: `node` `tmux` `gh` `dos2unix` の自動導入に失敗した場合は、警告で継続せず明示的に失敗させるよう変更

## [0.35.0] - 2026-03-31

### Changed
- Migrated Codex integration from MCP server to official Codex Plugin (`openai/codex-plugin-cc`)
- Renamed `ENABLE_CODEX_MCP` to `ENABLE_CODEX_PLUGIN` (backward compatible — old saved configs auto-migrate)
- Simplified CLAUDE.md delegation rules (plugin's built-in skills replace manual 7-section format)
- Codex setup now uses 2-axis state detection (plugin × MCP) for safe migration

### Added
- `--codex-plugin` CLI flag (alias: `--codex-mcp` preserved for backward compat)
- Interactive migration prompt for existing Codex MCP users
- Codex plugin and legacy MCP cleanup in uninstall flow
- `codex_plugin` field in manifest for tracking

### Removed
- MCP server registration (`claude mcp add -s user codex -- codex mcp-server`)
- 7-section delegation format in CLAUDE.md partials (replaced by plugin's built-in skills)

## [0.34.0] - 2026-03-25

### Added
- **プラグイン自動更新**: `setup.sh --update` / `/update-kit` 実行時にプラグインを `claude plugin install` で再インストールし最新化。add-only 方式（ユーザー追加プラグインは保持）
- **i18n**: `STR_DEPLOY_PLUGINS_UPDATED` を en/ja に追加

## [0.33.0] - 2026-03-25

### Added
- **macOS CI**: `test.yml` を matrix 化し `macos-latest` ジョブを追加。brew cache + Bash 4+ 明示使用 + Bash 3.2 re-exec テスト
- **semver ルール**: CLAUDE.md に Versioning セクションを追加。patch/minor/major の判断基準を明文化

### Fixed
- **uninstall.sh**: CLAUDE.md のキットセクション除去を `sed` → `awk` に変更（macOS BSD sed の互換性問題を修正）

## [0.32.1] - 2026-03-25

### Changed
- **wizard.sh リファクタリング**: `HOOK_LABELS` 二重定義を `_init_hook_labels()` に統一、`save_config()` をキー配列ループ化、`_prompt_yes_no()` 抽出で yes/no ステップを簡素化 (1117→1099 行)

## [0.32.0] - 2026-03-25

### Changed
- **setup.sh 分解**: ビルド・デプロイ関数群 (~700 行) を `lib/deploy.sh` に抽出。setup.sh はオーケストレーション専用 (585 行) に
- **レガシーラッパー削除**: `build_settings()` / `build_settings_to_file()` を削除し、`build_settings_file()` に統一
- **CLAUDE.md**: sourcing 順序・Architecture セクション・Adding a New Feature セクションを実態に合わせて更新

## [0.31.0] - 2026-03-25

### Added
- **単体テスト基盤**: 82 本の関数レベル単体テストを追加（template, snapshot, merge, json-builder, features, detect, prerequisites, wizard-utils）。`tests/run-unit-tests.sh` ランナーと `tests/unit/` ディレクトリ構成
- **テストヘルパー拡充**: `assert_equals`, `assert_not_equals`, `assert_matches`, `assert_empty`, `assert_not_empty`, `run_func` を `tests/helpers.sh` に追加

### Fixed
- **`assert_json_has_key` の false/null 誤判定**: `jq -e` → `jq -e '($key) != null'` に修正。値が false/null のキーでも正しく存在検出
- **`assert_file_contains` の正規表現マッチ**: `grep -q` → `grep -qF` に修正。リテラル文字列マッチに統一

### Changed
- **CI**: `.github/workflows/test.yml` に単体テストステップを追加（シナリオテストの前に実行）

## [0.30.1] - 2026-03-25

### Fixed
- **CLAUDE.md スナップショットの二重マーカー自己修復**: `_snapshot_claude_md()` の書き込み後に BEGIN マーカーの数を検証し、複数ペアが検出された場合は最初のペアだけを再抽出して自動修復。v0.30.0 以前のバグでスナップショットに二重マーカーが残った環境で、update のたびに false conflict が発生する問題を解消
- **`grep -cF || echo 0` の二重出力バグ修正**: コマンド置換内の `|| echo 0` が `"0\n0"` を生成する問題を `lib/snapshot.sh` / `lib/template.sh` で統一修正

## [0.30.0] - 2026-03-24

**大規模リファクタリングマイルストーン** (v0.20.4 → v0.30.0)

### Added
- **Feature registry** (`lib/features.sh`): `declare -A _FEATURE_FLAGS`, `_FEATURE_HAS_SCRIPTS`, `_FEATURE_ORDER` で 12 feature を一元管理。新 feature 追加時の編集ファイル数を 16-19 → 5 に削減
- **`_add_to_path_now_and_persist()`**: 即時 export + RC 永続化を統合
- **`_check_major_upgrade()`**: semver メジャーバージョン変更検出 + 復旧案内
- **Dirty check**: 全更新経路（install.sh, install.ps1, auto-update.sh, /update-kit）で git dirty preflight
- **シナリオテスト基盤**: 28 テスト（27 PASS + 1 SKIP）+ CI workflow
- **ヘッダーコメント + 契約定義**: 全 lib ファイルに Requires/Uses/Sets/Exports/Dry-run 分類

### Changed
- **Bash 4+ 必須化**: 二段階ブート（Stage 1: Bash 3.2 互換 → re-exec → Stage 2: Bash 4+）
- **`build_settings_file()` 統合**: `build_settings()` + `build_settings_to_file()` の ~140行重複を registry ループに統合
- **`deploy_hook_scripts()` 統合**: mode 引数（simple/merge-aware）、`_deploy_hook_scripts_safe()` 削除
- **Codex MCP コード分離**: setup.sh から ~420行を `lib/codex-setup.sh` に移動
- **関数一元化**: `_merge_settings_bootstrap()` → merge.sh、`_user_section_heading()` → template.sh、`_get_shell_rc_file()` → prerequisites.sh
- **ghostty.sh HackGen 重複関数削除**: fonts.sh の `install_hackgen_nf()` を使用。`_ghostty_ensure_brew()` → `_ensure_homebrew()` に統一

### Removed
- 未使用 i18n 文字列 31 個を en/ja から削除

## [0.24.0] - 2026-03-24

### Changed
- **PATH 共通化**: `_add_to_path_now_and_persist()` を prerequisites.sh に追加。即時 `export PATH` + RC ファイル永続化を一関数に統合。setup.sh の 5 箇所の inline PATH export を置換
- **`_get_shell_rc_file()` を prerequisites.sh に一元化**: codex-setup.sh の重複定義を削除
- **`_ensure_local_bin_in_path()` 削除**: `_add_to_path_now_and_persist()` に置換

## [0.23.0] - 2026-03-24

### Changed
- **Feature registry 導入**: `lib/features.sh` に `declare -A _FEATURE_FLAGS`, `_FEATURE_HAS_SCRIPTS`, `_FEATURE_ORDER` を定義。12 個の `is_true` ハードコードチェックを registry ループに置換
- **`build_settings_file()` 統合**: `build_settings()` + `build_settings_to_file()` の ~140行重複を `build_settings_file()` に統合。safety-net 先頭アサーション付き
- **`deploy_hook_scripts()` 統合**: 5 個の `is_true` 分岐を `_FEATURE_HAS_SCRIPTS` registry ループに置換。`_make_hooks_executable()` 抽出
- **テスト有効化**: `safety-net-first` + `registry-consistency` テストをスタブから実テストに更新

## [0.22.3] - 2026-03-24

### Added
- **ヘッダーコメント + 契約定義**: 全 lib ファイルに Requires/Uses/Sets globals/Exports/Dry-run 分類を明記。wizard.sh にインターフェース境界コメント。merge.sh にマージ戦略 3 系統を記載

## [0.22.2] - 2026-03-24

### Changed
- **`_merge_settings_bootstrap()` を merge.sh に移動**: update.sh → merge.sh。関連するマージロジックを一箇所に集約
- **`_user_section_heading()` を template.sh に一元化**: setup.sh と update.sh の重複定義を削除し template.sh に統合
- **ghostty.sh の HackGen 重複関数を削除**: `install_hackgen_font()` を削除し、fonts.sh の `install_hackgen_nf()` を使用

## [0.22.1] - 2026-03-24

### Changed
- **Codex MCP コード分離**: setup.sh から ~420行の Codex MCP 関連コードを `lib/codex-setup.sh` に移動。`run_codex_setup()` エントリポイント関数を追加。setup.sh は source + 呼び出しのみ。動作変更なし

## [0.22.0] - 2026-03-24

### Changed
- **Bash 4+ 必須化**: setup.sh を二段階ブートに分割。Stage 1（wizard, detect, prerequisites）は Bash 3.2 互換を維持し、Bash 4+ を検出して re-exec。Stage 2 以降は Bash 4+ 必須
- **`_detect_bash4()` + `check_bash4()`**: `/opt/homebrew/bin/bash`, `/usr/local/bin/bash` 等から Bash 4+ を自動検出。見つからない場合はエラーメッセージとインストール案内を表示
- **`_SETUP_ORIG_ARGS` + `_SETUP_SCRIPT_PATH`**: CLI 引数とスクリプトパスを setup.sh 冒頭で保存し、re-exec 時に引き継ぎ

## [0.21.0] - 2026-03-24

### Added
- **メジャーアップグレード検出**: `_check_major_upgrade()` で semver メジャーバージョン変更（例: v0→v1）を検出し、復旧案内を表示
- **Dirty check（全更新経路）**: `install.sh`, `install.ps1`（WSL + Git Bash）, `auto-update.sh`, `/update-kit` コマンドで、kit リポジトリにローカル変更がある場合は更新をブロックし `git stash` を案内
- **Recovery UX**: 更新失敗時にバックアップパスと復元コマンドを表示。`auto-update.sh` は `.starter-kit-last-backup` からパスを読み取り
- **Skip 通知**: update でスキップされたファイルがある場合、次回の対処方法を案内

### Changed
- **auto-update.sh**: `setup.sh --update` 呼び出しの `2>/dev/null` を除去し stderr を出力（recovery 情報を表示するため）。`--non-interactive` フラグを明示
- **/update-kit コマンド**: Pre-flight checks セクションと Recovery セクションを追加

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
