# web-content-extraction

Claude Code の **Web取得標準レイヤー**。公開URL／ローカルHTMLを [Defuddle](https://github.com/kepano/defuddle) で本文抽出し、LLMが読みやすい Markdown/JSON にして返す。生HTMLを直接読ませないための前処理。

## セットアップ

```bash
cd ~/.claude/skills/web-content-extraction
npm install   # defuddle + jsdom
```

依存: `defuddle`, `jsdom`（`defuddle/node` 用）, `pdfjs-dist`（PDF抽出）。
バージョンは**自動アップデート**で最新追従する（後述。`package.json` の値は随時更新される）。

## テスト

```bash
npm test   # node --test
```

- `test/url-guard.test.mjs` — SSRFガード（IP分類・IPv4-mapped IPv6・userinfo・guarded lookup 等）
- `test/defuddle-core.test.mjs` — charCount/cjkCharCount
- `test/extract-smoke.test.mjs` — **実抽出スモーク（HTML: defuddle+jsdom / PDF: pdfjs）**

DNS非依存・オフラインの決定的テストのみ。
CI は `.github/workflows/test.yml`（Node 20/22/24 マトリクス）。**注: `~/.claude` は git repo
ではないため、このディレクトリをリポジトリ化するまで CI は起動しない。**

## 使い方

### 公開URLの抽出

```bash
node ~/.claude/skills/web-content-extraction/scripts/defuddle-url.mjs "https://example.com/article"
```

- `fetch` で取得 → 安全オプションのJSDOMでDOM化 → `defuddle/node` で本文抽出 → Markdown化
- 出力は JSON（stdout）。`success` / `title` / `author` / `site` / `domain` / `published` /
  `description` / `wordCount` / `charCount` / `cjkCharCount` / `content`(Markdown) /
  `fetchedAt` / `finalUrl` などを含む。
- **PDF URL は自動フォールバック抽出**（`application/pdf` / `.pdf` / `%PDF-`）。
  `extractorEngine:"pdf"`・`pageCount` 付き、`content` はプレーンテキスト。
  日本語PDFも文字化けしない（CMap対応）。スキャンPDFは `charCount:0`＋警告（OCR要）。
- 失敗時は `success:false` と `error` を返し、exit code を返す（2=抽出失敗, 3=取得/HTTP, 4=URL拒否, 64=引数）。

### ローカルHTMLファイルの抽出（外部通信なし）

```bash
node ~/.claude/skills/web-content-extraction/scripts/defuddle-file.mjs ./page.html
```

- ネットワーク通信を一切行わない。非公開HTMLに安全。
- 出力に `sourcePath` / `parsedAt` / `offline:true` を含む。

## Claude Code での使い方

- Skill `web-content-extraction` が「Web取得時は毎回 Defuddle」を宣言。
- コマンド: `/web-article <url>`（記事要約）/ `/oss-analyze <url>`（OSS調査）/
  `/web-source-review <url>`（情報源の信頼性評価）。
- 詳細ルールは `SKILL.md` と `~/.claude/CLAUDE.md` の「Web取得・URL解析の標準ルール」を参照。

## 運用ルール（要点）

- **Web取得時は原則毎回 Defuddle を使う**。生HTMLのまま要約・分析・比較・レビューしない。
- 抽出失敗時は「**Defuddle抽出失敗**」と明示し、必要時のみ代替手段（raw / GitHub raw /
  公式API / Playwright / PDF専用抽出）を使い、その旨を明示する。
- 抽出結果には URL と取得日時を必ず残す。結果だけを真実とせず、重要事実は一次情報で再確認する。

## セキュリティ

- **外部フェッチ・スクリプト実行をしないDOM**で抽出（`resources:'usable'`を付けない／`runScripts`なし）。
- `useAsync` は defuddle に存在しないため、その意図（非同期外部取得なし）を
  「同期コア + 非フェッチDOM」で構造的に担保。
- **SSRF/内部URLガード**（標準で拒否、`ALLOW_PRIVATE_URLS=true` で開発時のみ解除・stderr監査）:
  - IPv4拒否: `127.0.0.0/8` / `10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16` /
    `169.254.0.0/16` / `100.64.0.0/10` / `0.0.0.0/8` / multicast・reserved。
    10進/8進/16進表記（WHATWG正規化）も同様に拒否
  - IPv6は**default-deny**: グローバルユニキャスト `2000::/3` 以外は全拒否
    （loopback・ULA・link-local・**site-local fec0::/10**・multicast・IPv4-mapped/compatible・
    **NAT64 64:ff9b::/96** を含む）。`2000::/3` 内でも **Teredo `2001::/32`・documentation
    `2001:db8::/32`・benchmarking・ORCHID** と、**埋め込みv4がprivateな6to4 `2002::/16`** を拒否
  - **判定はバイト単位**: `[::ffff:127.0.0.1]`→`::ffff:7f00:1` のような圧縮表記も確実に処理
  - `localhost` / `.local`・`.internal` 等の内部TLD / 単一ラベル内部ホスト名 / 非http(s) /
    **認証情報付きURL(`user:pass@`)** を拒否
  - **接続IPをpin**（guarded undici dispatcher）: ガード時とfetch時の名前解決を一致させ、
    **DNSリバインディング/TOCTOUを封じる**
  - **リダイレクトは手動追従し、各ホップを送信前に再検査**（30xで内部URLへ到達させない）
  - **本文はストリームでサイズ上限**（Content-Length事前拒否＋超過時abort、メモリDoS対策）

## 自動アップデート

**Claude Code を起動するたび**に、依存（`defuddle` / `jsdom` / `pdfjs-dist`）の最新リリースを
確認し、更新があれば自動適用する（`~/.claude/settings.json` の SessionStart フックが
`scripts/update-deps.mjs` を `async` で起動）。

- **検出元**: `npm view <pkg> version`（npm `latest` = 公開済みリリース。GitHubリリースに追従）。
- **安全策**: 更新後に `npm test`（**実抽出スモーク含む**）を実行し、**失敗したら
  `package.json` / `package-lock.json` を自動ロールバック**して元の版に戻す。破壊的リリースで
  skill が壊れない。
- **スロットル**: 起動毎の負荷を避けるため **24時間に1回**だけチェック（`logs/.last-update-check`）。
- **多重実行防止**: ロックファイル（`logs/.update.lock`）で同時起動セッションの競合を回避。
- **非ブロッキング**: `async` 実行なので起動を待たせない。
- **結果**: すべて `logs/update.log` に記録（通知はログのみ）。

手動で今すぐ実行（スロットル無視）:

```bash
cd ~/.claude/skills/web-content-extraction && npm run update:deps   # = update-deps.mjs --force
tail -f ~/.claude/skills/web-content-extraction/logs/update.log
```

> 注: 自動更新ゲートは `npm test` に依存する。テストが実抽出（HTML/PDF）を検証しているため
> ゲートは実効的だが、サイト固有の挙動変化までは捕捉できない。重要更新後は実URLでの確認を推奨。

## 環境変数

| 変数 | 既定 | 説明 |
|------|------|------|
| `ALLOW_PRIVATE_URLS` | `false` | `true` でプライベート/内部URLを許可（開発用途のみ。バイパスは stderr に監査記録） |
| `DEFUDDLE_USER_AGENT` | `Claude-Code-Defuddle/1.0 ...` | 取得時のUser-Agent |
| `DEFUDDLE_TIMEOUT_MS` | `20000` | 取得タイムアウト(ms) |
| `DEFUDDLE_MAX_BYTES` | `10485760` | 解析する本文の最大バイト数(10MB)。ストリームで超過時 abort |
| `DEFUDDLE_MAX_REDIRECTS` | `5` | 追従する最大リダイレクト数（各ホップを検査） |
| `DEFUDDLE_MAX_PDF_PAGES` | `2000` | PDF解析の最大ページ数（パースDoS対策） |

## 既知の制約

- `wordCount` は空白区切り集計のため**日本語では小さく出る**。日本語の分量は `charCount` /
  `cjkCharCount` で判断する。
- JavaScript必須のSPAは初期HTMLに本文がなく抽出できないことがある（Playwright等を併用）。
- **PDF はURL取得時のみ対応**（ローカルPDFファイルは未対応）。スキャン画像PDFはOCRが別途必要。
- 認証必須ページは非対応。
- linkedom は `defuddle/node`（jsdom専用）と非互換のため**不採用**（getComputedStyle未実装で抽出が劣化）。
