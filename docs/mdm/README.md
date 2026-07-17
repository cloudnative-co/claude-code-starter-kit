# MDM でのサイレント配布ガイド（macOS）

> English version: follow-up（未作成。本ファイルは日本語のみ）

対象読者: claude-code-starter-kit を Jamf / Intune / Workspace ONE / Ivanti などの MDM 経由で macOS 端末へゼロタッチ配布する運用者。

**現時点の実装は macOS のみ**（`mdm/install-mdm.sh` / `mdm/detect-mdm.sh` / `mdm/lib-mdm-config.sh`）。Windows 版（`install-mdm.ps1` 等）は別 Plan で今後実装予定であり、本ガイドの対象外。

設計契約（アーキテクチャ・フェーズ・セキュリティ設計の詳細）は設計仕様書を参照: [`docs/superpowers/specs/2026-07-16-mdm-silent-install-design.md`](../superpowers/specs/2026-07-16-mdm-silent-install-design.md)

---

## 1. 配布単位

「1 スクリプトで全部入り」は成立しない（前提ツールの一部は特権/再起動を要する重い導入のため、スクリプトではなく MDM ネイティブの配布機能に委ねる必要がある）。次の 2 層で配布する。

### MDM baseline（MDM のアプリ/pkg 配布機能で事前配置）

- **Xcode Command Line Tools（.pkg）**: 第一選択。`install-mdm.sh` は CLT 不在時、既定では非公式手法を使わず「MDM baseline で配布してください」というログを出して `exit 10` する（`KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true` を明示した場合のみ、Apple 公式に文書化されていない `softwareupdate` 経由のフォールバックをベストエフォートで試みる）。
- **Homebrew（任意）**: `install-mdm.sh` 自身が Homebrew 公式 `.pkg`（GitHub Releases）+ `HOMEBREW_PKG_USER` 方式で自動導入する（`curl | bash` は使わない）。ダウンロード URL は `https://github.com/Homebrew/brew/releases/download/` 配下のみに制約し、`pkgutil --check-signature` の署名検証は Homebrew の Developer ID Team ID（`927JGANW46`。2026-07-17 に release 6.0.11 の実 pkg で確認）に pin している。Homebrew 側が署名証明書をローテーションした場合は fail-closed（`exit 11`）になるため、その際はキットの更新を待つか MDM baseline での事前配布に切り替える。したがって Homebrew は MDM baseline での事前配布が必須ではないが、ネットワーク制限のある環境やオフライン端末では事前配布しておくと確実に導入できる。

### mdm/ bundle（MDM の「スクリプト実行」機能でアップロード）

- 実体は `install-mdm.sh` + `lib-mdm-config.sh`（同一 `mdm/` ディレクトリ）。
- **MDM が単一ファイルしかアップロードできない場合**: `install-mdm.sh` 単体をアップロードすればよい。隣に `lib-mdm-config.sh` が無いことを自分で検知し、`KIT_MDM_GIT_REF` に固定した ref でリポジトリの `mdm/` 一式を取得し、取得した実体から自分自身を再実行する（自己ブートストラップ）。
- オフライン端末が多い運用では、`install-mdm.sh` + `lib-mdm-config.sh` の両方を事前にまとめて配布（スクリプトのペイロード添付機能等）してもよい。

---

## 2. 設定キー

優先順位: **CLI 引数 > 環境変数 > 管理設定ファイル > 既定値**（既定値は standard プロファイル相当）。全入力源の値を優先順位確定後に一括で型検証するため、**環境変数・CLI 引数由来の不正値も `exit 50`** になる（管理設定ファイルだけが検証されるわけではない）。

**CLI 引数**は `KEY=VALUE` 形式（例: `install-mdm.sh PROFILE=full KIT_MDM_GIT_REF=v0.73.0`）。許可キー以外・`KEY=VALUE` 形式でない引数は警告して無視し、空の引数も無視する（Jamf の未使用スクリプトパラメータ `$4`〜`$11` が空文字で渡されるケースに対応）。

管理設定ファイルの配置: `/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf`。読み取り直前に「ファイルと親ディレクトリが root 所有」「ファイル・親ディレクトリとも group/other 書込不可」「symlink でない」ことを検証し、いずれか不満足なら `exit 50`。読み取りは検査した実体と読む実体を dev:inode 照合で束縛した fd から行う（検査と読み取りの間の差し替えは `exit 50`）。

### 本体（setup.sh）のキーを流用

| キー | 意味 | 備考 |
|---|---|---|
| `PROFILE` | `minimal` / `standard` / `full` | 既定 `standard` |
| `LANGUAGE` | `en` / `ja` | |
| `EDITOR_CHOICE` | エディタ選択 | `EDITOR` ではなくこの名前（誤名は本体キーと一致しない） |
| `COMMIT_ATTRIBUTION` | コミット/PR での Claude 帰属表示 | boolean |
| `ENABLE_GHOSTTY_SETUP` | Ghostty（GUI ターミナル）導入 | `ENABLE_GHOSTTY` ではなくこの名前。**MDM 配布では既定 `false`**（本体 `profiles/standard.conf` の既定 `true` を `install-mdm.sh` が未設定時のみ `false` へ上書きする）。導入したい場合は `mdm-config.conf` 等で明示的に `true` を設定する |
| `ENABLE_FONTS_SETUP` / `ENABLE_STATUSLINE` / `ENABLE_SAFETY_NET` / `ENABLE_AUTO_UPDATE` / `ENABLE_DOC_SIZE_GUARD` / `ENABLE_FEATURE_RECOMMENDATION` / `ENABLE_PRE_COMPACT_COMMIT` / `ENABLE_WEB_CONTENT_UPDATE` / `ENABLE_NO_FLICKER` / `ENABLE_NEW_INIT` | その他 feature toggle | 未指定時はプロファイル既定に従う |

これらのキー名は本体 `wizard/registry.sh` の `_CONFIG_KEYS` と自動照合するテスト（`tests/unit/test-mdm-keys-in-sync.sh`）で乖離を検知しているため、本体がキー名を変更すれば CI が落ちる。

### MDM 固有キー（`KIT_MDM_` 接頭辞）

| キー | 既定値 | 意味 |
|---|---|---|
| `KIT_MDM_TARGET_USER` | 自動検出（コンソールユーザー） | 明示指定時もローカルアカウント実在・UID>=501・home 所有者一致等を検証し、不一致は `exit 20` |
| `KIT_MDM_INSTALL_HOMEBREW` | `true` | brew 不在時に pkg 経由で自動導入するか |
| `KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE` | `false` | CLT の非公式 `softwareupdate` フォールバックを許可するか |
| `KIT_MDM_PREREQ_MODE` | `auto` | `auto` / `skip`（テスト用） / `fail`（不足時に即 `exit 10`） |
| `KIT_MDM_WINDOWS_MODE` | `gitbash` | Windows 実装向けに予約されたキー。現時点の macOS 実装では未使用 |
| `KIT_MDM_INSTALL_CLAUDE_CLI` | `true` | Claude Code CLI 導入を必須とするか。`false` ならレシートの `required_components` に `claude_cli` を含めず、`detect-mdm.sh` も CLI 有無を確認せず、`setup.sh` 側の CLI 導入処理もスキップされる |
| `KIT_MDM_GIT_REF` | `main` | 配布バージョン固定（ブランチ/タグ/40 or 64 桁 SHA）。fleet ではタグまたは SHA 固定を強く推奨（`main` は mutable）。単一ファイル配布の自己ブートストラップにもこの ref が適用される |
| `KIT_MDM_INSTALL_DIR` | `<対象ユーザーの canonical home>/.claude-starter-kit` | clone 先の絶対パス。**対象ユーザーの home 配下のみ許可**（home 外・`..` 含みは `exit 50`） |
| `KIT_MDM_LOG_DIR` | root: `/Library/Logs/ClaudeCodeStarterKit` / ユーザーモード: `<home>/Library/Logs/ClaudeCodeStarterKit` | ログ出力先の上書き。許可プレフィックスは実行モードで異なる: root は `/Library/Logs` 配下のみ（ユーザー書込可能領域への root 書込を防ぐ）、ユーザーモードは `<home>/Library/Logs` 配下のみ。違反は `exit 50` |
| `KIT_MDM_DRY_RUN` | `false` | `true` で本体 `setup.sh` の `--dry-run` に伝搬（実ファイルを変更しないプレビュー実行） |

---

## 3. 終了コード

| コード | 意味 |
|---|---|
| 0 | 成功 |
| 10 | 前提ツール導入失敗/不足（不足一覧をログに出力） |
| 11 | Homebrew ブートストラップ失敗 |
| 20 | 対象ユーザー・ホーム解決/検証失敗 |
| 21 | 非対応の実行コンテキスト（Windows 版の SYSTEM 実行検知用に予約。現行 macOS 実装では未使用） |
| 30 | キットセットアップ失敗 / git ref 照合失敗 |
| 40 | Claude Code CLI 導入失敗（キット自体は導入済みの部分失敗。レシート `partial:["claude_cli"]`） |
| 50 | 管理設定エラー（不正キー・不正値・パーミッション・不正 ref 形式） |
| 60 | 非対応 OS（Darwin 以外） |

---

## 4. ログ・レシート

### ログ

既定パス: root 実行時 `/Library/Logs/ClaudeCodeStarterKit/install-<UTC タイムスタンプ>.log`、ユーザーモード（非 root）実行時 `<home>/Library/Logs/ClaudeCodeStarterKit/install-<UTC タイムスタンプ>.log`（いずれも `KIT_MDM_LOG_DIR` で上書き可・許可プレフィックス配下のみ）。root フェーズ・ユーザーフェーズとも同一ファイルに追記される。秘密情報・トークンは書き込まれない。なお、設定確定・対象ユーザー解決より前の失敗（`exit 50` / `exit 20` の一部）はログファイルが開かれる前のため、stderr（MDM 側が捕捉するスクリプト出力）と終了コード・best-effort の `receipt-_unresolved.json` が報告経路になる。

### レシート

- root 実行時: `/Library/Application Support/ClaudeCodeStarterKit/receipt-<user>.json`
- ユーザーモード（非 root）実行時: `<home>/Library/Application Support/ClaudeCodeStarterKit/receipt-<user>.json`

schema:

```json
{
  "schema_version": 1,
  "kit_version": "...",
  "git_ref": "...",
  "resolved_sha": "...",
  "install_dir": "...",
  "required_components": ["kit", "claude_cli"],
  "profile": "standard",
  "target_user": "...",
  "result": "success",
  "exit_code": 0,
  "partial": [],
  "timestamp": "...",
  "log_path": "..."
}
```

失敗保証は best-effort。対象ユーザー未解決や書込不能時はレシートが書けないことがある。可能なら root 領域に `receipt-_unresolved.json` を書くフォールバックを試みるが、無条件の「必ず書く」保証はしない。書き出しは jq 非依存（`printf` + JSON エスケープ）。

**タイムアウトの目安**: 外部ダウンロード（Homebrew pkg 取得・キット clone・Claude CLI 導入）を含むためネットワーク状況に左右される。MDM 側のスクリプトタイムアウトは 15〜30 分程度を推奨。

---

## 5. 検知スクリプト（detect-mdm.sh）

```bash
bash mdm/detect-mdm.sh                          # root: コンソールユーザー / 非root: 自分自身のレシートを判定
bash mdm/detect-mdm.sh --user alice              # 対象ユーザーを明示
bash mdm/detect-mdm.sh --min-version 0.73.0      # kit_version がこれ未満なら non-compliant
```

標準出力:

- 準拠時: `compliant`（exit 0）
- 非準拠時: `non-compliant: <理由>`（exit 1）

対象ユーザーの既定: **root 実行（MDM の検知コンテキスト）ではコンソールユーザーを解決**して `receipt-<console-user>.json` を見る。非 root 実行では自分自身の self-check。`--user` の値と解決したユーザー名は文字種検証され、不正なら non-compliant。

判定条件（すべて満たして初めて `compliant`）:

- レシートの `result=="success"`
- レシートの `target_user` が対象ユーザーと一致（退職者アカウント等、別ユーザーのレシートを除外）
- `install_dir` の clone が実在し、`git rev-parse HEAD` がレシートの `resolved_sha` と一致（実体照合）
- `required_components` に `claude_cli` が含まれる場合のみ、**対象ユーザーの home**（`~/.local/bin/claude`）で Claude CLI を確認（検知プロセスの PATH には依存しない）
- `--min-version` 指定時は `kit_version` を比較

**既知の制限**（実装簡略化・follow-up 扱い）:

- 対象ユーザーのレシートファイルは 1 ユーザー 1 ファイル前提。設計仕様書 §8.4 の「複数レシートがある場合の timestamp 最新選択」は未実装（同名ファイルは上書きされるため通常運用では発生しない）。
- 既定では**システム領域のレシート**（`/Library/Application Support/...`）のみを見る。`install-mdm.sh` をユーザーモード（非 root）で実行した場合のレシートはユーザーの home 配下に書かれるため、既定の `detect-mdm.sh` 呼び出しでは見つからない（MDM の主経路である root 実行では影響しない）。

---

## 6. 冪等性・更新チャネル

`install-mdm.sh` は何度実行しても安全。既存 clone を検出したら `KIT_MDM_GIT_REF` を再解決して checkout し直し、対象ユーザーの既存インストール（`~/.claude/.starter-kit-manifest.json`）を検出した場合は本体を `setup.sh --update`（3-way マージの update パス）で呼び出す。root 実行時の git 操作（clone を含む）はすべて検証済み対象ユーザーへ環境分離降格して行われる。**再実行をいつ・どう起動するかは MDM 製品ごとに設計が異なる**ため、次の「検知→修復」パターンを共通の推奨形とする。

- **検知**: `detect-mdm.sh` を製品のレポーティング機能（Extension Attribute / Custom Attribute / Sensor）に載せる
- **修復**: `install-mdm.sh` を製品のスケジュール実行/ポリシー機能で定期的に起動する

具体的な組み方は次章で製品ごとに示す。

---

## 7. 製品別手順

> 以下は各製品の公式ドキュメントで確認できた範囲のみを記載する。確認できなかった項目は「要検証」と明記する。

### Jamf Pro

- **MDM baseline**: 必要なら CLT の pkg を、スクリプト実行より先に別 Policy（例: Execution Frequency = Once per computer）で配布する。
- **スクリプト枠**: `install-mdm.sh` を Jamf Pro の Script として登録し、Policy にアタッチする（root 権限で実行される）。
  - 設定はスクリプトパラメータ（Parameter 4〜11）に `KEY=VALUE` 形式で渡せる（例: Parameter 4 = `PROFILE=full`、Parameter 5 = `KIT_MDM_GIT_REF=v0.73.0`）。未使用パラメータの空文字は無視される。
  - 実行頻度は Policy の **Execution Frequency** で選ぶ。冪等な定期再実行には `Once every day` が扱いやすい（CLT 未導入等で失敗した端末は翌日以降の Recurring Check-in で再試行される）。`Ongoing`（チェックインの都度）はサーバー/クライアント負荷への影響が公式ドキュメントで注意喚起されている。
  - Recurring Check-in の既定間隔は 15 分（変更可能）。
- **検知（Extension Attribute）**: `detect-mdm.sh` の出力を Jamf Pro の EA スクリプト標準出力契約である `<result>...</result>` でラップする:

  ```bash
  #!/bin/bash
  result="$(/usr/bin/env bash /path/to/detect-mdm.sh 2>/dev/null)"
  echo "<result>${result}</result>"
  ```

  この EA を条件にした Smart Computer Group（例: 値が `non-compliant` を含む）を作り、それを上記 Policy のスコープにすれば「非準拠端末にのみ再配布」を実現できる。

### Microsoft Intune

現行実装は macOS のみのため、Intune 側も **macOS 向けの機能**（Windows の Platform Script / Remediations とは別物）を使う。

- **MDM baseline**: CLT の pkg を macOS 向け App（LOB pkg 配布）で事前配布する。
- **スクリプト枠（修復に相当）**: `Devices > By platform > macOS > Manage devices > Scripts` に `install-mdm.sh` を **Shell script** として登録する。既定は root 実行（"Run script as signed-in user" = No のまま）。
  - **Script frequency** を「1 回のみ」ではなく定期（例: 1 日ごと）に設定すると、その頻度で再実行される。macOS のシェルスクリプトはこの Script frequency 自体が組み込みの定期再実行機能であるため、**Windows 向けの Remediations や Win32 app による回避策は macOS では不要**——というより、そもそも**Remediations は Windows 専用機能**であり（公式ドキュメントの前提条件は Microsoft Entra 参加済みの Windows Enterprise/Pro/Education 端末に限定されている）、Win32 app（`.intunewin`）も Windows 専用パッケージ形式のため、いずれも本ガイドの macOS スコープには適用できない。
  - IME（Intune Management Extension）のチェックイン間隔は既定で約 8 時間。
- **検知（Custom attributes for macOS）**: `Devices > By platform > macOS > Organize devices > Custom attributes for macOS` に `detect-mdm.sh` を登録し、Data type を `String` にする。8 時間ごとに自動実行され、結果が `Result` 列に反映される（出力は 20KB 以下。`compliant` / `non-compliant: ...` の標準出力がそのまま報告される）。

### VMware/Omnissa Workspace ONE UEM

- **MDM baseline**: CLT を macOS 向け App として事前配布する。
- **Scripts（修復に相当）**: `install-mdm.sh` を macOS 向け Script（Bash）として登録する。Trigger Type を `SCHEDULE` または `SCHEDULE_AND_EVENT` にし、スケジュール間隔は `FOUR_HOURS` / `SIX_HOURS` / `EIGHT_HOURS` / `TWELVE_HOURS` / `TWENTY_FOUR_HOURS` から選ぶ（ログイン時などのイベントトリガーと併用も可）。
- **Sensors（検知に相当）**: `detect-mdm.sh` を macOS 向け Sensor（Bash）として登録し、Intelligent Hub のサンプルスケジュールに従って定期収集・報告させる。

### Ivanti Neurons for MDM（旧 MobileIron）

- `Admin > All Scripts` の Script Editor で `install-mdm.sh` をアップロードし、Mobile@Work for macOS の Script 設定で対象デバイスに紐付ける。Mobile@Work エージェントが定期的にポーリングし、割り当てられたスクリプトをダウンロード・実行する。
- **要検証**: ポーリング間隔の既定値、および `detect-mdm.sh` の判定結果をレポーティングする機構（Jamf EA / Intune Custom Attribute / Workspace ONE Sensor に相当する機能）の有無・使い方は、この執筆時点で公開ドキュメントから確認できていない。導入前に Ivanti サポートまたは最新の Administrator Guide で確認すること。

### 汎用 MDM（Iru を含む）

上記 4 製品以外（Iru を含む）は製品固有の一次情報を確認できていないため、次の**最小契約**のみを要求する汎用手順として扱う:

- root（または管理者権限）で `install-mdm.sh` をスクリプトとして 1 本実行できること
- 可能であれば、任意のタイミングで再実行できる（定期実行または手動トリガー）こと
- `detect-mdm.sh` の標準出力・終了コードをそのまま製品側のスクリプト実行結果として扱えること

Iru については製品仕様・正式名称を一次情報で確認できるまで固有の手順は記載しない（設計仕様書 §2.1 を参照）。

---

## 8. 既知の制限・実機確認事項

実装は単体テスト（モック含む）で検証済みだが、以下は実機またはネットワーク到達可能な環境での確認が必要、あるいは既知の制限として残っている。

- **Homebrew pkg 自動導入の実機確認**: GitHub API（`api.github.com/repos/Homebrew/brew/releases/latest`）のレート制限、`installer` 実行、`HOMEBREW_PKG_USER` plist の読み取り挙動は実機未検証（署名 Team ID `927JGANW46` と plist 受理条件 root/0600 は 2026-07-17 に実 pkg / Homebrew ソースで確認済み）。Homebrew の署名証明書ローテーション時は Team ID pin により fail-closed になる。
- **Xcode CLT の非公式フォールバック**（`KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true`）: `softwareupdate` 経由の導入は Apple 公式に文書化された手順ではなく、OS バージョンによって挙動が変わり得る。
- **`detect-mdm.sh` の複数レシート最新選択**: §5 のとおり 1 ユーザー 1 レシート前提（`target_user` 照合・`resolved_sha` 実体照合・コンソールユーザー既定は実装済み）。
- **root 実行の実機確認**: `launchctl asuser` + `sudo -u` + `env -i` による降格実行、コンソールユーザー解決（`scutil`）、`dscl` によるユーザー検証は単体テストではモックしており、root での end-to-end は実機確認が必要。
- **テストランナーの集計バグ**: `tests/helpers.sh` の pass/fail カウンタがサブシェル内での失敗を親プロセスのカウンタへ伝播しないケースがあり、サブシェル内失敗が CI を赤くしないことがある（プロジェクト全体に影響する既知バグで、別 PR で修正予定。mdm 関連の単体テストは出力の FAIL 行を直接ゲートにする CI ステップ（Bash 3.2 実行検証）で補完している）。
- **Windows 版は未実装**: `install-mdm.ps1` / `detect-mdm.ps1` / `lib-mdm-config.ps1` は本ガイド作成時点で存在しない。実装され次第、本ドキュメントに製品別の Windows 手順を追記する。
- **英語版ドキュメント**: 本ガイドは日本語のみ。英語版（`README.en.md`）は follow-up。

---

## 関連ドキュメント

- 設計仕様書: [`docs/superpowers/specs/2026-07-16-mdm-silent-install-design.md`](../superpowers/specs/2026-07-16-mdm-silent-install-design.md)
- ルート README: [README.md](../../README.md)
