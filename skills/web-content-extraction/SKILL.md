---
name: web-content-extraction
description: Web取得の標準前処理レイヤー。URL・公式ドキュメント・ブログ・ニュース・OSSページを読むときは、原則として毎回このSkillでDefuddleを使い本文をMarkdown/JSON化してから読む。生HTMLのまま要約・分析・比較・レビューしない。トリガー例: URLを読む/Webページ要約/OSS調査/公式Doc確認/記事解析/競合サイト確認/Web一次情報確認。
when_to_use: URL・Webページ・公式ドキュメント・ブログ・ニュース・OSS/GitHubページを読む前に毎回使う。生HTMLを直接読まず、まず Defuddle で本文を Markdown/JSON 化してから読む。URL要約・OSS調査・記事解析・競合確認・Web一次情報確認に対応。
---

# Web Content Extraction

## Purpose

Webページ本文を抽出し、LLMが読みやすい Markdown/JSON に整形する。
Claude Code が Webページ、URL、公式ドキュメント、ブログ記事、ニュース記事、OSSページを読む場合は、**原則として毎回このSkillを使う**。

## Mandatory Rule

When reading any public web URL, **use Defuddle first**.

Do not summarize, analyze, compare, or review a web page from raw HTML unless Defuddle extraction fails or the page type is explicitly unsupported.

## Use Cases

- URL要約 / 公式ドキュメント確認 / OSS調査
- ブログ記事分析 / ニュース記事分析 / 競合サイト分析
- ベンダー公式ブログの調査 / Web上の一次情報確認
- 技術記事の読み取り / LLM・RAG向けのWeb本文抽出

## Standard Commands

```bash
# 公開URLを取得して本文をMarkdown/JSON化（SSRFガードあり）
node ~/.claude/skills/web-content-extraction/scripts/defuddle-url.mjs <url>
```

```bash
# ローカルHTMLファイルを本文抽出（外部通信なし）
node ~/.claude/skills/web-content-extraction/scripts/defuddle-file.mjs <file>
```

出力は JSON（stdout）。最低限 `success`, `url`, `fetchedAt`/`parsedAt`, `title`, `author`,
`site`, `domain`, `published`, `description`, `wordCount`, `content`(Markdown) を含む。
`warnings` / `fetchWarnings` がある場合は抽出の信頼性に注意する。

## Output Fields

| フィールド | 意味 |
|-----------|------|
| `success` | 本文抽出に成功したか（false は抽出失敗/空） |
| `warnings` | 本文が短い・空など低信頼の警告 |
| `url` / `requestedUrl` / `finalUrl` | 対象URL（リダイレクト後の最終URL含む） |
| `fetchedAt` / `parsedAt` | 取得・解析時刻（ISO8601, 監査用に必ず保持） |
| `title` `author` `site` `domain` `published` `description` | メタデータ |
| `wordCount` | 語数（空白区切り。**日本語は極端に小さく出る**） |
| `charCount` | 非空白の文字数（**日本語の実分量はこちらで判断**） |
| `cjkCharCount` | CJK文字数（日本語/中国語/韓国語の量の目安） |
| `content` | 本文（HTMLはMarkdown、PDFはプレーンテキスト） |
| `extractorType` | サイト固有抽出器が使われた場合の種別 |
| `extractorEngine` | PDF抽出時のみ `"pdf"`。`pageCount` も付く |

## Security Rules

- **同期コア + 非フェッチDOM** で動作する（`useAsync` はupstreamに存在しないため意図を構造で担保）。
- 外部フォールバック・サブリソース外部取得・ページ内スクリプト実行は**行わない**。
- 社内URL、顧客URL、認証付きURL、個人情報・機密を含むページを外部送信しない。
- `localhost` / プライベートIP(10/8,172.16/12,192.168/16,127/8,169.254/16,100.64/10 等) /
  `.local`/`.internal` 等 / 単一ラベルの内部ホスト名 / 非http(s) / **認証情報付きURL** は**標準で拒否**。
- IP判定は**バイト単位**。10進/8進/16進 IPv4 も拒否。IPv6は**default-deny**（グローバルユニキャスト
  `2000::/3` 以外は全拒否。Teredo/site-local/documentation/NAT64/IPv4-mapped/6to4(private埋め込み)等を含む）。
- **接続IPをpin**（guarded undici dispatcher）して **DNSリバインディング/TOCTOU を封じる**。
- **リダイレクトは手動追従し各ホップを送信前に再検査**。**本文はストリームでサイズ上限**（メモリDoS対策）。
- 開発用途で明示的に許可する場合のみ `ALLOW_PRIVATE_URLS=true`（バイパスは stderr に監査記録）。
- 抽出結果には必ず URL と取得日時を残す。
- 抽出結果だけを唯一の真実として扱わない。重要な事実は一次情報で再確認する。

## Failure Handling

- Defuddle抽出に失敗した場合は、必ず「**Defuddle抽出失敗**」と明示する。
- 不完全な抽出結果（`success:false` や `warnings` あり）で断定しない。
- 必要なら以下の代替手段を検討する:
  - raw HTML取得 / GitHub raw / 公式API / Playwright(MCP) / PDF専用抽出 / 手動確認
- 代替手段を使った場合は、**Defuddleではなく代替手段を使ったこと**を明示する。

## PDF対応

公開URLが PDF（`content-type: application/pdf` / `.pdf` / 先頭 `%PDF-`）の場合、`defuddle-url.mjs`
は自動で **pdfjs-dist によるテキスト抽出にフォールバック**する（`extractorEngine:"pdf"`, `pageCount` 付き）。

- **日本語/CJK PDF も文字化けしない**（fsベースのCMapReaderFactoryで packed CMap を解決）。
- `content` はMarkdownでなくプレーンテキスト。
- スキャン画像のみのPDFは `charCount:0`＋警告 → **OCRが必要**（本Skillの対象外）。
- ローカルPDFファイルは現状未対応（`defuddle-file.mjs` はHTML専用）。

## Tests

```bash
cd ~/.claude/skills/web-content-extraction && npm test   # node --test
```

`test/url-guard.test.mjs`（SSRFガード）/ `test/defuddle-core.test.mjs`（charCount）/
`test/extract-smoke.test.mjs`（**実抽出スモーク: HTML+PDF**）を実行。DNS非依存・オフラインの
決定的テストのみ。CIは `.github/workflows/skill-web-content-extraction.yml`（Node 22/24 マトリクス）。

## 自動アップデート

Claude Code 起動毎に依存（defuddle/jsdom/pdfjs-dist）の最新を確認し、更新があれば適用→
`npm test` 通過時のみ採用、失敗時は自動ロールバックする（SessionStartフック → `scripts/update-deps.mjs`、
24h スロットル、ログは `logs/update.log`）。手動実行は `npm run update:deps`。詳細は README 参照。

## Unsupported or Caution Cases

- 認証が必要なページ / 社内・顧客・非公開ページ / 個人情報・機密を含むページ
- JavaScript必須のSPA（初期HTMLに本文がない） / PDF
- robots.txt や利用規約に反する大量取得

PDFやGitHubリポジトリなど、Defuddleだけでは不十分な対象では適切な専用手段を併用する。

## Implementation Notes (重要・現実との差分)

> 本Skillは defuddle の実API検証に基づく（0.6.x で検証、0.18.x で再確認。依存は自動更新）。当初設計（linkedom / `useAsync:false`）からの逸脱:
- **linkedom は使用不可**: `defuddle/node` は jsdom 専用(peerDependency)。linkedom では
  `getComputedStyle`/メディアクエリ評価が未実装で例外となり、ノイズ除去に失敗する（実証済み）。
  → **jsdom を採用**。
- **`useAsync` は存在しない**（0.6.x–0.18.x の dist 全体に出現なし）。意図（非同期外部取得をしない）は
  「同期 `parse()` + `resources:'usable'` を付けないDOM + スクリプト非実行」で構造的に担保。
- `defuddle/node` に文字列を渡すと内部JSDOMが `resources:'usable'` で**外部フェッチする**ため、
  本Skillは**自前で安全オプションのJSDOMを構築**して渡し、外部取得を防いでいる。
