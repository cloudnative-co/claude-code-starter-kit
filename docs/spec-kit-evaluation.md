# GitHub Spec Kit 評価レポート (StarterKit 統合可否)

**評価日**: 2026-05-20
**対象**: GitHub Spec Kit `v0.8.11` (commit `5301b34`) + Claude Code 統合
**評価環境**: macOS Darwin 25.5.0 / Claude Code 2.1.144 / uv 0.9.26 / Python 3.14.3
**評価成果物**: 実プロジェクト 1 本を `constitution → specify → clarify → plan → tasks` まで走破
**ステータス**: ドラフト（共同開発者のレビュー待ち）

---

## サマリー（3 行）

- Spec Kit はグローバル `~/.claude/` を **一切汚染しない**。すべて `<project>/.claude/skills/` と `.specify/` に展開され、StarterKit と **直接衝突しない**（差分実測ゼロ）。
- 5 コマンド体験は総合 **★4.6/5.0**。特に `/speckit-clarify`（10 カテゴリ × 最大 5 問 × Recommended 提示）と `/speckit-tasks`（`[P]` 並列マーカー + `[USx]` ストーリー紐付け + ファイルパス必須）は StarterKit にも転用したい完成度。
- 採用判定: **条件付き採用（案 B: プリセット/拡張として隔離）**。フル統合は Python/uv ランタイム依存と Spec Kit のリリース追従義務を背負うコストが大きい。**`commands/spec-kit-init.md` 1 ファイル + CLAUDE.md 数行追加** で 1.25 人日相当の薄い導線を出す形が最もコスト対効果が高い。

---

## 採用判定

- [ ] そのまま採用
- [x] **条件付き採用（案 B: プリセット/拡張として隔離）**
- [ ] 見送り

### 採用の条件

1. `specify-cli` 本体は StarterKit がインストールしない（ユーザーの `uv tool` に委ねる）。
2. StarterKit に `/spec-kit-init` を 1 ファイル追加し、specify-cli の install / `specify init --integration claude` / cn-memory との責務分離をドキュメント化する。
3. CLAUDE.md (kit-managed セクション) に Spec Kit の `<!-- SPECKIT START -->` マーカーと並存する旨を 2–3 行で記載する。
4. Spec Kit v0.10（git extension opt-in 化）/ v1.0 のリリースが出たタイミングで再評価する。

---

## 各コマンドの実評価

| コマンド | 品質 (1-5) | 良かった点 | 物足りなかった点 |
|---|---|---|---|
| `/speckit-constitution` | ★★★★☆ (4) | SemVer ベースの版上げルール / Sync Impact Report (HTML コメント) による差分明示 / template/spec/tasks への伝播チェック / `NON-NEGOTIABLE` マーカーで原則の硬度を明示できる | 単一プロジェクト前提で、組織横断のメタ憲法（cn-memory が担う領域）との分離方針はテンプレに無い。`TODO(FIELD)` を残したまま PR がマージされる運用リスクへの note も弱い |
| `/speckit-specify` | ★★★★★ (5) | What/Why に絞る規律（`Avoid HOW to implement`）/ User Story の P1/P2/P3 + Independent Test 構造 / **NEEDS CLARIFICATION 最大 3 個ルール** で発散防止 / Success Criteria の **technology-agnostic** 強制（正しい例まで提示）/ `checklists/requirements.md` 自動生成 | sequential 番号 (001, 002, …) は大規模リポで衝突しやすい（解決ロジック自体は存在）。技術詳細は specify では書けず、自然に plan/contracts に流れる設計の意図がテンプレ内では明示されにくい |
| `/speckit-clarify` | ★★★★★ (5) | **10 カテゴリのタクソノミー** に基づく構造化スキャン / 最大 5 問 1 問ずつ / **Recommended オプションを reasoning 付きで先頭提示** / `## Clarifications / ### Session YYYY-MM-DD` で履歴を残し atomic 統合 | 「Recommended」の妥当性は LLM 品質依存。専門家向けに自明な質問になることがある。`$ARGUMENTS` での領域指定の活用例が乏しい |
| `/speckit-plan` | ★★★★☆ (4) | **Constitution Check ゲート** が plan の中核 / Phase 0 (research.md) と Phase 1 (data-model/contracts/quickstart) の分離 / **Complexity Tracking で constitution 違反を justify する仕組み** / contracts/ を source of truth として zod schema を生成する流れ | テンプレの "Project Structure" が `single / web / mobile` の 3 オプションプリセットで、Lambda + Terraform 系インフラ構造には適合度が低く手直しが要る。research.md の Decision/Rationale/Alternatives 形式は ADR と被るが関係性は未定義 |
| `/speckit-tasks` | ★★★★★ (5) | タスク粒度が「LLM 1 タスク = 1 PR」に合う / `[P]` 並列 + `[USx]` 紐付け + ファイルパス必須 + チェックリスト形式 / **Phase 1 Setup / Phase 2 Foundational ブロッカー / Phase 3+ Story 順** で MVP-first が自然に強制される / Constitution III の test-first を Tests Phase で物理的に組み込める | 56 タスクは中規模機能としてはやや多い。タスク間の `depends on T028, T036, ...` は手書きで自動依存グラフではない。`/speckit-implement` の API コスト試算が必要（評価対象外） |

**総合**: 5 コマンド平均 **4.6 / 5.0**。What → Why → How → Tasks の流れが明確に分節され、各ステージの成果物が次のステージの入力として強くタイプ付けされている。

---

## StarterKit との衝突マトリクス

**結論先出し: 直接衝突は検出されず**。グローバル `~/.claude/` への Spec Kit 由来書き込みは Phase 3 で実測 **ゼロ**。スコープが綺麗に分離している。

| パス | StarterKit | Spec Kit | 衝突リスク | 緩和策案 |
|---|---|---|---|---|
| `~/.claude/commands/*.md` | 18 件 (plan / research / tdd / code-review / build-fix / update-kit ほか) | 書き込まない | **なし** | StarterKit は `~/.claude/` (グローバル)、Spec Kit は `<project>/.claude/` (ローカル) でスコープが完全に違う |
| `~/.claude/skills/*` | 12 件 (backend-patterns / security-review / tdd-workflow ほか) | 書き込まない | **なし** | 同上。名前空間も `speckit-*` 接頭辞で完全分離 |
| `<project>/.claude/skills/speckit-*` | 書き込まない | 14 件 | **なし** | StarterKit はプロジェクトローカルには触らない |
| `.specify/` 全般 | 完全に未使用 | プロジェクトメタ全体 | **なし** | StarterKit のテンプレ・hook・コマンドはこの prefix を一切参照しない |
| `<project>/CLAUDE.md` のマーカー | `<!-- BEGIN STARTER-KIT-MANAGED -->` … `<!-- END STARTER-KIT-MANAGED -->` | `<!-- SPECKIT START -->` … `<!-- SPECKIT END -->` | **なし** | マーカー名が完全に異なる。同一ファイルに両ブロック共存可能 |
| `~/.claude/CLAUDE.md` (グローバル) | StarterKit のみが管理 | 関与しない | **なし** | Spec Kit はプロジェクトローカル `CLAUDE.md` にのみ書き込む |
| `.specify/scripts/bash/*.sh` | 未使用 | 5 ファイル | **低** | deny rule 抵触なし (`rm -rf` / `curl` / `wget` / `sudo` / `git push --force` を一切使わない)。唯一の git 操作は `git checkout -b` と参照系のみ |
| `~/.claude/.starter-kit-manifest.json` | StarterKit のみ | 関与しない | **なし** | Spec Kit の manifest は `<project>/.specify/integrations/claude.manifest.json` で別物 |
| グローバル `~/.claude/` 書き込み | StarterKit が全面管理 | **ゼロ書き込み**（実測） | **なし** | 最も重要な事実 |

### 追加観察

- StarterKit の `/plan` (汎用設計プラン) と Spec Kit の `/speckit-plan` (SDD plan) は **両方共存** する状態になる。意味的に近いが名前は別なので機能としては衝突しない。CLAUDE.md で 1 行説明すれば足りる。
- Spec Kit の bash スクリプトに `rm -rf` / `curl` / `wget` / `sudo` / `git push --force` などの危険操作は **一切なし**。StarterKit の `safety-net` (`cc-safety-net`) と `tmux-hooks` 等の hook とも実害は出ない見込み。`safety-net` が `git checkout -b` を厳格モードで警告する可能性のみ要観察。
- **タスク仕様書にあった `/speckit.constitution` 形式 (ドット区切り) は v0.7 以前**。v0.8.x からは `/speckit-constitution`（ハイフン区切り）に変更されている。社内ドキュメントを更新する際は注意。

---

## 推奨統合方針 — 3 案の比較

### 案 A: フル統合（StarterKit profile に組み込み）

`features/spec-kit/` を新設、`profiles/standard` 以上で `ENABLE_SPEC_KIT=true`、`setup.sh` 内で `uv tool install specify-cli` と `specify init --integration claude --script sh` を自動実行。

| 項目 | 内容 |
|---|---|
| メリット | 1 コマンドで SDD ワークフロー込みのフル環境が手に入る |
| リスク | Python 3.10+ / uv を StarterKit のプリリクに追加 → WSL/MSYS/Linux 各ディストリでの検証コスト倍増。Spec Kit v0.10 (git extension opt-in) / v0.6+ (bundled assets default) / v0.8 (コマンド命名変更) などブレイキングチェンジへの追従義務 |
| 工数 | 約 **4 人日**（feature 新設 + uv 自動 install + setup.sh 改修 + update path 検証） |

### 案 B: プリセット/拡張として隔離（推奨）

StarterKit に `/spec-kit-init` を 1 ファイル追加。`specify-cli` の `uv tool install` 案内、`specify init --integration claude` の実行手順、コマンド命名がハイフン区切りである注意、cn-memory との責務分離方針の 4 ブロック構成。

| 項目 | 内容 |
|---|---|
| メリット | コア依存（bash/jq/curl/git/gh/node/tmux）に Python ランタイムを加えない / Spec Kit のリリース追従は `uv tool upgrade` に委譲 / 使う人だけ使う設計、SDD を選好しないユーザーへの影響ゼロ |
| リスク | Spec Kit を「StarterKit の機能」として認識しにくい（外部ツール感が残る）→ CLAUDE.md とドキュメントで吸収可能 / `/spec-kit-init` が陳腐化する可能性 → 年次レビューで追従 |
| 工数 | 約 **1.25 人日**（このコミットで初期実装は提供済み） |

### 案 C: 方法論のみ吸収（Spec Kit CLI を導入しない）

Constitution Check ゲート、User Story P1/P2/P3 + Independent Test、`[P]` 並列マーカー、Sync Impact Report などの方法論を StarterKit の `commands/plan.md`, `commands/research.md`, `commands/tdd.md` 等に手書きで吸収。

| 項目 | 内容 |
|---|---|
| メリット | 外部依存ゼロ / StarterKit 設計と完全に整合する (Bash 3.2 互換、グローバル設置) |
| リスク | SKILL.md の継続更新（Spec Kit 側が頻繁に改善）に手作業で追従する義務 / `/speckit-clarify` の Recommended UX を短いコマンドで再現しきれず品質劣化 / 知財/ライセンス引用範囲を都度判断する手間 |
| 工数 | 初期 **5.5 人日** + 年次メンテ |

### 推奨案と理由

**案 B**。

1. **コスト対効果**: 約 1.25 人日で SDD ワークフローの恩恵を享受できる。案 A の 4 日 / 案 C の 5.5 日 + 継続コストと比べ圧倒的に軽量。
2. **依存スタックの保護**: StarterKit が Bash + GNU 系に限定されている依存設計は、WSL / MSYS / 各 Linux ディストリでの再現性確保の根拠。Python ランタイムを足すと検証マトリクスが倍増する。
3. **進化速度の整合**: Spec Kit は v0.8.11 時点でも頻繁にバージョンアップしている。フル統合するとリリース毎の追従義務が発生する。隔離方式なら specify-cli の `uv tool upgrade` に任せられる。

cn-memory との責務分離は **明示的分離** を採用: cn-memory = 個人プロファイル＋組織横断の標準（ゼロトラスト原則、TS strict、Okta SSO 等）、Spec Kit constitution = プロジェクト固有の原則・SLA・コンプライアンス。両方をロードし、**プロジェクト固有 > 組織標準** を CLAUDE.md kit-managed セクションに 2 行で明記。

---

## このコミットで提供する変更

このコミットは「案 B の最小実装」を提案として含める。共同開発者のレビュー後に：

- 修正・拡張する → このブランチに follow-up コミットを足す
- 案 A または案 C を選ぶ → 別ブランチで作り直し、本ブランチは close
- 見送り → このブランチを close、`docs/spec-kit-evaluation.md` をリポに残すか否か議論

含まれる変更:

1. `commands/spec-kit-init.md` 新規（このコマンドのソース）
2. `docs/spec-kit-evaluation.md` 新規（このレポート）
3. `i18n/en/CLAUDE.md.base` と `i18n/ja/CLAUDE.md.base` への 2–3 行追加（Spec Kit との並存規約）
4. `CHANGELOG.md` に `## [0.51.0] - 2026-05-20` エントリ追加

含まない（採用が決まったあとに別 PR）:

- `features/spec-kit/` 新設（案 A の領域）
- `setup.sh` への uv 自動インストール（案 A の領域）
- 既存 `commands/plan.md` 等の改修（案 C の領域）

---

## 次のアクション提案

1. 共同開発者が本 PR をレビューし、案 B 採用 / 修正要求 / 別案で進めるかを決定
2. 採用なら本ブランチを merge
3. Spec Kit v0.10 リリース監視を `features/feature-recommendation/` の枠組みで自動化するか別 issue で検討（option）

---

## ロールバック手順（採用見送り時）

ローカル環境への副作用は `specify-cli` のインストールと sandbox ディレクトリのみ。本 PR を close すれば StarterKit リポへの影響はゼロ。個人環境を片付ける場合のみ：

```bash
# specify-cli を削除（共同開発者環境では実行不要）
uv tool uninstall specify-cli

# 評価用 sandbox を削除
rm -rf ~/sandbox/spec-kit-eval
```

`~/.claude/` への副作用は実測ゼロのため、復元は不要。
