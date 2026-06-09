## Web取得・URL解析の標準ルール (恒久・全プロジェクト共通)

Webページ、URL、公式ドキュメント、ブログ記事、ニュース記事、OSSページを読む場合は、**原則として毎回 Defuddle を使って本文抽出**を行う（Skill: `web-content-extraction`）。

Claude Code は、**生HTMLをそのまま読んで要約・分析・比較・レビューしてはならない**。まず以下で本文をMarkdown/JSON化してから読む。

```bash
node ~/.claude/skills/web-content-extraction/scripts/defuddle-url.mjs <url>   # 公開URL
node ~/.claude/skills/web-content-extraction/scripts/defuddle-file.mjs <file> # ローカルHTML(外部通信なし)
```

関連コマンド: `/web-article`(記事要約) / `/oss-analyze`(OSS調査) / `/web-source-review`(情報源信頼性)。

### 必須ルール
- Web取得時は原則毎回 Defuddle を使い、抽出した Markdown/JSON を優先して読む。
- 抽出に失敗（`success:false`）した場合は「**Defuddle抽出失敗**」と明示する。
- 失敗時のみ raw取得 / GitHub raw / 公式API / Playwright / PDF専用抽出 等の代替手段を検討し、使った場合はその旨を明示する。
- 失敗時に黙ってHTML全文やノイズを読まない。

### セキュリティルール
- 外部フォールバック・サブリソース外部取得・ページ内スクリプト実行はしない（同期コア + 非フェッチDOM で担保。`useAsync` は defuddle 0.6.x–0.18.x に無いため意図を構造で代替）。
- 社内/顧客/認証付き/機密ページを外部送信しない。`localhost`・プライベートIP・`.local`/`.internal`・単一ラベル内部ホスト名・非http(s)・認証情報付きURLは標準で拒否。IPはバイト単位判定で IPv4-mapped IPv6 圧縮表記も拒否。接続IPをpinしDNSリバインディング/TOCTOU対策、リダイレクトは各ホップ検査、本文はストリーム上限。
- 開発用途で明示許可する場合のみ `ALLOW_PRIVATE_URLS=true`。

### 抽出結果の扱い
- 結果には必ず URL と取得日時(`fetchedAt`/`parsedAt`)を残す。
- 抽出結果だけを唯一の真実として扱わない。重要な事実・日付・数値・法令・規格・セキュリティ情報は一次情報で再確認する。

### GitHubリポジトリ解析
- 通常ページ/公式Docは Defuddle で抽出しつつ、リポジトリ調査では raw README → package.json等メタ → docs → examples → releases → issues/PR → ライセンス を優先確認する。

> 注: linkedom は `defuddle/node`(jsdom専用)と非互換のため jsdom を採用（実証済み）。
