# mattpocock/skills 評価レポート (StarterKit 統合可否)

**評価日**: 2026-05-31
**対象**: [mattpocock/skills](https://github.com/mattpocock/skills) (commit `e3b90b5`, pushed 2026-05-28)
**評価環境**: macOS Darwin 25.5.0 / Claude Code 2.1.158
**評価成果物**: `git clone --depth 1` + `gh api` でのメタデータ一次検証 + 17 エージェント並列分析ワークフロー（14 skill 個別評価 + 重複/競合マトリクス + セキュリティ精査 + 統合方式比較）+ Claude Code 公式ドキュメント照合
**ステータス**: ドラフト（共同開発者のレビュー待ち）

---

## サマリー（3 行）

- 中身の品質は本物（battle-tested・opinionated・良質）。だが **StarterKit は既に同種の開発作法を多重に保有** している（常時起動の `superpowers` が brainstorming / TDD / debugging を強制、加えてキット独自の `/tdd` `/plan` `/research` `/handover` と `tdd-guide` / `architect` / `code-reviewer` agent）。14 skill のうち **過半が重複・競合**。
- **ネイティブ plugin 統合は技術的にブロック**。本リポは `.claude-plugin/marketplace.json` を持たず `plugin.json` のみ。公式導入経路は**第三者製 `npx skills`（skills.sh）**で、`@latest`（ピン留めなし）の npm コードがインストール時に実行される。キットの「ピン留め marketplace から `claude plugin install`・インストール時コード実行なし」というサプライチェーン信頼モデルと相容れない。
- 採用判定: **見送り（案 D）**。真に net-new な価値は 4〜5 個に集約され、それらは上流 `npx skills add` で個別に入れれば足りる。キット本体に取り込むと、重複・コマンド名衝突（`/tdd`・`/handoff`）・`superpowers` との行動衝突・vendoring 保守負債を抱える。将来 `marketplace.json` が上流に追加されたら案 C（薄いガイド）を再評価する。

---

## 採用判定

- [ ] そのまま採用
- [ ] 条件付き採用（案 C: 薄いガイドコマンドとして隔離）
- [x] **見送り（案 D）** — キット本体は不変。本レポートのみを判断記録として残す

---

## 何者か（一次情報・`gh api` 検証）

| 項目 | 値 |
|---|---|
| 作者 | Matt Pocock（Total TypeScript / AI Hero 運営、TypeScript 教育者）|
| Star / Fork | **112,252 / 9,852**（API 実測。作成 約3か月での 11万 Star は GitHub 全体でも異例）|
| License | **MIT**（Copyright 2026 Matt Pocock。再配布・改変可）|
| 作成 / 最終 push | 2026-02-03 / 2026-05-28（活発に保守中）|
| 形式 | Claude plugin（`.claude-plugin/plugin.json` に 14 skill 登録。`marketplace.json` は**不在**）|
| 公式導入 | `npx skills@latest add mattpocock/skills`（第三者製 skills.sh installer）|
| 思想 | Pragmatic Programmer / DDD / Ousterhout / Kent Beck を引用。「GSD・BMAD・Spec-Kit のようにプロセスを所有せず、小さく組み替え可能に」= **キット哲学と親和的** |

> 補足: Star 数自体は API で確定。中身の品質も独立分析で「良質」と確認できたため、人気は単なるバズではなく実体を伴う。ただし「キットに足りないものを埋めるか」は別問題であり、本レポートの主題はそこにある。

---

## 14 skill 評価マトリクス（既存キットとの重複・競合・独自性）

内訳: **独自 4 / 補完 3 / 重複 2 / 競合 3 / 完全重複 2**

| skill | 既存キット相当 | 判定 | 要点 |
|---|---|---|---|
| **triage** | なし | 独自 | Issue の状態機械 + 耐リファクタ AGENT-BRIEF + out-of-scope KB。`setup-matt-pocock-skills` に **hard 依存** |
| **to-issues** | なし | 独自 | plan/PRD を tracer-bullet 縦スライスで独立 Issue 化。**hard 依存** |
| **prototype** | なし | 独自 | 使い捨て試作（logic/UI 分岐 + portable-logic-module）。依存・衝突なし |
| **caveman** | なし | 独自 | トークン圧縮出力モード。⚠️ `personalization.md`（構造化 Markdown 厳守）と**行動衝突** |
| **grill-with-docs** | prompt-patterns / brainstorming | 補完 | CONTEXT.md 用語集 + ADR 規律が net-new。作者の最有力 skill |
| **improve-codebase-architecture** | architect agent / refactor-cleaner | 補完 | 深いモジュール化を deletion-test + before/after HTML レポートで提示。distinctive |
| **zoom-out** | architect / prompt-patterns | 補完(薄) | 7 行のリフレーミング prompt。prompt-patterns に畳める程度 |
| **diagnose** | superpowers:systematic-debugging（常時強制）/ build-fix | 重複 | 「再現ループ先行」6 相規律は鋭いが、バグ起動面で superpowers と競合 |
| **to-prd** | /plan / spec-kit-init | 重複 | 会話文脈→PRD は新しいが計画面で重複。**hard 依存** |
| **tdd** | ⚠️ `/tdd`(commands) / tdd-workflow / tdd-guide / superpowers:TDD | 競合 | **`/tdd` コマンド名が直接衝突**。哲学も相違（キット=80%カバレッジ+E2E / 本家=縦スライス+公開挙動） |
| **handoff** | ⚠️ `/handover` + 既存 `/handoff` skill / strategic-compact | 競合 | **`/handoff` が既存 skill と衝突**、`/handover` と 1 文字違い |
| **setup-matt-pocock-skills** | setup.sh wizard / claude-md-management | 競合 | CLAUDE.md/AGENTS.md を編集 → **キットのマーカー管理領域・doc-size-guard（AGENTS.md 100行 error）と衝突** |
| **grill-me** | prompt-patterns "Grill Mode" / brainstorming（常時強制） | 完全重複 | brainstorming がほぼ同等を常時実行 |
| **write-a-skill** | skill-creator / superpowers:writing-skills | 完全重複 | 既に 2 つの skill 作成ツールが導入済 |

---

## StarterKit との衝突・重複マトリクス（見送りの主因）

| 観点 | 内容 | リスク |
|---|---|---|
| `/tdd` コマンド名 | `commands/tdd.md` が `/tdd` を既に束縛。本家 tdd を入れると名前衝突（解決は last-loaded-wins になり得る） | **高** |
| `/handoff` コマンド名 | 環境に既存 `/handoff` skill あり、かつキットの `/handover` と 1 文字違い。3 つが乱立 | **中** |
| `superpowers` 常時起動 | `using-superpowers` が作業前に brainstorming / TDD / debugging skill を強制 → `grill-me`/`tdd`/`diagnose` は起動面を奪い合う | **中**（行動衝突）|
| CLAUDE.md/AGENTS.md 所有権 | `setup-matt-pocock-skills` が両ファイルを編集 → キットの `BEGIN/END STARTER-KIT-MANAGED` マーカー管理・`doc-size-guard` hook と衝突 | **中** |
| hard 依存連鎖 | `triage`/`to-issues`/`to-prd` は `setup-matt-pocock-skills` 無しでは非機能。価値の高い Issue 系を採るには最も衝突の大きい setup も連れてくる必要がある | **中** |
| 出力スタイル | `caveman` の持続的圧縮は `personalization.md` の「構造化 Markdown・エグゼクティブ深度」と相反 | 低 |

---

## セキュリティ評価（`security-reviewer` 精査 + 直接確認）

- **総合リスク: 低。リポ内容は vendoring 安全。**
- インストール時・呼び出し時の**自動コード実行・ネットワーク送信・認証情報読取・隠し payload は皆無**。間接プロンプトインジェクション（"ignore previous" / "send to URL" / ".env 読取"）も検出されず。
- `handoff` skill は逆に「秘密情報を redact せよ」と指示（好材料）。同梱スクリプト（`link-skills.sh` / `list-skills.sh` / `block-dangerous-git.sh` / `hitl-loop.template.sh`）はいずれも安全（`eval` なし、ネットワーク・認証情報アクセスなし）。
- **唯一の留意点 = `npx skills@latest`（第三者・unpinned installer）のサプライチェーン**。ゼロトラスト運用では npx を避け、ピン留め commit で導入するか git-clone（固定 ref）+ レビュー後に `link-skills.sh` 実行が望ましい。
- `git-guardrails` の PreToolUse hook は防御的で安全（ただし denylist のため回避可能 = 事故防止用であり対敵制御ではない）。`deprecated/qa` に「レビューなし Issue 起票」指示があるが **plugin 未登録 = 非導入**。

---

## 統合方式 4 案の比較

| 案 | 方式 | 実現性 | キット哲学（PR #65 案B = 疎結合・vendoring なし）適合 |
|---|---|---|---|
| A | `config/plugins.json` に marketplace 追加 | 🚫 **ブロック**（`marketplace.json` 不在。`claude plugin marketplace add` は marketplace.json を要求 — 公式ドキュメントで確認） | — |
| B | SKILL.md をキット `skills/` に vendoring | △ 技術的には可 | ❌ **案 B の真逆**（上流 fork・再同期負債・setup 前提崩壊・personal/deprecated 混入リスク）|
| C | `spec-kit-init` 同型の薄いガイドコマンド | ✅ 容易 | ✅ 一致（疎結合・更新は上流 `npx skills add` に委譲）|
| **D** | **見送り（本レポートのみ残す）** | ✅ 容易 | 中立（責務分界の案内は残せないが、キットへのリスク・依存・保守負債はゼロ）|

---

## 見送り（案 D）を推す理由

1. **重複過多**: 14 中、真に net-new は 4〜5 個。残りはキット既存資産（特に常時起動の `superpowers`）と重複・競合する。全面採用は「同じ作法を二重三重に積む」結果になり、ユーザーを混乱させる。
2. **ネイティブ統合の道が塞がれている**: `marketplace.json` 不在で案 A は不可。案 C を採っても実体導入は第三者 installer 依存となり、キットの信頼モデルに穴を開ける。
3. **コマンド名衝突の実害**: `/tdd`・`/handoff` の衝突は、導入方式に関係なくユーザー環境で発生する設計上の地雷。
4. **最小コスト原則**: 価値の高い 4〜5 skill が欲しいユーザーは、各自 `npx skills@latest add mattpocock/skills` で選択導入すれば足りる。キットが導線を持つ必然性は薄く、保守負債だけが残る。
5. **案 C との比較**: 案 C（薄いガイド）も成立はするが、(a) 第三者 installer をキット導線で推奨する形になる点、(b) 衝突・重複の警告を延々と書く必要がある点、(c) `marketplace.json` 不在という上流都合に縛られる点で、現時点では費用対効果が見合わない。

---

## 将来の再評価トリガー（条件が変われば案 C を再検討）

- 上流 `mattpocock/skills` に `.claude-plugin/marketplace.json` が追加され、`claude plugin install` でのネイティブ・ピン留め導入が可能になったとき（案 A/C の前提が整う）。
- キットが `superpowers` 同梱方針を見直し、process 系 skill の重複が解消されたとき。
- ユーザー需要として「Issue トラッカー triage / 使い捨て prototype / CONTEXT.md+ADR 規律」が具体的に挙がったとき（その場合は該当 skill のみ案 C で薄く導線化）。

---

## このコミットで提供する変更

採用判定が**見送り**のため、**キット本体（`setup.sh` / `config/` / `commands/` / `skills/` / `features/` / `profiles/` / `i18n/`）は一切変更しない**。

含まれる変更:

1. `docs/mattpocock-skills-evaluation.md` 新規（本レポート = 判断記録）
2. `CHANGELOG.md` に評価レポート追加の patch エントリ（`## [0.51.1]`）

含まない:

- 新規コマンド・skill・feature・plugin エントリ（採用しないため）
- `~/.claude/` への副作用（評価は `git clone` した temp ディレクトリと API 参照のみ。グローバル環境への書き込みゼロ）

---

## 次のアクション提案

1. 共同開発者が本 PR をレビューし、**見送り承認 / 案 C への方針転換 / 特定 skill の個別深掘り** を決定。
2. 見送り承認なら本ブランチを merge し、`docs/mattpocock-skills-evaluation.md` を判断記録としてリポに残す（将来の再評価の基点）。
3. 方針転換（案 C 採用）なら、別 PR で `commands/matt-pocock-skills-init.md`（厳選推奨リスト + 衝突警告 + npx サプライチェーン注意 + `/setup-matt-pocock-skills` 必須の明記）を実装。
