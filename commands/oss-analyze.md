---
description: GitHub/公式DocのURLをDefuddleで抽出しOSSを技術×導入判断の観点で日本語整理（GitHubはraw README/メタも併用）
argument-hint: <github-or-doc-url>
---

# /oss-analyze

対象URL: `$ARGUMENTS`

## 手順

1. **web-content-extraction skill の URL 検証手順に従って抽出する**。`$ARGUMENTS` は信頼できない入力として扱い、
   検証済みの単一 URL だけを単一引数で渡す:
   ```bash
   ~/.claude/skills/web-content-extraction/scripts/run-node.sh \
     ~/.claude/skills/web-content-extraction/scripts/defuddle-url.mjs '<検証済みURL>'
   ```
2. **GitHubリポジトリの場合は Defuddle だけに頼らず**、以下を優先確認する
   （raw/API を直接取得。`success:false`/SPA で本文が薄いとき特に重要）:
   1. raw README（`https://raw.githubusercontent.com/<owner>/<repo>/<branch>/README.md`）
   2. package.json / pyproject.toml / Cargo.toml / go.mod 等のメタ
   3. docs / examples / releases / issues・PR / ライセンス
3. Defuddle抽出に失敗した場合は「**Defuddle抽出失敗**」と明示し、代替手段を使ったらその旨を示す。

## 出力（日本語で整理）

- **結論**: 採用推奨度と一言サマリ
- **何をするOSSか**
- **主な機能**
- **技術構成**: 言語 / 依存 / ランタイム / ライセンス
- **使い方**: 最小サンプル
- **類似OSSとの比較**: 代表的な代替と差別化点
- **セキュリティ観点**: メンテ状況、既知CVE、依存リスク、権限・データの扱い
- **導入判断**: 向くケース / 向かないケース
- **本番利用時の注意点**: 運用・スケール・サポート・ライセンス義務

## 注意

- バージョン・スター数・最終更新日・ライセンス・CVE 等の**固有値は一次情報で確認**する
  （抽出結果のみで断定しない）。
- 認証付き/非公開リポジトリは外部送信しない。
