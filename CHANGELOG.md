# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.55.0] - 2026-06-12

リファクタリング Issue #78〜#103 の一括対応。12 領域の並列監査（130 件の検証済み findings）に基づき、壊れていた hook の修正・update 経路の堅牢化・常時コンテキストの削減・大規模な dead code 整理・テスト基盤の刷新を行った。

### Fixed
- **codex-setup / plugin インストールの正確性を修正（#78）**: `claude plugin list` の判定を非アンカー `grep -qw "codex"` から行頭トークンを正確にパースする `_claude_plugin_list_has()`（`name@version` 形式・bullet プレフィックス対応）へ変更し、別 plugin 名への部分一致誤判定を解消。legacy Codex MCP の削除は plugin インストール成功を確認した後にのみ実行（CLI インストール失敗時に bare `return`（=0）で成功扱いになり MCP だけ消える事故を防止）。plugin install / marketplace add の失敗時は捕捉した CLI 出力を表示して警告（無音失敗の解消）。API キー検証失敗時の再入力ループの `continue` 漏れも修正
- **strategic-compact のカウンタが一度も累積しない問題を修正（#79）**: カウンタファイル名が hook 呼び出しごとに変わる `$$`（PID）キーだったため毎回 1 にリセットされ、compact 提案が一度も発火しなかった。stdin の `session_id` をサニタイズしてキーにする方式へ変更
- **pr-creation-log の hook スキーマ不一致を修正（#79, #103）**: 存在しない `tool_output.output` を参照していたため PR URL を一度も抽出できなかった。実スキーマの `tool_response.stdout` / `tool_response.stderr` を読む外部スクリプト `log-pr.sh` へ移行（legacy 経路は `PR_CREATION_LOG_LEGACY=1` で共用）。捏造スキーマ前提だったテストは実 hook 入力 fixture ベースに是正
- **memory-persistence の Stop hook 誤用を再設計（#80）**: 応答完了ごとに発火する `Stop` で session-end 処理を行っていたため空のセッションノートが毎ターン量産されていた。`SessionEnd` へ移行し、session-end は既存ノートの更新と 30 日超 `.tmp` の掃除のみ。session-start はノート先頭 80 行を stdout（コンテキスト）へ出力
- **3-way merge が JSON の `false` 値を「キー欠落」と同一視するバグを修正（#81）**: `jq` の `.[$k] // empty` は `false`/`null` でも empty になるため、`false` 設定キーの競合解決が破壊されていた（keep-mine でキー消失等）。`merge_settings_3way()` / `_merge_object_3way()` / `_merge_settings_bootstrap()` を `has($k)` 判定へ修正し、user 変更・両方変更・bootstrap の各分岐の回帰テストを追加（修正前コードで FAIL することを確認済み）
- **dry-run が実 `~/.claude` 全体を temp へ丸ごとコピーする問題を解消（#82）**: `projects/` のセッション履歴等までコピーしていたため遅く、プライバシー面でも不要だった。キット関連ファイル＋manifest 記載ファイルの選択コピーへ変更（manifest 不在の fresh-with-existing 経路では既存の agents/ 等キット関連ツリーもコピーし、merge-aware 配備のプレビュー精度を維持）
- **wizard の `--hooks` CLI 指定が保存 config に上書きされる問題を修正（#83）**: トークン表の不一致で `safety-net` / `pre-commit` の CLI 指定が override として記録されなかった。`HOOK_KEYS` / `HOOK_TOKENS` レジストリ駆動に一元化
- **フォント直接ダウンロード経路を修復（#84）**: IBM Plex Mono の URL（`fonts.google.com/download`）が HTML を返すようになり展開が必ず失敗していた。GitHub Releases の固定 zip へ変更し、zip マジックバイト検証を追加。`lib/fonts.sh` の素の `timeout` は `_run_with_timeout` へ修正
- **install.sh の再 clone フォールバックが既存インストールを消失させる問題を修正（#85）**: pull 失敗時に `rm -rf` → `git clone` の順だったため、ネットワーク断で削除だけ成功していた。temp clone 成功後に入れ替える `_clone_to_temp_and_swap()` へ変更（`install.ps1` の WSL / Git Bash 埋め込みも同一修正、中断残骸の自己修復掃除付き）。`.gitattributes` で Git Bash の CRLF 破損も防止
- **doc-blocker がキット自身の機能をブロックする内部矛盾を解消（#86）**: 同梱 agents / commands / skills が出力を指示する正規パス（`HANDOVER.md`、`docs/CODEMAPS/` 等）を許可リスト化した外部スクリプトへ移行
- **web-content-extraction の exit code 分類をエラーコードベースに修正（#88）**: 日本語エラーメッセージの部分文字列マッチではなく url-guard の `error.code` で判定。`DEFUDDLE_MAX_REDIRECTS` の検証追加、`__HOME__` 置換の Windows パス破壊も修正
- **pre-compact-commit の `CLAUDE_PROJECT_DIR` 未設定ガードを追加（#89）**: `cd` 失敗時にカレントディレクトリで `git add -A` が走らないよう条件ガードを追加し、matcher を仕様準拠の `"*"` へ修正

### Changed
- **hook ランタイムコストを削減（#89）**: tmux-hooks の PreToolUse 2 連 spawn を単一スクリプトへ統合、SessionStart 系 hook の matcher を `"startup"` に変更（resume / compact 時の不要起動を抑止）、console-log-guard の毎ターン git 走査を `SessionEnd` へ移行、settings.json 埋め込みの inline hook 7 種をすべて `~/.claude/hooks/<feature>/` の外部スクリプトへ移行、auto-update の legacy 判定をビルド時環境変数へ変更（hook 実行ごとの `claude --version` を排除）
- **update 経路の堅牢化**: kit が配布を終了したファイルを update 時に掃除する retired-file sweep を追加。掃除は保護付き — kit が今も配布しているファイルのユーザー削除は retire と区別して snapshot baseline を保持（削除保護フローを維持）、ローカル変更のある retired ファイルは警告して温存、空になったディレクトリは削除。manifest に `claude_dir` を記録し dry-run プレビューでも削除を正しく報告。git-push-review の hook スクリプトを `_FEATURE_SCRIPT_ORDER` レジストリ経由で update 配備・manifest 追跡の対象化（従来は fresh install のみ配備され、update 後の settings.json が存在しないスクリプトを参照し得た）。manifest v1 旧インストールの statusLine が retired な bash 実装を指したままになるケースは現行実装へ自動移行
- **Node.js の既定インストールメジャーを 20（EOL）→ 24 に引き上げ（#87）**: `check_node()` が既存 node のメジャーを検証し 22 未満は再インストールを試行。nvm installer を v0.40.5 へ更新、`install.ps1` の Node 直接インストールを setup.sh 検証へ一本化
- **standard プロファイルの既定 plugin を削減（#90）**: 常時コンテキスト負荷の大きい `pr-review-toolkit` / `claude-md-management` / `superpowers` / `document-skills` / `example-skills` を full のみの既定に変更（standard では明示選択で導入可能）。README のプラグイン表・個数も同期
- **web-content-extraction の配備・更新コストを削減（#91）**: `node_modules/` / `logs/` / `*.bak` を配布対象から除外、runtime 自動更新が書き換える `package.json` / `package-lock.json` は競合扱いせず snapshot には kit 版を保存（baseline 汚染による翌 update の巻き戻りを防止）、`jsdom` / `defuddle` の import 遅延化、自動更新に中断検出＋再開時のテストゲートを追加
- **rules/ を全面刷新（#92, #90）**: 常時注入される全 11 ファイル約 493 行を、陳腐化したモデル名・実装と乖離した hook 記述を排した簡潔な構成へ縮減。`config/permissions.json` から廃止ツール名（`MultiEdit` / `LS` / `TodoRead`）を削除
- **agents/ を全面刷新（#93）**: 上流プロジェクト残骸の除去と大幅スリム化（9 agent 合計約 3,300 行削減）、6 agent の model を `opus` → `sonnet` に変更
- **commands / skills / memory を整理（#94）**: 例示肥大の削減（計約 1,500 行）、memory/ ドキュメントの実態同期
- **uninstall を manifest 駆動化（#99）**: ランタイム生成物の削除を manifest の `cleanup_paths` 読み取りへ変更（旧 manifest 向けフォールバック維持）、削除前に `_safe_cleanup_path()` で検証、glob 掃除を空白を含むパスでも安全な実装へ
- **CI を分割・高速化（#103）**: unit と scenario を別ジョブ化し、scenario を `core` / `update` / `features` の 3 shard で並列実行（`SCENARIO_GROUP` は allowlist 検証付き — 未知値は fail-open せず即エラー）
- **内部リファクタ（ユーザー動作不変）**: setup.sh 後半約 280 行を `setup_main()` 等へ関数化（#95）、lib/deploy.sh の `build_claude_md` 二重実装統合と semver 判定共通化（#96）、lib/merge.sh / lib/update.sh の重複統合・`eval` 排除（#97）、wizard.sh（1,307 行）を registry / steps に 3 分割（#98）、install.sh / install.ps1 の bootstrap 重複統合（#99）、prerequisites / fonts の重複統合（#100）

### Removed
- **dead code を一掃（#101）**: 旧 bash 版ステータスライン `statusline-command.sh`（Python 版が正）、`skills/strategic-compact/suggest-compact.sh`（重複コピー）、`skills/continuous-learning`（未参照 skill）、実装済み計画書 `docs/superpowers/`、`lib/template.sh` の参照ゼロ関数、未使用 i18n 文字列、profiles の廃止キー `AGENTS_MD` を削除
- **`commands/code-review.md` を削除（#94）**: 公式 `code-review` plugin と機能重複のため

### Added
- **hook 実スキーマ fixture によるテスト基盤（#103）**: Claude Code が実際に渡す hook 入力 JSON を `tests/fixtures/hooks/` として固定化し、全 hook スクリプトを実入力で検証する `test-hook-fixtures.sh` を追加。日本語経路のシナリオテスト（`fresh-install-ja`）も追加
- **回帰テストを大幅追加**: retired-file sweep / git-push-review update 配備 / statusline 移行 / merge false 値の全分岐 / fonts / install-bootstrap / codex-setup / wizard / setup / deploy / update / dryrun / i18n ほか（unit テスト計 298 件 Pass）

### Docs
- **ドキュメントと実態を同期（#102）**: CLAUDE.md を現行アーキテクチャ（wizard 分割 / `setup_main` / `_FEATURE_SCRIPT_ORDER` / `install_selected_plugins`）へ更新、README（ja/en）のフック数・プラグイン構成を同期、`docs/wizard-config-mapping`（ja/en）を更新

## [0.54.0] - 2026-06-11

### Changed
- **グローバル CLAUDE.md に注入される feature partial を最小化（Fable 5 セーフティ分類器の誤検知対策）**: Claude Code の新モデル Fable 5 には cybersecurity/biology 話題向けのセーフティ分類器があり、`~/.claude/CLAUDE.md` のキット管理セクションに含まれる SSRF 防御・認証情報・セキュリティ監査等の技術記述の累積によって、無害なメッセージ（挨拶のみ等）でも "Fable 5's safety measures flagged this message" が発生し Opus へ強制切替されることを実機検証で確認した。発生条件は「Fable 5 使用 + `web-content-extraction` / `codex-plugin` feature 有効」で、トリガーは特定キーワードではなくキット管理ブロック全体の累積（キーワード除去のみでは再現が続き、ブロック最小化で解消することを段階的切り分けで確認済み）。対策として、常時コンテキストに注入される CLAUDE.md partial 4 ファイル（`i18n/{ja,en}/partials/web-content-extraction.md`、`features/codex-plugin/CLAUDE.md.partial.{ja,en}`）を「行動指針 + コマンド一覧 + 詳細はドキュメント参照」の最小構成に変更。除去した技術詳細（SSRF ガード仕様・プライベート IP 拒否・DNS リバインディング対策・失敗時フォールバック手順）は `skills/web-content-extraction/SKILL.md` の Security Rules / Failure Handling 節に既存のため情報の欠落はなし（skill は on-demand 読み込みで常時注入されない）。Codex partial の委譲基準詳細・セキュリティ注意（API キーを含めない等）は plugin 本体ドキュメントへ委譲。既存インストールには `setup.sh --update` / `/update-kit` の 3-way merge で適用される（キット管理セクションのみ更新、ユーザーセクションは保持）

## [0.53.1] - 2026-06-10

### Fixed
- **3-way merge がキー削除の代わりに literal JSON `null` を書き込むバグを修正**: `lib/merge.sh` の `merge_settings_3way()`（トップレベルキー）と `_merge_object_3way()`（env 等のオブジェクト内サブキー）で、競合解決の結果が「キーが存在しない側」（kit がキーを削除 / ユーザーがキーを削除）になった場合に、`del(.[$k])` ではなく `null` がそのまま `settings.json` へ代入されていた。代表的な影響経路: ① kit がキーを削除 + ユーザーが値を変更 + 「[U]se kit's」選択（または記憶済み use-kit preference）→ 削除したはずのキーが `"KEY": null` として残存 ② ユーザーがサブキーを手動削除 + kit 側は未変更 → update のたびに削除したキーが `null` 値で復活（このほか「ユーザーがキー削除 + kit が値変更 + keep-mine/非対話」等、解決結果が不在側になる経路すべてに同じガードが効く）。Claude Code の `env` は文字列値を想定するため `null` は不正値。代入チョークポイントで `"null"` 選択を `del` に変換する形で両関数を修正し、回帰テスト 3 件を `tests/unit/test-merge.sh` に追加（修正なしで FAIL することを確認済み）。なお `_merge_settings_bootstrap()` は分岐構造上 null が競合経路に到達しないため対象外

## [0.53.0] - 2026-06-10

### Fixed
- **safety-net の `cc-safety-net` バイナリを自動インストールするように修正（#68）**: これまで safety-net feature は hook 定義と STRICT env を `settings.json` に配置するだけで、hook が呼び出す `cc-safety-net` バイナリ自体はインストールしていなかった。#67 の matcher 修正で hook が実際に発火するようになった結果、バイナリ不在環境では `command not found`（deny JSON が出力されない）となり、**保護が黙って無効化（silent fail-open）** されていた。`setup.sh` に `maybe_install_cc_safety_net()` を追加し、feature 有効かつバイナリ未導入のとき `npm install -g --ignore-scripts --no-audit --no-fund cc-safety-net` で自動導入する（`lib/prerequisites.sh` の `check_cc_safety_net()`、Biome と同パターン + WCE と同水準のサプライチェーン hardening。`--ignore-scripts` でも bin link は npm の reify ステップで作成されるため動作に影響なし）。npm prefix が書き込み不可・npm 不在などで失敗した場合は警告して継続（非致命）し、手動インストール手順を案内。dry-run では `[WOULD RUN]` ログのみ、テストハーネスは `SAFETY_NET_SKIP_NPM_INSTALL=1` でスキップ

### Changed
- **STRICT env に正準名 `CC_SAFETY_NET_STRICT` を追加（legacy 名は互換のため併置）**: upstream の正準環境変数は `CC_SAFETY_NET_STRICT` で、従来の `SAFETY_NET_STRICT` は legacy alias。一方、旧バイナリ（0.7.x 等）は legacy 名しか認識せず、`setup.sh` はバイナリ既存時にインストールをスキップするため、正準名への置き換えだけでは既存環境の strict mode が黙って無効化される（Codex レビュー指摘・0.7.1 で実証）。このため `features/safety-net/hooks.json` は両方の名前を `"1"` で設定する: 新バイナリ（1.x）は正準名を優先し、旧バイナリは legacy 名で fail-closed を維持。既存インストールは update の 3-way merge で追従する。**注意**: `SAFETY_NET_STRICT` の値を手動変更していた場合（例: `"0"` で fail-closed を無効化）、1.x バイナリでは新たに追加される正準名 `CC_SAFETY_NET_STRICT="1"` が legacy 名より優先されるため strict mode が再有効化される（安全側への変化）。カスタム値を維持したい場合は `~/.claude/settings.json` の `CC_SAFETY_NET_STRICT` に再設定すること
- **cc-safety-net のリポジトリ URL を更新**: upstream が `kenryu42/claude-code-safety-net` から `kenryu42/cc-safety-net` にリネームされたため、README（ja/en）・CLAUDE.md のリンクを新 URL へ更新（旧 URL も GitHub のリダイレクトで到達可能）

### Added
- **`uninstall.sh` に cc-safety-net の削除プロンプトを追加**: npm グローバルに `cc-safety-net` が存在する場合、削除するか確認する（他の AI CLI でも使われ得るため既定は残す）。削除失敗は非致命で手動コマンドを案内
- **unit テスト**: `tests/unit/test-safety-net-install.sh` を追加（hooks.json の env / matcher / コマンド、profiles 配線、setup.sh / prerequisites.sh / uninstall.sh の自動導入配線、`check_cc_safety_net()` の stub npm による機能テスト）

## [0.52.3] - 2026-06-10

### Fixed
- **doc-blocker が Claude Code の auto-memory 書き込みをブロックしていた問題を修正**: doc-blocker hook（PreToolUse / Write）の除外条件に `~/.claude/projects/<プロジェクト>/memory/` 配下を追加。Claude Code 本体の永続メモリ機能（`MEMORY.md` および各メモリファイル）への `.md` Write が `exit 2` でブロックされ、メモリが保存できなかった。通常の `.md`/`.txt` 散乱防止と README/CLAUDE/AGENTS/CONTRIBUTING の除外は従来どおり維持

## [0.52.2] - 2026-06-10

### Fixed
- **web-content-extraction の堅牢化（レビュー追補）**: env 上限値（`DEFUDDLE_MAX_PDF_PAGES` / `DEFUDDLE_MAX_PDF_TEXT_CHARS` / `DEFUDDLE_MAX_BYTES` / `DEFUDDLE_TIMEOUT_MS`）を `parsePositiveInt` で検証し、非数値・0・負などの不正値で上限が無効化される fail-open / fail-broken を防止。PDF 抽出全体を `withSilencedStdout` で包み、pdfjs のログによる stdout(JSON) 汚染を防止（`defuddle-core` と対称化）。自動更新フック（`update-deps.mjs`）と deploy / CI の `npm install` / `npm ci` に `--ignore-scripts` を付与し、依存の lifecycle script 経由のサプライチェーン攻撃面を縮小。`assertPublicUrl` の DNS 事前チェック（公開ホスト名→プライベート IP 解決の拒否）を `dns.lookup` モックで検証するテストを追加

## [0.52.1] - 2026-06-09

### Fixed
- **hook の matcher を Claude Code 仕様（tool 名マッチ）に修正（#67）**: base settings および `features/*/hooks.json` の多くの hook が matcher に `tool == "Bash" && tool_input.command matches "..."` のような **boolean 式**を使っていたが、Claude Code の matcher は tool 名への完全一致 / `|` 区切り / 正規表現のみをサポートするため、これらは正規表現として tool 名に評価され**一切マッチせず hook が発火していなかった**。全 hook の matcher を tool 名形式（`"Bash"` / `"Write"` / `"Edit"` / `"Edit|Write"`）へ修正。対象: `safety-net` / `doc-blocker` / `tmux-hooks`（dev サーバーブロック・reminder）/ `git-push-review` / `prettier-hooks` / `console-log-guard` / `biome-hooks` / `doc-size-guard` / `pr-creation-log`（通常・legacy）/ `strategic-compact`
- **matcher が担っていた tool 入力フィルタをスクリプト内 stdin 判定へ移設**: matcher は tool 名しか絞れないため、`tool_input.command` / `tool_input.file_path` による絞り込みを各 hook スクリプト内（`jq` で stdin JSON を判定）へ移動。これにより `tmux-hooks` の dev サーバーブロックが全 Bash をブロックする・`prettier`/`biome`/`console-log-guard` が全ファイルで走る・`doc-size-guard` が全 Write で走る、といった広すぎる発火を防止
- **ブロック用 exit code を 2 に修正**: `doc-blocker` と `tmux-hooks` の dev サーバーブロックが `exit 1`（Claude Code では non-blocking でツール実行は継続）だったため、`exit 2`（ブロック）へ修正。matcher 修正だけではブロックとして機能しなかった問題を解消
- **`strategic-compact` の matcher が全ツールにマッチしていた問題**: `tool == "Edit" || tool == "Write"` の `||` が正規表現の空選択肢となり全ツールにマッチしていたため、`"Edit|Write"` へ修正。手動設定例（`SKILL.md`）の matcher も同様に修正
- **`git-push-review` の hook 化**: hook 実行環境には対話 TTY が無く `read -r` が機能しないため、`git push` 検出時に**非ブロッキングのレビュー喚起メッセージ**を stderr へ出す形に修正
- **`tmux-hooks` dev サーバーブロックの自己ブロック（デッドロック）解消 + 過剰許可是正**: matcher 修正で hook が実際に発火するようになった結果、ブロック時に案内する推奨コマンド `tmux new-session -d -s dev "npm run dev"` 自体が `npm run dev` に再マッチして `exit 2` され、推奨どおり tmux で dev サーバーを起動できないデッドロックが顕在化していた。tmux 外（`$TMUX` 無し）かつ tmux 起動形（`new-session`/`new`/`send-keys`）でない素の dev コマンドのみをブロックするガードを追加（コマンドに `tmux` の語を含むだけで回避される過剰許可も防止）

## [0.52.0] - 2026-06-09

### Added
- **web-content-extraction スキル（Defuddle ベース Web 取得標準レイヤー）**: URL・公式ドキュメント・ブログ・ニュース・OSS ページを読むとき、生 HTML を直接読まずに [Defuddle](https://github.com/kepano/defuddle) で本文を Markdown/JSON 化してから読むための実行スキルを追加（`standard`/`full` で導入）。既存スキルと異なり **実行スクリプト + npm 依存（`defuddle` / `jsdom` / `pdfjs-dist` / `undici`）を持つ「重い」スキル**。公開 URL 取得（`scripts/defuddle-url.mjs`、SSRF 防御・PDF 対応）とローカル HTML 抽出（`scripts/defuddle-file.mjs`、外部通信なし・PDF 拒否）を提供。**Node.js 22+ が必要**（CI で 22/24 をテスト）。Node 未検出環境では URL/PDF 機能を「Node 未検出」と明示して無効化し、インストールは失敗させない
- **コマンド3種**: `/web-article`（記事の構造的要約・事実と意見の分離）、`/oss-analyze`（OSS を技術×導入判断で整理、GitHub は raw README/メタ併用）、`/web-source-review`（情報源の信頼性評価）。いずれも `$ARGUMENTS` を bash へ直接展開せず、単一 http(s) URL 検証 → 単一引数渡しの command injection 対策を保持
- **web-content-update feature（opt-in 自動更新フック）**: SessionStart で `update-deps.mjs` を async 実行し、スキルの依存（`defuddle`/`jsdom`/`pdfjs-dist`）を latest 追従更新。24h スロットル・1h backoff・`wx` atomic lock（stale 30 分で奪取）・**`npm test` テストゲート + 失敗時ロールバック（`npm ci`）**。ゼロトラスト観点から **既定 OFF（`full` のみ既定 ON、`minimal`/`standard` は opt-in）**。`undici` は自動更新対象に含めず手動更新（`npm run update:deps`）
- **CLAUDE.md 標準ルール（i18n 経由・INSTALL_SKILLS ゲート）**: `i18n/{ja,en}/CLAUDE.md.base` の kit-managed 区画に `{{FEATURE:web-content-extraction}}` マーカーを追加し、`i18n/{ja,en}/partials/web-content-extraction.md` の本文をスキル導入時のみ注入。`minimal`（スキル未導入）では注入せずマーカーを除去
- **依存解決の配線**: `setup.sh`（fresh / fresh-with-existing / update / dry-run の全経路）でスキル配置後に `npm ci --omit=dev` を実行する `maybe_install_web_content_deps()` を追加。Node/npm 未検出時は警告して継続（非致命）、dry-run は `[WOULD RUN]` ログのみ、テストハーネスは `WCE_SKIP_NPM_INSTALL` でスキップ
- **CI / テスト**: `tests/unit/test-web-content-extraction.sh`（スキル配置・registry 配線・hooks.json・settings/CLAUDE.md ゲートの検証）と、Node 22/24 マトリクスでスキルの `node --check` + `npm ci` + `npm test` を回す `.github/workflows/skill-web-content-extraction.yml` を追加

### Security
- **非フェッチ安全 DOM**: 自前構築の JSDOM を `defuddle/node` に渡し（`resources:'usable'`/`runScripts` を付けない）、サブリソース外部取得・ページ内スクリプト実行を行わない（`linkedom` は `defuddle/node` 非互換のため jsdom 採用）
- **SSRF 多層防御**: http(s) 限定・認証情報付き URL 拒否、IPv4 private/reserved 全域 + IPv6 default-deny（`2000::/3` のみ許可、Teredo/6to4/NAT64/site-local 等を除外）をバイト単位判定。`undici` の guarded dispatcher で接続 IP を pin（DNS リバインディング/TOCTOU 対策）、リダイレクトは各ホップ再検査（https→http ダウングレード拒否）、本文はストリーム上限。`ALLOW_PRIVATE_URLS=true` 時のみ解除し stderr 監査
- **PDF 安全抽出**: pdfjs-dist legacy + デフォルト Node data factory が `cMapUrl` 絶対パスから CMap を読んで CJK 対応（外部通信なし）、ページ/文字数上限（解凍爆弾対策）、`loadingTask` を try/finally で必ず destroy。stdout は JSON 専用

### Notes
- アンインストール: `uninstall.sh` がスキルの `node_modules/`・`logs/`（manifest 非追跡）を明示削除
- 配布物に `node_modules/`・`logs/`・`*.bak` を含めない（`.gitignore` に追加）

## [0.51.1] - 2026-05-31

### Added
- **mattpocock/skills 評価レポート（見送り判断）**: [mattpocock/skills](https://github.com/mattpocock/skills)（commit `e3b90b5`）を StarterKit に取り込むか調査し、`docs/mattpocock-skills-evaluation.md` を新規追加。14 skill を個別評価した結果、過半が既存資産（常時起動 `superpowers` + キット独自の `/tdd` `/plan` `/handover` 等）と重複・競合し、ネイティブ plugin 統合は `marketplace.json` 不在でブロック、公式導入は第三者製 `npx skills` installer 依存であることから **見送り（案 D）** を推奨。キット本体（`setup.sh` / `config/` / `commands/` / `skills/` / `features/`）は不変。将来 `marketplace.json` が上流に追加された場合の再評価トリガーも記載

## [0.51.0] - 2026-05-20

### Added
- **GitHub Spec Kit 統合プロポーザル**: 仕様駆動開発（SDD）ツールキットである [GitHub Spec Kit](https://github.com/github/spec-kit) を StarterKit と並存させるための薄い導線として `/spec-kit-init` コマンドを追加。`specify-cli` 本体は本キットがインストールせず、`uv tool install specify-cli` でユーザー側に入れる前提。コマンドは前提条件チェック → `specify init --integration claude` 案内 → cn-memory との責務分離説明 → SDD ワークフロー誘導の 5 ステップで構成
- **評価レポート**: `docs/spec-kit-evaluation.md` を新規追加。Spec Kit v0.8.11 を実プロジェクトで `constitution → specify → clarify → plan → tasks` まで走破し、各コマンドを 5 段階評価。グローバル `~/.claude/` への書き込みゼロを実測確認、StarterKit との衝突マトリクス、cn-memory との責務分離方針、フル統合（案A）/隔離（案B）/方法論吸収（案C）の 3 案比較を含む
- **CLAUDE.md kit-managed セクション拡張**: `i18n/{en,ja}/CLAUDE.md.base` に Spec Kit との並存規約を 3 行追加。`<!-- SPECKIT START --> ... <!-- SPECKIT END -->` マーカーが `<!-- BEGIN STARTER-KIT-MANAGED --> ... <!-- END STARTER-KIT-MANAGED -->` と共存可能であること、プロジェクトローカル constitution が cn-memory のグローバル規約を上書きする優先順位を明示

## [0.50.2] - 2026-05-15

### Fixed
- **macOS bash で PATH 永続化先を修正**: `$SHELL` が bash の macOS 環境では `~/.bash_profile` と `~/.bashrc` の両方に `~/.local/bin` や Homebrew Node.js の PATH を追加するよう変更。Ghostty などの bash login shell と通常の bash の両方で `claude` が見つからない問題を解消

## [0.50.1] - 2026-05-15

### Fixed
- **macOS 初回セットアップ時の Bash 4+ 検出を堅牢化**: Homebrew 標準配置の Bash 4+ 候補を明示的に検証してから `setup.sh` を re-exec するよう変更。非数値のバージョン出力を拒否し、`/bin/bash` が Bash 3.2 の環境でも安全に Bash 4+ を探せるよう改善
- **dry-run 中の Bash 自動インストールを抑止**: Bash 4+ が未導入の dry-run では package manager による Bash インストールへ進まず、副作用なしで失敗するよう変更

## [0.50.0] - 2026-04-13

### Added
- **Biome hooks と条件付き自動インストール**: `biome-hooks` feature を追加し、JS/TS の `Edit` / `Write` 後に `biome check --write` を実行可能にした。`full` profile では Biome を既定有効にし、`biome` が未導入なら `brew install biome` を先に試行、失敗時のみ `npm install -g @biomejs/biome` にフォールバックする。standard/minimal/custom では Biome を明示有効化した場合のみ自動インストールを試行する

### Changed
- **formatter hook の排他制御を追加**: `prettier-hooks` と `biome-hooks` に相互 conflict を定義し、saved config / update / non-interactive / CSV hooks を含む全設定経路で両方が同時有効のまま残らないよう wizard 側で正規化する

## [0.49.1] - 2026-04-13

### Changed
- **CLAUDE.md 更新**: Feature Recommendation System のアーキテクチャ概要を Notable Features に追加。Execution Flow に `_detect_and_write_pending_features` を追加。「Adding a New Feature」チェックリストに `displayName`/`description` 整備と recommendation 除外の確認項目を追加

## [0.49.0] - 2026-04-13

### Added
- **/update-kit で pending feature の対話的レビュー**: update 完了後に `pending-features.json` を検出し、各新機能について「有効にする / 今はいい / 今後聞かない」を Claude が対話的に提示。有効化時は `setup.sh --update` を再実行して 3-way merge 経由で settings.json を安全に再生成

## [0.48.0] - 2026-04-13

### Added
- **update 時の pending 検出と SessionStart 通知**: `setup.sh --update` 後に新機能を自動検出し `pending-features.json` を生成。SessionStart hook で新機能の名前・概要を通知し `/update-kit` への誘導を表示。通知は日本語/英語対応、4件以上は先頭3件+省略表示。Full profile は全自動有効化のため通知なし

## [0.47.0] - 2026-04-13

### Added
- **Feature Recommendation データ基盤**: `DISMISSED_FEATURES` CSV による dismiss 管理、`ENABLE_FEATURE_RECOMMENDATION` フラグ、既存ユーザー向けマイグレーションロジックを追加。`lib/recommendation.sh` にヘルパー関数を配置。`profiles/*.conf` / `wizard.sh` / `i18n` を更新
- **feature.json スキーマ正規化**: `pre-compact-commit` と `statusline` の `feature.json` に不足していた `displayName` を追加し、全 feature で統一スキーマに正規化

## [0.46.0] - 2026-04-13

### Added
- **effortLevel のデフォルトを high に設定**: `settings-base.json` に `"effortLevel": "high"` を追加。全プロファイル共通で Claude の推論深度を high に固定。ユーザーは settings.json で個別に上書き可能

## [0.45.1] - 2026-04-13

### Changed
- **GitHub Actions を SHA pinning に変更**: `actions/checkout`, `actions/cache`, `ludeeus/action-shellcheck` をタグ指定からコミット SHA 固定に変更し、サプライチェーン攻撃リスクを低減
- **Dependabot で GitHub Actions の自動更新を有効化**: `.github/dependabot.yml` を追加し、SHA pinning されたアクションの週次自動更新 PR を生成

## [0.45.0] - 2026-04-03

### Fixed
- **saved config の空値が profile default を上書きする問題を修正**: `_safe_source_config()` で空値をスキップし、`save_config()` で空値を書き出さないよう変更。新機能の `ENABLE_*` フラグが update path で正しく採用されるようになる。`SELECTED_PLUGINS=""` 等の正当な空値は `_CONFIG_EMPTY_ALLOWED_KEYS` 定数で例外管理

## [0.44.0] - 2026-04-03

### Changed
- **No Flicker モードを standard プロファイルでも有効化**: `CLAUDE_CODE_NO_FLICKER=1` を standard/full 両プロファイルでデフォルト有効に変更

## [0.43.1] - 2026-04-03

### Fixed
- **legacy 24h キャッシュが auto-update の hook スクリプト差し替えを阻害する問題を修正**: `setup.sh --update` 実行時に旧版 auto-update.sh が使用する `~/.claude/.starter-kit-update-cache` を削除するよう変更。v0.43.0 の `kit_owned` 修正が実際に適用されるために必要な前提条件

## [0.43.0] - 2026-04-03

### Changed
- **bootstrapped snapshot 環境での hook スクリプト更新動作を変更**: `_update_file()` に `kit_owned` フラグを追加。bootstrapped snapshot（初回 update 等ベースラインが存在しない状態）で `setup.sh --update` を実行した際、hook スクリプト（auto-update, statusline 等）の kit 管理ファイルが interactive/non-interactive を問わず最新版に差し替わるよう変更。これにより auto-update hook が自身を更新できない問題を解消

## [0.42.0] - 2026-04-03

### Added
- **No Flicker モード**: Claude Code の実験的フリッカー防止レンダラー (`CLAUDE_CODE_NO_FLICKER=1`) を feature toggle として追加。full プロファイルで有効、minimal/standard では無効

## [0.41.0] - 2026-04-01

### Changed
- **PR creation hook を限定実行へ最適化**: `pr-creation-log` に hook-level `if` と `async` を導入し、`gh pr create` 以外の Bash 実行では hook を起動しないよう変更
- **PR creation hook の shell を簡素化**: shell 内の `gh pr create` 再判定を削除し、PR URL 抽出だけに責務を絞って後処理を軽量化
- **旧版 Claude Code へ安全にフォールバック**: `2.1.89` 未満では `pr-creation-log` を legacy hook 形状で生成し、`if` / `async` 非対応環境でも従来挙動を維持

## [0.40.0] - 2026-04-01

### Changed
- **skill frontmatter を限定強化**: 同梱 skill すべてに `when_to_use` を追加し、Claude Code が起動条件を判断しやすい形に整理
- **背景 skill を slash menu から除外**: `continuous-learning` に `user-invocable: false` を追加し、hook 連携前提の skill を前面に出さないよう調整
- **skill 作成ガイドを明文化**: README と architecture 文書に、starter-kit が推奨する最小 frontmatter セット (`name` / `description` / `when_to_use`) と `argument-hint` / `user-invocable` の使い分けを追記

## [0.39.0] - 2026-04-01

### Changed
- **auto-update を session 境界の async 実行へ移行**: `SessionStart` に加えて `SessionEnd` でも毎回更新確認を行い、hook-level `async: true` で非同期実行するよう変更
- **24時間キャッシュを廃止**: Claude Code `2.1.89+` では 24h TTL をやめ、`~/.claude/.starter-kit-update.lock/` による重複実行防止へ移行
- **更新確認の頻度を変更**: Claude Code `2.1.89+` では 24h に 1 回ではなく、session 境界ごとに `git fetch --tags --quiet` を試みるよう変更
- **auto-update の健全性チェックを拡張**: update 完了後の health check が `SessionStart` と `SessionEnd` の両 hook 登録を確認するよう変更
- **旧版 Claude Code へ安全にフォールバック**: `2.1.89` 未満を検出した場合は `SessionStart` のみの旧 auto-update hook を生成するよう変更
- **非同期失敗を次回へ持ち越し**: バックグラウンド更新失敗を `~/.claude/.starter-kit-update-status` に保存し、次回 hook 実行時に 1 回だけ警告するよう変更

### Compatibility
- Claude Code `2.1.89` で確認
- auto-update は引き続き one-liner install (`~/.claude-starter-kit/.git` が存在する環境) のみで有効
- 旧版 Claude Code を検出した場合は `SessionStart` + 24h cache の旧 hook へフォールバック

## [0.38.0] - 2026-04-01

### Added
- **PostCompact hook による compact 完了通知**: `memory-persistence` に `PostCompact` を追加し、compact 後に session notes / learned context の再利用フローを案内する軽量メッセージを表示

### Changed
- **compact フロー文書を更新**: `CLAUDE.md` と `memory/context-engineering.md` に `PostCompact` を含む compact 前後の役割分担を追記
- **検証導線を更新**: ローカル検証手順に unit / scenario test を追加し、`PostCompact` は Claude Code `2.1.89` で確認済み・旧版では無視される可能性がある旨を明記

## [0.37.3] - 2026-03-31

### Added
- **自動更新ヘルスチェック**: `setup.sh --update` および `/update-kit` の完了時に auto-update が正しく動作しているかチェックし、問題があれば警告を表示。SessionStart hook の登録状態、Git リポジトリの存在、リモートとのバージョン差異を検証する

## [0.37.2] - 2026-03-31

### Fixed
- **Codex login status の stderr 出力を許容**: `codex login status` が stdout ではなく stderr に状態を出す環境でも `_codex_login_status` が正しく認証済みと判定できるよう修正

## [0.37.1] - 2026-03-31

### Fixed
- **Codex MCP cleanup の検出漏れを修正**: `claude mcp list/remove` の user-scope 固定をやめ、`~/.claude.json` 側など user 固定で見えない legacy Codex MCP も plugin 移行時に cleanup できるよう修正
- **macOS の timeout fallback で login 判定が空になる不具合を修正**: `_run_with_timeout` が stdout/stderr を保持するようにし、`codex login status` の結果を command substitution で正しく受け取れるよう修正

## [0.37.0] - 2026-03-31

### Changed
- **update / dry-run の進捗表示を改善**: `setup.sh --update` と `/update-kit` 系の更新で `Step N/M` 表示を追加し、長い処理の途中経過が見えるよう改善
- **settings.json merge の要約を追加**: 3-way merge 完了時に keep-user / kit-update / conflicts などの集計を表示し、quiet mode でも何が起きたか把握しやすく改善
- **preview 実行の見分けを改善**: dry-run 子プロセスを `Preview Mode` として明示し、対話モードのプレビュー起動前後にも案内を追加

## [0.36.0] - 2026-03-31

### Changed
- **前提ツールの自動導入を統一**: `git` `jq` `curl` GNU `sed` GNU `awk` `bash 4+` `node` `tmux` `gh` を、未導入時に自動インストールを試みる挙動に統一
- **Bash 4+ 更新導線を改善**: macOS の Bash 3.2 環境では Bash 4+ の自動導入を試した上で re-exec し、失敗時のみ手動コマンドを案内
- **セットアップ失敗条件を明確化**: `node` `tmux` `gh` `dos2unix` の自動導入に失敗した場合は、警告で継続せず明示的に失敗させるよう変更

## [0.35.0] - 2026-03-31

### Changed
- Migrated Codex integration from MCP server to official Codex Plugin (`openai/codex-plugin-cc`)
- Renamed `ENABLE_CODEX_MCP` to `ENABLE_CODEX_PLUGIN` (backward compatible — old saved configs auto-migrate)
- Simplified CLAUDE.md delegation rules (plugin's built-in skills replace manual 7-section format)
- Codex setup now uses 2-axis state detection (plugin × MCP) for safe migration

### Added
- `--codex-plugin` CLI flag (alias: `--codex-mcp` preserved for backward compat)
- Interactive migration prompt for existing Codex MCP users
- Codex plugin and legacy MCP cleanup in uninstall flow
- `codex_plugin` field in manifest for tracking

### Removed
- MCP server registration (`claude mcp add -s user codex -- codex mcp-server`)
- 7-section delegation format in CLAUDE.md partials (replaced by plugin's built-in skills)

## [0.34.0] - 2026-03-25

### Added
- **プラグイン自動更新**: `setup.sh --update` / `/update-kit` 実行時にプラグインを `claude plugin install` で再インストールし最新化。add-only 方式（ユーザー追加プラグインは保持）
- **i18n**: `STR_DEPLOY_PLUGINS_UPDATED` を en/ja に追加

## [0.33.0] - 2026-03-25

### Added
- **macOS CI**: `test.yml` を matrix 化し `macos-latest` ジョブを追加。brew cache + Bash 4+ 明示使用 + Bash 3.2 re-exec テスト
- **semver ルール**: CLAUDE.md に Versioning セクションを追加。patch/minor/major の判断基準を明文化

### Fixed
- **uninstall.sh**: CLAUDE.md のキットセクション除去を `sed` → `awk` に変更（macOS BSD sed の互換性問題を修正）

## [0.32.1] - 2026-03-25

### Changed
- **wizard.sh リファクタリング**: `HOOK_LABELS` 二重定義を `_init_hook_labels()` に統一、`save_config()` をキー配列ループ化、`_prompt_yes_no()` 抽出で yes/no ステップを簡素化 (1117→1099 行)

## [0.32.0] - 2026-03-25

### Changed
- **setup.sh 分解**: ビルド・デプロイ関数群 (~700 行) を `lib/deploy.sh` に抽出。setup.sh はオーケストレーション専用 (585 行) に
- **レガシーラッパー削除**: `build_settings()` / `build_settings_to_file()` を削除し、`build_settings_file()` に統一
- **CLAUDE.md**: sourcing 順序・Architecture セクション・Adding a New Feature セクションを実態に合わせて更新

## [0.31.0] - 2026-03-25

### Added
- **単体テスト基盤**: 82 本の関数レベル単体テストを追加（template, snapshot, merge, json-builder, features, detect, prerequisites, wizard-utils）。`tests/run-unit-tests.sh` ランナーと `tests/unit/` ディレクトリ構成
- **テストヘルパー拡充**: `assert_equals`, `assert_not_equals`, `assert_matches`, `assert_empty`, `assert_not_empty`, `run_func` を `tests/helpers.sh` に追加

### Fixed
- **`assert_json_has_key` の false/null 誤判定**: `jq -e` → `jq -e '($key) != null'` に修正。値が false/null のキーでも正しく存在検出
- **`assert_file_contains` の正規表現マッチ**: `grep -q` → `grep -qF` に修正。リテラル文字列マッチに統一

### Changed
- **CI**: `.github/workflows/test.yml` に単体テストステップを追加（シナリオテストの前に実行）

## [0.30.1] - 2026-03-25

### Fixed
- **CLAUDE.md スナップショットの二重マーカー自己修復**: `_snapshot_claude_md()` の書き込み後に BEGIN マーカーの数を検証し、複数ペアが検出された場合は最初のペアだけを再抽出して自動修復。v0.30.0 以前のバグでスナップショットに二重マーカーが残った環境で、update のたびに false conflict が発生する問題を解消
- **`grep -cF || echo 0` の二重出力バグ修正**: コマンド置換内の `|| echo 0` が `"0\n0"` を生成する問題を `lib/snapshot.sh` / `lib/template.sh` で統一修正

## [0.30.0] - 2026-03-24

**大規模リファクタリングマイルストーン** (v0.20.4 → v0.30.0)

### Added
- **Feature registry** (`lib/features.sh`): `declare -A _FEATURE_FLAGS`, `_FEATURE_HAS_SCRIPTS`, `_FEATURE_ORDER` で 12 feature を一元管理。新 feature 追加時の編集ファイル数を 16-19 → 5 に削減
- **`_add_to_path_now_and_persist()`**: 即時 export + RC 永続化を統合
- **`_check_major_upgrade()`**: semver メジャーバージョン変更検出 + 復旧案内
- **Dirty check**: 全更新経路（install.sh, install.ps1, auto-update.sh, /update-kit）で git dirty preflight
- **シナリオテスト基盤**: 28 テスト（27 PASS + 1 SKIP）+ CI workflow
- **ヘッダーコメント + 契約定義**: 全 lib ファイルに Requires/Uses/Sets/Exports/Dry-run 分類

### Changed
- **Bash 4+ 必須化**: 二段階ブート（Stage 1: Bash 3.2 互換 → re-exec → Stage 2: Bash 4+）
- **`build_settings_file()` 統合**: `build_settings()` + `build_settings_to_file()` の ~140行重複を registry ループに統合
- **`deploy_hook_scripts()` 統合**: mode 引数（simple/merge-aware）、`_deploy_hook_scripts_safe()` 削除
- **Codex MCP コード分離**: setup.sh から ~420行を `lib/codex-setup.sh` に移動
- **関数一元化**: `_merge_settings_bootstrap()` → merge.sh、`_user_section_heading()` → template.sh、`_get_shell_rc_file()` → prerequisites.sh
- **ghostty.sh HackGen 重複関数削除**: fonts.sh の `install_hackgen_nf()` を使用。`_ghostty_ensure_brew()` → `_ensure_homebrew()` に統一

### Removed
- 未使用 i18n 文字列 31 個を en/ja から削除

## [0.24.0] - 2026-03-24

### Changed
- **PATH 共通化**: `_add_to_path_now_and_persist()` を prerequisites.sh に追加。即時 `export PATH` + RC ファイル永続化を一関数に統合。setup.sh の 5 箇所の inline PATH export を置換
- **`_get_shell_rc_file()` を prerequisites.sh に一元化**: codex-setup.sh の重複定義を削除
- **`_ensure_local_bin_in_path()` 削除**: `_add_to_path_now_and_persist()` に置換

## [0.23.0] - 2026-03-24

### Changed
- **Feature registry 導入**: `lib/features.sh` に `declare -A _FEATURE_FLAGS`, `_FEATURE_HAS_SCRIPTS`, `_FEATURE_ORDER` を定義。12 個の `is_true` ハードコードチェックを registry ループに置換
- **`build_settings_file()` 統合**: `build_settings()` + `build_settings_to_file()` の ~140行重複を `build_settings_file()` に統合。safety-net 先頭アサーション付き
- **`deploy_hook_scripts()` 統合**: 5 個の `is_true` 分岐を `_FEATURE_HAS_SCRIPTS` registry ループに置換。`_make_hooks_executable()` 抽出
- **テスト有効化**: `safety-net-first` + `registry-consistency` テストをスタブから実テストに更新

## [0.22.3] - 2026-03-24

### Added
- **ヘッダーコメント + 契約定義**: 全 lib ファイルに Requires/Uses/Sets globals/Exports/Dry-run 分類を明記。wizard.sh にインターフェース境界コメント。merge.sh にマージ戦略 3 系統を記載

## [0.22.2] - 2026-03-24

### Changed
- **`_merge_settings_bootstrap()` を merge.sh に移動**: update.sh → merge.sh。関連するマージロジックを一箇所に集約
- **`_user_section_heading()` を template.sh に一元化**: setup.sh と update.sh の重複定義を削除し template.sh に統合
- **ghostty.sh の HackGen 重複関数を削除**: `install_hackgen_font()` を削除し、fonts.sh の `install_hackgen_nf()` を使用

## [0.22.1] - 2026-03-24

### Changed
- **Codex MCP コード分離**: setup.sh から ~420行の Codex MCP 関連コードを `lib/codex-setup.sh` に移動。`run_codex_setup()` エントリポイント関数を追加。setup.sh は source + 呼び出しのみ。動作変更なし

## [0.22.0] - 2026-03-24

### Changed
- **Bash 4+ 必須化**: setup.sh を二段階ブートに分割。Stage 1（wizard, detect, prerequisites）は Bash 3.2 互換を維持し、Bash 4+ を検出して re-exec。Stage 2 以降は Bash 4+ 必須
- **`_detect_bash4()` + `check_bash4()`**: `/opt/homebrew/bin/bash`, `/usr/local/bin/bash` 等から Bash 4+ を自動検出。見つからない場合はエラーメッセージとインストール案内を表示
- **`_SETUP_ORIG_ARGS` + `_SETUP_SCRIPT_PATH`**: CLI 引数とスクリプトパスを setup.sh 冒頭で保存し、re-exec 時に引き継ぎ

## [0.21.0] - 2026-03-24

### Added
- **メジャーアップグレード検出**: `_check_major_upgrade()` で semver メジャーバージョン変更（例: v0→v1）を検出し、復旧案内を表示
- **Dirty check（全更新経路）**: `install.sh`, `install.ps1`（WSL + Git Bash）, `auto-update.sh`, `/update-kit` コマンドで、kit リポジトリにローカル変更がある場合は更新をブロックし `git stash` を案内
- **Recovery UX**: 更新失敗時にバックアップパスと復元コマンドを表示。`auto-update.sh` は `.starter-kit-last-backup` からパスを読み取り
- **Skip 通知**: update でスキップされたファイルがある場合、次回の対処方法を案内

### Changed
- **auto-update.sh**: `setup.sh --update` 呼び出しの `2>/dev/null` を除去し stderr を出力（recovery 情報を表示するため）。`--non-interactive` フラグを明示
- **/update-kit コマンド**: Pre-flight checks セクションと Recovery セクションを追加

## [0.20.4] - 2026-03-24

### Fixed
- **一時ファイルの追跡漏れを修正**: `lib/template.sh`, `lib/fonts.sh`, `lib/json-builder.sh` の `mktemp` で作成した一時ファイルが `_cleanup_tmp` トラップに登録されていなかった問題を修正。`_register_tmp()` ヘルパーを追加し全箇所で一貫して追跡
- **`_dryrun_claudemd_diff()` のマーカーなしガード**: CLAUDE.md にマーカーがない場合に `_extract_kit_section` が失敗して差分表示がスキップされる問題を修正
- **`_run_with_timeout()` の set -e 安全性**: `wait` の非0終了が `set -e` でシェルを中断し終了コードを取得できない問題を修正。watcher サブシェルの kill/wait エラーハンドリングも改善
- **`_save_openai_key()` の stat フォールバック**: パーミッション取得失敗時に警告を表示してデフォルト 600 を使用（API キー保護）
- **`write_manifest()` の kit_version 精度向上**: `git describe --tags --always` でタグなしリポジトリでもハッシュを記録。`kit_commit` フィールドを追加
- **バックアップパスの永続化**: `backup_existing()` で `_BACKUP_TIMESTAMP` をグローバル化し、`~/.claude/.starter-kit-last-backup` にパスを保存。bootstrap マイグレーション時にバックアップパスを表示
- **`build_settings_json()` の echo → printf**: JSON パイプラインで `echo` のバックスラッシュ解釈による破損を防止

## [0.18.0] - 2026-03-24

### Fixed
- **update 時にユーザーカスタマイズが上書きされる問題を修正**: `language` や `permissions` 等をユーザーが変更していた場合、update で kit デフォルトに戻されてしまう問題を修正。競合時はユーザーに確認プロンプトを表示するように変更
- **update 前にバックアップを取得**: `setup.sh --update` 実行時も `~/.claude.backup.<timestamp>` を作成し、merge 失敗時の復旧手段を確保
- **部分失敗後の再実行で設定が消える問題を修正**: スナップショット更新をスクリプト末尾に移動し、途中失敗→再実行でユーザー設定が「未変更」と誤判定される問題を解消
- **初回マイグレーションで全ファイルがスキップされる問題を修正**: `bootstrap_snapshot_from_current` 後もファイル差分を比較し、kit 更新があればユーザーに確認するように改善
- **hook scripts が update 時に無条件上書きされる問題を修正**: `~/.claude/hooks/` 配下も `_update_file()` 経由でユーザー変更を検出・確認するように変更

### Added
- **merge 判定の記憶機能**: 競合解決時に `[RK] Keep & Remember` / `[RU] Use kit's & Remember` を選ぶと、判定が `~/.claude/.starter-kit-merge-prefs.json` に保存され次回以降は自動適用
- **`--reset-prefs` フラグ**: `setup.sh --update --reset-prefs` で保存済み merge 判定をクリアし、次回 update で改めて確認

## [0.17.0] - 2026-03-24

### Changed
- **既存 install の移行を update 経路へ寄せる**: 使える snapshot を持たない古い starter-kit install でも、現在の `~/.claude` から first snapshot を起こして migration update に入るよう改善
- **manifest / snapshot の管理対象を絞り込み**: managed file tracking を starter kit が実際に配布・生成するファイルに限定し、ユーザーが独自追加したファイルまで snapshot に取り込まないよう修正

### Fixed
- **既存 `~/.claude` 再構成前の警告追加**: plain `setup.sh` が backup-and-reconfigure フローに入る前に、既存ユーザーへ明示的に warning を出すよう改善

## [0.16.0] - 2026-03-24

### Fixed
- **Update 復元の堅牢化**: manifest に `COMMIT_ATTRIBUTION` と `ENABLE_NEW_INIT` を保存し、保存済み wizard config が欠けている環境でも update 時の設定復元が崩れにくいよう修正
- **初回 upgrade の復元改善**: saved config に新キーがない古い install でも、現在の `settings.json` を fallback として読んで `COMMIT_ATTRIBUTION` と `ENABLE_NEW_INIT` を復元するよう改善
- **旧 `AGENTS.md` の後始末**: 古い release が `~/.claude` に配置していた `AGENTS.md` を update / uninstall 時に削除し、manifest 更新後も残骸が残らないよう修正

### Removed
- **`~/.claude/AGENTS.md` 配布を廃止**: このスターターキットは Claude Code 向けのため、他エージェント向けファイルを `~/.claude/` に配布する挙動を削除

## [0.15.0] - 2026-03-22

### Added
- **Anthropic Skills マーケットプレイス** ([anthropics/skills](https://github.com/anthropics/skills)) を追加。Anthropic 公式のスキルクリエイター・スキル集をプラグインとして利用可能に
  - `document-skills`: ドキュメント作成・編集スキル（DOCX, PDF, PPTX, XLSX 対応）
  - `example-skills`: クリエイティブ・技術・エンタープライズ向けスキルのサンプル集
  - いずれも Standard / Full プロファイルでデフォルト有効
- プラグイン数: 12個 → 14個（v0.8.0 で削除済みだった community 版 pr-review-toolkit の README ゴーストエントリも併せて削除）
- マーケットプレイス数: 1 → 2（`claude-plugins-official` + `anthropic-agent-skills`）

## [0.14.0] - 2026-03-20

### Changed
- **ステータスライン刷新**: Braille Dots パターン（Python）に全面切り替え。点字文字によるプログレスバーと使用率に応じた緑→赤グラデーションで ctx / 5h / 7d レートリミットを1行表示

### Acknowledgements
- ステータスライン実装は [逆瀬川さん](https://nyosegawa.com/posts/claude-code-statusline-rate-limits/) の記事 "Pattern 5: Braille Dots" を参考にしました。感謝！

## [0.13.1] - 2026-03-18

### Fixed
- **Homebrew インストール**: 対話モードで `NONINTERACTIVE=1` が無条件に設定されていたため sudo プロンプトが表示されず、Homebrew のインストールに失敗する問題を修正

## [0.13.0] - 2026-03-15

### Changed
- **厳選版 v2 リファクタリング**: 「少なく、鋭く」の原則に基づき、付加価値の低い機能を削除
- **Strategic Compact フック強化**: FIC（Frequent Intentional Compaction）早期警告を追加。ツールコール数が閾値の60%に達した時点で `/compact` を推奨
- **Doc Size Guard**: Standard+Full → **Full のみ** に変更（上級者向け機能のため）

### Removed
- `/parallel` コマンド: Claude Code の `--worktree` でネイティブ対応済み
- `/cross-review` コマンド: Codex MCP 前提で利用者限定。`/code-review` で十分
- `sdd-workflow` スキル: 外部フレームワーク依存、スキルとしては中途半端
- `orchestration-pattern` スキル: 教育的内容は README/ブログで説明すべき
- `context-management` スキル: Strategic Compact フック強化でカバー
- `agent-native-design` スキル: 一般論は README で説明すべき
- `daily-practices` ルール: `anti-patterns` ルールと重複
- `doc-freshness-guard` フック: 3日警告は多くのプロジェクトでノイズ

## [0.12.0] - 2026-03-15

### Added
- **Orchestration Pattern スキル** (`orchestration-pattern`): Command → Agent → Skill の3層設計パターンガイド。ワークフロー構築時のリファレンス
- **Prompt Patterns スキル** (`prompt-patterns`): 実践的プロンプトテクニック集（Discovery, Quality Challenge, Efficiency, Debugging, Session Management パターン）
- **Permissions Guide ルール** (`permissions-guide`): dangerously-skip-permissions を使わずにセキュリティを保つ permissions 設定のベストプラクティス
- **Daily Practices ルール** (`daily-practices`): コミット規律、コンテキスト衛生、デバッグアプローチ、Plan Before Execute のガイドライン
- `/handover` コマンドにセッション命名規約（`/rename` パターン）を追記

### Changed
- **エージェント frontmatter 強化**:
  - `planner`, `code-reviewer`, `security-reviewer` に `permissionMode: plan` を追加（レビュー重視）
  - `planner` に `Bash` ツールを追加（プロジェクト状態確認用）
  - `security-reviewer` の tools をレビュー専任に最適化（Write/Edit 除去）
  - `doc-updater` の model を `haiku` に変更（軽量化）
- **スキル frontmatter 修正**: `eval-harness`, `project-guidelines-example`, `verification-loop` に未設定だった YAML frontmatter を追加
- スキル: 14個 → 16個
- ルール: 9種 → 11種

## [0.11.0] - 2026-03-15

### Added
- **AGENTS.md 自動生成**: Claude Code 以外のエージェント（Codex CLI, Cursor, Copilot, Gemini CLI）でも使えるユニバーサルコンテキストファイルを全プロファイルで自動デプロイ
- **Doc Size Guard フック** (`doc-size-guard`): CLAUDE.md / AGENTS.md の行数超過を PostToolUse フックで自動警告・エラー化。壊れたパス参照も検出
  - AGENTS.md: 60行で警告、100行でエラー
  - CLAUDE.md: 150行で警告、300行でエラー
  - Standard / Full プロファイルでデフォルト有効
- **Doc Freshness Guard フック** (`doc-freshness-guard`): git commit 時にドキュメントの `last-validated` 日付をチェックし、古いドキュメントを警告・エラー化。superseded ADR への参照も検出
  - `DOC_FRESHNESS_WARN_DAYS`（デフォルト3日）/ `DOC_FRESHNESS_ERROR_DAYS`（デフォルト5日）で閾値カスタマイズ可能
  - macOS (BSD date) / Linux (GNU date) 両対応
  - Standard / Full プロファイルでデフォルト有効
- **Context Management スキル** (`context-management`): Context Rot 対策と FIC（Frequent Intentional Compaction）のガイダンス。フェーズ切替時の予防的 compact 推奨
- **Agent-Native Design スキル** (`agent-native-design`): AI エージェントが効率的に扱えるコード設計ガイドライン（grep-able 命名、collocated テスト、feature-based 構造等）
- **SDD Workflow スキル** (`sdd-workflow`): 仕様駆動開発（Spec-Driven Development）のワークフローガイダンス。Requirements → Design → Tasks → Implementation の4フェーズ
- **`/research` コマンド**: RPI ワークフローの Research フェーズをコマンド化。コードベースの深い調査を `research.md` に出力（Standard / Full）
- **`/parallel` コマンド**: Git Worktree を使った並列エージェント実行（Multi-Agent Division + Best-of-N 戦略）の支援（Full のみ）
- **`/handover` コマンド**: セッション引き継ぎ用の構造化ドキュメント `HANDOVER.md` を生成。Context Rot 対策（Standard / Full）
- **`/cross-review` コマンド**: Claude と Codex MCP のクロスモデルレビュー。Codex 未設定時はマルチパス自己レビューにフォールバック（Full のみ）
- **Anti-patterns ルール** (`anti-patterns.md`): エージェントの典型的失敗モード防止（幻覚ガード、スコープ逸脱防止、ループ検出、完了整合性チェック等）。全プロファイルで有効

### Changed
- スラッシュコマンド: 14個 → 18個
- フック: 11個 → 13個
- スキル: 11個 → 14個
- ルール: 8種 → 9種
- README（日本語・英語）を新機能数に合わせて更新

## [0.10.0] - 2026-03-11

### Added
- **Safety Net フック** (`safety-net`): [cc-safety-net](https://github.com/kenryu42/claude-code-safety-net) による破壊的コマンドの実行前ブロック
  - `git reset --hard`, `git checkout -- <file>`, `git push --force`, `rm -rf` 等の危険なコマンドを PreToolUse フックで自動検出・ブロック
  - `SAFETY_NET_STRICT=1` を env に設定し、パース不能コマンドも fail-closed（ブロック）にする
  - PreToolUse 配列の先頭に配置し、他のフックより先に実行
  - Standard / Full プロファイルでデフォルト有効
  - 前提条件: `npm install -g cc-safety-net` が別途必要
- **自動アップデート機能** (`auto-update`): SessionStart フックで GitHub の最新バージョンを自動チェック・適用
  - 24時間キャッシュで起動遅延を最小化（キャッシュ内は < 1ms で通過）
  - 新バージョン検出時はバックグラウンドで `git pull` + `setup.sh --update` を実行
  - 3-way merge によりユーザー設定を保持したまま更新
  - ワンライナーインストール（`~/.claude-starter-kit/`）の場合のみ動作
  - Standard / Full プロファイルでデフォルト有効（`ENABLE_AUTO_UPDATE=false` でオプトアウト可能）

## [0.9.0] - 2026-03-10

### Added
- **Update メカニズム**: `install.sh` 再実行時にユーザー設定を保持しつつ kit を更新する仕組み
  - Snapshot 比較方式: デプロイ時のファイルを `~/.claude/.starter-kit-snapshot/` に保存し、次回 update 時に3者比較（snapshot / current / new_kit）
  - `settings.json` の jq ベース3者マージ: 配列（permissions, hooks）はユーザー追加分を保持しつつ kit 新規エントリを追加。スカラー競合は対話的に解決
  - ファイル（agents, rules, skills 等）: ユーザー変更を検出し `[A]ppend / [S]kip / [D]iff` の対話 UI で選択
  - `--non-interactive` 時はユーザー変更ありのファイルをスキップ（安全側）
  - manifest v2 形式: `version`, `kit_version`, `snapshot_dir` フィールドを追加
  - `install.sh` が manifest v2 + snapshot を検出すると自動的に update モード（`setup.sh --update`）に切り替え
  - manifest v1 からの初回実行はフル再セットアップ + snapshot 作成（次回から update 対応）
- 新規ライブラリ: `lib/snapshot.sh`, `lib/merge.sh`, `lib/update.sh`
- i18n: `STR_UPDATE_*` 文字列（英語・日本語）

## [0.8.1] - 2026-03-10

### Fixed
- **permissions 構造バグ**: `deny` と `allowedTools` が `permissions` オブジェクトの外にトップレベルで出力されていた問題を修正（[公式スキーマ](https://json.schemastore.org/claude-code-settings.json) 準拠）
  - `deny` → `permissions.deny` にネスト
  - `allowedTools` → `permissions.allow` にリネーム＋ネスト
  - `settings-base.json` から空の `permissions: {}` を削除（マージ時の上書き防止）
  - Thanks to [@enpipi](https://github.com/enpipi) for reporting!
- **statusline ToS 準拠**: ステータスラインを Anthropic ToS 準拠版に差し替え

## [0.8.0] - 2026-03-07

### Changed
- **ステータスライン刷新**: 簡易スクリプトからリッチ版に置き換え
  - 3行表示: モデル名・コンテキスト%・diff統計・git branch・トークン数・バージョン情報・5h/7dレートリミットバー
  - Haiku probe によるレートリミット取得（360秒キャッシュ）
  - npm registry から最新バージョン取得（1時間キャッシュ）、current/latest 表示・差分時は黄色ハイライト
  - タイムゾーン自動検出（ハードコード `Asia/Tokyo` を廃止）
  - `stat` コマンドの macOS/Linux 両対応フォールバック

### Fixed
- **プラグイン marketplace 登録バグ**: `_compute_selected_plugins()` が非公式 marketplace のプラグインに `@marketplace` 修飾子を付けず、marketplace が登録されない問題を修正
- **pr-review-toolkit 重複**: `claude-plugins-official` と `claude-code-plugins` の両方に登録されていた重複エントリを解消（official 版に統一）

### Removed
- `claude-code-statusline` プラグイン（marketplace 構造に非準拠でインストール不可能だった。機能は features/statusline に統合）
- `claude-code-plugins` marketplace 定義（使用プラグインなし）

## [0.7.0] - 2026-03-06

### Added
- **セキュリティハードニング**: プロンプトインジェクション対策を permissions.json に組み込み
  - deny リストを 57 項目に大幅拡充（ネットワーク exfil、破壊的 git、クレデンシャルアクセス、RC 改ざん）
  - `python3 *` / `node *` / `curl *` / `wget *` / `cat *` を allowedTools から除外（都度確認に変更）
  - git サブコマンドを個別指定（`git:*` → `git status`, `git diff *` 等）
  - `disableBypassPermissionsMode: "disable"` で `--dangerously-skip-permissions` を無効化
  - `enableAllProjectMcpServers: false` でプロジェクト内 MCP サーバーの自動承認を無効化（CVE-2025-59536 対策）
- `rules/security.md` にプロンプトインジェクション防御ルール・疑わしいパターン検知ガイドを追加
- `CLAUDE.md` に Security Hardening セクション（設計判断・既知の限界）を追加
- claude-code-statusline プラグインを全プロファイルに追加
- `.gitignore` に `.env` セキュリティパターンを強化

## [0.6.0] - 2026-02-24

### Added
- **コンパクト前自動コミット機能** (`pre-compact-commit`): コンテキスト圧縮直前に `git add -A && git commit` を自動実行し、作業中の変更消失を防止
- `CLAUDE.md` にマージ改善・feature 追加手順の詳細を反映

## [0.5.0] - 2026-02-23

### Added
- **ステータスライン表示機能** (`statusline`): Claude Code のステータスバーにカスタム情報を表示

### Fixed
- 別ユーザー所有の Homebrew を検出して再インストールする処理を修正
- `uninstall.sh` の未使用 `STR_NO_MANIFEST` 変数を削除

## [0.4.0] - 2026-02-17

### Added
- **マルチマーケットプレイスプラグインサポート**: 同名プラグインが複数のマーケットプレイスに存在する場合、`name@marketplace` 形式で区別
- **非対話ワンライナーインストール**: `--non-interactive` フラグまたは `NONINTERACTIVE=1` 環境変数でウィザードをスキップ
- `CLAUDE.md` にワンライナー・Bash 3 互換・プラグイン追加手順を反映

### Fixed
- ワンライナー実行時の `_setup_args` 未束縛変数エラーを修正 (0.4.1, 2026-02-18)

## [0.3.0] - 2026-02-14

### Security
- **包括的セキュリティレビュー修正**:
  - API キーを `curl --config -` (stdin) 経由で渡すように変更（`ps` 出力への露出防止）
  - 設定ファイルの `source` を廃止し、`_safe_source_config()` による allowlist ベースのパーサーに変更
  - `umask 077` + temp ファイルの自動クリーンアップ (`trap`)
  - `_sanitize_config_value()` で設定値のメタ文字を除去
  - RC ファイル変更時のパーミッション保持 (`stat` + `chmod`)

## [0.2.0] - 2026-02-12

### Added
- **クロスプラットフォームフォントインストール** (`lib/fonts.sh`): IBM Plex Mono と HackGen NF を macOS / Windows に自動インストール
- **Windows Terminal フォント自動設定**: HackGen35 Console NF をデフォルトフォントに設定（バックアップ付き）
- **ShellCheck CI**: GitHub Actions で PR 時に自動実行
- **install.sh 安全ガード**: `_safe_install_dir()` で危険なパスへの `rm -rf` を防止
- Claude CLI の自動インストール機能
- WSL での Windows PATH 汚染による Claude CLI 誤検出を防止

### Fixed
- macOS で Xcode CLT 未インストール時に自動インストールして続行
- macOS で Homebrew 未インストール時に自動インストール
- macOS フォントインストールに直接ダウンロードのフォールバック追加
- Windows フォントインストールのハング防止
- Windows Terminal フォント設定が再実行時にスキップされる問題を修正

### Changed
- 未使用関数 6 個を削除（リファクタリング）

### Documentation
- README に Max 20x プラン推奨、`/init` による作業再開、`--resume` による前回セッション復元の How To を追加
- エディタの説明とインストール手順を README に追加
- `CLAUDE.md` にテンプレートエンジン・プラグインシステム・デプロイターゲットを追記

## [0.2.1] - 2026-02-13

### Fixed
- Ghostty インストール後の Gatekeeper 検疫ブロックを `xattr -d` で防止
- HackGen NF フォントインストール時の Homebrew PATH 解決漏れを修正
- Standard プロファイルで Ghostty セットアップを有効化
- Ghostty 誤検出を修正（`-d` → `-x` でバイナリ存在チェック）
- brew cask レジストリ残存時に Ghostty が実際にインストールされない問題を修正
- brew `node@20` の keg-only PATH 未解決でエラー表示される問題を修正

## [0.1.0] - 2026-02-11

### Added
- **初回リリース**: Claude Code Starter Kit
- **対話型ウィザード** (`wizard/wizard.sh`): 言語・プロファイル・エディタ・フック・プラグインを対話形式で選択
- **3 プロファイル**: Minimal / Standard / Full
- **9 エージェント**: planner, architect, tdd-guide, code-reviewer, security-reviewer, build-error-resolver, e2e-runner, refactor-cleaner, doc-updater
- **8 ルール**: coding-style, git-workflow, hooks, patterns, performance, security, testing, agents
- **14 スラッシュコマンド**: /plan, /tdd, /build-fix, /code-review, /e2e, /verify, /checkpoint 等
- **9 フック**: tmux リマインダー, git push レビュー, doc ブロッカー, prettier, console.log ガード, メモリ永続化, strategic compact, PR 作成ログ
- **プラグイン自動インストール**: `claude plugin install` による一括導入
- **Ghostty ターミナルセットアップ** (macOS): Homebrew cask インストール + HackGen NF フォント + Catppuccin Mocha テーマ
- **Codex MCP セットアップ**: OpenAI API キー検証 → codex login → MCP サーバー登録 → E2E 接続テスト
- **i18n**: 日本語 / English 完全対応
- **Windows サポート**: WSL2 + Windows Terminal（`install.ps1`）および Git Bash（`--git-bash`）
- **マニフェストベースのアンインストール**: デプロイしたファイルのみを安全に削除
- **Claude CLI 自動インストール**: ネイティブインストーラー経由で `~/.local/bin/claude` に導入
- **テンプレートエンジン** (`lib/template.sh`): `{{VAR}}` / `{{FEATURE:name}}` プレースホルダー置換
- **JSON ビルダー** (`lib/json-builder.sh`): settings-base.json + permissions.json + hook fragments の再帰的ディープマージ
- **OS 検出** (`lib/detect.sh`): macOS / Linux / WSL / MSYS の自動判別
- フック・プラグイン選択での全選択/全解除ショートカット (`a`/`n`)
- nvm フォールバック（Homebrew なしの Node.js インストール）
- `CLAUDE.md` をプロジェクトルートに追加

### Documentation
- README を日本語メインに書き換え、初心者向けに大幅改善
- 料金プラン・認証方法・デプロイ環境ガイド・Codex MCP 後付け手順を追記
- スクリーンショットの送り方・エディタのインストール手順を追記
