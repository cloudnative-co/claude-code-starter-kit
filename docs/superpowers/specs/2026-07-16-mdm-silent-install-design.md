# MDM サイレントインストール機能 設計書

- 日付: 2026-07-16
- ステータス: ドラフト v3（Codex クロスレビュー 2 巡（v1:15件 + v2:5件）を全反映・シンジのレビュー待ち）
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
| 配布形態 | スクリプト配布。配布単位は「MDM baseline（前提の事前配布）+ mdm/ bundle」（§3.1）。pkg/.intunewin 化は将来拡張 |
| スコープ | Claude Code 本体 + 前提ツール + キットをゼロタッチ導入（前提の一部は MDM baseline で事前配布・§3.1） |
| 設定指定 | CLI 引数 > 環境変数 > 管理設定ファイル > 既定値（standard プロファイル） |
| アプローチ | C: 薄い MDM 層（mdm/）+ 本体の最小強化 |
| プロセス | 作成物はすべて（spec 含む）Codex クロスレビューを通す |

### 2.1 「対応 MDM」の確度区分

- **一次情報で手順検証する（製品別ガイドを書く）**: Intune / Jamf / Workspace ONE / Ivanti
- **汎用 MDM 契約のみ（製品固有ガイドなし）**: Iru ほか — 「root/管理者権限でスクリプトを 1 本実行できる」ことだけを要求する契約に格下げ。
  Iru は製品仕様・正式名称を一次情報で確認できるまで固有手順を書かない

## 3. スコープ / 非スコープ

**スコープ:** mdm/ ラッパー（install/detect ×2 OS）、管理設定の型検証パーサ（sh + ps1 の2実装・§4.1）、
ログ・終了コード・レシートの機械可読契約、ダウンロード信頼固定・ref ピン留め、特権降格の環境分離契約、
docs/mdm、本体への最小強化（§11）、単体テスト + Bash 3.2 CI + 設定キー乖離検出テスト。

**非スコープ（将来拡張 — §17）:** pkg/.intunewin ビルドパイプライン、managed-settings.json 配布、
アンインストール MDM ラッパー、全ユーザー一括/ログイン時 LaunchAgent 方式、Windows SYSTEM からのユーザーコンテキストへのハンドオフ。

### 3.1 配布単位の定義（Codex v2 High#5 を反映）

「1 スクリプトで全部入り」は前提ツールの事前配布と外部 lib への依存があるため成立しない。正式な配布単位を次のとおり定義する:

- **MDM baseline（事前配布・製品のアプリ/pkg 配布機能で設置）**:
  - macOS: Xcode Command Line Tools（pkg）。必要に応じて Homebrew（公式 pkg）
  - Windows: Git for Windows（管理者権限が要る場合）。必要に応じて追加前提
  - 目的: 特権や再起動を要する重い前提を、スクリプトではなく MDM ネイティブのソフトウェア配布で入れる
- **mdm/ bundle（スクリプト配布の実体・MDM の「スクリプト実行」で起動）**:
  - `install-mdm.sh` + `lib-mdm-config.sh`（macOS）/ `install-mdm.ps1` + `lib-mdm-config.ps1`（Windows）
  - MDM が単一ファイルしかアップロードできない場合に備え、**install-mdm.{sh,ps1} 自身を自己ブートストラップ launcher とする**（§4.1・§5.1a）:
    隣接する lib-mdm-config.* が無ければ、install-mdm 冒頭で `KIT_MDM_GIT_REF` 固定（§5.5 の SHA 確定手順）で mdm/ 一式を取得し、取得した実体から自身を再実行する。
    これにより「install-mdm.sh 1 ファイルだけをスクリプト枠にアップロード」でも動作する（追加の launcher 成果物は作らず、既存 install-mdm がその役を兼ねる）
  - オフライン fleet 向けには bundle 一式（install-mdm + lib-mdm-config）を MDM のスクリプト添付/ペイロードで同時配布する方式も可
  - ガイド（§13）に「各製品で MDM baseline に何を、スクリプト枠に何をアップロードするか」を明記する

## 4. アーキテクチャ

### 4.1 ファイル構成

```
mdm/
├── install-mdm.sh      # macOS: root 実行前提のエントリ兼自己ブートストラップ launcher（§3.1。Bash 3.2 互換必須 — 素の macOS /bin/bash で動くこと）
├── install-mdm.ps1     # Windows: ユーザーコンテキスト実行前提兼自己ブートストラップ launcher（§3.1。SYSTEM 検知時は exit 21）
├── detect-mdm.sh       # macOS: 対象ユーザー・最新・実体照合つきレシート判定
├── detect-mdm.ps1      # Windows: 同上
├── lib-mdm-config.sh   # macOS/Bash 用 管理設定の型検証パーサ（Bash 3.2 互換・sh 系が source）
└── lib-mdm-config.ps1  # Windows/PowerShell 用 管理設定の型検証パーサ（ps1 系が dot-source）
docs/mdm/
├── README.md           # 共通契約 + 製品別手順（en）
└── README.ja.md        # 同（ja）
```

**Windows 設定パーサ（Codex v2 High#3 を反映）**: PowerShell の `.ps1` は `lib-mdm-config.sh` を source できないため、
同一契約（優先順位・型検証・ACL/reparse-point 検証）を実装する `lib-mdm-config.ps1` を別途用意する。
両実装は**同じ設定入力に対して同じ検証結果（採用値・exit 50 判定）を返す**ことを契約とし、§12 の契約一致テストで担保する。

### 4.2 責務分離の原則

- **mdm/ 層が担う**: 特権コンテキスト処理・対象ユーザー/ホーム検証・環境分離降格・前提ブートストラップ・
  管理設定の型検証・ダウンロード信頼固定・ref ピン留め・ログ・終了コード・レシート・**setup.sh の直接呼び出し**
- **本体（setup.sh + lib）が担う**: 従来どおりのプロファイル適用・deploy・Claude Code CLI 導入・update 検出
- MDM 製品固有の事情はコードに持ち込まず、ドキュメントで吸収する（MDM 非依存契約）

## 5. macOS フロー（install-mdm.sh）

### 5.1 実行フェーズ

```
[R: root フェーズ]
R1 引数/環境変数解析 → 管理設定ファイル読込(§7,型検証) → 設定確定・ログ開始
R2 対象ユーザー・ホーム解決と検証(§5.4)
R3 前提ブートストラップ(§5.2)
[U: ユーザーフェーズ — 環境分離降格(§5.3)]
U1a 自己ブートストラップ(§3.1): 隣接する lib-mdm-config.sh が無ければ KIT_MDM_GIT_REF 固定で mdm/ 一式を取得し取得実体から再実行
U1b キット取得 + ref ピン留め(§5.5) — install.sh は再実行しない。clone と ref 確定を wrapper が管理
U2 setup.sh --non-interactive を直接実行(検証済み設定を本体の実キー名で環境変数注入。§7.3。ENABLE_GHOSTTY_SETUP 既定 false)
U3 Claude Code CLI 導入の確認(KIT_MDM_INSTALL_CLAUDE_CLI=true のとき。本体の既存処理を強制有効化 — §11(a))
[R: 終端フェーズ]
R4 レシート書き出し(§8.3) + 終了コード確定 + ログクローズ
※ 非 root 起動時は「ユーザーモード」: R3 の system-wide 導入は不可のため brew も不足前提もなければ exit 10。降格(§5.3)はスキップ
```

### 5.2 前提ツール戦略

必須前提には公式 pkg 配布が無いもの（bash 4+, GNU sed, GNU awk, tmux）が含まれるため Homebrew を核に据える:

1. **brew あり** → 何もしない（本体の既存 brew 自動導入が全前提をカバー）
2. **brew なし & KIT_MDM_INSTALL_HOMEBREW=true（既定）** → 前提ブートストラップ → 1. へ
3. **brew なし & KIT_MDM_INSTALL_HOMEBREW=false** → 不足前提の一覧をログに出して exit 10

**前提ブートストラップ:**
- **Xcode CLT**: 第一選択は **MDM baseline での pkg 事前配布**（§3.1）。`softwareupdate` ラベル方式は Apple 公式手順として
  文書化されていないため（公式は `xcode-select --install` が GUI を要求）、既定では CLT 不在時に「MDM 配布せよ」と exit 10 し、
  `KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true` 明示時のみ非公式手法をフォールバックで試みる
- **Homebrew**: 公式 `.pkg` + `HOMEBREW_PKG_USER` を第一選択（出典: https://docs.brew.sh/Installation ）。
  prefix 手作業作成 + chown は撤回。multi-user 共有は公式非対応のため対象ユーザー単独所有で導入

### 5.3 特権降格の環境分離契約

降格は次の形を必須とする（root 環境を一切継承しない）:

```
launchctl asuser <uid> sudo -u <user> -H \
  /usr/bin/env -i \
  HOME=<canonical_home> USER=<user> LOGNAME=<user> \
  PATH=<固定 PATH: brew bin + /usr/bin:/bin:/usr/sbin:/sbin> \
  LANG=<設定 or 既定> \
  <許可リストの KIT_* / ENABLE_*_SETUP / ENABLE_* / PROFILE / LANGUAGE / EDITOR_CHOICE を明示列挙> \
  /bin/bash <script> <args...>
```

proxy 変数を fleet で使う場合は管理設定キーで許可リストに含める。引数は配列/明示引数で渡す（注入防止）。

### 5.4 対象ユーザー・ホーム検証

予約名拒否だけでは不十分。R2 で以下を検証し、いずれか失敗で exit 20:
- `KIT_MDM_TARGET_USER` > コンソールユーザー（`scutil` ConsoleUser、フォールバック `stat -f%Su /dev/console`）
- 実在するローカルアカウント（`dscl . -read /Users/<user>` 成功）、UID >= 501（システムアカウント除外）
- ホームが `dscl` の NFSHomeDirectory と一致・実在・**所有者が対象ユーザー**、symlink でない（`-L`）、canonical 化（`cd + pwd -P`）
- root による chown・clone 先がこの canonical home 配下に限定されることを保証

### 5.5 バージョンピン留め（Codex v1 High + v2 High#1 を反映）

既存 `install.sh`/`auto-update.sh` は `git pull --ff-only` のみで ref を切り替えず、さらに install.sh:151-154 は
pull 失敗時に**再 clone（main）へフォールバック**して固定を破る。よって **MDM wrapper は install.sh を再実行しない**。
wrapper が ref を次の手順で確定する:

1. `KIT_MDM_GIT_REF` の形式判定を分離: 40/64桁 hex は SHA として扱う / それ以外は `git check-ref-format --branch <ref>` で検証（不正なら exit 50）。
   ★素の `git check-ref-format <ref>` は完全 ref（refs/heads/... 形式）を要求し、bare な `main` や tag 名 `v0.72.0` を exit 1 で弾く（実測確認済み）。
   `--branch` は短縮名（main / v0.72.0 / feature/x）を許容しつつ危険文字・先頭ハイフンを拒否するため、`KIT_MDM_GIT_REF` の検証にはこちらを使う
2. 取得: 新規は `git clone` 後、既存/新規とも `git fetch origin <ref>` → **`git rev-parse FETCH_HEAD^{commit}`（SHA 指定時は `<ref>^{commit}`）で確定 SHA を解決**
   （明示 fetch はローカル branch/tag を更新しないことがあるため、FETCH_HEAD の commit を真実とする）
3. `git checkout --detach <解決した SHA>` → `git rev-parse HEAD` が解決 SHA と一致することを照合（不一致は exit 30）
4. 確定した HEAD SHA を `resolved_sha` としてレシートに記録（§8.3）
5. その後 wrapper が `setup.sh --non-interactive`（または `--update`）を**直接**呼ぶ（install.sh の pull/フォールバックを経由しない）

### 5.6 Ghostty / フォント / プラグイン

- Ghostty（GUI アプリ）: MDM 既定 **off**。実キーは **`ENABLE_GHOSTTY_SETUP`**（§7.3）。管理設定で on 可
- フォント: 既存の直接 DL フォールバック（~/Library/Fonts）を利用。実キーは `ENABLE_FONTS_SETUP`
- プラグイン / Codex Plugin: プロファイル既定に従う

## 6. Windows フロー（install-mdm.ps1）

### 6.1 実行コンテキストと書込先の両立

- **ユーザーコンテキスト実行を必須**（Intune「ログオンユーザーの資格情報で実行: はい」等）。SYSTEM 起動時は exit 21 + ガイド誘導
- **書込先はユーザーが書ける場所に統一**: ログ/レシートは `%LOCALAPPDATA%\ClaudeCodeStarterKit\`。
  管理設定の読み取り元は `C:\ProgramData\...`（配布は MDM が管理者権限で設置）
- **machine-wide 前提導入は user context 不可**なので、Git for Windows 等は MDM baseline で事前配布（§3.1）を第一選択とし、
  winget のユーザースコープ導入が可能な範囲のみ自動化。導入不能時は不足一覧をログに出して exit 10（ゼロタッチを偽装しない）

### 6.2 モードと前提

- **既定モード: Git Bash**。`KIT_MDM_WINDOWS_MODE=wsl` は WSL 事前有効化済み fleet でのみ選択可
- Git for Windows 不在時: winget（ユーザースコープ）→ 公式インストーラ（/VERYSILENT /NORESTART、HTTPS + 公式チェックサム別経路照合・§9）の順。
  管理者権限が要る導入は §3.1 の事前配布へ
- 以降は既存 `install.ps1` の Git Bash モード相当に委譲。Git Bash 同梱ツールの実態（GNU sed/awk 同梱、jq 非同梱想定）は実機確認（§15）

## 7. 設定体系

### 7.1 優先順位

**CLI 引数 > 環境変数 > 管理設定ファイル > 既定値（standard プロファイル）**

### 7.2 管理設定ファイルと型検証パーサ

既存 `_safe_source_config()` は未知キー無視・値の型検証なしのため MDM 用途には流用しない。
`lib-mdm-config.sh`（+ `.ps1`）に型検証パーサを新規実装（`source`/`eval`/`Invoke-Expression` 禁止）:
- 未知キーは無視ではなく警告ログ + 記録
- 値は型別に検証し、不正値は加工せず exit 50:
  boolean（`true|false|1|0|yes|no|on|off`）/ enum（PROFILE = minimal|standard|full）/
  git ref（§5.5 の判定: SHA or `git check-ref-format --branch`。素の check-ref-format は main/tag を弾くため --branch を使う）/ username（OS ユーザー名文字種）/ path（絶対 + 許可プレフィックス配下）
- 配置: macOS `/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf`、Windows `C:\ProgramData\ClaudeCodeStarterKit\mdm-config.conf`
- 読み取り前に §9.2 のパーミッション/所有者/symlink・ACL/reparse-point 検証

### 7.3 設定キー（Codex v2 High#4 を反映 — 本体の実キー名に一致）

**既存キー流用（検証後 setup.sh へ環境変数で伝搬）** — 本体 `wizard/registry.sh` の `_CONFIG_KEYS` に実在するキー名を使う:
- `PROFILE` / `LANGUAGE` / **`EDITOR_CHOICE`**（`EDITOR` ではない）/ `COMMIT_ATTRIBUTION`
- **`ENABLE_GHOSTTY_SETUP`**（`ENABLE_GHOSTTY` ではない。standard.conf は `=true` のため MDM 既定 false は正キーで上書き）/
  `ENABLE_FONTS_SETUP` / `ENABLE_STATUSLINE` / `ENABLE_SAFETY_NET` / その他 `ENABLE_*` 群

許可キー一覧・型・MDM 既定値は **実在の `_CONFIG_KEYS` から生成/照合**し、乖離を検出するテスト（§12）を必須とする
（本体がキー名を変えた場合に MDM 側が黙って無効化されるのを防ぐ）。

**MDM 固有キー（接頭辞 `KIT_MDM_`）:**

| キー | 既定値 | 意味 |
|---|---|---|
| `KIT_MDM_TARGET_USER` | （自動検出・検証あり §5.4） | 対象ユーザーの明示指定 |
| `KIT_MDM_INSTALL_HOMEBREW` | `true` | brew 不在時の公式 pkg ブートストラップ可否（macOS） |
| `KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE` | `false` | CLT の非公式 softwareupdate 導入を許可（既定は pkg 事前配布を要求） |
| `KIT_MDM_PREREQ_MODE` | `auto` | `auto` / `skip`（テスト用） / `fail`（不足で exit 10） |
| `KIT_MDM_WINDOWS_MODE` | `gitbash` | `gitbash` / `wsl`（WSL 事前有効化済み fleet のみ） |
| `KIT_MDM_INSTALL_CLAUDE_CLI` | `true` | Claude Code CLI 導入の可否（detect の照合条件にも反映・§8.4） |
| `KIT_MDM_GIT_REF` | `main` | 配布バージョン固定（タグ/ブランチ/SHA）。§5.5 で必ず適用 |
| `KIT_MDM_INSTALL_DIR` | 対象ユーザー解決後に `<canonical_home>/.claude-starter-kit` を組立（§7.4） | clone 先 |
| `KIT_MDM_LOG_DIR` | §8.2 の既定 | ログ出力先の上書き（許可プレフィックス配下のみ） |
| `KIT_MDM_DRY_RUN` | `false` | 本体の --dry-run へ伝搬 |

### 7.4 KIT_MDM_INSTALL_DIR の既定値

既定値を文字列 `~/.claude-starter-kit` にしてはならない（変数内で tilde 非展開 + 既存 `_safe_install_dir` の絶対パス検証に失敗）。
R2 で対象ユーザーの canonical home を解決した後に絶対パスとして組み立て、明示指定時は §7.2 の path 検証を通す。

## 8. MDM 共通契約

### 8.1 終了コード表（固定契約）

| コード | 意味 |
|---|---|
| 0 | 成功 |
| 10 | 前提ツール導入失敗 / 不足（不足一覧をログに出力） |
| 11 | Homebrew ブートストラップ失敗（macOS） |
| 20 | 対象ユーザー・ホーム解決/検証失敗（§5.4） |
| 21 | 非対応の実行コンテキスト（Windows: SYSTEM 実行） |
| 30 | キットセットアップ失敗 / ref 照合失敗（§5.5） |
| 40 | Claude Code CLI 導入失敗 |
| 50 | 管理設定エラー（不正キー・不正値・パーミッション・不正 ref 形式） |
| 60 | 非対応 OS / OS バージョン |

### 8.2 ログ

- macOS: `/Library/Logs/ClaudeCodeStarterKit/install-<timestamp>.log`（ユーザーモード時は `~/Library/Logs/...`）
- Windows: `%LOCALAPPDATA%\ClaudeCodeStarterKit\Logs\install-<timestamp>.log`
- 単一ファイルに両フェーズを追記。秘密情報・トークンは書かない。行頭にタイムスタンプ + フェーズタグ

### 8.3 レシート（Codex v1 Medium + v2 High#2 を反映）

- macOS: `/Library/Application Support/ClaudeCodeStarterKit/receipt-<user>.json`（ユーザーモード時はユーザー領域）
- Windows: `%LOCALAPPDATA%\ClaudeCodeStarterKit\receipt-<user>.json`
- **schema**: `{schema_version, kit_version, git_ref, resolved_sha, install_dir, required_components[], profile, target_user, result, exit_code, partial[], timestamp, log_path}`
  - `install_dir`: 実際の clone パス（detect が対象 clone を特定するため。canonical home 配下を再検証）
  - `required_components[]`: この端末で必須としたコンポーネント（例 `["kit","claude_cli"]`。`KIT_MDM_INSTALL_CLAUDE_CLI=false` なら `claude_cli` を含めない）
  - `partial[]`: 部分失敗したコンポーネント（§10）
- **失敗保証は best-effort**: ユーザー未解決・設定エラー・書込不能では receipt を書けないことがある。代替出力契約:
  (a) 可能なら root 領域に `receipt-_unresolved.json` を書く、(b) 不可ならログ + 終了コードを唯一のシグナルとする。無条件の「必ず receipt」保証はしない
- 書き出しは jq 非依存（printf で生成、値は JSON エスケープ）

### 8.4 検知スクリプト（detect-mdm.* — Codex v1 High + v2 High#2 を反映）

- 対象ユーザーを解決し、そのユーザーのレシートのみ対象（`--user <name>` で明示可）。複数あれば timestamp 最新を採用
- **実体照合を receipt の宣言に基づき条件付きで行う**:
  - `result=="success"` かつ `install_dir` の clone が実在し `resolved_sha` と一致
  - `required_components[]` に `claude_cli` が含まれる場合のみ Claude CLI 導入を確認（`KIT_MDM_INSTALL_CLAUDE_CLI=false` の端末を非準拠にしない）
  - すべて満たして初めて exit 0
- 退職者アカウントのレシートは対象ユーザー不一致で除外。`--min-version X.Y.Z` で kit_version 比較
- 標準出力に 1 行サマリー（Jamf EA の `<result>` 形式はガイドに記載）

### 8.5 冪等性・更新チャネル

- 何度実行しても安全。既存インストール検出時は §5.5 の ref 切替 + 本体 update パス（wrapper が setup.sh --update を直接呼ぶ）
- **更新チャネルは MDM 製品ごとに設計が異なる**:
  - **Intune**: Platform Script は script 変更時のみ再実行（週次自動再実行ではない、出典:
    https://learn.microsoft.com/en-us/intune/device-management/tools/run-powershell-scripts-windows ）。
    定期更新は **Remediations（検知=detect-mdm + 修復=install-mdm）** または **Win32 app の requirement/detection rule** で構成
  - **Jamf**: Policy の実行頻度（Recurring Check-in 等）で構成
  - **Workspace ONE / Ivanti**: スケジュール実行またはコンプライアンス修復で構成
  - detect-mdm を検知、install-mdm を修復とする「検知→修復」パターンを共通推奨形とする
- 全外部ダウンロードにタイムアウト。MDM 側タイムアウト設定の推奨値をガイドに記載

## 9. セキュリティ設計

### 9.1 ダウンロードの信頼固定

- キット取得は `KIT_MDM_GIT_REF` で固定（§5.5 の SHA 確定 + 照合）。既定 `main` は mutable のため fleet ではタグ/SHA 固定を強く推奨とガイドに明記
- Claude Code / Homebrew の公式リモートスクリプトは curl|bash が公式手法であり既存キットと同じ信頼境界を継承。
  同一経路のチェックサム同梱は改ざん防止にならないため、検証は OS 同梱の署名検証（`pkgutil --check-signature` / Authenticode）を優先し、
  無いものは「公式ドメイン + TLS を信頼境界とする」と設計上明記（過剰な安全性を偽装しない）
- Git for Windows 等の pkg は公式配布ハッシュを別経路（公式サイト記載値）で照合

### 9.2 管理設定の TOCTOU・パーミッション

読み取り直前に検証（いずれか失敗で exit 50）:
- ファイルと**親ディレクトリ**が root/Administrators 所有・group/other 書込不可
- symlink でない（`-L`）、reparse point でない（Windows）
- 検査後に開いた fd から読む（TOCTOU 回避）。Windows は ACL を検証（POSIX mode だけに依存しない）
- `KIT_MDM_LOG_DIR` 等の root 書込先も許可プレフィックス配下に制約

### 9.3 root 最小化

- root で実行するのは R1〜R3・R4 のみ。キット本体・Claude CLI・brew 操作はユーザー権限（§5.3 の分離降格）
- ログ・レシートのディレクトリは root 所有 755 / ファイル 644（秘密情報を含まない）

## 10. エラーハンドリング方針

- `set -euo pipefail` + フェーズ境界で明示的な終了コードマッピング
- 部分失敗: Claude CLI 導入失敗（40）はキット配備成功後でも失敗として報告し、レシート `partial: ["claude_cli"]` に記録
- 失敗時もレシートは best-effort で書く（§8.3）
- **本体レビュー（P1-2）で判明した `grep | head` × pipefail 即死パターンを mdm/ 層に持ち込まない**（`|| true`/条件分岐で pipefail 伝播を止める）

## 11. 本体への変更（最小強化）

1. **(a) 非対話モードでの Claude CLI 導入確実化**: `_need_claude_cli_install`/`_install_claude_cli` の非対話経路を確認し、
   スキップ/プロンプト待ちがあれば環境変数で強制有効化できるようにする
2. **(b) TTY ガード**: setup.sh:225 / lib/prerequisites.sh:781 は read 失敗時 "n" で fail-closed 確認済み。追加の TTY 依存が見つかった場合のみ最小修正
3. **(c) wrapper は install.sh を再実行しない**: §5.5 のとおり clone/ref 確定は wrapper が管理し、`setup.sh` を直接呼ぶ。
   本体側の改変は原則不要（install.sh の pull/再clone フォールバックを迂回するだけ）。setup.sh が「追跡ブランチ前提」の箇所があれば mdm 層で吸収
4. 上記以外は本体に手を入れない

## 12. テスト計画

- `tests/unit/test-mdm-config.sh`: 型検証パーサ（boolean/enum/gitref/username/path の不正値が exit 50、未知キー警告、優先順位、パーミッション/symlink 検証）
- `tests/unit/test-mdm-config-parity.sh`: **lib-mdm-config.sh と .ps1 の契約一致**（同一入力→同一採用値・同一 exit 判定。PowerShell が CI にある前提。無い場合は §15 で方式決定）
- `tests/unit/test-mdm-keys-in-sync.sh`: **MDM 許可キー一覧が本体 `_CONFIG_KEYS` と乖離していない**ことを検証（EDITOR_CHOICE/ENABLE_GHOSTTY_SETUP 等の名称ドリフト検出）
- `tests/unit/test-mdm-install.sh`: 引数解析・対象ユーザー/ホーム検証（scutil/dscl/stat モック）・終了コード・ref 確定（fetch/FETCH_HEAD^{commit} モック）・レシート生成（jq で install_dir/required_components/partial[] 検証）
- `tests/unit/test-mdm-ref-validate.sh`: **git ref 形式検証**が main / tag(v0.72.0) / 完全 ref(refs/heads/x) / 40桁SHA を許容し、不正値（危険文字・先頭ハイフン・空）を exit 50 で弾くことを検証（--branch 方式の回帰テスト）
- `tests/unit/test-mdm-bootstrap.sh`: **自己ブートストラップ launcher**（§3.1）が lib-mdm-config.* 欠如を検知し取得・再実行フローに入ること（取得はモック）、既に揃っていれば再取得しないことを検証
- `tests/unit/test-mdm-detect.sh`: 実体照合・install_dir による clone 特定・required_components 条件付き照合・別ユーザー除外・最新レシート選択・--min-version
- **Bash 3.2 互換 CI**: macOS `/bin/bash`（3.2）で mdm/*.sh の parser・trap・終了コード経路を実行（既存の macOS Bash 3.2 re-exec ジョブに相乗り可否を実装時確認）
- shellcheck: `mdm/*.sh` を CI 対象 glob と CLAUDE.md 記載コマンドに追加
- シナリオ: Linux CI で `KIT_MDM_PREREQ_MODE=skip` + sudo 降格シミュレートの非対話スモーク
- 実機（macOS）: ユーザーモード + root モードの手動確認手順を PR に記載

## 13. ドキュメント計画

- `docs/mdm/README.md`（en）/ `README.ja.md`（ja）: 共通契約 + **配布単位（§3.1: MDM baseline に何を、スクリプト枠に何を）** +
  製品別手順: Jamf / Intune（Platform Script + Remediations/Win32 app 更新チャネル）/ Workspace ONE / Ivanti / 汎用（Iru 含む）
- ルート `README.md` に MDM 配布セクションを追加しリンク
- 製品固有記述は公式ドキュメントで確認できた範囲のみ記載し、未検証事項は「要検証」と明記

## 14. バージョニング・CHANGELOG

- **0.73.0**（minor）。`CHANGELOG.md` に `## [0.73.0] - 2026-07-XX` でユーザー可視の変更を記載
- `mdm/` はキットの deploy 対象ではない（`~/.claude/` に配布しない）ため manifest/snapshot/update 機構への影響なし。
  `_CONFIG_KEYS` にも KIT_MDM_* は追加しない（ラッパー層で完結）。ただし §12 の乖離検出テストで本体キーと同期を監視

## 15. 実装時確認リスト（未検証事項 — 着手時に一次情報で確認）

- [ ] Claude Code 公式インストーラ（install.sh / install.ps1）の現行仕様（docs.anthropic.com）
- [ ] Xcode CLT の MDM pkg 事前配布手順と softwareupdate ラベル方式の現行動作
- [ ] Homebrew 公式 pkg + HOMEBREW_PKG_USER の非対話導入手順
- [ ] Intune: Platform Script 再実行仕様、Remediations/Win32 app 更新チャネル構成
- [ ] winget のユーザースコープ可用性、Git for Windows のサイレントフラグと公式チェックサム
- [ ] Git Bash 同梱ツールの実態（GNU sed/awk 同梱、jq 非同梱想定）
- [ ] Workspace ONE / Ivanti のスクリプト配布・スケジュール・Sensor 仕様
- [ ] 「Iru」の製品仕様（確認できるまで汎用手順の対象）
- [ ] setup.sh 非対話パスの Claude CLI 導入条件（§11(a)）と wrapper 直接呼び出し時の update 検出整合（§11(c)）
- [ ] macOS の対象ユーザー・ホーム検証 API（scutil ConsoleUser / dscl NFSHomeDirectory）の現行挙動
- [ ] CI に PowerShell（pwsh）があるか（§12 の parity テスト方式決定）
- [ ] `git fetch origin <ref>` → `FETCH_HEAD^{commit}` の挙動を各 ref 種別（tag/branch/SHA）で実機確認

## 16. プロセス要件

- 本機能の**全コミット（この spec 含む）**を `codex exec`（`--model gpt-5.6-sol`）でクロスレビューする
  （`codex exec review --commit` はカスタムプロンプト併用不可のため `codex exec` にプロンプト + read-only で実施）
- レビュー結果は `<メインリポジトリ>/.review/codex/mdm-<sha>.md` に保存し、指摘の 採用 / 裁定 / 却下 を記録
- 同一箇所のレビュー往復は 2 回まで。収束しない場合はシンジへエスカレーション
- 実装は superpowers:writing-plans → TDD（テスト先行）で進める

## 17. 将来拡張（明示的に今回やらないこと）

- .pkg（productbuild + 署名/公証）/ .intunewin ビルドパイプライン
- Windows SYSTEM 実行からのユーザーコンテキストへのハンドオフ
- 全ユーザー一括 / ログイン時 LaunchAgent・Active Setup 方式
- Claude Code の managed-settings.json 配布テンプレート
- アンインストール MDM ラッパー・レポート集約

## 18. Codex クロスレビュー反映履歴

- **v1 → v2（コミット eabbae6、gpt-5.6-sol medium、指摘15件を全採用）**: Windows 書込先/ユーザー・home 検証/env -i/CLT 事前配布化/
  receipt schema/Intune 更新チャネル/型検証パーサ/Bash 3.2 CI/Iru 格下げ 等。裁定記録: `.review/codex/mdm-eabbae6.md`
- **v2 → v3（コミット 5be3042、gpt-5.6-sol medium、High 5件を全採用）**: 誤検知0・全件妥当とメインが原文コードで裁定。反映:
  - ref 固定手順の厳密化: FETCH_HEAD^{commit} 解決 + checkout --detach + 照合、install.sh 再実行せず setup.sh 直接呼び出し、
    ref 形式判定を SHA/git check-ref-format に分離（§5.5, §11c）
  - receipt に install_dir + required_components を追加し detect の条件付き照合に反映（§8.3, §8.4）
  - Windows 用 lib-mdm-config.ps1 を追加し両実装の契約一致テストを必須化（§4.1, §12）
  - **本体設定名を実キーに修正: EDITOR→EDITOR_CHOICE / ENABLE_GHOSTTY→ENABLE_GHOSTTY_SETUP**、
    許可キー乖離検出テストを追加（§7.3, §12）。v2 の誤キーでは「MDM 既定 off」が無効だった
  - 配布単位を「MDM baseline + mdm/ bundle」として正式定義（§3.1）、「1スクリプト全部入り」の矛盾を解消
  裁定記録: `.review/codex/mdm-5be3042.md`
- **v3 → v4（コミット 431e5e1、gpt-5.6-sol medium、High 2件を全採用）**: メインが `git check-ref-format` の実挙動を実測確認して裁定。反映:
  - ref 形式検証を `git check-ref-format --branch` に修正（素の check-ref-format は bare な main / tag を exit 1 で弾くため既定値 main が設定エラーになる欠陥だった）。main/tag/完全ref/SHA/不正値を回帰テスト対象に追加（§5.5, §7.2, §12）
  - 単一ファイル配布の launcher を独立成果物にせず install-mdm.{sh,ps1} の自己ブートストラップ機能として定義（§3.1, §4.1, §5.1a）、テストも追加（§12）
  裁定記録: `.review/codex/mdm-431e5e1.md`
