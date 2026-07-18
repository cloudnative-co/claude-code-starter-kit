---
description: 入力URLをDefuddleで本文抽出し、記事を構造的に要約・分析する（事実と意見を分離、一次情報候補を提示）
argument-hint: <url>
---

# /web-article

対象URL: `$ARGUMENTS`

## 手順

1. **web-content-extraction skill の URL 検証手順に従って抽出する**（生HTMLを直接読まない）。
   `$ARGUMENTS` は信頼できない入力として扱い、検証済みの単一 URL だけを単一引数で渡す:
   ```bash
   ~/.claude/skills/web-content-extraction/scripts/run-node.sh \
     ~/.claude/skills/web-content-extraction/scripts/defuddle-url.mjs '<検証済みURL>'
   ```
2. **PDF URL は自動でフォールバック抽出される**（`content-type: application/pdf` か `.pdf`、
   または先頭が `%PDF-`）。その場合 `extractorEngine:"pdf"` となり、`content` はMarkdownでなく
   プレーンテキスト、`pageCount` を含む。日本語PDFも文字化けせず抽出する（CMap対応済み）。
   スキャン画像PDFは `charCount:0` で警告が出る → OCRが必要。
3. 出力JSONの `success` が `false`、または `warnings`/`fetchWarnings` がある場合は
   **「Defuddle抽出失敗」または「抽出不完全」と明示**し、必要なら代替手段（raw取得/公式API/
   Playwright/OCR/手動確認）を検討する。代替手段を使った場合はその旨を明示する。
4. 抽出できた `content` を一次的な読み取り対象として、以下を**日本語**で整理する。

## 出力フォーマット

- **メタ情報**: タイトル / 著者 / サイト / 公開日 / URL(finalUrl) / 取得日時(fetchedAt)
- **本文要約**: 3〜6行
- **重要ポイント**: 箇条書き
- **事実と意見の分離**: 「事実(検証可能)」と「著者の主張・意見」を分けて列挙
- **追加確認が必要な点**: 曖昧・未検証・要裏取りの箇所
- **引用すべき一次情報候補**: 本文が参照している一次情報・公式ソースの候補

## 注意

- 抽出結果だけを真実として扱わない。重要な事実・日付・数値・法令・規格・セキュリティ情報は
  一次情報で再確認する。
- 社内・顧客・認証付き・機密URLは外部送信しない（SSRFガードが内部URLを標準で拒否）。
