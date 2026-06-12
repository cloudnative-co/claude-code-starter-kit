# Hooks Reference

このキットが `~/.claude/settings.json` に合成する hook の概要。実行時の正は
配備後の `settings.json` であり、本ドキュメントは「どの機能がどのイベントを
使うか」を素早く確認するための索引。各機能の有効/無効はプロファイルと
ウィザードの選択で決まる（`docs/wizard-config-mapping.md` 参照）。

## キットが使用する hook イベント

| イベント | 使用する機能（例) |
|---|---|
| `SessionStart` | auto-update, web-content-update, feature-recommendation |
| `SessionEnd` | auto-update |
| `PreToolUse` | safety-net, tmux-hooks, doc-blocker |
| `PostToolUse` | prettier-hooks, biome-hooks, doc-size-guard, pr-creation-log |
| `PreCompact` | pre-compact-commit |

機能ごとの正確な定義は `features/<feature>/hooks.json` を参照。複数機能が
同じイベントを使う場合、`merge_deep()` が配列を連結するため共存できる
（`safety-net` の `PreToolUse` エントリは常に先頭）。

## Compaction 前後の流れ（関連機能が有効な場合）

- `PreCompact`: compaction でコンテキストが要約される前に走る（例: pre-compact-commit のスナップショット）
- `PostCompact`: compaction 完了直後に走る
- `SessionStart`: 次セッション開始時の復元・通知に使う
