# Update Mechanism Design

## Problem

`install.sh` を再実行すると `~/.claude/settings.json` が毎回ゼロから再構築され、ユーザーが手動で追加した設定（MCP サーバー、カスタム hooks、permissions 等）がすべて消失する。

## Solution: Snapshot Comparison + 3-Way Merge

kit がデプロイした時点のファイルをスナップショットとして保存し、update 時に「snapshot / current / new_kit」の3者比較でユーザー変更を検出・保持する。

## Data Structure

### Snapshot Directory

```
~/.claude/.starter-kit-snapshot/
  ├── settings.json
  ├── CLAUDE.md
  ├── agents/
  ├── rules/
  ├── commands/
  ├── skills/
  ├── hooks/
  └── memory/
```

### Manifest v2

```json
{
  "version": "2",
  "timestamp": "2026-03-10T12:34:56Z",
  "kit_version": "v0.8.0",
  "profile": "standard",
  "language": "ja",
  "editor": "vscode",
  "plugins": "pr-review-toolkit,superpowers@claude-code-plugins",
  "files": ["..."],
  "snapshot_dir": "/Users/shinji/.claude/.starter-kit-snapshot"
}
```

- `version: "2"` で新形式を識別（v1 は update 不可、フル再セットアップへ fallback）
- `kit_version` を追加

## settings.json Merge Strategy

トップレベルキー単位でマージ判定:

| Key | Strategy |
|-----|----------|
| `permissions.deny[]` | 配列: kit 新規エントリを追加、ユーザー追加分を保持 |
| `permissions.allow[]` | 同上 |
| `hooks.*[]` | 配列: kit 新規 hook を追加、ユーザー追加分を保持 |
| `mcpServers` | ユーザー専有、kit は触らない |
| `env` | オブジェクト: 両方のキーをマージ、競合時は質問 |
| `language` | スカラー: 競合時は質問 |
| Other scalars | 競合時は質問 |

### 3-Way Array Merge Logic

- snapshot にない & current にある → ユーザー追加 → 保持
- snapshot にある & new_kit にない → kit が削除 → 質問
- new_kit にある & snapshot にない → kit が新規追加 → 追加

## Update Flow

### install.sh Auto-Detection

```
install.sh 実行
  └── clone_or_update()
  └── manifest v2 存在?
        ├── YES → setup.sh --update
        └── NO  → manifest v1 存在?
              ├── YES → 警告 + setup.sh（通常モード + snapshot 書き出し）
              └── NO  → setup.sh（通常モード + snapshot 書き出し）
```

### setup.sh --update Flow

```
1. wizard 不起動（profile/language/editor は manifest から復元）

2. settings.json マージ:
   a. snapshot と current を比較
   b. kit 新版を生成（build_settings()）
   c. 3者比較:
      - snapshot == current → new_kit で上書き
      - snapshot == new_kit → current を維持
      - 両方変更 → キー単位マージ、競合は質問

3. ファイル（agents, rules, skills 等）:
   a. snapshot vs current 比較:
      - 差分なし → new_kit で上書き
      - 差分あり → 質問「追記 / スキップ / diff 表示」
   b. kit 新規ファイル → デプロイ
   c. kit 削除ファイル → 質問「削除 / 残す」

4. snapshot 更新（skip したファイルは更新しない）
5. manifest v2 更新
```

### Conflict UI

```
settings.json:
  hooks.PreToolUse:
    kit 追加: [new hook entry]
    user 追加: [custom hook entry]
  → [B]oth / [K]it優先 / [U]ser優先 / [S]kip ?

agents/planner.md:
  → [A]ppend / [S]kip / [D]iff ?
```

### --non-interactive Update

- ユーザー変更なし → 上書き
- ユーザー変更あり → スキップ（安全側）
- 競合 → kit 新規追加分のみマージ、ユーザー変更は保持
- スキップしたファイル一覧をログ出力

## Implementation Structure

### New Files

| File | Purpose | Est. Lines |
|------|---------|-----------|
| `lib/update.sh` | update ロジック本体 | ~300 |
| `lib/merge.sh` | settings.json 3者マージ | ~200 |

### Modified Files

| File | Changes |
|------|---------|
| `install.sh` | manifest v2 検出 → `--update` フラグ付与 |
| `setup.sh` | `--update` モード分岐 + snapshot 書き出し |
| `wizard/wizard.sh` | `--update` フラグパース |
| `lib/json-builder.sh` | snapshot 保存関数追加 |

### Key Functions

**lib/update.sh:**
- `run_update()` — update エントリポイント
- `_detect_user_changes()` — snapshot vs current 比較
- `_prompt_file_update()` — ファイル単位の対話（append/skip/diff）
- `_write_snapshot()` — snapshot ディレクトリ初期化・更新
- `_detect_manifest_version()` — v1/v2 判定

**lib/merge.sh:**
- `merge_settings_json()` — 3者マージエントリポイント
- `_diff_json_keys()` — トップレベルキー差分検出
- `_merge_arrays()` — 配列の3者マージ
- `_prompt_scalar_conflict()` — スカラー競合対話
- `_merge_objects()` — オブジェクト再帰マージ

### setup.sh Changes

```bash
main() {
  if [[ "$UPDATE_MODE" == "true" ]]; then
    _restore_config_from_manifest
    run_update
  else
    run_wizard
    build_settings
    deploy_files
    _write_snapshot  # NEW
  fi
  write_manifest  # v2 format
}
```

## Constraints

- Bash 3.2 互換（macOS デフォルト）
- `jq` 依存（settings.json マージに必須）
- snapshot は skip したファイルの分は更新しない
- manifest v1 からの update は不可（フル再セットアップが必要）
