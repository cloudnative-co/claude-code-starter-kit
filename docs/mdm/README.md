# MDM でのサイレント配布ガイド（macOS）

> English version: follow-up（未作成。本ファイルは日本語のみ）

対象読者: claude-code-starter-kit を Jamf / Intune / Workspace ONE / Ivanti などの MDM 経由で macOS 端末へゼロタッチ配布する運用者。

**現時点の実装は macOS のみ**（`mdm/install-mdm.sh` / `mdm/render-expected.py` / `mdm/detect-mdm.sh`）。Windows 版（`install-mdm.ps1` 等）は今後対応予定であり、本ガイドの対象外。

---

## 1. 配布単位

production remediation の配布単位は、同じキットリリースに含まれる **`install-mdm.sh` と `render-expected.py` の 2 ファイル**。両方を同じ root-owned ディレクトリへ配置し、`install-mdm.sh` を直接実行する。`render-expected.py` は checkout のコードを実行せず期待状態を静的に生成する trust bundle の一部であり、対象端末の checkout から取得した別コピーで代用しない。検知には `detect-mdm.sh` も別途配布する。

### MDM baseline（MDM のアプリ/pkg 配布機能で事前配置）

- **Xcode Command Line Tools（.pkg）**: 第一選択。`install-mdm.sh` は CLT 不在時、既定では非公式手法を使わず「MDM baseline で配布してください」というログを出して `exit 10` する（`KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true` を明示した場合のみ、Apple 公式に文書化されていない `softwareupdate` 経由のフォールバックをベストエフォートで試みる）。
- **Homebrew**: setup を実行する対象ユーザーから Homebrew が実行でき、`brew --prefix` がそのユーザーによって書込可能であることが必要。`KIT_MDM_PREREQ_MODE=auto`（既定）で brew が存在しない、壊れている、または対象ユーザーから利用できない場合は、Homebrew 公式 `.pkg`（GitHub Releases）+ `HOMEBREW_PKG_USER` を適用して対象ユーザーで再検証する。`KIT_MDM_PREREQ_MODE=fail` は自動導入・修復を行わず、利用可能な brew がなければ `exit 10`。auto の pkg 適用または適用後の再検証に失敗した場合は `exit 11`。事前配布するときも、対象ユーザーが prefix へ書き込める状態にする。

Homebrew pkg のダウンロード URL は `https://github.com/Homebrew/brew/releases/download/` 配下に制約し、`pkgutil --check-signature` で Team ID `927JGANW46`（2026-07-17 に release 6.0.11 の実 pkg で確認）へ pin する。署名証明書のローテーション時は fail-closed になる。MDM 管理下の `setup.sh` は独自の Homebrew `curl | bash` installer や nvm installer へフォールバックしない。`fail` では package manager、Node.js、Bash 4+ を含む前提ツールの自動導入も行わず、不足を `exit 10` で報告する。`auto` でも前提ツールを満たせなければ `exit 10`。ネットワーク制限・オフライン環境では baseline への事前配布を推奨する。

### install bundle（MDM の pkg / file 配布 + スクリプト実行機能で配置）

- `install-mdm.sh` と `render-expected.py` を同じ root-owned ディレクトリへ配置する。推奨 mode はディレクトリ `0755`、`install-mdm.sh` `0755`、`render-expected.py` `0644`。別配布の `detect-mdm.sh` は直接実行のため `0755` とする。ファイル、最終ディレクトリ、信頼起点までの祖先は symlink ではなく、root 所有かつ group/other 書込不可にする。単一スクリプト枠しかない製品では、2 ファイルを pkg / file payload で先に配置し、スクリプト枠から配置済み `install-mdm.sh` を起動する。
- production は **root 実行かつ小文字 40 桁の commit SHA 指定が必須**。root は固定 HTTPS URL から root-private な authoritative checkout を作り、対象ユーザーから書き換えられないことを確認する。Git は setup 前の checkout 構築にだけ使用し、postcondition 検証と detector では起動しない。
- `setup.sh` は authoritative checkout から、検証済み対象ユーザーの clean 環境で実行する。root は checkout 内の shell / Python コードを source も実行もせず、trust bundle の `render-expected.py` だけを root で実行する。
- renderer は固定 SHA と MDM 設定から、存在すべき managed files（present）の内容・mode と、存在してはならない managed files（absent）を静的に生成する。root は配備後の live files / snapshot が present と一致し、absent が双方から消えていることを完全照合した場合だけ schema v2 レシートを書く。
- **推奨起動方法はファイルの直接実行**。shebang と内蔵 launcher が継承環境を破棄し、`/bin/bash --noprofile --norc -p` へ再実行する。値は環境変数ではなく `KEY=VALUE` 形式の CLI 引数にする。

  ```bash
  FULL_SHA=0123456789abcdef0123456789abcdef01234567
  /path/to/install-mdm.sh KIT_MDM_GIT_REF="$FULL_SHA"
  ```
- MDM 製品が明示的な shell wrapper を要求する場合は、単なる `/bin/bash install-mdm.sh` ではなく次の clean privileged Bash で起動する。

  ```bash
  FULL_SHA=0123456789abcdef0123456789abcdef01234567
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /bin/bash --noprofile --norc -p /path/to/install-mdm.sh \
      PROFILE=standard KIT_MDM_GIT_REF="$FULL_SHA"
  ```

---

## 2. 設定キー

production の優先順位は **CLI 引数 > root-owned 管理設定ファイル > 既定値**（既定プロファイルは `standard`）。launcher は production で継承環境を破棄するため、MDM agent や呼び出し元の環境変数は設定入力にならない。設定を渡すときは CLI 引数か管理設定ファイルを使う。

**CLI 引数**は `KEY=VALUE` 形式（例: `install-mdm.sh PROFILE=full KIT_MDM_GIT_REF=0123456789abcdef0123456789abcdef01234567`）。未知のキー、未知の非空引数、不正値は fail-closed で `exit 50`。空の引数だけは、Jamf の未使用スクリプトパラメータに対応するため無視する。

管理設定ファイルの配置: `/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf`。実装は固定パス `/Library/Application Support` を信頼起点とし、そこから最終ディレクトリまでの存在する各要素と設定ファイルが root 所有、非 symlink、group/other 書込不可、macOS ACL なしであることを検証する。読み取りは検査した inode と open 済み fd を照合して束縛し、不一致や未知キーを含む設定は `exit 50`。

production では対象のローカルアカウント、UID 501 以上、対象ユーザー所有の home が必要。`dscl` の `NFSHomeDirectory` 値は canonicalize して採用するのではなく、**最初から absolute canonical physical path**（`cd -P` の結果と文字列完全一致）でなければならない。`..`、重複 `/`、末尾 `/`、symlink 祖先など別名で同じ場所を指す値も拒否し、home 解決/検証失敗として `exit 20` にする。コンソールユーザー自動検出を使う場合はユーザーセッション開始後に実行する。ADE / PreStage などがアカウントまたは home 作成前に実行した場合も `exit 20` になるため、作成後の定期 check-in で再試行させる。

### 本体（setup.sh）のキーを流用

| キー | 意味 | 備考 |
|---|---|---|
| `PROFILE` | `minimal` / `standard` / `full` | 既定 `standard` |
| `LANGUAGE` | `en` / `ja` | |
| `EDITOR_CHOICE` | `vscode` / `cursor` / `zed` / `neovim` / `none` | `EDITOR` ではなくこの名前（誤名は本体キーと一致しない） |
| `COMMIT_ATTRIBUTION` | コミット/PR での Claude 帰属表示 | boolean |
| `ENABLE_GHOSTTY_SETUP` | Ghostty（GUI ターミナル）導入 | `ENABLE_GHOSTTY` ではなくこの名前。MDM 既定 `false` |
| `ENABLE_FONTS_SETUP` | プログラミングフォント導入 | MDM 既定 `false` |
| `ENABLE_AUTO_UPDATE` | キットの自動更新 | MDM では常に `false`。`true` は `exit 50` |
| `ENABLE_WEB_CONTENT_UPDATE` | Web 取得スキル依存の自動更新 | MDM では常に `false`。`true` は `exit 50` |
| `ENABLE_CODEX_PLUGIN` | Codex Plugin | MDM では常に `false`。`true` は `exit 50` |
| `ENABLE_STATUSLINE` / `ENABLE_SAFETY_NET` / `ENABLE_DOC_SIZE_GUARD` / `ENABLE_FEATURE_RECOMMENDATION` / `ENABLE_PRE_COMPACT_COMMIT` / `ENABLE_NO_FLICKER` / `ENABLE_NEW_INIT` | その他 feature toggle | 未指定時はプロファイル既定に従う |

`ENABLE_GHOSTTY_SETUP` / `ENABLE_FONTS_SETUP` だけは `PROFILE` にかかわらず MDM 既定 `false` で、CLI または管理設定ファイルによる明示的な `true` で opt-in できる。キットの auto-update、web updater、通常の marketplace plugin、Codex Plugin は MDM では常に無効にし、更新は新しい40桁 SHAを指定した MDM 再配布で行う。`SELECTED_PLUGINS` は MDM の許可キーではなく、指定すると `exit 50`。fresh / update とも profile preset や保存済みユーザー設定からこれらを再有効化しない。

### MDM 固有キー（`KIT_MDM_` 接頭辞）

| キー | 既定値 | 意味 |
|---|---|---|
| `KIT_MDM_TARGET_USER` | 自動検出（コンソールユーザー） | 明示指定時もローカルアカウント実在・UID>=501・home 所有者一致を検証する。`dscl` home 値自体が canonical physical path でない場合を含め、不一致は `exit 20` |
| `KIT_MDM_INSTALL_HOMEBREW` | `true` | brew 不在時に pkg 経由で自動導入するか |
| `KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE` | `false` | CLT の非公式 `softwareupdate` フォールバックを許可するか |
| `KIT_MDM_PREREQ_MODE` | `auto` | production で許可するのは `auto` / `fail`。`auto` は対象ユーザーから利用・書込可能な Homebrew を検証し、必要なら公式 pkg を適用したうえで本体前提ツールの導入を許可する。`fail` はすべての前提ツールを検査のみとし、不足時は `exit 10`。`skip` は source-only テスト専用で production は `exit 50` |
| `KIT_MDM_WINDOWS_MODE` | `gitbash` | Windows 実装向けに予約されたキー。現時点の macOS 実装では未使用 |
| `KIT_MDM_INSTALL_CLAUDE_CLI` | `true` | Claude Code CLI 導入を必須とするか。`true` では導入後に下記 Apple Developer ID requirement を検証する。`false` ならレシートの `required_components` に `claude_cli` を含めず、`detect-mdm.sh` も CLI 有無を確認せず、`setup.sh` 側の CLI 導入処理もスキップされる |
| `KIT_MDM_GIT_REF` | `main`（dry-run のみ） | production remediation では小文字 40 桁の full SHA が必須。省略時の `main`、branch、tag、短縮 SHA、64 桁 SHA は production で `exit 50`。dry-run では構文上有効な ref も使用可能 |
| `KIT_MDM_INSTALL_DIR` | `<対象ユーザーの canonical home>/.claude-starter-kit` | production の保持用 checkout はこの固定パスだけを許可し、別パス指定は `exit 50` |
| `KIT_MDM_LOG_DIR` | root: `/Library/Logs/ClaudeCodeStarterKit` / 非 root dry-run: `<home>/Library/Logs/ClaudeCodeStarterKit` | ログ出力先の上書き。root は `/Library/Logs` 配下、非 root dry-run は自分の `<home>/Library/Logs` 配下だけを許可する。違反は `exit 50` |
| `KIT_MDM_DRY_RUN` | `false` | `true` で本体 `setup.sh` の `--dry-run` に伝搬（実ファイルを変更しないプレビュー実行） |

### Proxy

| キー | 意味 | 検証 |
|---|---|---|
| `HTTP_PROXY` / `HTTPS_PROXY` | root フェーズのダウンロードと対象ユーザーフェーズへ渡す proxy | secret-free な `http://host[:port]` / `https://host[:port]`（末尾 `/` は可）だけを許可。userinfo、資格情報、path、query、fragment、空白、制御文字は拒否 |
| `NO_PROXY` | proxy 除外指定 | 空白と制御文字を拒否 |

proxy と `KIT_MDM_TARGET_USER` も production の継承環境からは読まれない。MDM 製品側で CLI 引数として可視化するか、root-owned 管理設定ファイルへ記述する。

### MDM 管理範囲

- `settings.json` はファイル全体が MDM-owned desired state。fresh / update とも renderer の期待内容へ収束し、ユーザーが追加した key や hook は保持しない。
- キットが配布する agents / rules / commands / skills / hook scripts は MDM-owned。present の各 live file / snapshot は内容・modeを完全一致させ、profile 変更やキットからの廃止で absent になった管理ファイルは双方から除去する。
- `CLAUDE.md` は `BEGIN/END STARTER-KIT-MANAGED` 間だけを MDM 管理する。既存の user section は保持し、その内容は期待状態と deployment digest の対象外にする。
- キットの配布対象ではないユーザー作成ファイル（`user-*` を含む）は保持し、manifest、snapshot、deployment digest の対象に加えない。

---

## 3. 終了コード

| コード | 意味 |
|---|---|
| 0 | 成功 |
| 10 | CLT 不足、Homebrew の自動導入が無効、または setup / dry-run に必要な前提ツールが不足・導入失敗 |
| 11 | Homebrew 公式 pkg bootstrap または導入後の対象ユーザー利用性再検証の失敗 |
| 20 | 対象ユーザー・ホーム解決/検証失敗 |
| 21 | 非対応の実行コンテキスト（非 root の通常 remediation）、または同一対象ユーザーの remediation lock 競合。非 root は dry-run のみ許可 |
| 30 | 前提条件以外のキットセットアップ、expected-state 照合、または git ref / HEAD 照合の失敗 |
| 40 | Claude Code CLI 導入失敗（キット自体は導入済みの部分失敗。レシート `partial:["claude_cli"]`） |
| 50 | 管理設定エラー（不正キー・不正値・パーミッション・不正 ref 形式） |
| 60 | 非対応 OS（Darwin 以外） |

---

## 4. ログ・レシート

### ログ

既定パス: root 実行時 `/Library/Logs/ClaudeCodeStarterKit/install-<UTC タイムスタンプ>.log`、非 root dry-run 時 `<home>/Library/Logs/ClaudeCodeStarterKit/install-<UTC タイムスタンプ>.log`（いずれも `KIT_MDM_LOG_DIR` で上書き可・許可プレフィックス配下のみ）。wrapper の各フェーズと対象ユーザー setup の終了コードを記録する。setup 自体の詳細出力は MDM のスクリプト実行 stdout / stderr で確認する。proxy の資格情報は入力自体を拒否し、proxy 値やトークンをログ・レシートへ書かない。設定確定・対象ユーザー解決より前の失敗は、stderr と終了コードが主な報告経路になる。

### レシート

レシートは system/root contract で、保存先は `/Library/Application Support/ClaudeCodeStarterKit/receipt-<user>.json`。非 root dry-run はレシートを作成・更新しない。

成功レシートは root 親プロセスが配備後の postcondition を再検証してから、root-owned、非 symlink、group/other 書込不可、ACL なしのファイルとして atomic に書く。schema v2:

```json
{
  "schema_version": 2,
  "kit_version": "...",
  "git_ref": "...",
  "resolved_sha": "...",
  "install_dir": "...",
  "required_components": ["kit", "claude_cli"],
  "profile": "standard",
  "language": "ja",
  "manifest_path": "/Users/alice/.claude/.starter-kit-manifest.json",
  "manifest_sha256": "<64-hex>",
  "deployment_sha256": "<64-hex>",
  "target_user": "...",
  "result": "success",
  "exit_code": 0,
  "partial": [],
  "timestamp": "...",
  "log_path": "..."
}
```

成功レシートは、次のすべてを root 親プロセスが検証できた場合だけ atomic に書く。

- production で指定した full SHA、root-private authoritative checkout の detached HEAD、保持用 checkout の detached HEAD が一致する
- trusted static renderer が生成した present / absent の完全な期待リストと manifest が一致し、present の各 live file / snapshot の内容・mode が期待値と一致し、absent が双方に存在しない
- managed files / snapshot が対象ユーザー所有の regular file、link count 1、ACL なしで、canonical path にある。`settings.json` は全内容、`CLAUDE.md` は managed section だけを照合する
- schema v2 manifest の SHA-256、profile、language、kit commit が一致し、検証した ordered deployment（present の relative path、live/snapshot hash、live/snapshot mode、および absent path）の SHA-256 を `deployment_sha256` に固定する

成功レシート自体とその信頼チェーンも root-owned、非 symlink、group/other 書込不可、ACL なしでなければならない。失敗レシートは best-effort で、対象ユーザー未解決や安全に書き込めない場合は作成されないことがある。

### Dry-run

通常 remediation は root 専用で、非 root 実行は副作用を起こす前に `exit 21`。明示的な `KIT_MDM_DRY_RUN=true` だけは非 root でも許可する。launcher は継承環境を破棄するため、`KIT_MDM_DRY_RUN=true /path/to/install-mdm.sh` という環境変数 prefix ではなく次のように CLI 引数で渡す。

```bash
FULL_SHA=0123456789abcdef0123456789abcdef01234567
/path/to/install-mdm.sh KIT_MDM_DRY_RUN=true KIT_MDM_GIT_REF="$FULL_SHA"
```

dry-run は一時 checkout で `setup.sh --dry-run` を実行し、成功・失敗どちらでも削除する。前提ツール、固定 install dir、管理 marker、manifest、managed files、レシートを作成・更新しないため、既存の compliance 判定も変わらない。ただし監査用ログは永続作成し、stderr も出力するため、ファイルシステム全体に対する副作用ゼロの実行ではない。CLT または dry-run に必要な軽量前提ツールが不足していても導入せず `exit 10`。

**タイムアウトの目安**: 外部ダウンロード（Homebrew pkg 取得・キット clone・Claude CLI 導入）を含むためネットワーク状況に左右される。MDM 側のスクリプトタイムアウトは 15〜30 分程度を推奨。

---

## 5. 検知スクリプト（detect-mdm.sh）

```bash
FULL_SHA=0123456789abcdef0123456789abcdef01234567
./mdm/detect-mdm.sh                          # root: コンソールユーザー / 非root: 自分自身を判定
./mdm/detect-mdm.sh --user alice              # 対象ユーザーを明示
./mdm/detect-mdm.sh --min-version 0.73.0      # kit_version の下限
./mdm/detect-mdm.sh --expected-commit "$FULL_SHA" # 指定した40桁 commitへ固定
```

`detect-mdm.sh` も privileged shebang から clean Bash へ入るため、実行権限を付けて直接起動する。`/bin/sh detect-mdm.sh` や `/bin/bash detect-mdm.sh` は shebang の保護を迂回するため禁止。shell wrapper が必須なら、§1 と同じ `env -i` + `/bin/bash --noprofile --norc -p` 形式を使う。

標準出力:

- 準拠時: `compliant`（exit 0）
- 非準拠時: `non-compliant: <理由>`（exit 1）
- 使用法エラー: usage を stderr へ出力（exit 2）。未知/不足引数、不正な semver、40 桁でない `--expected-commit` が該当

対象ユーザーの既定: **root 実行（MDM の検知コンテキスト）ではコンソールユーザーを解決**し、非 root 実行では自分自身を self-check する。どちらも system 領域の root receipt だけを信頼する。`--user` の値と解決したユーザー名は文字種検証され、不正なら non-compliant。

判定条件（すべて満たして初めて `compliant`）:

- root-owned で非 symlink、group/other 書込不可、ACL なしの schema v2 レシートと、その root-owned な親ディレクトリ信頼チェーン
- レシートの `result=="success"` かつ `exit_code==0`
- レシートの `target_user` が対象ユーザーと一致（退職者アカウント等、別ユーザーのレシートを除外）
- `resolved_sha` が小文字40桁 SHAで、`install_dir/.git/HEAD` が exact 41 bytes の detached HEAD として一致。`--expected-commit` 指定時はその SHA とも一致
- detector は Git を一切起動せず、HEAD を inode/size 束縛した fd から直接読むため、checkout の Git config、hook、filter を実行しない
- `manifest_path` が対象ユーザーの固定パスで、manifest SHA-256、schema v2、`kit_commit`、`profile`、`language`、`claude_dir`、snapshot、present / absent の管理ファイル一覧が一致
- present の各 live file / snapshot は対象ユーザー所有の regular file、link count 1、ACL なしで、absent は双方に存在しない。内容・mode・absent path から再計算した ordered digest がレシートの `deployment_sha256` と一致する。`CLAUDE.md` の user section と manifest 外のユーザーファイルは再計算対象外
- `required_components` に `claude_cli` が含まれる場合、`~/.local/bin/claude` が `~/.local/share/claude/versions/<version>` 配下の実体への symlink であり、fd-bound snapshot に対する `codesign --verify --strict -R` が次の**明示 Apple Developer ID requirement**を満たす: identifier `com.anthropic.claude-code`、`anchor apple generic`、intermediate certificate OID `1.2.840.113635.100.6.2.6`、leaf certificate OID `1.2.840.113635.100.6.1.13`、leaf `subject.OU`（Team ID）`Q6L2SF6YDW`
- 上記 requirement に加えて、`codesign -dv` の identifier `com.anthropic.claude-code`、Team ID `Q6L2SF6YDW`、Authority `Developer ID Application: Anthropic PBC (Q6L2SF6YDW)` も完全一致する。identifier / Team ID / Authority の表示文字列だけでは Apple の trust anchor を証明したことにならない
- `--min-version` 指定時は `kit_version` を比較

postcondition と detector が証明するのは、対象ユーザー所有ツリーを検査した**時点の観測結果**であり、ツリー全体の永続的・原子的な snapshot ではない。per-user lock はキットの remediation 同士だけを直列化し、対象ユーザーが検査と同時に意図的な rename / write を続ける状況までは排他しない。通常の変更は次回 detector で non-compliant になる。hostile な同時変更まで防ぐ必要がある環境では、root-owned write-protected subtree または APFS snapshot など別の端末統制が必要で、本実装の非破壊な user-owned 配備契約の範囲外。

---

## 6. 冪等性・更新チャネル

production の保持用 checkout は `<対象ユーザーの canonical home>/.claude-starter-kit` に固定する。対象ユーザー権限で作成した `.claude-starter-kit-mdm-managed` marker を持つ checkout だけを再構築対象として認め、marker のない既存ディレクトリは削除せず `exit 50` にする。root は target-user writable path へ marker を直接書き込まず、owner / mode / ACL / link count と内容を bounded snapshot で検証する。保持用 checkout は対象ユーザー所有の運用 artifact で、配備の authority や root の実行元にはしない。

再構築は対象ユーザー権限で、保持先と**同じ親ディレクトリ**の専用 stage に fixed-SHA checkout を完成させる。clean HEAD と管理 marker を検証した後だけ、初回は no-replace rename、更新時は exchange rename で保持先へ原子的に切り替え、切替後も marker / HEAD を再検証する。clone・checkout・marker 作成・切替後検証の途中で失敗した場合、更新時は旧 checkout を保持または復元し、初回は自身が作成した不完全な保持先と stage を除去するため、次回 remediation で安全に再試行できる。

各 remediation は指定した full SHA から root-private authoritative checkout を新規作成し、対象ユーザーで `setup.sh --non-interactive`（既存 manifest があれば `--update`）を実行する。終了後は Git を起動せず detached HEAD を直接照合し、renderer の期待状態へ収束したことを検証してから一時 checkout を削除する。

同一対象ユーザーの mutating remediation は、system 領域の root-owned per-user lock で全工程を排他する。競合した実行は checkout、管理履歴、レシートを変更せず `exit 21`。既存 `~/.claude` の再構成前には予約 prefix `~/.claude.mdm-backup.<UTCタイムスタンプ>[.<連番>]` へバックアップし、MDM バックアップは最新1世代だけ保持する。この prefix は MDM 専用のため、ユーザーの保存先には使わない。

root-owned managed history は、直前に root postcondition を通過した **present path だけ**を削除権限として保持する。次回 remediation はこの履歴にある旧 managed path を profile 変更・廃止時に安全に absent へ収束できるが、失敗した remediation の期待一覧、対象ユーザー manifest、失敗レシートを削除根拠にはしない。history は postcondition 成功後だけ atomic に更新され、失敗時は前回成功時の内容を維持する。

初回の MDM 移行では root history がまだないため、今回の profile で absent になるキット同名 path に checkout と異なる内容が残っている場合、そのファイルを削除せず `exit 30` で停止する。対象が以前の管理ファイルか個人ファイルかを自動判定できないためであり、管理者が内容を確認して退避・削除するか、その path を present にする profile で一度 postcondition を成立させてから profile を変更する。

MDM から渡した設定値は update/再実行でも維持される: wrapper は内部マーカー `KIT_MDM_MANAGED=true` を注入し、本体（wizard）は manifest / 保存済みユーザー設定の復元後に MDM 注入値を再適用する（管理端末では MDM 管理者の設定が保存済みユーザー設定より優先。非 MDM 実行には影響しない）。

**再実行をいつ・どう起動するかは MDM 製品ごとに設計が異なる**ため、次の「検知→修復」パターンを共通の推奨形とする。

- **検知**: `detect-mdm.sh` を製品のレポーティング機能（Extension Attribute / Custom Attribute / Sensor）に載せる
- **修復**: root-owned に配置した install bundle の `install-mdm.sh` を、製品のスケジュール実行/ポリシー機能で full SHA 指定付きで定期起動する

具体的な組み方は次章で製品ごとに示す。

---

## 7. 製品別手順

> 以下は各製品の公式ドキュメントで確認できた範囲のみを記載する。確認できなかった項目は「要検証」と明記する。

### Jamf Pro

- **MDM baseline**: 必要なら CLT の pkg を、スクリプト実行より先に別 Policy（例: Execution Frequency = Once per computer）で配布する。
- **install bundle**: `install-mdm.sh` と `render-expected.py` を同じ root-owned payload path へ入れた pkg を配布する。Policy では pkg をスクリプトより先に実行する。
- **スクリプト枠**: 配置済み `install-mdm.sh` を直接起動する launcher を Jamf Pro の Script として登録し、Policy にアタッチする（root 権限で実行される）。
  - 設定はスクリプトパラメータ（Parameter 4〜11）から launcher 経由で `KEY=VALUE` として渡せる（例: Parameter 4 = `PROFILE=full`、Parameter 5 = `KIT_MDM_GIT_REF=0123456789abcdef0123456789abcdef01234567`）。未使用パラメータの空文字は無視される。
  - 実行頻度は Policy の **Execution Frequency** で選ぶ。冪等な定期再実行には `Once every day` が扱いやすい（CLT 未導入等で失敗した端末は翌日以降の Recurring Check-in で再試行される）。`Ongoing`（チェックインの都度）はサーバー/クライアント負荷への影響が公式ドキュメントで注意喚起されている。
  - Recurring Check-in の既定間隔は 15 分（変更可能）。
- **検知（Extension Attribute）**: `detect-mdm.sh` の出力を Jamf Pro の EA スクリプト標準出力契約である `<result>...</result>` でラップする:

  ```bash
  #!/bin/bash
  result="$(/path/to/detect-mdm.sh \
    --expected-commit 0123456789abcdef0123456789abcdef01234567 2>/dev/null || true)"
  printf '<result>%s</result>\n' "${result:-non-compliant: detector failed}"
  exit 0
  ```

  SHA は remediation と同じ値へ置き換える。この EA を条件にした Smart Computer Group（例: 値が `non-compliant` を含む）を作り、それを上記 Policy のスコープにすれば「非準拠端末にのみ再配布」を実現できる。

### Microsoft Intune

現行実装は macOS のみのため、Intune 側も **macOS 向けの機能**（Windows の Platform Script / Remediations とは別物）を使う。

- **MDM baseline / install bundle**: CLT と、`install-mdm.sh` + `render-expected.py` を root-owned path へ配置する pkg を macOS 向け App（LOB pkg 配布）で事前配布する。
- **スクリプト枠（修復に相当）**: `Devices > By platform > macOS > Manage devices > Scripts` に、配置済み `install-mdm.sh` を full SHA 指定で直接起動する **Shell script** を登録する。既定は root 実行（"Run script as signed-in user" = No のまま）。
  - **Script frequency** を「1 回のみ」ではなく定期（例: 1 日ごと）に設定すると、その頻度で再実行される。macOS のシェルスクリプトはこの Script frequency 自体が組み込みの定期再実行機能であるため、**Windows 向けの Remediations や Win32 app による回避策は macOS では不要**——というより、そもそも**Remediations は Windows 専用機能**であり（公式ドキュメントの前提条件は Microsoft Entra 参加済みの Windows Enterprise/Pro/Education 端末に限定されている）、Win32 app（`.intunewin`）も Windows 専用パッケージ形式のため、いずれも本ガイドの macOS スコープには適用できない。
  - IME（Intune Management Extension）のチェックイン間隔は既定で約 8 時間。
- **検知（Custom attributes for macOS）**: `Devices > By platform > macOS > Organize devices > Custom attributes for macOS` に次の wrapper を登録し、Data type を `String` にする。Custom Attribute は検知スクリプトの stdout を保存したうえで wrapper 自体は必ず `exit 0` にする。exit 1 をそのまま返すと non-compliant 文字列を結果として収集できない場合がある。

  ```bash
  #!/bin/bash
  result="$(/path/to/detect-mdm.sh --expected-commit 0123456789abcdef0123456789abcdef01234567 2>/dev/null || true)"
  printf '%s\n' "${result:-non-compliant: detector failed}"
  exit 0
  ```

  `--expected-commit` は配布対象の40桁 SHAへ置き換える。8 時間ごとに自動実行され、結果が `Result` 列に反映される（出力は20KB以下）。

### VMware/Omnissa Workspace ONE UEM

- **MDM baseline / install bundle**: CLT と、`install-mdm.sh` + `render-expected.py` を root-owned path へ配置する pkg を macOS 向け App として事前配布する。
- **Scripts（修復に相当）**: 配置済み `install-mdm.sh` を full SHA 指定で起動する launcher を macOS 向け Script（Bash）として登録する。Trigger Type を `SCHEDULE` または `SCHEDULE_AND_EVENT` にし、スケジュール間隔は `FOUR_HOURS` / `SIX_HOURS` / `EIGHT_HOURS` / `TWELVE_HOURS` / `TWENTY_FOUR_HOURS` から選ぶ（ログイン時などのイベントトリガーと併用も可）。
- **Sensors（検知に相当）**: `detect-mdm.sh` を macOS 向け Sensor（Bash）として登録し、Intelligent Hub のサンプルスケジュールに従って定期収集・報告させる。

### Ivanti Neurons for MDM（旧 MobileIron）

- `install-mdm.sh` と `render-expected.py` を同じ root-owned path へ事前配置し、`Admin > All Scripts` の Script Editor には配置済み installer を full SHA 指定で起動する launcher を登録する。Mobile@Work for macOS の Script 設定で対象デバイスに紐付けると、エージェントが割り当てられた launcher をダウンロード・実行する。
- **要検証**: 2-file bundle の payload 配布方法、ポーリング間隔の既定値、および `detect-mdm.sh` の判定結果をレポーティングする機構（Jamf EA / Intune Custom Attribute / Workspace ONE Sensor に相当する機能）の有無・使い方は、この執筆時点で公開ドキュメントから確認できていない。導入前に Ivanti サポートまたは最新の Administrator Guide で確認すること。

### 汎用 MDM（Iru を含む）

上記 4 製品以外（Iru を含む）は製品固有の一次情報を確認できていないため、次の**最小契約**のみを要求する汎用手順として扱う:

- `install-mdm.sh` と `render-expected.py` を同じ root-owned path へ安全に配置できること
- root で、配置済み `install-mdm.sh` を full SHA 指定付きで直接実行できること
- 可能であれば、任意のタイミングで再実行できる（定期実行または手動トリガー）こと
- `detect-mdm.sh` の標準出力を収集できること。製品が非0終了を結果として保存しない場合は Intune と同様に stdout を捕捉して wrapper を `exit 0` にする

Iru については製品仕様・正式名称を一次情報で確認できるまで固有の手順は記載しない。

---

## 8. 実機確認事項

実装は単体テスト（モック含む）で検証済みだが、以下は実機またはネットワーク到達可能な環境での確認が必要。

- **Homebrew pkg 自動導入の実機確認**: GitHub API（`api.github.com/repos/Homebrew/brew/releases/latest`）のレート制限、`installer` 実行、`HOMEBREW_PKG_USER` plist の読み取り挙動は実機未検証（署名 Team ID `927JGANW46` と plist 受理条件 root/0600 は 2026-07-17 に実 pkg / Homebrew ソースで確認済み）。Homebrew の署名証明書ローテーション時は Team ID pin により fail-closed になる。
- **system Python の前提**: trusted renderer は非 symlink の `/usr/bin/python3` を使い、`codesign` が Apple platform binary、`Authority=Software Signing`、`Authority=Apple Root CA` を報告することを必須とする。CLT / macOS 側の配置や署名出力が変更された場合は expected-state 生成が fail-closed（`exit 30`）になる。
- **Xcode CLT の非公式フォールバック**（`KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true`）: `softwareupdate` 経由の導入は Apple 公式に文書化された手順ではなく、OS バージョンによって挙動が変わり得る。
- **production remediation の実機確認**: full SHA からの root-private authoritative checkout、target-user setup、trusted renderer の expected-state 完全照合、固定保持用 checkout と管理 marker、schema v2 receipt 作成までの root end-to-end は実機未検証。`launchctl asuser` + `sudo -u` + `env -i`、`scutil`、`dscl`、APFS の owner / mode / ACL / link count も実機で確認が必要。
- **detector / Claude CLI の実機確認**: Git を起動しない direct HEAD 読み取り、deployment digest の再計算、および実際に導入された Claude CLI での symlink 解決と `codesign` 照合は実機 end-to-end が未検証。installer と detector は同じ明示 Apple Developer ID requirement（`anchor apple generic`、intermediate OID `1.2.840.113635.100.6.2.6`、leaf OID `1.2.840.113635.100.6.1.13`、leaf OU / Team ID `Q6L2SF6YDW`、identifier `com.anthropic.claude-code`）を要求し、identifier / Team ID / Authority の表示も完全一致させる。Anthropic が native installer の symlink 配置、identifier、Team ID、署名 Authority または証明書チェーンを変更した場合は、導入が `exit 40` または検知が non-compliant になる。
- **MDM 製品への bundle 配布確認**: Jamf / Intune / Workspace ONE / Ivanti で 2-file bundle を root-owned path へ配置し、定期 launcher と detector の結果収集を組み合わせる手順は、各製品 UI を通した end-to-end が未検証。特に Ivanti の payload 配布と検知レポートは §7 のとおり要確認。
- **proxy 経由の実機確認**: secret-free authority-only proxy を経由した Homebrew、キット、Claude CLI の取得は実ネットワークで未検証。userinfo を含む認証 proxy は仕様上拒否する。
- **Windows 版は未実装**: `install-mdm.ps1` / `detect-mdm.ps1` / `lib-mdm-config.ps1` は本ガイド作成時点で存在しない。実装され次第、本ドキュメントに製品別の Windows 手順を追記する。
- **英語版ドキュメント**: 本ガイドは日本語のみ。英語版（`README.en.md`）は follow-up。

---

## 関連ドキュメント

- ルート README: [README.md](../../README.md)
