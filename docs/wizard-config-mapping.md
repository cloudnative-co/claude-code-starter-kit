# ウィザード設定と反映先の対応表

この文書は、セットアップウィザードや非対話モードの引数が、最終的にどこへ反映されるかを整理したものです。

まず前提として、設定は大きく 3 種類あります。

1. `settings.json` や `CLAUDE.md` のような生成ファイルに直接書かれるもの
2. ファイル配置や追加セットアップ処理に使われるもの
3. プリセットや manifest のように、次回実行や内部管理のために保持されるもの

`settings.json` に見えないから未使用、とは限りません。特に `PROFILE` や `INSTALL_*` は、結果ファイルよりも配置処理や初期値の決定に効く項目です。

## ウィザードの各ステップ

| ステップ | 保存キー / CLI | 何に効くか | 主な反映先 | `settings.json` に見えるか |
|---|---|---|---|---|
| 言語 | `LANGUAGE` / `--language` | 表示言語と生成物の言語設定 | `settings.json`, `CLAUDE.md`, i18n 読み込み | はい |
| プロファイル | `PROFILE` / `--profile` | 個別フラグの初期値セットを決める | `wizard` の初期化, manifest | いいえ |
| Codex MCP | `ENABLE_CODEX_MCP` / `--codex-mcp` | Codex CLI 認証と Claude MCP 登録を行うか | `setup.sh` の Codex MCP セットアップ | いいえ |
| エディタ | `EDITOR_CHOICE` / `--editor` | git push review hook で使うエディタ差分表示コマンド | `hooks.json` の差し込み, manifest | 間接的 |
| Ghostty | `ENABLE_GHOSTTY_SETUP` / `--ghostty` | Ghostty の追加セットアップ | Ghostty 設定処理 | いいえ |
| フック | `ENABLE_*` / `--hooks` | 有効化するフックを選ぶ | `settings.json` の hooks 合成 | はい |
| プラグイン | `SELECTED_PLUGINS` / `--plugins` | Claude Code セッション内で有効化する推奨プラグイン | プラグイン導入処理, manifest | いいえ |
| Claude Code 帰属 | `COMMIT_ATTRIBUTION` / `--commit-attribution` | コミットと PR の Claude Code 帰属表示 | `settings.json` の `attribution` | はい |
| 確認・デプロイ | `WIZARD_RESULT` | 保存して終えるか、すぐデプロイするか | 実行フロー制御 | いいえ |

## 基本選択の対応表

| キー | 用途 | 主な反映先 | 備考 |
|---|---|---|---|
| `LANGUAGE` | UI 表示言語と生成物の言語 | `settings.json`, `CLAUDE.md`, i18n | 現在は `日本語` / `English` を設定 |
| `PROFILE` | Minimal / Standard / Full / Custom の初期値選択 | `wizard` のデフォルト展開, manifest | 実際の挙動は個別フラグへ展開される |
| `EDITOR_CHOICE` | git push review hook のエディタコマンド | `features/git-push-review/hooks.json` | エディタを使わない場合は `none` |
| `COMMIT_ATTRIBUTION` | Claude Code 帰属の表示有無 | `settings.json` の `attribution.commit`, `attribution.pr` | `false` で commit / PR 両方の帰属表示を空文字にする |
| `ENABLE_CODEX_MCP` | Codex MCP セットアップ実行可否 | Codex CLI 認証と `claude mcp add` | 反映は `settings.json` ではなく外部セットアップ |
| `ENABLE_GHOSTTY_SETUP` | Ghostty の追加セットアップ | macOS 向け Ghostty 設定 | macOS 以外では無効化される |
| `ENABLE_FONTS_SETUP` | プログラミング用フォント導入 | フォントインストール処理 | 生成設定ではなく環境変更 |
| `SELECTED_PLUGINS` | 推奨プラグインの選択 | プラグイン導入処理, manifest | `name@marketplace` 形式に対応 |

## コンテンツ配置フラグ

| キー | 何を配置するか | 主な反映先 | update 時の扱い |
|---|---|---|---|
| `INSTALL_AGENTS` | `~/.claude/agents/` | 初回配置, update | `true` のときだけ同期対象 |
| `INSTALL_RULES` | `~/.claude/rules/` | 初回配置, update | 同上 |
| `INSTALL_COMMANDS` | `~/.claude/commands/` | 初回配置, update | 同上 |
| `INSTALL_SKILLS` | `~/.claude/skills/` | 初回配置, update | 同上 |
| `INSTALL_MEMORY` | `~/.claude/memory/` | 初回配置, update | 同上 |

## フック選択の対応表

これらのフラグは、対応する `features/*/hooks.json` を `settings.json` に合成するために使われます。

| キー | フック / 機能 | 主な目的 | `settings.json` に入るか |
|---|---|---|---|
| `ENABLE_SAFETY_NET` | Safety Net | 危険なコマンドの遮断 | はい |
| `ENABLE_AUTO_UPDATE` | Auto Update | セッション開始時の更新確認 | はい |
| `ENABLE_TMUX_HOOKS` | Tmux Reminder | 長時間処理を tmux に誘導 | はい |
| `ENABLE_GIT_PUSH_REVIEW` | Git Push Review | push 前に差分確認 | はい |
| `ENABLE_DOC_BLOCKER` | Doc Blocker | 不要な `.md` / `.txt` 作成を抑制 | はい |
| `ENABLE_PRETTIER_HOOKS` | Prettier Auto-format | JS / TS 編集後の整形 | はい |
| `ENABLE_CONSOLE_LOG_GUARD` | Console Log Guard | `console.log` の取り残し検知 | はい |
| `ENABLE_MEMORY_PERSISTENCE` | Memory Persistence | 重要な知識の永続化補助 | はい |
| `ENABLE_STRATEGIC_COMPACT` | Strategic Compact | compact 提案の補助 | はい |
| `ENABLE_PR_CREATION_LOG` | PR Creation Log | PR 作成ログの補助 | はい |
| `ENABLE_PRE_COMPACT_COMMIT` | Pre-compact Commit | compact 前のコミット補助 | はい |
| `ENABLE_STATUSLINE` | Statusline | ステータスライン機能 | はい |
| `ENABLE_DOC_SIZE_GUARD` | Doc Size Guard | 大きすぎる `CLAUDE.md` / `AGENTS.md` を警告 | はい |

## よくある誤解

### `PROFILE` が最終設定に見えない

正常です。`PROFILE` は preset 名を直接使うのではなく、インストール対象、フック、プラグインなどの初期値へ展開されます。

### `SELECTED_PLUGINS` が `settings.json` に見えない

正常です。プラグインは Claude Code セッション内で導入する想定で、manifest と導入処理に使われます。

### `ENABLE_CODEX_MCP` が `settings.json` に見えない

正常です。このフラグは `settings.json` を変えるのではなく、Codex CLI 認証や Claude MCP 登録の実行有無を切り替えます。

