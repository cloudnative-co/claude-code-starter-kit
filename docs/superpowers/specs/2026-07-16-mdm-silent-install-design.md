# MDM サイレントインストール機能 設計書

- 日付: 2026-07-16
- ステータス: ドラフト v2（Codex クロスレビュー eabbae6 の指摘15件を反映済み・シンジのレビュー待ち）
- ブランチ: feat/mdm-silent-install
- 対象バージョン: 0.73.0（minor — 新機能）

## 1. 背景・目的

claude-code-starter-kit を MDM（モバイルデバイス管理）経由で組織の管理端末へサイレント配布可能にする。
現状の `--non-interactive` モードは「TTY のある端末でユーザー自身が実行する」前提であり、
MDM 配布に必要な「特権コンテキスト（root/SYSTEM）からの実行」「対象ユーザーのホームへの正しい配備」
「Homebrew 不在端末への対応」「機械可読な成否報告」「バージョンピン留めと更新チャネル」が欠けている。本機能でこれらを埋める。

## 2. 確定要件（2026-07-16 ヒアリング結果）

| 項目 | 決定 |
|---|---|
| 対象 OS | macOS + Windows |
| 想定 MDM | Intune / Jamf / VMware Workspace ONE / MobileIron (Ivanti) を製品別に検証。Iru は一次情報未確認のため汎用契約扱い（§2.1） |
| 配布形態 | スクリプト配布（pkg/.intunewin 化は将来拡張） |
| スコープ | 全部入り: Claude Code 本体 + 前提ツール + キットを 1 スクリプトでゼロタッチ導入 |
| 設定指定 | CLI 引数 > 環境変数 > 管理設定ファイル > 既定値（standard プロファイル） |
| アプローチ | C: 薄い MDM 層（mdm/）+ 本体の最小強化 |
| プロセス | 作成物はすべて（spec 含む）Codex クロスレビューを通す |

### 2.1 「対応 MDM」の確度区分（Codex Low 指摘を反映）

確定対象を確度で区分し、未検証製品を「確定」と誤記しない:
- **一次情報で手順検証する（製品別ガイドを書く）**: Intune / Jamf / Workspace ONE / Ivanti
- **汎用 MDM 契約のみ（製品固有ガイドなし）**: Iru ほか — 「root/管理者権限でスクリプトを 1 本実行できる」ことだけを要求する契約に格下げ。
  Iru は製品仕様・正式名称を一次情報で確認できるまで固有手順を書かない

## 3. スコープ / 非スコープ

**スコープ:** mdm/ ラッパー（install/detect ×2 OS）、管理設定の型検証パーサ、ログ・終了コード・レシートの機械可読契約、
ダウンロード信頼固定、特権降格の環境分離契約、docs/mdm、本体への最小強化（§11）、単体テスト + Bash 3.2 CI。

**非スコープ（将来拡張 — §17）:** pkg/.intunewin ビルドパイプライン、managed-settings.json 配布、
アンインストール MDM ラッパー、全ユーザー一括/ログイン時 LaunchAgent 方式、Windows SYSTEM からのユーザーコンテキストへのハンドオフ。

## 4. アーキテクチャ

### 4.1 ファイル構成

```
mdm/
├── install-mdm.sh      # macOS: root 実行前提のエントリポイント（Bash 3.2 互換必須 — 素の macOS /bin/bash で動くこと）
├── install-mdm.ps1     # Windows: ユーザーコンテキスト実行前提（SYSTEM 検知時は exit 21）
├── detect-mdm.sh       # macOS: 対象ユーザー・最新・実体照合つきレシート判定
├── detect-mdm.ps1      # Windows: 同上
└── lib-mdm-config.sh   # 管理設定の型検証パーサ（Bash 3.2 互換・install/detect が source）
docs/mdm/
├── README.md           # 共通契約 + 製品別手順（en）
└── README.ja.md        # 同（ja）
```

### 4.2 責務分離の原則

- **mdm/ 層が担う**: 特権コンテキスト処理・対象ユーザー/ホーム検証・環境分離降格・前提ブートストラップ・
  管理設定の型検証・ダウンロード信頼固定・ログ・終了コード・レシート・ref ピン留め
- **本体（install.sh → setup.sh）が担う**: 従来どおりの clone・プロファイル適用・deploy・Claude Code CLI 導入・update 検出。
  mdm/ 層は本体を「対象ユーザー権限 + 環境分離 + 設定環境変数」で呼ぶ
- MDM 製品固有の事情はコードに持ち込まず、ドキュメントで吸収する（MDM 非依存契約）

## 5. macOS フロー（install-mdm.sh）

### 5.1 実行フェーズ

```
[R: root フェーズ]
R1 引数/環境変数解析 → 管理設定ファイル読込(§7,型検証) → 設定確定・ログ開始
R2 対象ユーザー・ホーム解決と検証(§5.4)
R3 前提ブートストラップ(§5.2)
[U: ユーザーフェーズ — 環境分離降格(§5.3)]
U1 キット取得: KIT_MDM_GIT_REF を明示 fetch+checkout でピン留め(§5.5)。既存インストールなら update パス
U2 setup.sh --non-interactive 実行(プロファイル・言語・トグルは検証済み設定を環境変数で注入。ENABLE_GHOSTTY 既定 false)
U3 Claude Code CLI 導入の確認(本体の既存処理を強制有効化 — §11(a))
[R: 終端フェーズ]
R4 レシート書き出し(§8.3) + 終了コード確定 + ログクローズ
※ 非 root 起動時は「ユーザーモード」: R2 は現在ユーザーで自明成立、R3 の system-wide 導入は不可のため
  brew も不足前提もなければ exit 10(不足一覧をログ提示)。降格(R5.3)はスキップ
```

### 5.2 前提ツール戦略

キットの必須前提には公式 pkg 配布が存在しないもの（bash 4+, GNU sed, GNU awk, tmux）が含まれるため、Homebrew を核に据える:

1. **brew あり** → 何もしない（本体の既存 brew 自動導入が全前提をカバー）
2. **brew なし & KIT_MDM_INSTALL_HOMEBREW=true（既定）** → 前提ブートストラップ（下記）→ 1. へ
3. **brew なし & KIT_MDM_INSTALL_HOMEBREW=false** → 不足前提の一覧をログに出して exit 10

**前提ブートストラップの精緻化（Codex High/Medium 指摘を反映）:**
- **Xcode CLT**: `softwareupdate` ラベル方式は Apple 公式手順として文書化されていない（公式は `xcode-select --install` が GUI を要求）。
  よって **第一選択は「MDM による CLT の pkg 事前配布」**とし、ガイドに手順を記載。
  softwareupdate ラベル方式（`touch .../.com.apple.dt.CommandLineTools.installondemand.in-progress` + `softwareupdate -i <label>`）は
  **非公式フォールバック**として実装するが、既定では CLT 不在時に「CLT を MDM 配布せよ」と exit 10 し、
  `KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true` を明示したときのみ非公式手法を試みる（前提の妥当性を利用者判断に委ねる）
- **Homebrew**: 公式 `.pkg` インストーラ + `HOMEBREW_PKG_USER` を第一選択とする（Homebrew 公式ドキュメント準拠、
  出典: https://docs.brew.sh/Installation ）。prefix の手作業作成 + chown 方式は権限境界が曖昧なため撤回。
  Homebrew は multi-user 共有を公式非対応とするため、対象ユーザー単独所有として導入する

利点: 本体の前提導入ロジック（`lib/prerequisites.sh`）を 100% 再利用でき、mdm/ 層は CLT 手配 + Homebrew 公式 pkg 導入の
オーケストレーションに縮小する。

### 5.3 特権降格の環境分離契約（Codex High 指摘を反映）

「root 環境を持ち込まない」を具体的契約として定義する。降格は次の形を必須とする:

```
launchctl asuser <uid> sudo -u <user> -H \
  /usr/bin/env -i \
  HOME=<canonical_home> USER=<user> LOGNAME=<user> \
  PATH=<固定 PATH: brew bin + /usr/bin:/bin:/usr/sbin:/sbin> \
  LANG=<設定 or 既定> \
  <許可リストの KIT_* / ENABLE_* / PROFILE / LANGUAGE / EDITOR を明示列挙> \
  /bin/bash <script> <args...>
```

- `env -i` で root の環境変数を一切継承しない。必要な変数だけを明示的に再設定
- proxy 設定（HTTP(S)_PROXY 等）を fleet で使う場合は許可リストに含める（管理設定キーで制御）
- 引数はスペース連結せず配列/明示引数で渡す（word splitting・注入防止）

### 5.4 対象ユーザー・ホーム検証（Codex High 指摘を反映）

予約名拒否だけでは不十分。R2 では以下を検証し、いずれか失敗で exit 20:
- `KIT_MDM_TARGET_USER` > コンソールユーザー（`scutil` の ConsoleUser、フォールバック `stat -f%Su /dev/console`）
- 解決したユーザーが実在するローカルアカウントであること（`dscl . -read /Users/<user>` 成功）
- UID が通常ユーザー範囲（>= 501）であること（システムアカウント・_mbsetupuser・root・loginwindow を除外）
- ホームディレクトリが `dscl` の NFSHomeDirectory と一致し、実在し、**所有者が対象ユーザー**であること
- ホームパスが symlink でないこと（`-L` 検査）、canonical 化（`cd + pwd -P`）した絶対パスを以降で使用
- root による chown・clone 先がこの canonical home 配下に限定されることを保証

### 5.5 バージョンピン留め（Codex High 指摘を反映）

既存 `install.sh`/`auto-update.sh` は `git pull --ff-only` のみで ref を切り替えない（実装ギャップ）。
mdm/ 層は `KIT_MDM_GIT_REF` を必ず適用する:
- 新規: `git clone` 後 `git fetch origin <ref> && git checkout --detach <ref>`（タグ/ブランチ/SHA を明示チェックアウト）
- 既存: `git fetch origin <ref> && git checkout --detach <ref>`（追跡ブランチの pull ではなく ref へ切替。rollback・タグ移動に追従）
- checkout 後の実際の HEAD SHA をレシートに記録（レシートと実体の乖離を防ぐ）
- ref 切替が本体 update 検出と整合するよう、§11(c) で本体側の受け入れを確認

### 5.6 Ghostty / フォント / プラグイン

- Ghostty（GUI アプリ）: MDM 既定 **off**（GUI アプリは MDM ネイティブのアプリ配布が適切）。管理設定で on 可
- フォント: 既存の直接 DL フォールバック（~/Library/Fonts）をそのまま利用
- プラグイン / Codex Plugin: プロファイル既定に従う

## 6. Windows フロー（install-mdm.ps1）

### 6.1 実行コンテキストと書込先の両立（Codex High 指摘を反映）

- **ユーザーコンテキスト実行を必須**とする（Intune Platform Script「ログオンユーザーの資格情報で実行: はい」等）。
  SYSTEM 起動時は exit 21 + ガイド誘導
- **書込先はユーザーが書ける場所に統一**: ログ/レシートは `%LOCALAPPDATA%\ClaudeCodeStarterKit\`（ユーザー領域）。
  `C:\ProgramData\...` は標準ユーザーが書けないため撤回。管理設定ファイルの読み取り元は ProgramData（配布は MDM が管理者権限で設置）で可
- **machine-wide 前提導入は user context では不可**なので、Git for Windows 等が管理者権限を要する場合は
  「MDM で事前配布」を第一選択にし、winget のユーザースコープ導入が可能な範囲のみ自動化。
  導入不能時は不足一覧をログに出して exit 10（ゼロタッチを偽装しない）

### 6.2 モードと前提

- **既定モード: Git Bash**。WSL2 有効化は再起動を要しサイレント配布に不向きなため、
  `KIT_MDM_WINDOWS_MODE=wsl` は「WSL 事前有効化済み fleet」でのみ選択可（WSL 有効化は MDM の機能配布で行う手順をガイドに記載）
- Git for Windows 不在時: winget（ユーザースコープ利用可能時）→ 公式インストーラ（/VERYSILENT /NORESTART、
  HTTPS + 公式チェックサムを別経路で照合、§9）の順。管理者権限が要る導入は §6.1 のとおり事前配布に委ねる
- 以降は既存 `install.ps1` の Git Bash モード相当に委譲。Git Bash 同梱ツールの実態（GNU sed/awk 同梱、jq 非同梱の想定）は実機確認（§15）

## 7. 設定体系

### 7.1 優先順位

**CLI 引数 > 環境変数 > 管理設定ファイル > 既定値（standard プロファイル）**

### 7.2 管理設定ファイルと型検証パーサ（Codex Medium 指摘を反映）

既存 `_safe_source_config()` は「未知キーを無視・値を型別検証しない」ため、MDM 用途にはそのまま流用しない。
`lib-mdm-config.sh` に **型検証パーサ**を新規実装（Bash 3.2 互換、`source`/`eval` 禁止）:
- 未知キーは無視ではなく **警告ログ + 記録**（設定ミスの早期発見）
- 値は型別に検証し、**不正値は加工（サニタイズ）せず exit 50**:
  - boolean: `true|false|1|0|yes|no|on|off` のみ
  - enum（PROFILE 等）: 許可値集合のみ（minimal|standard|full）
  - git ref（KIT_MDM_GIT_REF）: `[A-Za-z0-9._/-]+` かつ `..` を含まない
  - username（KIT_MDM_TARGET_USER）: OS のユーザー名文字種のみ
  - path（KIT_MDM_INSTALL_DIR/LOG_DIR）: 絶対パスかつ §5.4 の canonical home 配下（install dir）/ 許可プレフィックス配下（log dir）

- 配置: macOS `/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf`、
  Windows `C:\ProgramData\ClaudeCodeStarterKit\mdm-config.conf`
- 読み取り前に §9 のパーミッション/所有者/symlink 検証を行う

### 7.3 設定キー

**既存キー流用**（検証後 setup.sh へ環境変数で伝搬）: `PROFILE` / `LANGUAGE` / `EDITOR` / `ENABLE_*` 群

**MDM 固有キー**（接頭辞 `KIT_MDM_`）:

| キー | 既定値 | 意味 |
|---|---|---|
| `KIT_MDM_TARGET_USER` | （自動検出・検証あり §5.4） | 対象ユーザーの明示指定 |
| `KIT_MDM_INSTALL_HOMEBREW` | `true` | brew 不在時の公式 pkg ブートストラップ可否（macOS） |
| `KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE` | `false` | CLT の非公式 softwareupdate 導入を許可（既定は pkg 事前配布を要求） |
| `KIT_MDM_PREREQ_MODE` | `auto` | `auto` / `skip`（テスト用） / `fail`（不足で exit 10） |
| `KIT_MDM_WINDOWS_MODE` | `gitbash` | `gitbash` / `wsl`（WSL 事前有効化済み fleet のみ） |
| `KIT_MDM_INSTALL_CLAUDE_CLI` | `true` | Claude Code CLI 導入の可否 |
| `KIT_MDM_GIT_REF` | `main` | 配布バージョン固定（タグ/ブランチ/SHA）。§5.5 で必ず適用 |
| `KIT_MDM_INSTALL_DIR` | 対象ユーザー解決後に `<canonical_home>/.claude-starter-kit` を組立（§7.4） | clone 先 |
| `KIT_MDM_LOG_DIR` | §8.2 の既定 | ログ出力先の上書き（許可プレフィックス配下のみ） |
| `KIT_MDM_DRY_RUN` | `false` | 本体の --dry-run へ伝搬 |

### 7.4 KIT_MDM_INSTALL_DIR の既定値（Codex Medium 指摘を反映）

既定値を文字列 `~/.claude-starter-kit` にしてはならない（変数内で tilde は展開されず、既存 `_safe_install_dir` の
絶対パス検証にも失敗する）。R2 で対象ユーザーの canonical home を解決した後に絶対パスとして組み立て、
明示指定時は §7.2 の path 検証（絶対パス + canonical home 配下）を通す。

## 8. MDM 共通契約

### 8.1 終了コード表（固定契約）

| コード | 意味 |
|---|---|
| 0 | 成功 |
| 10 | 前提ツール導入失敗 / 不足（不足一覧をログに出力） |
| 11 | Homebrew ブートストラップ失敗（macOS） |
| 20 | 対象ユーザー・ホーム解決/検証失敗（§5.4） |
| 21 | 非対応の実行コンテキスト（Windows: SYSTEM 実行） |
| 30 | キットセットアップ失敗（setup.sh 非 0 終了） |
| 40 | Claude Code CLI 導入失敗 |
| 50 | 管理設定エラー（不正キー・不正値・パーミッション） |
| 60 | 非対応 OS / OS バージョン |

### 8.2 ログ

- macOS: `/Library/Logs/ClaudeCodeStarterKit/install-<timestamp>.log`（ユーザーモード時は `~/Library/Logs/...`）
- Windows: `%LOCALAPPDATA%\ClaudeCodeStarterKit\Logs\install-<timestamp>.log`
- 単一ファイルに root/ユーザー両フェーズを追記。秘密情報・トークンは書かない。行頭にタイムスタンプ + フェーズタグ

### 8.3 レシート（Codex Medium 指摘を反映）

- macOS: `/Library/Application Support/ClaudeCodeStarterKit/receipt-<user>.json`（ユーザーモード時はユーザー領域）
- Windows: `%LOCALAPPDATA%\ClaudeCodeStarterKit\receipt-<user>.json`
- **schema**: `{schema_version, kit_version, git_ref, resolved_sha, profile, target_user, result, exit_code, partial[], timestamp, log_path}`
  （`partial[]` を schema に正式定義 — §10 の部分失敗記録と整合）
- **失敗保証は best-effort に明確化**: 対象ユーザー未解決・設定エラー・書込不能の場合は receipt を書けないことがある。
  その場合の代替出力契約: (a) 可能なら root 領域の共通パス `/Library/Application Support/ClaudeCodeStarterKit/receipt-_unresolved.json` に最小レシートを書く、
  (b) それも不可ならログと終了コードのみを唯一の成否シグナルとする。「必ず receipt」という無条件保証はしない
- 書き出しは jq 非依存（printf で生成、値は JSON エスケープ）

### 8.4 検知スクリプト（detect-mdm.* — Codex High 指摘を反映）

古い/別ユーザーの成功レシートで compliant 判定しないための照合を必須化:
- 対象ユーザーを解決し、そのユーザーのレシートのみを対象にする（`--user <name>` で明示可）
- 複数レシートがあれば timestamp 最新を採用（優先順位を定義）
- レシートの `result=="success"` に加え、**実体照合**: `resolved_sha` の clone が実在し、
  Claude CLI（`command -v claude` 等）が実際に導入済みかを確認して初めて exit 0
- 退職者アカウントのレシートは対象ユーザー不一致で除外
- 引数 `--min-version X.Y.Z`: kit_version 比較で古ければ exit 1
- 標準出力に 1 行サマリー（Jamf EA の `<result>` 形式はガイドに記載）

### 8.5 冪等性・更新チャネル（Codex High 指摘を反映）

- 何度実行しても安全。既存インストール検出時は本体の update パス + §5.5 の ref 切替
- **更新チャネルは MDM 製品ごとに設計が異なる**（「定期再実行で更新」を一律前提にしない）:
  - **Intune**: Platform Script は script 変更時のみ再実行（週次自動再実行ではない、出典:
    https://learn.microsoft.com/en-us/intune/device-management/tools/run-powershell-scripts-windows ）。
    定期更新は **Remediations（検知=detect-mdm + 修復=install-mdm）** または **Win32 app の requirement/detection rule** で構成する
  - **Jamf**: Policy の実行頻度（Recurring Check-in / Once per day 等）で定期実行を構成
  - **Workspace ONE / Ivanti**: スケジュール実行またはコンプライアンス修復で構成
  - 各製品の推奨構成をガイドに明記。detect-mdm を検知、install-mdm を修復とする「検知→修復」パターンを共通の推奨形とする
- 全外部ダウンロードにタイムアウト。MDM 側タイムアウト設定の推奨値をガイドに記載

## 9. セキュリティ設計（Codex High 指摘を反映）

### 9.1 ダウンロードの信頼固定

- キット取得は `KIT_MDM_GIT_REF` で固定（既定 `main` は mutable のため、fleet では**タグ/SHA 固定を強く推奨**とガイドに明記）
- Claude Code / Homebrew の公式リモートスクリプト（`claude.ai/install.sh`, brew）は curl|bash が公式手法であり、
  これは既存キットと同じ信頼境界を継承する。**同一経路のチェックサム同梱は改ざん防止にならない**ため、
  検証はソースが独立した trust anchor（OS 同梱の署名検証: `pkgutil --check-signature` / Authenticode）を優先し、
  それが無いものは「公式ドメイン + TLS を信頼境界とする」と設計上明記（過剰な安全性を偽装しない）
- Git for Windows 等の pkg は公式配布のハッシュを**別経路（公式サイト記載値）**で照合

### 9.2 管理設定の TOCTOU・パーミッション（Codex High 指摘を反映）

root が読む管理設定ファイルは、読み取り直前に以下を検証（いずれか失敗で exit 50）:
- ファイルと**親ディレクトリ**が root 所有・group/other 書込不可
- symlink でないこと（`-L`）、reparse point でないこと（Windows）
- 検査後に開いた fd から読む（検査→再オープンの差替え TOCTOU を避ける。可能な範囲で `open`→`fstat` 相当を実装）
- Windows は ACL を検証（Administrators/SYSTEM のみ書込可）。POSIX mode だけに依存しない
- `KIT_MDM_LOG_DIR` 等の root 書込先も許可プレフィックス配下に制約（任意パスへの root 書込を禁止）

### 9.3 root 最小化

- root で実行するのは R1〜R3・R4 のみ。キット本体・Claude CLI・brew 操作はユーザー権限（§5.3 の分離降格）
- ログ・レシートのディレクトリは root 所有 755 / ファイル 644（秘密情報を含まない）

## 10. エラーハンドリング方針

- `set -euo pipefail`（既存規約踏襲）+ フェーズ境界で明示的な終了コードマッピング
- 部分失敗: Claude CLI 導入失敗（40）はキット配備成功後でも失敗として報告し、レシート `partial: ["claude_cli"]` に記録
- 失敗時もレシートは best-effort で書く（§8.3）— 「未実行」と「実行して失敗」を区別
- **注意**: 本体レビュー（P1-2）で判明した `grep | head` × pipefail 即死パターンを mdm/ 層に持ち込まない
  （`|| true` や条件分岐で pipefail 伝播を止める）

## 11. 本体への変更（最小強化）

1. **(a) 非対話モードでの Claude CLI 導入確実化**: `_need_claude_cli_install`/`_install_claude_cli` の非対話経路を確認し、
   スキップ/プロンプト待ちがあれば環境変数で強制有効化できるようにする
2. **(b) TTY ガード**: setup.sh:225 / lib/prerequisites.sh:781 は read 失敗時 "n" で fail-closed 確認済み。
   実装時の非対話網羅テストで追加の TTY 依存が見つかった場合のみ最小修正
3. **(c) ref 切替の受け入れ**: §5.5 の detached checkout 後に本体 update 検出（manifest/snapshot 比較）が正しく動くことを確認。
   本体が「追跡ブランチ前提」の箇所があれば mdm 層側で吸収（本体改変は最小限）
4. 上記以外は本体に手を入れない

## 12. テスト計画（Codex Medium 指摘を反映）

- `tests/unit/test-mdm-config.sh`: 型検証パーサ（boolean/enum/gitref/username/path の不正値が exit 50、未知キー警告、優先順位、パーミッション/symlink 検証）
- `tests/unit/test-mdm-install.sh`: 引数解析・対象ユーザー/ホーム検証（scutil/dscl/stat をモック）・終了コード・レシート生成（jq で JSON 妥当性 + partial[] 検証）
- `tests/unit/test-mdm-detect.sh`: 検知の実体照合・別ユーザー除外・最新レシート選択・--min-version
- **Bash 3.2 互換 CI**: macOS `/bin/bash`（3.2）で mdm/*.sh の parser・trap・終了コード経路を実行するジョブを test.yml に追加（Codex Medium 指摘）。
  既存の「macOS Bash 3.2 re-exec 検証」ジョブに相乗り可能か実装時に確認
- `install-mdm.ps1`/`detect-mdm.ps1`: PowerShell 構文検証（`Test-ScriptFileInfo`/PSScriptAnalyzer が CI にある場合。無い場合の方式は §15）
- シナリオ: Linux CI で `KIT_MDM_PREREQ_MODE=skip` + sudo 降格シミュレートの非対話スモーク
- shellcheck: `mdm/*.sh` を CI 対象 glob と CLAUDE.md 記載コマンドに追加
- 実機（macOS）: ユーザーモード + root モードの手動確認手順を PR に記載

## 13. ドキュメント計画

- `docs/mdm/README.md`（en）/ `README.ja.md`（ja）: 共通契約（設定キー・終了コード・ログ/レシートパス・タイムアウト目安）+
  製品別手順: Jamf（Policy + Script、実行頻度、EA 例）/ Intune（Platform Script、**Remediations/Win32 app による更新チャネル**、64bit 実行）/
  Workspace ONE（Scripts & Sensors、スケジュール）/ Ivanti（スクリプト配布・コンプライアンス修復）/
  汎用（Iru を含むその他: 「管理者権限でスクリプトを 1 本実行できること」だけを要求）
- ルート `README.md` に MDM 配布セクションを追加しリンク
- 製品固有記述は公式ドキュメントで確認できた範囲のみ記載し、未検証事項は「要検証」と明記

## 14. バージョニング・CHANGELOG

- **0.73.0**（minor）。`CHANGELOG.md` に `## [0.73.0] - 2026-07-XX` でユーザー可視の変更を記載
- `mdm/` はキットの deploy 対象ではない（`~/.claude/` に配布しない）ため manifest/snapshot/update 機構への影響なし。
  `_CONFIG_KEYS` にも追加しない（KIT_MDM_* はラッパー層で完結）

## 15. 実装時確認リスト（未検証事項 — 着手時に一次情報で確認）

- [ ] Claude Code 公式インストーラ（install.sh / install.ps1）の現行仕様（docs.anthropic.com）
- [ ] Xcode CLT の MDM pkg 事前配布手順（第一選択）と softwareupdate ラベル方式の現行動作（非公式フォールバック）
- [ ] Homebrew 公式 pkg + HOMEBREW_PKG_USER の非対話導入手順（https://docs.brew.sh/Installation ）
- [ ] Intune: Platform Script の再実行仕様、Remediations/Win32 app による更新チャネル構成の正確な手順
- [ ] winget のユーザースコープ可用性、Git for Windows のサイレントフラグと公式チェックサム提供方式
- [ ] Git Bash 同梱ツールの実態（GNU sed/awk 同梱、jq 非同梱の想定）
- [ ] Workspace ONE / Ivanti のスクリプト配布・スケジュール・Sensor 仕様
- [ ] 「Iru」の製品仕様（確認できるまで汎用手順の対象）
- [ ] setup.sh 非対話パスの Claude CLI 導入条件（§11(a)）と detached checkout の update 検出整合（§11(c)）
- [ ] macOS の対象ユーザー・ホーム検証 API（scutil ConsoleUser / dscl NFSHomeDirectory）の現行挙動

## 16. プロセス要件

- 本機能の**全コミット（この spec 含む）**を `codex exec`（`--model gpt-5.6-sol`）でクロスレビューする
  （`codex exec review --commit` はカスタムプロンプト併用不可のため、`codex exec` にプロンプト + read-only で実施）
- レビュー結果は `<メインリポジトリ>/.review/codex/mdm-<sha>.md` に保存し、指摘の 採用 / 裁定 / 却下 を記録
- 同一箇所のレビュー往復は 2 回まで。収束しない場合はシンジへエスカレーション
- 実装は superpowers:writing-plans → TDD（テスト先行）で進める

## 17. 将来拡張（明示的に今回やらないこと）

- .pkg（productbuild + 署名/公証）/ .intunewin ビルドパイプライン
- Windows SYSTEM 実行からのユーザーコンテキストへのハンドオフ（スケジュールタスク方式）
- 全ユーザー一括 / ログイン時 LaunchAgent・Active Setup 方式
- Claude Code の managed-settings.json 配布テンプレート
- アンインストール MDM ラッパー・レポート集約

## 18. Codex クロスレビュー反映履歴

- **v1 → v2（コミット eabbae6 のレビュー、gpt-5.6-sol medium effort、指摘15件を全採用）**:
  誤検知 0件・全件妥当とメイン（Fable 5）が原文コード+一次情報で裁定。主な反映:
  - High: Windows 書込先を %LOCALAPPDATA% に統一・machine-wide 導入の事前配布化（§6.1）/ ダウンロード信頼固定の現実的定義（§9.1）/
    対象ユーザー・ホーム検証の追加（§5.4）/ env -i 環境分離降格契約（§5.3）/ 管理設定 TOCTOU・ACL 対策（§9.2）/
    CLT ゼロタッチ前提を pkg 事前配布へ格下げ（§5.2）/ KIT_MDM_GIT_REF の ref 切替契約（§5.5, §11c）/
    検知の実体照合・別ユーザー除外（§8.4）/ Intune 更新チャネルを Remediations/Win32 app へ（§8.5）
  - Medium: Homebrew 公式 pkg 経路（§5.2）/ 型検証パーサ（§7.2）/ receipt schema に partial[] + 失敗保証の best-effort 化（§8.3）/
    Bash 3.2 CI（§12）/ KIT_MDM_INSTALL_DIR 既定値の絶対パス組立（§7.4）
  - Low: 対応 MDM の確度区分（Iru を汎用契約に格下げ、§2.1）
  裁定記録: `.review/codex/mdm-eabbae6.md`
