# MDM でのサイレント配布ガイド（macOS）

> English version: follow-up（未作成。本ファイルは日本語のみ）

対象読者: claude-code-starter-kit を Jamf / Intune / Workspace ONE / Ivanti などの MDM 経由で macOS 端末へゼロタッチ配布する運用者。

**現時点の実装と本ガイドの対象は macOS 13.5 以上のみ**（`mdm/install-mdm.sh` / `mdm/render-expected.py` / `mdm/detect-mdm.sh`）。MDM の Safety Net / Web Content Extraction runtime は公式 Node v24.18.0 を固定し、その upstream binary が要求する最小 OS を下限とする。Windows MDM 配布はこの機能の対象外で、対応スクリプトも実装していない。

この機能の目的は、MDM が配布した信頼済み bundle と固定 commit SHA から、ユーザー操作なしで Claude Code CLI と starter kit を導入し、指定した profile / language / feature policy へ冪等に収束させること。検知が非準拠になれば、**新しい SHA への更新だけでなく、同じ SHA の再実行でも**改変・欠落を期待状態へ修復できる。MDM 層は本体の `setup.sh` を対象ユーザー権限で再利用し、配備処理を別実装しない。`settings.json` 以外のユーザー所有領域を不用意に消さないこと、非 MDM の通常インストール/update の挙動を変えないことも契約に含む。

ここでいう「ゼロタッチ」は**利用者への対話を要求しない配備全体**を指す。Xcode Command Line Tools（CLT）は MDM の pkg 配布機能で先に置く baseline が既定であり、`install-mdm.sh` 単体が CLT まで常に自動導入するという意味ではない。

---

## 1. 配布単位

production remediation の配布単位は、同じキットリリースに含まれる **`install-mdm.sh` と `render-expected.py` の 2 ファイル**。両方を同じ root-owned ディレクトリへ配置し、`install-mdm.sh` を直接実行する。`render-expected.py` は checkout のコードを実行せず期待状態を静的に生成する trust bundle の一部であり、対象端末の checkout から取得した別コピーで代用しない。検知には `detect-mdm.sh` も別途配布する。

### MDM baseline（MDM のアプリ/pkg 配布機能で事前配置）

- **OS**: macOS 13.5 以上。13.4 以下はネットワーク取得やユーザー状態変更の前に `exit 60` とする。
- **対象ユーザー home**: `dscl` の絶対 canonical path と所有 UID を一致させ、owner に search bit があり group/other 書込不可の mode を要求する。ACL は無し、または macOS が標準で付与する継承なしの `group:everyone deny delete` 1件だけを許可する。この判定は component が使う home 配下の各 user-owned ancestor（`~/.local`、`~/Library`、`~/Library/Fonts` 等）にも適用し、allow、継承、複数 ACE は拒否する。任意の inheritable ACL は保持用 checkout へ伝播して trust contract を壊すため `exit 20` で拒否する。
- **Xcode Command Line Tools（.pkg）**: 第一選択。`install-mdm.sh` は CLT 不在時、既定では非公式手法を使わず「MDM baseline で配布してください」というログを出して `exit 10` する（`KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true` を明示した場合のみ、Apple 公式に文書化されていない `softwareupdate` 経由のフォールバックをベストエフォートで試みる）。
- **Homebrew**: setup を実行する対象ユーザーから Homebrew が実行でき、`brew --prefix` がそのユーザーによって書込可能であることが必要。`KIT_MDM_PREREQ_MODE=auto`（既定）で brew が存在しない、壊れている、または対象ユーザーから利用できない場合は、Homebrew 公式 `.pkg`（GitHub Releases）+ `HOMEBREW_PKG_USER` を適用して対象ユーザーで再検証する。`KIT_MDM_PREREQ_MODE=fail` は自動導入・修復を行わず、利用可能な brew がなければ `exit 10`。auto の pkg 適用または適用後の再検証に失敗した場合は `exit 11`。事前配布するときも、対象ユーザーが prefix へ書き込める状態にする。

Homebrew pkg のダウンロード URL は `https://github.com/Homebrew/brew/releases/download/` 配下に制約し、`pkgutil --check-signature` で Team ID `927JGANW46`（2026-07-17 に release 6.0.11 の実 pkg で確認）へ pin する。署名証明書のローテーション時は fail-closed になる。MDM 管理下の `setup.sh` は独自の Homebrew `curl | bash` installer や nvm installer へフォールバックしない。`fail` では CLT fallback、package manager、Node.js、Bash 4+、Biome、Safety Net、Web Content Extraction runtime、Ghostty、fonts のネットワーク取得や artifact の build / repair を行わず、固定 baseline を読み取り専用で検査する。root-owned Node / Web Content Extraction bundle が正しければ、setup が対象ユーザー側の activation symlink だけを作成・修復できる。前提ツール不足は `exit 10`、policy が要求する component の検査不成立は該当する setup / CLI failure として報告する。`auto` でも前提ツールまたは必須 component を満たせなければ成功にしない。ネットワーク制限・オフライン環境では baseline への事前配布を推奨する。

**Apple 署名の扱い**: このキット自身は何も署名・再署名しない。このキットの実行・検証に Developer ID 証明書、秘密鍵、Apple Developer アカウントは不要であり、MDM 製品や組織独自 pkg の署名要件は別契約となる。固定 CLT source / link / Python 実体の metadata と Apple 付与済み署名（`identifier "com.apple.python3" and anchor apple`、Sealed Resources v2）を検証してから framework を別 inode 群へコピーし、owner / mode / ACL / symlink / hardlink 境界、同じ Apple 署名、isolated self-test、private full mtree seal を後続フェーズの rebound まで照合する。root 実行の remediation / dry-run と root detector は、この copy を全実行期間 root-owned mode `0700` の private workspace に保持する。唯一の例外である明示的な non-root dry-run は非権威で receipt を変更しないため、実行ユーザー所有 mode `0700` の ephemeral workspace を使う。通常の root helper は private copy だけを実行する。対象ユーザーへ降格する3つの user-owned filesystem 操作と、最終 seal 不一致で private copy を失効させた後の failure-only rollback だけは fixed source を使うが、各呼出し前に署名・Sealed Resources v2・metadata・identity を再束縛し、`-I -B -S` で実行する。production では user-owned 操作の結果も後段の root-private postcondition で再検証する。CLT Python の署名は Apple が付与したもので、こちらが選んだ Developer ID ではない。Node / Ghostty / Claude CLI / Homebrew pkg についても、それぞれ upstream が付与した署名と Team ID を検証するだけである。

`fail` は MDM が事前配布した baseline artifact を読み取り専用で検査するモード。Biome / Safety Net / Node / fonts は `auto` と同じ固定 version、private layout、archive / payload / source SHA-256 または root-owned provenance marker を要求し、同名コマンドや SemVer だけでは受理しない。Ghostty / Claude CLI は明示した Apple Developer ID requirement も要求する。Web Content Extraction の初回 `fail` preseed は、package / lock / marker、layout、owner / mode / ACL を検証した root / MDM trustbase 自体を初回の payload 信頼源とする。過去の receipt / component manifest や対象ユーザー側 activation は前提にせず、setup は通信や build をせず activation symlink だけを作成する。初回成功後は root-owned component manifest の digest が全 file bytes / metadata の後続 drift を検知する。このため、Web Content Extraction の preseed bundle は installer と同じ管理・署名済み配布物に含め、別の未検証 source から root path を作らない。

### install bundle（MDM の pkg / file 配布 + スクリプト実行機能で配置）

- `install-mdm.sh` と `render-expected.py` を同じ root-owned ディレクトリへ配置する。推奨 mode はディレクトリ `0755`、`install-mdm.sh` `0755`、`render-expected.py` `0644`。別配布の `detect-mdm.sh` は直接実行のため `0755` とする。ファイル、最終ディレクトリ、信頼起点までの祖先は symlink ではなく、root 所有かつ group/other 書込不可にする。単一スクリプト枠しかない製品では、2 ファイルを pkg / file payload で先に配置し、スクリプト枠から配置済み `install-mdm.sh` を起動する。
- production は **root 実行、`KIT_MDM_GIT_REF` による小文字 40 桁の commit SHA、`KIT_MDM_EXPECTED_POLICY_SHA256` による小文字 64 桁の expected policy SHA-256 が必須**。root は固定 HTTPS URL から root-private な authoritative checkout を作り、対象ユーザーから書き換えられないことを確認する。Git は setup 前の checkout 構築にだけ使用し、postcondition 検証と detector では起動しない。
- `setup.sh` は authoritative checkout から、検証済み対象ユーザーの clean 環境で実行する。root は checkout 内の shell / Python コードを source も実行もせず、trust bundle の `render-expected.py` だけを root で実行する。
- renderer は固定 SHA と MDM 設定から、存在すべき managed files（present）の内容・mode、存在してはならない managed files（absent）、必須 runtime components、canonical `policy.json` を静的に生成する。production remediation と dry-run は事前配布された `policy.json` の SHA-256 を必須入力とし、root はその一致に加えて配備後の live files / snapshot と runtime components を照合できた場合だけ schema v3 レシートを書く。
- **推奨起動方法はファイルの直接実行**。shebang と内蔵 launcher が継承環境を破棄し、launcher file の physical root-owned chain に加えて、snapshot 作成前に固定 `/private/tmp` の physical chain、root owner、exact mode `1777`、ACL なしを検証してから `/bin/bash --noprofile --norc -p` へ再実行する。値は環境変数ではなく `KEY=VALUE` 形式の CLI 引数にする。

  ```bash
  FULL_SHA=0123456789abcdef0123456789abcdef01234567
  POLICY_SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  /path/to/install-mdm.sh \
    KIT_MDM_GIT_REF="$FULL_SHA" \
    KIT_MDM_EXPECTED_POLICY_SHA256="$POLICY_SHA"
  ```
- MDM 製品が明示的な shell wrapper を要求する場合は、単なる `/bin/bash install-mdm.sh` ではなく次の clean privileged Bash で起動する。

  ```bash
  FULL_SHA=0123456789abcdef0123456789abcdef01234567
  POLICY_SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  /usr/bin/env -i HOME=/var/root PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /bin/bash --noprofile --norc -p /path/to/install-mdm.sh \
      PROFILE=standard KIT_MDM_GIT_REF="$FULL_SHA" \
      KIT_MDM_EXPECTED_POLICY_SHA256="$POLICY_SHA"
  ```

### expected policy SHA-256 の作成

package / policy 作成側では、配布する full SHA を checkout したツリーと、端末へ渡す設定と同じ renderer 引数から policy SHA-256 を作る。`--checkout` / `--output` / `--profile` / `--language` / `--editor` / `--claude-cli-required` / `--logical-home` はすべて必須で、特に editor と Claude CLI 方針を暗黙の既定値に委ねる経路はない。次は installer 既定の `standard` / `en` / `none` / Claude CLI 必須に対応する例。下表の boolean policy 設定（`ENABLE_*`、`INSTALL_*`、`COMMIT_ATTRIBUTION`）を明示する場合は、installer の `KEY=VALUE` と renderer の `--override KEY=VALUE` の双方へ同じ値で渡す。renderer の override allowlist は checkout の全 profile key から導出されるため、下表の一部だけを別の固定リストで管理しない。

```bash
POLICY_TMP="$(mktemp -d)"
POLICY_OUTPUT="$POLICY_TMP/rendered"
python3 /path/to/render-expected.py \
  --checkout /path/to/checkout-at-full-sha \
  --output "$POLICY_OUTPUT" \
  --profile standard \
  --language en \
  --editor none \
  --claude-cli-required true \
  --logical-home /Users/MDMPolicy
POLICY_SHA="$(jq -r '.policy_sha256' "$POLICY_OUTPUT/manifest.json")"
rm -rf "$POLICY_TMP"
```

`--logical-home` は absolute canonical path が必要だが policy digest には含まれないため、この生成専用 placeholder を使える。生成後は `POLICY_SHA` が小文字64桁であることを検証し、同じ値を remediation / dry-run の `KIT_MDM_EXPECTED_POLICY_SHA256` と detector の `--expected-policy-sha256` へ配布する。出力ディレクトリは機微情報を含まないが、一時成果物として処分する。

---

## 2. 設定キー

production の優先順位は **CLI 引数 > root-owned 管理設定ファイル > 既定値**（既定プロファイルは `standard`）。launcher は production で継承環境を破棄するため、MDM agent や呼び出し元の環境変数は設定入力にならない。設定を渡すときは CLI 引数か管理設定ファイルを使う。

**CLI 引数**は `KEY=VALUE` 形式（例: `install-mdm.sh PROFILE=full KIT_MDM_GIT_REF=0123456789abcdef0123456789abcdef01234567 KIT_MDM_EXPECTED_POLICY_SHA256=<64-hex>`）。未知のキー、未知の非空引数、不正値は fail-closed で `exit 50`。空の引数だけは、Jamf の未使用スクリプトパラメータに対応するため無視する。

管理設定ファイルの配置: `/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf`。実装は固定パス `/Library/Application Support` を信頼起点とし、そこから最終ディレクトリまでの存在する各要素と設定ファイルが root 所有、非 symlink、group/other 書込不可、macOS ACL なしであることを検証する。読み取りは検査した inode と open 済み fd を照合して束縛し、不一致や未知キーを含む設定は `exit 50`。

```text
PROFILE=standard
KIT_MDM_GIT_REF=0123456789abcdef0123456789abcdef01234567
KIT_MDM_EXPECTED_POLICY_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

この2つの固定入力は CLI と管理設定ファイルのどちらで渡しても必須。両方に同じキーがある場合は CLI 値が優先されるが、片方を省略可能になるわけではない。

production では対象のローカルアカウントと UID 501 以上が必要。local `dscl` と macOS search policy の `UniqueID` / `GeneratedUID`、home inode の所有 UID が完全一致しなければ `exit 20` にする。nil UUID も拒否する。`dscl` の `NFSHomeDirectory` 値は canonicalize して採用するのではなく、**最初から absolute canonical physical path**（`cd -P` の結果と文字列完全一致）でなければならない。`..`、重複 `/`、末尾 `/`、symlink 祖先など別名で同じ場所を指す値も拒否する。コンソールユーザー自動検出を使う場合はユーザーセッション開始後に実行する。ADE / PreStage などがアカウントまたは home 作成前に実行した場合も `exit 20` になるため、作成後の定期 check-in で再試行させる。

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
| `INSTALL_AGENTS` / `INSTALL_RULES` / `INSTALL_COMMANDS` / `INSTALL_SKILLS` | 対応する agents / rules / commands / skills の配備 | boolean。未指定時はプロファイル既定に従う |
| `ENABLE_TMUX_HOOKS` | 長時間の foreground 処理で background 実行または tmux を提案する reminder | boolean。未指定時はプロファイル既定に従う |
| `ENABLE_DOC_BLOCKER` | ad-hoc な SUMMARY / REPORT 系ドキュメント書込み時の確認 hook | boolean。通常のドキュメントは妨げない |
| `ENABLE_PRETTIER_HOOKS` | Prettier による JS / TS 自動整形 hook | boolean。Biome と同時に `true` なら Biome を優先し、Prettier を `false` へ正規化する |
| `ENABLE_BIOME_HOOKS` | Biome による JS / TS 自動整形・lint hook | boolean。必要な Biome runtime は required component として検査する |
| `ENABLE_PR_CREATION_LOG` | PR 作成後の URL 記録と review command 案内 hook | boolean。未指定時はプロファイル既定に従う |
| `ENABLE_AGENT_TEAMS` | Claude Code の experimental Agent Teams 設定 | boolean。`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` を有効化する |
| `ENABLE_STATUSLINE` / `ENABLE_SAFETY_NET` / `ENABLE_DOC_SIZE_GUARD` / `ENABLE_FEATURE_RECOMMENDATION` / `ENABLE_PRE_COMPACT_COMMIT` / `ENABLE_NO_FLICKER` / `ENABLE_NEW_INIT` | その他 feature toggle | 未指定時はプロファイル既定に従う |

`ENABLE_GHOSTTY_SETUP` / `ENABLE_FONTS_SETUP` だけは `PROFILE` にかかわらず MDM 既定 `false` で、CLI または管理設定ファイルによる明示的な `true` で opt-in できる。Ghostty の opt-in は、MDM が署名済みで `com.apple.quarantine` のない `/Applications/Ghostty.app` を先に配布することが前提で、対象ユーザーとして動く `setup.sh` は Homebrew cask の導入を試みず、署名・quarantine 検証とユーザー設定だけを行う。これにより非 admin アカウントで password / Gatekeeper prompt が発生しない。キットの auto-update、web updater、通常の marketplace plugin、Codex Plugin は MDM では常に無効にし、更新は新しい40桁 SHAを指定した MDM 再配布で行う。`SELECTED_PLUGINS` は MDM の許可キーではなく、指定すると `exit 50`。fresh / update とも profile preset や保存済みユーザー設定からこれらを再有効化しない。

### MDM 固有キー（`KIT_MDM_` 接頭辞）

| キー | 既定値 | 意味 |
|---|---|---|
| `KIT_MDM_TARGET_USER` | 自動検出（コンソールユーザー） | 明示値・コンソール値は Directory Services へ渡す requested name / alias として1〜255文字の safe ASCII（先頭は英数字または`_`、以降は英数字・`_`・`.`・`@`・`+`・`-`）だけを受理する。UID から search-policy の canonical short name を再取得し、こちらは1〜32文字の従来の厳格 grammarへ固定する。requested / canonical の UID・GeneratedUID・canonical home が一致し、UID>=501かつhome owner一致の場合だけ採用する。`dscl` home 値自体が canonical physical path でない場合を含め、不一致は `exit 20` |
| `KIT_MDM_INSTALL_HOMEBREW` | `true` | brew 不在時に pkg 経由で自動導入するか |
| `KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE` | `false` | CLT の非公式 `softwareupdate` フォールバックを許可するか |
| `KIT_MDM_PREREQ_MODE` | `auto` | production で許可するのは `auto` / `fail`。`auto` は対象ユーザーから利用・書込可能な Homebrew を検証し、必要なら公式 pkg を適用したうえで本体前提ツールの導入を許可する。`fail` はすべての前提ツールを検査のみとし、不足時は `exit 10`。`skip` は source-only テスト専用で production は `exit 50` |
| `KIT_MDM_WINDOWS_MODE` | `gitbash` | 設定互換性のため受理する予約キー。macOS 実装では未使用であり、Windows MDM 対応を意味しない |
| `KIT_MDM_INSTALL_CLAUDE_CLI` | `true` | Claude Code CLI 導入を必須とするか。`true` では導入後に下記 Apple Developer ID requirement を検証する。`false` ならレシートの `required_components` に `claude_cli` を含めず、`detect-mdm.sh` も CLI 有無を確認せず、`setup.sh` 側の CLI 導入処理もスキップされる |
| `KIT_MDM_GIT_REF` | 必須 | production remediation と dry-run はどちらも小文字 40 桁の full SHA が必須。省略時の `main`、branch、tag、短縮 SHA、64 桁 SHA は `exit 50` |
| `KIT_MDM_EXPECTED_POLICY_SHA256` | 必須 | production remediation と dry-run の両方で必要な小文字64桁 SHA-256。欠落・形式不正は lock / log / prerequisite / transaction より前に `exit 50`。renderer が現在の profile / language / editor / commit attribution / feature / 必須 component から算出した `policy.json` と不一致なら setup 前に `exit 50` |
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

- `settings.json` はファイル全体が MDM-owned desired state。各 authoritative reconciliation で renderer の期待内容へ収束し、ユーザーが追加した key や hook は保持しない。
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
| 21 | 非対応の実行コンテキスト（非 root の通常 remediation）、または host-global remediation lock の競合。非 root は dry-run のみ許可 |
| 30 | 前提条件以外のキットセットアップ、required component の provenance / attestation、expected-state、または git ref / HEAD 照合の失敗 |
| 40 | 必須の Claude Code CLI 導入・検証失敗。`partial:["claude_cli"]` を失敗レシートへ記録し、outer transaction は直前の成功状態または初回の不在状態への rollback を試みる |
| 50 | 管理設定エラー（不正キー・不正値・パーミッション、不正 ref / expected policy SHA-256、または両者の欠落） |
| 60 | 非対応 OS（Darwin 以外、または macOS 13.5 未満）、または host-global remediation lock backend を安全に確立できない |
| 129 | `SIGHUP` を受信して安全に中断 |
| 130 | `SIGINT` を受信して安全に中断 |
| 143 | `SIGTERM` を受信して安全に中断 |

---

## 4. ログ・レシート

### ログ

既定パス: root 実行時 `/Library/Logs/ClaudeCodeStarterKit/install-<UTC タイムスタンプ>.log`、非 root dry-run 時 `<home>/Library/Logs/ClaudeCodeStarterKit/install-<UTC タイムスタンプ>.log`（いずれも `KIT_MDM_LOG_DIR` で上書き可・許可プレフィックス配下のみ）。wrapper の各フェーズと対象ユーザー setup の終了コードを記録する。setup 自体の詳細出力は MDM のスクリプト実行 stdout / stderr で確認する。proxy の資格情報は入力自体を拒否し、proxy 値やトークンをログ・レシートへ書かない。設定確定・対象ユーザー解決より前の失敗は、stderr と終了コードが主な報告経路になる。

### レシート

レシートは system/root contract で、保存先は `/Library/Application Support/ClaudeCodeStarterKit/receipt-<user>.json`。非 root dry-run はレシートを作成・更新しない。

成功レシートは root 親プロセスが配備後の postcondition を再検証してから、root-owned、mode `0600`、非 symlink、link count 1、ACL なしの fresh inode へ atomic に書く。schema v3:

```json
{
  "schema_version": 3,
  "kit_version": "...",
  "git_ref": "...",
  "resolved_sha": "...",
  "install_dir": "...",
  "required_components": ["claude_cli", "kit", "node_runtime", "safety_net", "web_content_runtime"],
  "policy_sha256": "<64-hex>",
  "profile": "standard",
  "language": "ja",
  "manifest_path": "/Users/alice/.claude/.starter-kit-manifest.json",
  "manifest_sha256": "<64-hex>",
  "deployment_sha256": "<64-hex>",
  "component_manifest_path": "/Library/Application Support/ClaudeCodeStarterKit/components-12345678-ABCD-1234-ABCD-1234567890EF.json",
  "component_manifest_sha256": "<64-hex>",
  "target_user": "...",
  "target_uid": 501,
  "target_generated_uid": "12345678-ABCD-1234-ABCD-1234567890EF",
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
- canonical `policy.json` の実 SHA-256、renderer manifest の `policy_sha256`、必須入力 `KIT_MDM_EXPECTED_POLICY_SHA256` がすべて一致する
- 対象アカウントの UID / GeneratedUID を local `dscl`、search policy、home owner へ再束縛し、成功レシートの `target_uid` / `target_generated_uid` に固定する
- renderer が policy から導出した `required_components` を ASCII 辞書順・重複なしで記録し、各必須 runtime component の導入・完全性検査が成功する。検査結果は次の component manifest へ固定し、そのパスと SHA-256 を成功レシートへ記録する

### Runtime component manifest

root 親プロセスは `/Library/Application Support/ClaudeCodeStarterKit/components-<GeneratedUID>.json` に、mode `0600`、root-owned、非 symlink、link count 1、ACL なしの schema v1 component manifest を atomic に書く。ユーザー名だけでなく UID / GeneratedUID、`policy_sha256` を含め、再作成アカウントや別 policy の attestation を流用できないようにする。

```json
{
  "schema_version": 1,
  "target_user": "alice",
  "target_uid": 501,
  "target_generated_uid": "12345678-ABCD-1234-ABCD-1234567890EF",
  "policy_sha256": "<64-hex>",
  "entries": [
    {"component":"kit","path":"/Users/alice/.claude-starter-kit","kind":"tree","sha256":"<64-hex>"}
  ]
}
```

`entries` は `component` / `path` / `kind` / `sha256` からなり、ASCII の component / path 順へ安定ソートして重複を許さない。receipt の必須 component と過不足なく対応し、`fonts` 以外は各1 entry、`fonts` だけは複数 file entry とする。manifest 自体は最大1000 entries。

installer / detector の file / tree digest は同一の canonical walker を使う。`/` から `openat` 相当の directory fd と `O_NOFOLLOW` で各 path を束縛し、byte-sort した preorder recordへ entry type、relative path、mode、UID/GID、link count、BSD flags、bounded xattr の name/value、file size / content hash、symlink target を含める。拡張 ACL、非 directory の hardlink、許可外 owner、group/other writable な非 symlink、特殊ファイル、別 filesystem、absolute / tree 外 / dangling な symlink を拒否する。symlink は walk 対象として追跡せず、相対 target の全 hop が同じ tree 内の安全な実体へ解決することだけを fd 上で確認する。完全な capture を2回行い、metadata・directory entries・xattr・bytesを含む canonical recordが同一の場合だけ SHA-256 を採用する。

1つの artifact digest の上限は10万 filesystem entries、深さ256、単一 file 512 MiB、file bytes 合計2 GiB、symlink 40 hop。path / xattr にも個別・合計上限があり、上限超過や検査中の変更は fail-closed にする。

| component | policy 上の必須条件 | attestation 対象 |
|---|---|---|
| `kit` | 常に必須 | `~/.claude-starter-kit` tree |
| `claude_cli` | `KIT_MDM_INSTALL_CLAUDE_CLI=true` | native layout で署名検証済みの実行ファイル実体 |
| `biome` | profile 解決後の `ENABLE_BIOME_HOOKS=true` | 対象ユーザー所有の `~/.local/lib/claude-code-starter-kit/biome/2.5.4` versioned private tree。architecture 固有の native `biome` と固定 `package.json` だけを含め、`~/.local/bin/biome` が exact `biome` を指すことも別 postcondition で束縛する |
| `node_runtime` | `safety_net` または `web_content_runtime` が必須 | `/Library/Application Support/ClaudeCodeStarterKit/runtime/node-v24.18.0-darwin-{arm64\|x64}` の公式 Node full tree（bundled npm 11.16.0 を含む）。root:wheel、upstream mode、ACL なし、group/other 書込不可とし、`~/.local/bin/node` が exact `bin/node` を指すことも別 postcondition で束縛する |
| `safety_net` | profile 解決後の `ENABLE_SAFETY_NET=true` | 対象ユーザー所有の `~/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6` versioned private tree。固定 JS / `package.json` と private Node を直接呼ぶ deterministic wrapper を含め、`~/.local/bin/cc-safety-net` が exact wrapper を指すことも別 postcondition で束縛する |
| `web_content_runtime` | profile 解決後の `INSTALL_SKILLS=true` | `/Library/Application Support/ClaudeCodeStarterKit/runtime/web-content-extraction/node-v24.18.0-npm-v11.16.0-darwin-{arm64\|x64}/e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c-f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd` の root-owned bundle tree。exact children は `.claude-code-starter-kit-wce-runtime.json`、`package.json`、`package-lock.json`、`node_modules`。bundle 内は全 entry が root:wheel、ACL なしで、symlink / 特殊ファイルを拒否する。directory は `0755`、top-level の3 regular files は `0644`、`node_modules` 内の regular file は `0644` / `0755`。xattr は `com.apple.provenance` だけを許可し、その値も tree digest に封印する。ユーザー側 `~/.claude/skills/web-content-extraction/node_modules` は対象 UID 所有、link count 1、ACL なしで bundle 内 `node_modules` への exact absolute symlink とする |
| `ghostty` | `ENABLE_GHOSTTY_SETUP=true` の明示 opt-in。MDM による事前配布必須 | `/Applications/Ghostty.app` tree。Apple-anchored Developer ID requirement、identifier `com.mitchellh.ghostty`、Team ID `24VZTF6M5V`、`com.apple.quarantine` 不在を検証する。対象ユーザー権限では `/Applications` へ非対話 cask 導入できないため、`auto` / `fail` とも未配布または quarantine 残存なら失敗する |
| `fonts` | `ENABLE_FONTS_SETUP=true` の明示 opt-in | `~/Library/Fonts` の IBM Plex Mono 1.1.0 exact 16 TTF と HackGen NF 2.10.0 exact 4 TTF。filename、file SHA-256、sfnt 構造、family / version / PostScript name を検証して20個の file entry にする。その他の既存 font は保持し、managed inventory には含めない |

### Runtime component の取得元と provenance attestation

component digest は、固定 artifact の provenance gate を通過した live tree と metadata を root contract に固定し、その後の drift を検知する。成功レシートを発行する前の provenance gate は component ごとに次のようにする。

- Biome 2.5.4 の `auto` は `https://registry.npmjs.org/@biomejs/cli-darwin-{arm64|x64}/-/cli-darwin-{arm64|x64}-2.5.4.tgz` を package manager で実行せず直接取得する。arm64 archive / binary / `package.json` SHA-256 は順に `befd5504c242b0174f9f57c9b2f2b14fd106c5f4568bee1b204d1369b890a688` / `1250bb41a0409cf6c3133fc47819237eb61251624297f87158d2bed3ec123c3c` / `54947a4827f0a6960d84eae39de98dba707b6f9222a276beaaa54ab4014dc68c`、x64 は `12e7076f80070aa085653f67fc1cb88f658253c67eb35677fab7c80c5aceb3cb` / `b3dfae5422dbd86272bb8ed40afec66670ea7754531d8fbcbae7e445e5430387` / `f25fac4d876cbd18fe78753dd06fde9a12607a76006546cf6a9549a8f1fb511f`。archive の inventory / member type を制限し、versioned private tree へ atomic に公開する。Homebrew、user PATH、既存 npm global tree は MDM baseline として受理しない。`fail` は通信・変更を行わず、同じ2-file tree と command symlink が事前配布済みの場合だけ受理する。
- Safety Net 1.0.6 の `auto` は `https://registry.npmjs.org/cc-safety-net/-/cc-safety-net-1.0.6.tgz`（SHA-256 `588a23f77637f34b99b6fcff68787b19d2cf692470c284ec633e982008b0a6ab`）を直接取得し、`dist/bin/cc-safety-net.js`（SHA-256 `1ffbfafabf2fe4fc9b6bf64a8088ca3a96c2714cf8fd8afd5b1b326582c982d4`）と `package.json`（SHA-256 `2e57b465553ba97e1e6f7a37655fc52e31cad4ca739140bb7af40d052e3d88c8`）だけを安全に抽出する。root-private Node の absolute path で JS を実行し `NODE_OPTIONS` / `NODE_PATH` を破棄する deterministic wrapper を生成して versioned private tree へ atomic に公開する。`fail` は通信・変更を行わず、この exact tree、wrapper、command symlink が事前配布済みの場合だけ受理する。
- `node_runtime` は architecture ごとの公式 Node v24.18.0 `.tar.xz` を固定する。URL は `https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-{arm64|x64}.tar.xz`、arm64 SHA-256 は `4477b9f78efb77744cf5eb57a0e9594dba66466b38b4e93fa9f35cb907a095a6`、x64 は `4a3b6bc81542154430825128d9a279e8b364e8d90581544e506ef7579fd1ab6f`。`auto` はこの固定 HTTPS URLから root-private な同一 filesystem stage へ安全に展開し、tree metadata、exact version / architecture、system library だけへの依存、`bin/node` の Apple Developer ID requirement（identifier `node`、Team ID `HX7739G8FX`、Developer ID intermediate / leaf OID）を検証して atomic に公開する。`fail` は通信や tree 変更を行わず、同じ固定 tree が root trustbase に事前配布済みの場合だけ受理する。対象ユーザーの activation symlink は setup が作成・修復し、postcondition で再検証する。Homebrew / user-local Node は MDM runtime として受理しない。
- Web Content Extraction runtime は Node v24.18.0 / bundled npm 11.16.0、配布対象 commit の `package.json` SHA-256 `e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c`、`package-lock.json` SHA-256 `f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd`、現在の architecture を固定する。package / lock は private package、lockfile v3、exact registry tarball、SHA-512 integrity、install script / link なしの契約も満たす必要がある。
  - `auto`: root 専用の stage、home、cache、tmp、空の user/global npm config を使う clean environment で、registry を `https://registry.npmjs.org/` に固定する。継承するネットワーク設定は構文検証済みの `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` だけとし、固定 Node / npm で `npm ci --omit=dev --ignore-scripts --no-bin-links --no-audit --no-fund` を実行する。npm 補助物 `node_modules/.package-lock.json` は必須にせず、存在しても許容する。bundle 内 symlink / 特殊ファイルを全面拒否し、exact source files、非空の `node_modules`、root direct dependency ごとの directory と regular `package.json` の存在、canonical schema v1 marker、metadata / xattr / digest を検証して同一 filesystem から atomic publish する。既存 bundle が有効なら再利用し、不正な canonical leaf は quarantine へ隔離して再構築する。修復成功後の quarantine は自動削除せず、フォレンジック確認または手動 cleanup 用に保持する。
  - `fail`: 通信、build、root bundle の repair / quarantine を行わず、同じ root-owned bundle を読み取り専用で検査する。初回 preseed は過去の receipt や既存 activation を要求せず、root / MDM trustbase と canonical package / lock / marker / metadata / digest 契約だけで受理する。setup は exact bundle を再検証して対象ユーザーの activation symlink だけを atomic に作成・修復し、root wrapper が postcondition を再検証する。
  - activation: ユーザー側には bundle の `node_modules` への exact absolute symlink だけを作る。通常インストールが作成した既存の real `node_modules` directory は、対象ユーザー所有、ACL なし、group/other 書込不可の場合に限り、同じ skill directory 内のランダムな `.node-modules.pre-mdm.XXXXXX` へ inode ごと atomic に退避してから symlink を公開する。安全に置換できる既存 symlink / single-link regular file は、旧 leaf を同じ random name へ一時退避し、新 activation の検証後に token-bound inode だけを除去するため永続 backup を残さない。実 directory は削除せず pre-MDM backup として保持するため、利用者への確認なしで MDM 管理状態へ収束できる。正しい activation がすでに存在する再実行では symlink inode を置き換えず、新しい backup も作らない。この backup namespace は fresh setup、update、remediation、`uninstall.sh` のいずれも自動削除しない。uninstall は kit-managed files と disposable な `node_modules` / `logs` だけを除去し、backup とそれを含む skill directory を保持するため、不要と確認した backup は利用者が明示的に削除する。activation symlink とユーザーディレクトリの通常 xattr、および root runtime の祖先ディレクトリの通常 xattr は信頼根拠にせず、それ自体では拒否しない。hash-versioned bundle は複数ユーザーから共有でき、古い bundle を通常 remediation が自動削除することはない。web updater は両 mode で無効。

  marker は compact JSON、下記 key 順、末尾 LF 1 個の exact bytes。次は arm64 の内容で、x64 では `arch` だけを `x64` にする。

  ```json
  {"arch":"arm64","lock_sha256":"f39ea3b4028710e986afb1c423b7895845e0d41839521e6cee866ed37cdb33cd","node_version":"v24.18.0","npm_version":"11.16.0","package_sha256":"e63fb86cb553a034ecafd4ca11334d317b8b5d115775daa728e56c3bf5b1749c","registry":"https://registry.npmjs.org/","schema_version":1}
  ```

- Ghostty は MDM が事前配布した app が上記 Apple Developer ID requirement を満たし、`com.apple.quarantine` がない場合だけ再利用する。不在、署名不一致、quarantine 残存はいずれも `auto` / `fail` とも fail-closed とし、対象ユーザーから Homebrew cask の導入や再導入は試みない。Developer ID 検証は notarization / Gatekeeper 判定とは別契約なので、配布側でも Gatekeeper policy を確認する。
- fonts の `auto` は、IBM Plex Mono 1.1.0 の公式 archive（7,307,192 bytes、SHA-256 `4bfc936d0e1fd19db6327a3786eabdbc3dc0d464500576f6458f6706df68d26c`）と HackGen NF 2.10.0 の公式 archive（25,120,250 bytes、SHA-256 `f8abd483d5edfad88a78ed511978f43c83b43c48e364aa29ebe4a68217474428`）から exact 20 TTF へ毎回収束させる。ZIP inventory、entry type/path、展開 size、archive / file hash、sfnt table、family / version / PostScript name を検証して各 file を atomic に置き換える。`fail` は通信・変更を行わず、同じ20 files を事前配布 baseline として検査する。対象外の font はどちらの mode でも削除しない。publisher が別途公開した checksum asset ではなく、このリリースで公式 asset bytes から固定した hash である。

schema v2 レシートは schema v3 detector では non-compliant になる。install bundle と detector を同じリリースへ更新して remediation を1回実行すると、現在の desired policy と identity を束縛した schema v3 レシートへ自己修復する。

レシート自体は成功・失敗とも root-owned、mode `0600`、非 symlink、link count 1、ACL なしで、その親ディレクトリ信頼チェーンも root-owned かつ group/other 書込不可でなければならない。既存レシートの inode を再利用せず、同一ディレクトリの一時ファイルから atomic に置き換える。失敗レシートは best-effort で、対象ユーザー未解決や安全に書き込めない場合は作成されないことがある。

schema / semantics と transaction の最終 identity を検証済みの成功レシートを同一ディレクトリへ atomic に公開する操作が remediation の commit point になる。公開前の書込み・検証失敗は remediation failure として outer transaction を rollback する。最終 rename と transaction state の確定だけは HUP / INT / TERM を mask し、公開後の stage cleanup / backup rotation / log 失敗は成功状態を巻き戻したり成功終了コードを変更したりせず、回復に必要な path を保持する。

期待 manifest が必要とする `~/.claude` / snapshot 配下の親ディレクトリは transaction の対象に含める。対象ユーザーに owner `rwx` がない、または group / other writable な既存親だけを mode `0700` へ修復し、すでに安全な `0755` / `0711` 等は変更しない。適用前の path・inode・mode を root-private journal へ固定し、commit 前の失敗や HUP / INT / TERM では変更した親を元の mode へ逆順で復元する。成功時は修復後の mode を保持し、manifest と detector は present / absent-only の親を同じ owner / mode / ACL / effective-access 契約で検査する。

### Dry-run

通常 remediation は root 専用で、非 root 実行は副作用を起こす前に `exit 21`。明示的な `KIT_MDM_DRY_RUN=true` だけは非 root でも許可する。launcher は継承環境を破棄するため、`KIT_MDM_DRY_RUN=true /path/to/install-mdm.sh` という環境変数 prefix ではなく次のように CLI 引数で渡す。

```bash
FULL_SHA=0123456789abcdef0123456789abcdef01234567
POLICY_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # §1で生成した値に置換
/path/to/install-mdm.sh KIT_MDM_DRY_RUN=true KIT_MDM_GIT_REF="$FULL_SHA" \
  KIT_MDM_EXPECTED_POLICY_SHA256="$POLICY_SHA"
```

dry-run は一時 checkout で `setup.sh --dry-run` を実行し、成功・失敗どちらでも削除する。root dry-run では、既存の root-owned managed history が有効なら、そこにある削除許可 inventory を一時コピーへ束縛して preview にも渡すため、profile 変更で廃止されるファイルを実 remediation と同じ基準で表示できる。非 root dry-run は system history を削除権限として読まない。Web Content Extraction runtime は既存 bundle を読み取り専用で検査する。activation が未作成、user-owned・ACL なし・group/other 書込不可の real directory として pre-MDM backup へ安全に退避可能、または user-owned・ACL なし・link count 1 の symlink/regular file として安全に atomic repair 可能なら予定変更として許可し、既存の正しい activation は exact binding を検査する。foreign-owned、ACL 付き、group/other writable、special inode、hardlink など本実行でも安全に置換できない状態は拒否する。dry-run 自体は build、repair、quarantine、pre-MDM backup、activation 更新を行わない。前提ツール、固定 install dir、管理 marker、manifest、managed files、managed history、レシートを作成・更新しないため、既存の compliance 判定も変わらない。ただし監査用ログは永続作成し、stderr も出力するため、ファイルシステム全体に対する副作用ゼロの実行ではない。CLT または dry-run に必要な軽量前提ツールが不足していても導入せず `exit 10`。

**タイムアウト**: root launcher は、metadata/API query・renderer・local validation を120秒、Git network operation を300秒（1 KiB/s 未満が60秒継続した場合も停止）、package download / installer を600秒、`pkgutil` を60秒、Web Content Extraction の `npm ci` を900秒、`setup.sh` と明示 opt-in の CLT install をそれぞれ1200秒で停止する。期限切れ時は対象 process group へ TERM、続いて KILL を送り、子孫 process と一時 control data を回収してから内部 status 124 を該当フェーズの失敗として扱う。Node archive の download は従来どおり connect 30秒 / 全体600秒。この値は管理設定や継承環境から延長・無効化できない。

MDM 製品側にも全体 watchdog を設定する。**30〜60分は初期設定の目安であり、完了時間の保証ではない。** CLT fallback と runtime build を同じ実行で許可する場合は、上記の複数フェーズが直列になり得るため、実フリートで計測して製品側上限を十分長くする。製品側が先に停止すると launcher 自身の cleanup 完了を待てないため、少なくとも単一の `setup.sh` 上限1200秒より短くしない。

---

## 5. 検知スクリプト（detect-mdm.sh）

```bash
FULL_SHA=0123456789abcdef0123456789abcdef01234567
POLICY_SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
sudo /path/to/root-owned/detect-mdm.sh \
  --expected-commit "$FULL_SHA" \
  --expected-policy-sha256 "$POLICY_SHA"
sudo /path/to/root-owned/detect-mdm.sh --user alice \
  --expected-commit "$FULL_SHA" \
  --expected-policy-sha256 "$POLICY_SHA" \
  --min-version 0.73.0
```

`detect-mdm.sh` も privileged shebang から clean Bash へ入るため、実行権限を付けて直接起動する。`/bin/sh detect-mdm.sh` や `/bin/bash detect-mdm.sh` は shebang の保護を迂回するため禁止。shell wrapper が必須なら、§1 と同じ `env -i` + `/bin/bash --noprofile --norc -p` 形式を使う。

production の検知は root-only で、`--expected-commit` と `--expected-policy-sha256` の両方が必須。前者は配布コード、後者は profile / language / editor / commit attribution / feature / CLI 方針と必須 component を束縛する。対象ユーザー/home、proxy、prerequisite mode、log、dry-run は最終配備状態ではないため policy digest に含めない。引数なしでレシート自身の SHA / policy だけを信じて `compliant` にする経路はない。`POLICY_SHA` は package 作成時に同じ固定 SHA・設定で renderer を実行し、生成された `manifest.json` の `policy_sha256` から取得する。`--min-version` は任意の追加制約。

標準出力:

- 準拠時: `compliant`（exit 0）
- 非準拠時: `non-compliant: <理由>`（exit 1）
- 使用法エラー: usage を stderr へ出力し、stdout は空（exit 2）。未知/不足引数、不正な semver、不正な `--user`、40 桁でない `--expected-commit`、64 桁でない `--expected-policy-sha256` が該当
- root の暗黙コンソールユーザー解決時に、ログイン画面・セットアップ中・対象ユーザー不在だった場合: `not-applicable: no eligible console user`（exit 3）。非準拠ではなく、ユーザーセッション開始後の再評価待ちとして扱う
- 正しい引数で非 root 実行された場合: `indeterminate: root privileges required`（exit 4）。非準拠ではなく、root 検知コンテキストの設定不備として扱う
- privileged launcher 自体の owner / mode / symlink / ACL または snapshot 検証失敗: stderr へ理由を出力（exit 50）
- `SIGHUP` / `SIGINT` / `SIGTERM` を受信して安全に中断: それぞれ exit 129 / 130 / 143

detector は **root-only**。schema v3 receipt、schema v2 managed history、schema v1 component manifest を mode `0600` で保持し、system 領域の root contract を一般ユーザーへ公開しないため、非 root self-check は提供しない。対象ユーザーを省略した root 実行ではコンソールユーザーを解決する。明示した `--user` の不正値は usage error（exit 2）であり、`non-compliant` 文字列は出力しない。

判定条件（すべて満たして初めて `compliant`）:

- root-owned、mode `0600`、非 symlink、link count 1、ACL なしの schema v3 レシートと、その root-owned な親ディレクトリ信頼チェーン
- レシートの `result=="success"` かつ `exit_code==0`
- レシートの `target_user` / `target_uid` / `target_generated_uid` が現在の local/search policy/home identity と一致（再作成アカウントや別ユーザーのレシートを除外）
- レシートの `policy_sha256` が小文字64桁で、必須の `--expected-policy-sha256` と一致。同じ commit でも profile / language / editor / feature / CLI 方針または必須 component が変われば non-compliant
- `install_dir` が対象ユーザーの canonical home 直下の固定パス `~/.claude-starter-kit` と一致し、`resolved_sha` が小文字40桁 SHAで、保持用 checkout と `.claude-starter-kit-mdm-managed` marker が対象 UID・安全な mode・ACL なし・link count 1・固定内容の契約を満たす。`install_dir/.git/HEAD` は同じ trust 条件の exact 41 bytes detached HEAD として一致し、`--expected-commit` 指定時はその SHA とも一致
- detector は Git を一切起動せず、HEAD を inode/size 束縛した fd から直接読むため、checkout の Git config、hook、filter を実行しない
- `manifest_path` が対象ユーザーの固定パスで、manifest SHA-256、schema v2、`kit_commit`、`profile`、`language`、`claude_dir`、snapshot、present / absent の管理ファイル一覧が一致
- present の各 live file / snapshot は対象ユーザー所有の regular file、link count 1、ACL なしで、absent は双方に存在しない。内容・mode・absent path から再計算した ordered digest がレシートの `deployment_sha256` と一致する。`CLAUDE.md` の user section と manifest 外のユーザーファイルは再計算対象外
- schema v2 の root-owned managed history が対象ユーザーの UID / GeneratedUID / canonical home と一致し、前回成功時の present inventory だけを保持する
- レシートが指す schema v1 component manifest の固定パス、SHA-256、root ownership / mode `0600` / ACL / link count、UID / GeneratedUID / policy 束縛、必須 component の完全な coverage が一致する。各 entry の file / tree digest を live artifact から再計算し、記録値と一致する。Ghostty は digest の前後で Apple Developer ID 署名、fonts は TrueType / OpenType header も再検証する
- `node_runtime` が必須なら、現在の architecture に対応する root-private v24.18.0 full tree の digest、owner / mode / ACL、Node 署名、exact version / architecture、system library 依存、bundled npm、および対象ユーザーの activation symlink がすべて一致する
- `web_content_runtime` が必須なら、package / lock SHA と architecture に対応する root-owned bundle の固定 path、exact children、canonical provenance marker、owner / mode / ACL、symlink 不在、許可 xattr（`com.apple.provenance` のみ）を含む tree digest、および対象ユーザー skill 内の exact `node_modules` activation symlink がすべて一致する。activation / user directory の xattr は trust boundary にしない
- `required_components` に `claude_cli` が含まれる場合、`~/.local/bin/claude` が `~/.local/share/claude/versions/<version>` 配下の実体への symlink であり、fd-bound snapshot に対する `codesign --verify --strict -R` が次の**明示 Apple Developer ID requirement**を満たす: identifier `com.anthropic.claude-code`、`anchor apple generic`、intermediate certificate OID `1.2.840.113635.100.6.2.6`、leaf certificate OID `1.2.840.113635.100.6.1.13`、leaf `subject.OU`（Team ID）`Q6L2SF6YDW`
- 上記 requirement に加えて、`codesign -dv` の identifier `com.anthropic.claude-code`、Team ID `Q6L2SF6YDW`、Authority `Developer ID Application: Anthropic PBC (Q6L2SF6YDW)` も完全一致する。identifier / Team ID / Authority の表示文字列だけでは Apple の trust anchor を証明したことにならない
- `--min-version` 指定時は SemVer 2.0 precedence で `kit_version` を比較する。prerelease は同じ core の final より低く、`+` 以降の build metadata は順位に影響しない。exact tag でない commit は `git describe` の距離と hash を build metadata（例: `v1.2.3+4.gabc1234`）へ正規化し、誤って prerelease 扱いしない

postcondition と detector が証明するのは、対象ユーザー所有ツリーを検査した**時点の観測結果**であり、ツリー全体の永続的・原子的な snapshot ではない。global remediation lock はキットの remediation 同士だけを直列化し、対象ユーザーが検査と同時に意図的な rename / write を続ける状況までは排他しない。通常の変更は次回 detector で non-compliant になる。hostile な同時変更まで防ぐ必要がある環境では、root-owned write-protected subtree または APFS snapshot など別の端末統制が必要で、本実装の非破壊な user-owned 配備契約の範囲外。

---

## 6. 冪等性・更新チャネル

production の保持用 checkout は `<対象ユーザーの canonical home>/.claude-starter-kit` に固定する。対象ユーザー権限で作成した `.claude-starter-kit-mdm-managed` marker を持つ checkout だけを再構築対象として認め、marker のない既存ディレクトリは削除せず `exit 50` にする。root は target-user writable path へ marker を直接書き込まず、owner / mode / ACL / link count と内容を bounded snapshot で検証する。保持用 checkout は対象ユーザー所有の運用 artifact で、配備の authority や root remediation の実行元にはしない。対象ユーザー自身が後日 `/update-kit` 等でこの checkout を使う操作は同一 UID の対話操作であり、root authority の契約外となる。

再構築は対象ユーザー権限で、保持先と**同じ親ディレクトリ**の専用 stage に fixed-SHA checkout を完成させる。clean HEAD と管理 marker を検証した後だけ、初回は no-replace rename、更新時は exchange rename で保持先へ原子的に切り替え、切替後も marker / HEAD を再検証する。clone・checkout・marker 作成・切替後検証の途中で失敗した場合、更新時は旧 checkout を保持または復元し、初回は自身が作成した不完全な保持先と stage を除去するため、次回 remediation で安全に再試行できる。

ここで `clean HEAD` は stage 構築後、tracked / untracked / ignored のすべてを Git で確認し、固定内容の管理 marker だけを除外した worktree に他の path がない条件。ただし target-owned の Git index は security authority にせず、`.git` と管理 marker だけを除外した root-private authoritative checkout と保持用 checkout を、同じ fd-bound content walker で path / type / canonical mode / file bytes / symlink target / xattr まで独立比較する。保持側の directory は 0755、regular file は executable class に応じ 0644 / 0755 を要求し、file flags は拒否する。この比較を setup 前後に行い、setup 前にはさらに exact detached HEAD と clean 状態の前後で保持用 checkout tree 全体（`.git` と管理 marker を含む）の canonical digest を取得し、setup 完了後に Git を起動せず再取得した `kit` component digestとの一致を成功条件にする。これにより `skip-worktree` で隠した tracked 改変、読めない mode、ignored path の差込みを含め、clean / full-SHA 検査後の一時置換を初回 baseline として採用しない。

切替後の checkout 固有 postcondition が Git semantics で検証する範囲は、ディレクトリ identity、管理 marker、exact 41-byte detached HEAD とその SHA、ignored を含む clean worktree までで、Git object database の全 byte が commit から一意に導出されることを証明するものではない。`.git` には clone ごとに異なり得る管理 byte があるため、checkout 全体の component digest を commit の正本 hash としては扱わない。一方、事前/最終 hash の一致と detector の live rehash は、その remediation で採用した保持用 checkout tree 全体の byte・metadata drift を検知するため、object / worktree の変更に加えて `.git` の `gc` / `repack` 等も non-compliant になる。保持用 checkout は root の実行元でも live 配備の期待状態ソースでもなく、次回 remediation で固定 URL / SHA から再構築する非 authority の運用 artifact である。live 配備は live / snapshot、manifest、その他 runtime components、managed history、receipt を独立に検証する。

各 remediation は指定した full SHA から root-private authoritative checkout を新規作成し、対象ユーザーで `setup.sh --non-interactive` を authoritative fresh reconciliation として実行する。対象ユーザーの既存 manifest / 保存済み config は desired policy や update mode の選択に使わず、retired path の削除権限には root-owned managed history だけを使う。終了後は Git を起動せず detached HEAD を直接照合し、renderer の期待状態へ収束したことを検証してから一時 checkout を削除する。

mutating remediation は、CLT / Homebrew の host-global 操作を含む全工程を system 領域の root-owned global lock で排他する。`/usr/bin/lockf` を利用できる macOS では native lock を使い、不在または fd 形式に非対応の macOS では root-owned fallback lock を使うため、`lockf` の有無を最小 OS 条件にはしない。対象ユーザーの setup 子プロセスが生存する間も lock を保持する。競合した実行は checkout、管理履歴、レシートを変更せず `exit 21`。既存 `~/.claude` の再構成前には予約 prefix `~/.claude.mdm-backup.<UTCタイムスタンプ>[.<連番>]` へバックアップし、MDM バックアップは最新1世代だけ保持する。この prefix は MDM 専用のため、ユーザーの保存先には使わない。

対象ユーザー状態への適用は outer transaction とし、既存 `~/.claude`（初回は不在状態）、保持用 checkout、root-owned managed history / component manifest を成功レシート公開まで復元可能に保持する。さらに policy が要求する component に応じて、Node / Biome / Safety Net / Claude CLI の exact activation（`~/.local/bin/node`、`biome`、`cc-safety-net`、`claude`）、Biome / Safety Net の専用 version tree（`~/.local/lib/claude-code-starter-kit/biome/2.5.4` と `~/.local/lib/claude-code-starter-kit/cc-safety-net/1.0.6`）、Claude CLI link が指す `~/.local/share/claude/versions` 内の exact target、`~/Library/Fonts` の管理対象 20 TTF、Ghostty config（`~/Library/Application Support/com.mitchellh.ghostty/config`）だけを user-owned external leaf として root-private journal に固定する。Web Content Extraction の user activation は `~/.claude` 配下にあるため、その rollback に含まれる。

postcondition / component attestation / receipt 公開の失敗、timeout、HUP / INT / TERM ではこれらを旧 inode または初回の不在状態へ復元する。Claude CLI の `auto` では prepare 時点の active link と、その link が指していた旧 version target だけを固定 inventory に含める。失敗時はその組を復元する一方、実行中に native installer が新規作成した別 version target は削除権限を事前に束縛できないため、非 active cache として残す。成功時は新しい active link を維持し、旧 target の transaction backup だけを commit 後に削除する。

`~/.local` 全体、その汎用 `bin` / `lib` / `share` tree、`~/Library/Fonts` 全体、Ghostty config の親ディレクトリは境界外で、無関係な利用者ファイルには触れない。同時変更や identity 競合を検出した leaf は上書き・削除せず、partial 状態と backup を診断・再試行用に保持して fail-closed とする。拒否した `~/.claude` / checkout 候補も `~/.claude.mdm-failed.*` / `~/.claude-starter-kit.mdm-failed.*` に保持し、rollback 後の失敗レシートは best-effort で発行する。旧 backup の cleanup は成功レシートの commit 後だけ行う。receipt 公開後に cleanup が完了しなければ transaction は `commit_cleanup` として rollback を禁止し、通常終了処理でも同じ固定 journal / root-private carrier を使って cleanup を再試行する。競合が続く場合はそれらを回復用に保持するが、公開済み成功状態と成功終了コードは変更しない。

CLT / Homebrew 導入、root-owned の Node / Web Content Extraction content-addressed bundle と cache / quarantine、MDM が事前配布する Ghostty app とその quarantine 状態はこの rollback 境界外で、検証済みの準備物を単調に保持する。`SIGKILL` と電源断には durable journal がなく trap / rollback を保証しない。発生時は実行停止を確認して candidate / stage / lock を調査し、detector の再評価後に remediation を再実行するか管理者が復旧する。

root-owned schema v2 managed history は `/Library/Application Support/ClaudeCodeStarterKit/managed-history-<GeneratedUID>.json` に、直前に root postcondition を通過した **present path だけ**を削除権限として保持し、対象ユーザー名、UID、GeneratedUID、canonical home へ束縛する。次回 remediation は identity が一致する履歴の旧 managed path だけを profile 変更・廃止時に absent へ収束できる。再作成アカウント、legacy schema、identity 不一致の履歴は削除権限に使わず、成功後に現在の identity で置き換える。失敗した remediation の期待一覧、対象ユーザー manifest、失敗レシートは削除根拠にしない。history は postcondition 成功後だけ mode `0600` の fresh inode へ atomic に更新され、失敗時は前回成功時の内容を維持する。

初回の MDM 移行では root history がまだないため、今回の profile で absent になるキット同名 path に checkout と異なる内容が残っている場合、そのファイルを削除せず `exit 30` で停止する。対象が以前の管理ファイルか個人ファイルかを自動判定できないためであり、管理者が内容を確認して退避・削除するか、その path を present にする profile で一度 postcondition を成立させてから profile を変更する。

MDM から渡した設定値は再実行でも authoritative policy になる。wrapper は内部マーカー `KIT_MDM_MANAGED=true` を注入し、本体（wizard）は対象ユーザーの manifest / 保存済み設定を policy input にせず MDM 注入値から構成を決める。`KIT_MDM_MANAGED` がない通常の fresh / update には影響しない。

**再実行をいつ・どう起動するかは MDM 製品ごとに設計が異なる**ため、次の「検知→修復」パターンを共通の推奨形とする。

- **検知**: `detect-mdm.sh` を製品の root レポーティング機能（Extension Attribute / Custom Attribute / Sensor）に載せる。signed-in user 権限で動かすと exit 4 になり、compliance は判定されない
- **修復**: root-owned に配置した install bundle の `install-mdm.sh` を、製品のスケジュール実行/ポリシー機能で `KIT_MDM_GIT_REF=<40-hex>` と `KIT_MDM_EXPECTED_POLICY_SHA256=<64-hex>` の両方を指定して定期起動する

具体的な組み方は次章で製品ごとに示す。

### MDM 管理の解除（decommission）

通常の `uninstall.sh` だけでは、MDM 側の定期 remediation が次回実行時にキットを再配備する。解除は次の順序で行う。

1. MDM 製品側で remediation の割り当て・定期スクリプト・bundle 配布を停止し、対象端末に新しい実行が降りないことを確認する。
2. 対象ユーザー権限で `uninstall.sh` を実行し、必要なら管理 marker を確認したうえで保持用 checkout `<home>/.claude-starter-kit` も削除する。
3. 実行中の remediation がないことを確認してから、root-owned の install/detect bundle、`/Library/Application Support/ClaudeCodeStarterKit`（設定・receipt・managed history・lock）、不要なら `/Library/Logs/ClaudeCodeStarterKit` を MDM の削除 payload で除去する。
4. detector の割り当ても停止または削除し、端末が remediation / 検知の対象母集団から外れたことを製品コンソールで確認する。

`runtime/` 配下の Node / Web Content Extraction tree は同じ端末の複数ユーザーから共有され得るため、通常 remediation は古い hash/version tree を自動削除しない。個別ユーザーの解除時にも残し、端末上の全対象ユーザーを解除して実行中の参照がないことを確認した host-wide decommission でだけ削除する。

---

## 7. 製品別手順

> 以下は各製品の公式ドキュメントで確認できた範囲のみを記載する。確認できなかった項目は「要検証」と明記する。

### Jamf Pro

- **MDM baseline**: 必要なら CLT の pkg を、スクリプト実行より先に別 Policy（例: Execution Frequency = Once per computer）で配布する。
- **install bundle**: `install-mdm.sh` と `render-expected.py` を同じ root-owned payload path へ入れた pkg を配布する。Policy では pkg をスクリプトより先に実行する。
- **スクリプト枠**: 配置済み `install-mdm.sh` を直接起動する launcher を Jamf Pro の Script として登録し、Policy にアタッチする（root 権限で実行される）。
  - Jamf が予約する `$1`〜`$3` は installer へ渡さない。`"$@"` をそのまま転送すると予約値が未知引数となり、全端末で `exit 50` になる。設定は Parameter 4〜11 に `KEY=VALUE` として入れ、launcher は `$4` 以降だけを個別に転送する。未使用パラメータの空文字は installer が無視する。

    ```bash
    #!/bin/bash
    # $5 = KIT_MDM_GIT_REF=<40-hex>
    # $6 = KIT_MDM_EXPECTED_POLICY_SHA256=<64-hex>
    exec /path/to/install-mdm.sh \
      "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
    ```

    例: Parameter 4 = `PROFILE=full`、Parameter 5 = `KIT_MDM_GIT_REF=0123456789abcdef0123456789abcdef01234567`、Parameter 6 = `KIT_MDM_EXPECTED_POLICY_SHA256=<64-hex>`。
  - 実行頻度は Policy の **Execution Frequency** で選ぶ。冪等な定期再実行には `Once every day` が扱いやすい（CLT 未導入等で失敗した端末は翌日以降の Recurring Check-in で再試行される）。`Ongoing`（チェックインの都度）はサーバー/クライアント負荷への影響が公式ドキュメントで注意喚起されている。
  - Recurring Check-in の既定間隔は 15 分（変更可能）。
- **検知（Extension Attribute）**: `detect-mdm.sh` の出力を Jamf Pro の EA スクリプト標準出力契約である `<result>...</result>` でラップする:

  ```bash
  #!/bin/bash
  result="$(/path/to/detect-mdm.sh \
    --expected-commit 0123456789abcdef0123456789abcdef01234567 \
    --expected-policy-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    2>/dev/null || true)"
  printf '<result>%s</result>\n' "${result:-non-compliant: detector failed}"
  exit 0
  ```

  commit SHA と policy SHA は remediation と同じ値へ置き換える。`not-applicable` はログイン前など対象ユーザー不在を示すため remediation の対象にしない。この EA を条件にした Smart Computer Group（例: 値が `non-compliant` を含む）を作り、それを上記 Policy のスコープにすれば「非準拠端末にのみ再配布」を実現できる。

### Microsoft Intune

現行実装は macOS のみのため、Intune 側も **macOS 向けの機能**（Windows の Platform Script / Remediations とは別物）を使う。

- **MDM baseline / install bundle**: CLT と、`install-mdm.sh` + `render-expected.py` を root-owned path へ配置する pkg を macOS 向け App（LOB pkg 配布）で事前配布する。
- **スクリプト枠（修復に相当）**: `Devices > By platform > macOS > Manage devices > Scripts` に、配置済み `install-mdm.sh` を `KIT_MDM_GIT_REF=<40-hex>` と `KIT_MDM_EXPECTED_POLICY_SHA256=<64-hex>` の両方を指定して直接起動する **Shell script** を登録する。既定は root 実行（"Run script as signed-in user" = No のまま）。
  - **Script frequency** を「1 回のみ」ではなく定期（例: 1 日ごと）に設定すると、その頻度で再実行される。macOS のシェルスクリプトはこの Script frequency 自体が組み込みの定期再実行機能であるため、**Windows 向けの Remediations や Win32 app による回避策は macOS では不要**——というより、そもそも**Remediations は Windows 専用機能**であり（公式ドキュメントの前提条件は Microsoft Entra 参加済みの Windows Enterprise/Pro/Education 端末に限定されている）、Win32 app（`.intunewin`）も Windows 専用パッケージ形式のため、いずれも本ガイドの macOS スコープには適用できない。
  - IME（Intune Management Extension）のチェックイン間隔は既定で約 8 時間。
- **検知（Custom attributes for macOS）**: `Devices > By platform > macOS > Organize devices > Custom attributes for macOS` に次の wrapper を登録し、Data type を `String` にする。Custom Attribute は検知スクリプトの stdout を保存したうえで wrapper 自体は必ず `exit 0` にする。exit 1 をそのまま返すと non-compliant 文字列を結果として収集できない場合がある。

  ```bash
  #!/bin/bash
  result="$(/path/to/detect-mdm.sh \
    --expected-commit 0123456789abcdef0123456789abcdef01234567 \
    --expected-policy-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    2>/dev/null || true)"
  printf '%s\n' "${result:-non-compliant: detector failed}"
  exit 0
  ```

  commit SHA と policy SHA は配布対象と同じ値へ置き換える。`not-applicable` は remediation 対象から除外する。8 時間ごとに自動実行され、結果が `Result` 列に反映される（出力は20KB以下）。

### VMware/Omnissa Workspace ONE UEM

- **MDM baseline / install bundle**: CLT と、`install-mdm.sh` + `render-expected.py` を root-owned path へ配置する pkg を macOS 向け App として事前配布する。
- **Scripts（修復に相当）**: 配置済み `install-mdm.sh` を `KIT_MDM_GIT_REF=<40-hex>` と `KIT_MDM_EXPECTED_POLICY_SHA256=<64-hex>` の両方を指定して起動する launcher を macOS 向け Script（Bash）として登録する。Trigger Type を `SCHEDULE` または `SCHEDULE_AND_EVENT` にし、スケジュール間隔は `FOUR_HOURS` / `SIX_HOURS` / `EIGHT_HOURS` / `TWELVE_HOURS` / `TWENTY_FOUR_HOURS` から選ぶ（ログイン時などのイベントトリガーと併用も可）。
- **Sensors（検知に相当）**: `detect-mdm.sh` を macOS 向け Sensor（Bash）として登録し、Intelligent Hub のサンプルスケジュールに従って定期収集・報告させる。

### Ivanti Neurons for MDM（旧 MobileIron）

- `install-mdm.sh` と `render-expected.py` を同じ root-owned path へ事前配置し、`Admin > All Scripts` の Script Editor には配置済み installer を `KIT_MDM_GIT_REF=<40-hex>` と `KIT_MDM_EXPECTED_POLICY_SHA256=<64-hex>` の両方を指定して起動する launcher を登録する。Mobile@Work for macOS の Script 設定で対象デバイスに紐付けると、エージェントが割り当てられた launcher をダウンロード・実行する。
- **要検証**: 2-file bundle の payload 配布方法、ポーリング間隔の既定値、および `detect-mdm.sh` の判定結果をレポーティングする機構（Jamf EA / Intune Custom Attribute / Workspace ONE Sensor に相当する機能）の有無・使い方は、この執筆時点で公開ドキュメントから確認できていない。導入前に Ivanti サポートまたは最新の Administrator Guide で確認すること。

### 汎用 MDM（Iru を含む）

上記 4 製品以外（Iru を含む）は製品固有の一次情報を確認できていないため、次の**最小契約**のみを要求する汎用手順として扱う:

- `install-mdm.sh` と `render-expected.py` を同じ root-owned path へ安全に配置できること
- root で、配置済み `install-mdm.sh` を `KIT_MDM_GIT_REF=<40-hex>` と `KIT_MDM_EXPECTED_POLICY_SHA256=<64-hex>` の両方を指定して直接実行できること
- 可能であれば、任意のタイミングで再実行できる（定期実行または手動トリガー）こと
- `detect-mdm.sh` の標準出力を収集できること。製品が非0終了を結果として保存しない場合は Intune と同様に stdout を捕捉して wrapper を `exit 0` にする

Iru については製品仕様・正式名称を一次情報で確認できるまで固有の手順は記載しない。

---

## 8. 実機確認事項

実装は単体テスト（モック含む）で検証済みだが、以下は実機またはネットワーク到達可能な環境での確認が必要。

- **固定 runtime artifact の実機確認**: Biome / Safety Net / Node / Web Content Extraction / fonts の固定 archive取得、安全な stage 展開、payload / source hash、native署名 / internal metadata、root-owned WCE bundle / activation symlinkの検証、WCE の npm isolated build・不正 leaf quarantine・atomic 公開・初回 `fail` preseed 受理を含む read-only baseline 検査は、実ネットワークと両 architecture の macOS で end-to-end 未検証。upstream asset bytes、package layout、署名 chainが変わった場合は pin により fail-closed になるため、version更新時は URL / hash / layout / test fixture を同じ変更で更新する。
- **Homebrew pkg 自動導入の実機確認**: GitHub API（`api.github.com/repos/Homebrew/brew/releases/latest`）のレート制限、`installer` 実行、`HOMEBREW_PKG_USER` plist の読み取り挙動は実機未検証（署名 Team ID `927JGANW46` と plist 受理条件 root/0600 は 2026-07-17 に実 pkg / Homebrew ソースで確認済み）。Homebrew の署名証明書ローテーション時は Team ID pin により fail-closed になる。
- **system Python の前提**: trusted renderer と検証 helper は `/usr/bin/python3` の `xcode-select` shim や full Xcode を実行しない。固定入口 `/Library/Developer/CommandLineTools/usr/bin/python3` を最大 8 hop で数値 version の実体へ解決し、固定 CLT source / link / Python 実体の metadata と Apple 付与済み requirement `=identifier "com.apple.python3" and anchor apple`、Sealed Resources v2 を検証する。次に framework を別 inode 群へコピーし、copy の owner / mode / ACL / symlink / hardlink 境界、同じ Apple 署名、isolated self-test を確認する。root 実行の remediation / dry-run と root detector はこの copy を全実行期間 root-owned mode `0700` の private workspace に保持し、明示的な non-root dry-run だけは非権威・receipt 不変の current-user-owned mode `0700` ephemeral workspace を使う。通常の root helper は private copy を isolated・bytecode 無効・`site` 無効（`-I -B -S`）で実行する。一方、対象ユーザーへ降格する3つの user-owned filesystem 操作は private copy を実行せず、identity を再束縛した検証済み fixed source CLT Python を同じフラグで使い、production では結果を後段の root-private postcondition で再検証する。最終 private seal が不一致なら旧 copy を直ちに失効させ、fresh private の再構築を試みる。再構築が失敗または signal で中断した場合の rollback に限り、初期化時に束縛した fixed source の署名・Sealed Resources v2・metadata・identity を呼出しごとに再検証して使う。self-test 後の private full mtree seal は baseline として後続フェーズの最終 rebound まで照合し、source tree の mtree/core 比較は行わない。`codesign` は検証にだけ使い、キットが再署名したり Developer ID 証明書・秘密鍵を要求したりすることはない。CLT の配置・metadata・署名が契約外なら prerequisite 不足として fail-closed（`exit 10`）になる。
- **Xcode CLT の非公式フォールバック**（`KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=true`）: `softwareupdate` 経由の導入は Apple 公式に文書化された手順ではなく、OS バージョンによって挙動が変わり得る。
- **production remediation の実機確認**: full SHA からの root-private authoritative checkout、target-user setup、trusted renderer の expected-state / policy / runtime component 照合、component manifest、固定保持用 checkout と管理 marker、schema v3 receipt 作成までの root end-to-end は実 MDM 製品から未検証。`launchctl asuser` + numeric UID の `sudo -u` + `env -i`、`scutil`、`dscl`、APFS の owner / mode / ACL / link count、native/fallback lock backend、outer transaction の後段失敗 / HUP / INT / TERM rollback、成功 receipt commit point、`SIGKILL` / 電源断後の運用復旧も実機で確認が必要。
- **detector / Claude CLI の実機確認**: root-only 検知コンテキストでの direct HEAD 読み取り、deployment digest と live runtime component digest の再計算、および実際に導入された Claude CLI での symlink 解決と `codesign` 照合は実機 end-to-end が未検証。installer と detector は同じ明示 Apple Developer ID requirement（`anchor apple generic`、intermediate OID `1.2.840.113635.100.6.2.6`、leaf OID `1.2.840.113635.100.6.1.13`、leaf OU / Team ID `Q6L2SF6YDW`、identifier `com.anthropic.claude-code`）を要求し、identifier / Team ID / Authority の表示も完全一致させる。Anthropic が native installer の symlink 配置、identifier、Team ID、署名 Authority または証明書チェーンを変更した場合は、導入が `exit 40` または検知が non-compliant になる。
- **MDM 製品への bundle 配布確認**: Jamf / Intune / Workspace ONE / Ivanti で 2-file bundle を root-owned path へ配置し、定期 launcher と detector の結果収集を組み合わせる手順は、各製品 UI を通した end-to-end が未検証。特に Ivanti の payload 配布と検知レポートは §7 のとおり要確認。
- **proxy 経由の実機確認**: secret-free authority-only proxy を経由した Homebrew、キット、Claude CLI の取得は実ネットワークで未検証。userinfo を含む認証 proxy は仕様上拒否する。
- **Windows MDM は対象外・未実装**: `install-mdm.ps1` / `detect-mdm.ps1` / `lib-mdm-config.ps1` は存在せず、本 PR の受け入れ条件にも含めない。
- **英語版ドキュメント**: 本ガイドの完全な英訳は未提供。`README.en.md` には MDM 機能の概要のみ掲載している。

---

## 関連ドキュメント

- ルート README: [README.md](../../README.md)
