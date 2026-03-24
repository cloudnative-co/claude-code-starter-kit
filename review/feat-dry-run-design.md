# Design: Dry-run 機構 (PR 2/2)

Branch: 未作成（PR #11 マージ後に着手）
Date: 2026-03-24
Target version: v0.19.0
Depends on: PR #11 v0.18.5 (feat/dry-run-and-fresh-install-safety)

## 背景

既存環境で「何が起きるか」を事前確認する手段がない。`--dry-run` フラグで install/update の影響範囲をプレビューできるようにする。

## 設計方針

### 基本原則
- `--dry-run` はデプロイを行わず、何が起きるかを表示して exit 0
- 軽量な前提ツール（git, jq, curl）が不足する場合、interactive では導入確認を行う。non-interactive では導入せず中止する。重いツール（Homebrew, Node 等）は dry-run 中に導入しない
- **sim dir リダイレクトだけに頼らない**: shell RC, plugins, Ghostty, fonts, Codex MCP は `CLAUDE_DIR` 外の操作があるため、各副作用ポイントで `DRY_RUN` を明示的にチェック
- merge プロンプトは出さない（完全に非対話）
- **sim dir 内の snapshot / manifest は一時成果物**: sim dir で通常フローを流すと `write_managed_snapshot()` や `write_manifest()` が実行されるが、これらはサマリ生成用の中間物であり、レポート表示後に sim dir ごと破棄する。実際の `~/.claude` の snapshot / manifest には一切触れない
- **diff / summary の比較基準は固定**: レポートの基準は常に「実際の `~/.claude`（current）vs sim dir 実行後（simulated）」の比較。sim dir 内部の中間状態は利用者に見せない

### merge 競合の表示（2段表示）
- **保存済み prefs あり**: 予定結果まで表示
  ```
  language: keep-mine (記憶済み) → あなたの値 "ja" を保持
  ```
- **保存済み prefs なし**: 本番で確認が入ることを表示
  ```
  permissions.allow: 競合あり (9件 vs 92件) → 本番では確認プロンプトが出ます
  ```

### 出力形式
```
=== Dry Run サマリ ===

作成されるファイル:
  ~/.claude/agents/planner.md
  ~/.claude/rules/coding-style.md
  ...

マージされるファイル:
  ~/.claude/settings.json
    language: 競合あり (ja vs English) → 本番では確認プロンプトが出ます
    permissions.allow: keep-mine (記憶済み) → あなたの値を保持
    [kit-add] statusLine: 新規追加されます

スキップ (kit 管理対象外として保持):
  ~/.claude/CLAUDE.md (既存ファイルを保持 → manifest/snapshot に載りません)

外部操作:
  [WOULD RUN] claude plugin install pr-review-toolkit
  [SKIP] Ghostty (無効)

--- settings.json diff (kit 追加分のみ) ---
+ "statusLine": { ... }
```

## 実装計画

### 新規ファイル: `lib/dryrun.sh`

| 関数 | 責務 |
|------|------|
| `_dryrun_init()` | sim ディレクトリ作成、既存 `~/.claude` ファイルのコピー |
| `_dryrun_log(action, target, detail)` | ログ蓄積（indexed array） |
| `_dryrun_summary()` | サマリ出力（action 種別ごとにグルーピング） |
| `_dryrun_diff(current, simulated, label)` | unified diff 表示 |
| `_dryrun_settings_report(current, simulated)` | settings.json のキー単位レポート（merge prefs 考慮） |

### CLI フラグ

**wizard/wizard.sh**:
```bash
DRY_RUN="${DRY_RUN:-false}"
# parse_cli_args:
--dry-run) DRY_RUN="true" ;;
```

### v0.18.0〜v0.18.5 で追加された考慮事項

- **`_MERGE_INTERACTIVE`**: dry-run 時は `false` に設定（設計通り）
- **`_merge_settings_bootstrap()`**: fresh install 既存ユーザーパスで使われる。sim dir 内で実行される
- **`_deploy_fresh_with_existing()`**: 新しい fresh install 分岐。sim dir redirect で対応
- **`_FRESH_SKIPPED_FILES`**: preserve/skip されたファイルは manifest/snapshot から除外される。dry-run サマリで「このファイルは preserve され、kit 管理対象に入りません」と表示する必要あり

### 統合ポイント（setup.sh）

#### ファイル操作の sim dir リダイレクト
deploy ブロック冒頭で `CLAUDE_DIR` を sim dir に切り替え、通常のフローを実行:
```bash
if [[ "$DRY_RUN" == "true" ]]; then
  _dryrun_init
  _ORIG_CLAUDE_DIR="$CLAUDE_DIR"
  CLAUDE_DIR="$_DRYRUN_DIR"
  _MERGE_INTERACTIVE="false"  # プロンプトなし
fi
```

#### 外部操作の個別ガード
`CLAUDE_DIR` 外の操作は sim dir では捕まらないので個別に:

| セクション | ガード方法 |
|-----------|-----------|
| Ghostty install | `_dryrun_log "EXTERNAL" "Ghostty" "brew install --cask ghostty"` |
| Font install | `_dryrun_log "EXTERNAL" "Fonts" "IBM Plex Mono + HackGen NF"` |
| Shell RC 変更 | `_dryrun_log "MODIFY" "~/.zshrc" "PATH entry"` |
| Plugin install | `_dryrun_log "EXTERNAL" "Plugins" "claude plugin install ..."` |
| Codex MCP | `_dryrun_log "EXTERNAL" "Codex MCP" "claude mcp add -s user codex"` |
| Claude CLI install | `_dryrun_log "EXTERNAL" "Claude CLI" "curl ... \| bash"` |

#### サマリ表示 + exit
```bash
if [[ "$DRY_RUN" == "true" ]]; then
  _dryrun_show_results "$_ORIG_CLAUDE_DIR"
  exit 0
fi
```

### Update mode の dry-run

`run_update()` 冒頭で:
1. 現在の `~/.claude` を sim dir にコピー
2. `claude_dir` を sim dir にリダイレクト
3. `_MERGE_INTERACTIVE=false` で通常の update フロー実行
4. サマリ + diff を表示

### 対応モード

| モード | dry-run 動作 |
|--------|-------------|
| Fresh install (クリーンスレート) | 作成されるファイル一覧 |
| Fresh install (既存あり) | merge プレビュー + ディレクトリ判定 |
| Update | 3-way merge プレビュー + diff |
| `--non-interactive --dry-run` | 同上（そもそも dry-run は常に非対話） |

## i18n

`STR_DRYRUN_*` を en/ja に追加:
- `STR_DRYRUN_TITLE` / `STR_DRYRUN_SUMMARY`
- `STR_DRYRUN_CREATED` / `STR_DRYRUN_MODIFIED` / `STR_DRYRUN_MERGED` / `STR_DRYRUN_SKIPPED`
- `STR_DRYRUN_EXTERNAL` / `STR_DRYRUN_WOULD_RUN` / `STR_DRYRUN_SKIP`
- `STR_DRYRUN_CONFLICT_WILL_PROMPT` / `STR_DRYRUN_CONFLICT_REMEMBERED`

## 修正対象ファイル

| File | Changes |
|------|---------|
| `lib/dryrun.sh` | **新規**: simulation infrastructure |
| `setup.sh` | dry-run init + CLAUDE_DIR redirect + 外部操作ガード + サマリ |
| `lib/update.sh` | dry-run 対応ガード |
| `wizard/wizard.sh` | `--dry-run` フラグ追加 |
| `i18n/en/strings.sh` | STR_DRYRUN_* 追加 |
| `i18n/ja/strings.sh` | 同上 |
| `README.md` / `README.en.md` | `--dry-run` の使い方・例 |
| `CLAUDE.md` | `DRY_RUN` 変数、`lib/dryrun.sh` のアーキテクチャ |
| `CHANGELOG.md` | エントリ追加 |
| `commands/update-kit.md` | dry-run の説明追加 |

## 検証方法

1. `bash setup.sh --dry-run` → ファイル変更なし + サマリ出力
2. `bash setup.sh --update --dry-run` → ファイル変更なし + diff 出力
3. `bash setup.sh --dry-run --non-interactive` → 全自動でサマリのみ
4. 既存 settings.json + merge prefs あり → 記憶済み判定が表示されるか
5. 既存 settings.json + merge prefs なし → 「本番では確認されます」が表示されるか
6. 外部操作が `[WOULD RUN]` でログされるか
7. `shellcheck -S warning` 全ファイル
8. dry-run 後にファイルシステムに変更がないことを `diff -r` で確認

## 注意点

- Bash 3.2 互換（macOS デフォルト）: 連想配列不可、indexed array のみ
- sim dir は `_SETUP_TMP_FILES` に登録するか trap で cleanup
- `CLAUDE_DIR` redirect 後もハードコードされた `$HOME/.claude` パスがないか全件確認
