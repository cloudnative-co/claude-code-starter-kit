# MDM サイレントインストール機能 設計書

- 日付: 2026-07-16
- ステータス: ドラフト（シンジのレビュー待ち）
- ブランチ: feat/mdm-silent-install
- 対象バージョン: 0.73.0（minor — 新機能）

## 1. 背景・目的

claude-code-starter-kit を MDM（モバイルデバイス管理）経由で組織の管理端末へサイレント配布可能にする。
現状の `--non-interactive` モードは「TTY のある端末でユーザー自身が実行する」前提であり、
MDM 配布に必要な「特権コンテキスト（root/SYSTEM）からの実行」「対象ユーザーのホームへの正しい配備」
「Homebrew 不在端末への対応」「機械可読な成否報告」が欠けている。本機能でこれらを埋める。

## 2. 確定要件（2026-07-16 ヒアリング結果）

| 項目 | 決定 |
|---|---|
| 対象 OS | macOS + Windows |
| 想定 MDM | Intune / Jamf / Iru / VMware Workspace ONE / MobileIron (Ivanti) |
| 配布形態 | スクリプト配布（pkg/.intunewin 化は将来拡張） |
| スコープ | 全部入り: Claude Code 本体 + 前提ツール + キットを 1 スクリプトでゼロタッチ導入 |
| 設定指定 | CLI 引数 > 環境変数 > 管理設定ファイル > 既定値（standard プロファイル） |
| アプローチ | C: 薄い MDM 層（mdm/）+ 本体の最小強化 |
| プロセス | 作成物はすべて（spec 含む）Codex クロスレビューを通す |

## 3. スコープ / 非スコープ

**スコープ:**
- `mdm/install-mdm.sh`（macOS）/ `mdm/install-mdm.ps1`（Windows）: MDM エントリポイント
- `mdm/detect-mdm.sh` / `mdm/detect-mdm.ps1`: インベントリ/検知スクリプト
- 管理設定ファイルの読み込み（allowlist パーサ、eval なし）
- ログ・終了コード・レシートの機械可読契約
- `docs/mdm/README.md` + `README.ja.md`（共通契約 + 製品別デプロイ手順）
- 本体への最小強化（§11）
- 単体テスト + CI 組み込み

**非スコープ（将来拡張 — §17）:**
- .pkg / .intunewin パッケージビルドパイプライン
- Claude Code 本体の組織ポリシー（managed-settings.json）配布 — ガイドで参照のみ
- アンインストール用 MDM ラッパー（既存 `uninstall.sh` の手順をガイドに記載するに留める）
- 全ユーザー一括インストール / ログイン時 LaunchAgent 方式

## 4. アーキテクチャ

### 4.1 ファイル構成

```
mdm/
├── install-mdm.sh      # macOS: root 実行前提のエントリポイント（Bash 3.2 互換必須 — 素の macOS で動くこと）
├── install-mdm.ps1     # Windows: ユーザーコンテキスト実行前提（SYSTEM 検知時は明確なエラー）
├── detect-mdm.sh       # macOS: レシート存在+バージョン判定（Jamf EA / WS1 Sensor 用）
└── detect-mdm.ps1      # Windows: 同上（Intune Remediation 検知用）
docs/mdm/
├── README.md           # 共通契約 + 製品別手順（en）
└── README.ja.md        # 同（ja）
```

### 4.2 責務分離の原則

- **mdm/ 層が担う**: 特権コンテキスト処理・対象ユーザー解決・前提ブートストラップ（CLT/Homebrew/Git for Windows）・
  管理設定読込・ログ・終了コード・レシート
- **本体（install.sh → setup.sh）が担う**: 従来どおりの clone・プロファイル適用・deploy・Claude Code CLI 導入・
  プラグイン導入・update 検出。mdm/ 層は本体を「対象ユーザー権限 + NONINTERACTIVE=1 + 設定環境変数」で呼ぶだけ
- MDM 製品固有の事情はコードに持ち込まず、ドキュメントで吸収する（MDM 非依存契約）

## 5. macOS フロー（install-mdm.sh）

### 5.1 実行フェーズ

```
[R: root フェーズ]
R1 引数/環境変数解析 → 管理設定ファイル読込（§7）→ 設定確定・ログ開始
R2 対象ユーザー解決: KIT_MDM_TARGET_USER > コンソールユーザー自動検出
   （scutil ConsoleUser、フォールバック stat -f%Su /dev/console。root/_mbsetupuser/loginwindow は無効として exit 20）
   ※ root 以外で起動された場合は「ユーザーモード」: 現在ユーザーを対象として R3 の system-wide 導入をスキップ
R3 前提ブートストラップ（§5.2）
   ※ ユーザーモード時（非 root 起動）は CLT/Homebrew の system-wide サイレント導入が不可のため、
     brew も不足前提もない場合は exit 10（不足一覧をログ提示）
[U: ユーザーフェーズ — launchctl asuser <uid> sudo -u <user> -H で降格]
U1 キット取得: git clone（KIT_MDM_GIT_REF でタグ/ブランチ固定可、既定 main）
   既存インストール（manifest あり）なら install.sh の update 検出に乗せる
U2 setup.sh --non-interactive 実行（プロファイル・言語・トグルは環境変数で注入。ENABLE_GHOSTTY は MDM 既定 false）
U3 Claude Code CLI 導入の確認（本体の既存処理を強制有効化 — §11(a)）
[R: 終端フェーズ]
R4 レシート書き出し + 終了コード確定 + ログクローズ
```

### 5.2 前提ツール戦略 ★承認時の提示内容からの変更点

承認時は「git: CLT / node: 公式 pkg / jq: 公式バイナリ」と個別 pkg 導入を提示したが、
キットの必須前提には **公式 pkg 配布が存在しないもの（bash 4+, GNU sed, GNU awk, tmux）** が含まれるため、
個別 pkg 方式では「全部入り」を達成できない。よって以下の段階戦略に変更する:

1. **brew あり** → 何もしない（本体の既存 brew 自動導入が全前提をカバー）
2. **brew なし & KIT_MDM_INSTALL_HOMEBREW=true（既定）** →
   root フェーズで (a) Xcode Command Line Tools をサイレント導入（softwareupdate ラベル方式）、
   (b) Homebrew を公式手順の非対話モードで対象ユーザー所有として導入
   （root で prefix ディレクトリ作成 + chown 対象ユーザー、展開・初期化は対象ユーザー権限で実行）→ 1. へ
3. **brew なし & KIT_MDM_INSTALL_HOMEBREW=false** →
   不足前提の一覧をログに出して exit 10（fleet 側で前提を事前配布する運用向け）

利点: 本体の前提導入ロジック（`lib/prerequisites.sh`）を 100% 再利用でき、mdm/ 層の新規実装が
CLT + Homebrew ブートストラップの 2 点に縮小する。managed Mac への brew 導入は Jamf 等で広く行われている標準手法。

### 5.3 Ghostty / フォント / プラグイン

- Ghostty（GUI アプリ）: MDM 既定 **off**。GUI アプリは MDM ネイティブのアプリ配布が適切。管理設定で on 可
- フォント: 既存の直接 DL フォールバックがユーザー領域（~/Library/Fonts）に入れるためそのまま有効
- プラグイン / Codex Plugin: プロファイル既定に従う（standard/full の既存挙動）

## 6. Windows フロー（install-mdm.ps1）

- **実行コンテキスト**: ユーザーコンテキスト実行を必須とする（Intune Platform Script は
  「ログオンしたユーザーの資格情報でスクリプトを実行: はい」、WS1/Ivanti も user context 指定）。
  SYSTEM で起動された場合は exit 21 + ガイド誘導メッセージ（スケジュールタスク・ハンドオフは将来拡張）
- **既定モード: Git Bash**。WSL2 有効化は再起動を要しサイレント配布に不向きなため、
  `KIT_MDM_WINDOWS_MODE=wsl` は「WSL 事前有効化済み fleet」でのみ選択可（WSL 有効化自体は MDM の機能配布で行う手順をガイドに記載）
- Git for Windows 不在時: winget（利用可能時）→ 公式インストーラ直接 DL（/VERYSILENT /NORESTART、HTTPS + チェックサム検証）の順で導入
- 以降は既存 `install.ps1` の Git Bash モード相当の処理に委譲し、Git Bash 上で install.sh → setup.sh --non-interactive を実行
- Git Bash 環境の前提充足（jq 等の非同梱ツール）は既存 MSYS パスの前提処理を流用し、不足時の導入経路は実装時に実機確認（§15）

## 7. 設定体系

### 7.1 優先順位

**CLI 引数 > 環境変数 > 管理設定ファイル > 既定値（standard プロファイル）**

### 7.2 管理設定ファイル

両 OS 共通の `key="value"` 形式。読み込みは既存 `_safe_source_config()` と同型の
**allowlist パーサ（キー検証 + 値サニタイズ、eval/source なし）** を mdm/ 層に実装（Bash 3.2 互換）。

- macOS: `/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf`
- Windows: `C:\ProgramData\ClaudeCodeStarterKit\mdm-config.conf`

MDM からはファイル配布（Jamf: スクリプト冒頭 heredoc or ファイル配布、Intune: 事前スクリプト等）で設置。

### 7.3 設定キー

**既存キー流用**（そのまま setup.sh へ環境変数で伝搬）: `PROFILE` / `LANGUAGE` / `EDITOR` / `ENABLE_*` 群（wizard/registry.sh の `_CONFIG_KEYS` 準拠）

**MDM 固有キー**（接頭辞 `KIT_MDM_` で名前空間分離）:

| キー | 既定値 | 意味 |
|---|---|---|
| `KIT_MDM_TARGET_USER` | （自動検出） | 対象ユーザーの明示指定 |
| `KIT_MDM_INSTALL_HOMEBREW` | `true` | brew 不在時のブートストラップ可否（macOS） |
| `KIT_MDM_PREREQ_MODE` | `auto` | `auto`=不足分導入 / `skip`=導入せず続行（テスト用） / `fail`=不足があれば exit 10 |
| `KIT_MDM_WINDOWS_MODE` | `gitbash` | `gitbash` / `wsl`（WSL 事前有効化済み fleet のみ） |
| `KIT_MDM_INSTALL_CLAUDE_CLI` | `true` | Claude Code CLI 導入の可否 |
| `KIT_MDM_GIT_REF` | `main` | 配布バージョン固定（タグ/ブランチ）。fleet のバージョン統制用 |
| `KIT_MDM_INSTALL_DIR` | `~/.claude-starter-kit` | clone 先（既存既定と同一） |
| `KIT_MDM_LOG_DIR` | §8.2 の既定 | ログ出力先の上書き |
| `KIT_MDM_DRY_RUN` | `false` | 本体の --dry-run へ伝搬（配布前検証用） |

## 8. MDM 共通契約

### 8.1 終了コード表（固定契約 — 検知スクリプト・ガイドにも記載）

| コード | 意味 |
|---|---|
| 0 | 成功 |
| 10 | 前提ツール導入失敗 / 不足（不足一覧をログに出力） |
| 11 | Homebrew ブートストラップ失敗（macOS） |
| 20 | 対象ユーザー解決失敗（コンソールユーザーなし等） |
| 21 | 非対応の実行コンテキスト（Windows: SYSTEM 実行） |
| 30 | キットセットアップ失敗（setup.sh 非 0 終了） |
| 40 | Claude Code CLI 導入失敗 |
| 50 | 管理設定エラー（不正キー・不正値） |
| 60 | 非対応 OS / OS バージョン |

### 8.2 ログ

- macOS: `/Library/Logs/ClaudeCodeStarterKit/install-<YYYYmmdd-HHMMSS>.log`（ユーザーモード時は `~/Library/Logs/ClaudeCodeStarterKit/`）
- Windows: `C:\ProgramData\ClaudeCodeStarterKit\Logs\install-<timestamp>.log`
- 単一ファイルに root/ユーザー両フェーズを追記（MDM コンソールのログ収集で 1 ファイル回収すれば全容が分かる）
- 秘密情報・トークンは書き込まない。行頭にタイムスタンプ + フェーズタグ（[R1] 等）

### 8.3 レシート（機械可読・インベントリ用）

- macOS: `/Library/Application Support/ClaudeCodeStarterKit/receipt-<user>.json`（ユーザーモード時はユーザー領域）
- Windows: `C:\ProgramData\ClaudeCodeStarterKit\receipt-<user>.json`
- 内容: `{schema_version, kit_version, git_ref, profile, target_user, result, exit_code, timestamp, log_path}`
- 書き出しは jq 非依存（前提導入前の失敗でも書けるよう printf で生成し、値は JSON エスケープ）

### 8.4 検知スクリプト（detect-mdm.*）

- 引数なし: レシート存在 + `result=="success"` で exit 0 / それ以外 exit 1（Intune Remediation・Jamf Smart Group 判定用）
- 引数 `--min-version X.Y.Z`: レシートの kit_version と比較し、古ければ exit 1（再実行トリガー用）
- レシートは root モード / ユーザーモードの両配置（/Library と ~/Library、ProgramData と %LOCALAPPDATA% 相当）を探索する
- 標準出力にバージョン等の 1 行サマリー（Jamf EA の `<result>` 形式はガイドに記載）

### 8.5 冪等性・更新チャネル

- 何度実行しても安全。既存インストール検出時は本体の update パス（`setup.sh --update`）へ
- MDM のポリシー定期実行（例: 週次）= そのまま更新チャネルになる
- 全外部ダウンロードにタイムアウト（`_run_with_timeout` 流用 or curl `--max-time`）。
  スクリプト全体の目安所要時間（初回 5〜15 分、brew ブートストラップ込みは +数分）をガイドに記載し、MDM 側タイムアウト設定の推奨値を示す

## 9. セキュリティ設計

- ダウンロードは HTTPS の公式ソース限定（claude.ai / brew.sh / git-scm.com / Apple softwareupdate）。
  ハッシュ/署名検証が提供されるものは検証（Git for Windows: 公式チェックサム、pkg 類: `pkgutil --check-signature` / Authenticode）
- root で実行するのは R1〜R3 と R4 のみに最小化。キット本体・Claude Code CLI・brew 操作はユーザー権限
- 管理設定は allowlist パーサのみ（`source` / `eval` 禁止 — 既存 `_safe_source_config()` と同水準）。
  root が読むファイルとして、パーミッション検証（root 所有・group/other 書込不可でなければ exit 50）を行う
- ログ・レシートのディレクトリは root 所有 755 / ファイル 644（秘密情報を含まないため読み取りは許容）
- 対象ユーザーへの降格は `launchctl asuser <uid> sudo -u <user> -H` で環境を正しく切り替え、root の環境変数を持ち込まない（許可リストの設定変数のみ明示的に伝搬）

## 10. エラーハンドリング方針

- `set -euo pipefail`（既存規約踏襲）+ フェーズ境界で明示的な終了コードマッピング
- 部分失敗の扱い: Claude CLI 導入失敗（40）はキット配備成功後でも失敗として報告（全部入りが契約のため）。
  ただしレシートに `partial: ["claude_cli"]` を記録し、検知スクリプトで区別可能にする
- 失敗時もレシートは必ず書く（result=failure + exit_code）— MDM 側で「未実行」と「実行して失敗」を区別するため

## 11. 本体への変更（最小強化）

1. **(a) 非対話モードでの Claude CLI 導入確実化**: 現行の `_need_claude_cli_install` / `_install_claude_cli` の
   呼び出し条件を実装時に確認し、非対話でスキップ・プロンプト待ちになる経路があれば
   環境変数（例: `KIT_FORCE_CLAUDE_CLI_INSTALL=1`）で強制有効化できるようにする
2. **(b) 判明済みの TTY ガード**は fail-closed を確認済み（setup.sh:225 / lib/prerequisites.sh:781 — read 失敗時 "n"）。
   実装時の非対話網羅テストで追加の TTY/brew 前提箇所が見つかった場合のみ最小修正
3. 上記以外は本体に手を入れない

## 12. テスト計画

- `tests/unit/test-mdm-config.sh`: 管理設定パーサ（不正キー拒否・値サニタイズ・優先順位・パーミッション検証）
- `tests/unit/test-mdm-install.sh`: 引数解析・対象ユーザー解決（scutil/stat をモック）・終了コード・レシート生成（JSON 妥当性を jq で検証）
- `tests/unit/test-mdm-detect.sh`: 検知スクリプトの exit code / --min-version 比較
- `install-mdm.ps1` / `detect-mdm.ps1`: 最低限の構文検証（CI に PowerShell がある場合。ない場合の方式は実装時に決定 — §15）
- シナリオ: Linux CI 上で `KIT_MDM_PREREQ_MODE=skip` + sudo による降格シミュレートの非対話スモーク
- shellcheck: `mdm/*.sh` を CI の対象 glob（`.github/workflows/shellcheck.yml`）と CLAUDE.md 記載コマンドに追加
- 実機（macOS）: ユーザーモード + root モードの手動確認手順を PR に記載

## 13. ドキュメント計画

- `docs/mdm/README.md`（en）/ `README.ja.md`（ja）:
  共通契約（設定キー・終了コード・ログ/レシートパス・タイムアウト目安）+
  製品別手順: Jamf（Policy + Script、EA 例）/ Intune（Platform Script 設定、Remediation 検知）/
  Workspace ONE（Scripts & Sensors）/ Ivanti / 汎用（Iru を含むその他 MDM 向け: 「root でスクリプトを 1 本実行できること」だけを要求）
- ルート `README.md` に MDM 配布セクションを追加しリンク
- 製品固有記述は公式ドキュメントで確認できた範囲のみ記載し、未検証事項は「要検証」と明記（正確性原則）

## 14. バージョニング・CHANGELOG

- **0.73.0**（minor: 新機能）。`CHANGELOG.md` に `## [0.73.0] - 2026-07-XX` でユーザー可視の変更を記載
- `mdm/` はキットの deploy 対象ではない（`~/.claude/` に配布しない）ため、manifest/snapshot/update 機構への影響なし。
  `_CONFIG_KEYS` にも追加しない（KIT_MDM_* はラッパー層で完結し、ユーザー毎の保存設定には含めない）

## 15. 実装時確認リスト（未検証事項 — 着手時に一次情報で確認）

- [ ] Claude Code 公式インストーラ（install.sh / install.ps1）の現行仕様を docs.anthropic.com で確認（既存 setup.sh の流用可否）
- [ ] Xcode CLT サイレント導入（softwareupdate ラベル方式）が現行 macOS で動作するか
- [ ] Homebrew 公式の非対話インストール手順（NONINTERACTIVE=1）と、root から対象ユーザー所有で導入する際の推奨手順
- [ ] Intune Platform Script の「ログオンユーザー資格情報で実行」の正確な仕様・制約（64bit 実行設定含む）
- [ ] winget の SYSTEM/ユーザーコンテキスト可用性、Git for Windows のサイレントフラグとチェックサム提供方式
- [ ] Git Bash 同梱ツールの実態（GNU sed/awk は同梱、jq は非同梱の想定 — 実機確認）
- [ ] Workspace ONE / Ivanti のスクリプト配布・Sensor 仕様（公式 Doc で確認できた範囲を記載）
- [ ] 「Iru」の製品仕様は一次情報未確認 — 確認できるまで汎用手順の対象として扱う
- [ ] setup.sh 非対話パスの Claude CLI 導入条件（§11(a)）

## 16. プロセス要件

- 本機能の**全コミット（この spec 含む）**を `codex exec review --model gpt-5.6-sol` でクロスレビューする
- レビュー結果は `<メインリポジトリ>/.review/codex/mdm-<sha>.md` に保存し、指摘の 採用 / 裁定 / 却下 を記録
- 同一箇所のレビュー往復は 2 回まで。収束しない場合はシンジへエスカレーション
- 実装は superpowers:writing-plans → TDD（テスト先行）で進める

## 17. 将来拡張（明示的に今回やらないこと）

- .pkg（productbuild + 署名/公証）/ .intunewin ビルドパイプライン
- Windows SYSTEM 実行からのスケジュールタスク・ハンドオフ
- 全ユーザー一括 / ログイン時 LaunchAgent・Active Setup 方式
- Claude Code の managed-settings.json 配布テンプレート
- アンインストール MDM ラッパー・レポート集約（fleet ダッシュボード）
