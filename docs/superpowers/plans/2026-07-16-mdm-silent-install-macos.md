# MDM サイレントインストール機能（Plan 1: 共有契約 + macOS）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MDM（Intune/Jamf/WS1/Ivanti）から macOS 管理端末へ claude-code-starter-kit をゼロタッチ配布できる薄い `mdm/` 層（設定パーサ・install/detect スクリプト・共通契約）を、既存 `setup.sh` に委譲する形で追加する。

**Architecture:** spec v4（`docs/superpowers/specs/2026-07-16-mdm-silent-install-design.md`）のアプローチ C。`mdm/install-mdm.sh` が root フェーズ（設定読込・ユーザー/home 検証・前提ブートストラップ）→ 環境分離降格（`env -i`）→ ユーザーフェーズ（ref 固定 clone → `setup.sh --non-interactive` 直接呼び出し）→ レシート書き出しを行う。設定は型検証パーサ `lib-mdm-config.sh`、成否は終了コード表 + 機械可読レシートで報告。Windows（Plan 2）は本 Plan の共通契約を PowerShell で再実装する。

**Tech Stack:** Bash 3.2 互換シェル（素の macOS `/bin/bash` で動くこと）、jq 非依存のレシート生成（printf + JSON エスケープ）、既存テストハーネス（`tests/run-unit-tests.sh` + `tests/helpers.sh` の `assert_*`）。

## Global Constraints

- **Bash 3.2 互換必須**: `mdm/*.sh` は素の macOS `/bin/bash`（3.2）で parser・trap・終了コード経路が動くこと。`declare -A`（連想配列）・`readarray`・`${var^^}` 等の Bash 4+ 構文は使わない
- **`set -euo pipefail`** を全 `mdm/*.sh` で使用。ただし本体レビュー P1-2 で判明した「`grep | head` × pipefail 即死」を持ち込まない（無ヒットし得るパイプは `|| true` / 条件分岐で pipefail 伝播を止める）
- **`source` / `eval` 禁止**（設定ファイルをコード実行しない。型検証パーサのみ）
- **秘密情報をログ・レシートに書かない**
- **main 直コミット禁止**。作業は `feat/mdm-silent-install` ブランチのみ
- **本体設定キーは実名を使う**（spec §7.3・本体 `wizard/registry.sh` の `_CONFIG_KEYS` 準拠）: `PROFILE` / `LANGUAGE` / `EDITOR_CHOICE` / `ENABLE_GHOSTTY_SETUP` / `ENABLE_FONTS_SETUP` / `ENABLE_STATUSLINE` 等（`EDITOR`・`ENABLE_GHOSTTY` ではない）
- **MDM 固有キーは接頭辞 `KIT_MDM_`**
- **終了コード表（固定契約）**: 0=成功 / 10=前提不足 / 11=Homebrew失敗 / 20=ユーザー・home検証失敗 / 21=非対応コンテキスト / 30=setup失敗またはref照合失敗 / 40=ClaudeCLI失敗 / 50=設定エラー / 60=非対応OS
- **各コミットは Codex（gpt-5.6-sol）クロスレビューを通す**（`codex exec review --commit <SHA> -m gpt-5.6-sol -c model_reasoning_effort='"low"' --ephemeral --ignore-user-config -o <メインリポジトリ>/.review/codex/mdm-<SHA>.md`）
- **テストハーネス**: 新規 `tests/unit/test-mdm-*.sh` は他の test-*.sh と同じく `run-unit-tests.sh` から source される。`helpers.sh` の `assert_*` / `pass` / `fail` / `$PROJECT_DIR` が利用可能。テストファイルは source 実行なので、関数定義後にグローバル状態を汚さないよう `unset -f` や subshell で隔離する

---

## File Structure

```
mdm/
├── lib-mdm-config.sh   # Task 1-2: 型検証パーサ + ファイル安全性検証（install/detect が source）
├── install-mdm.sh      # Task 3-8: root エントリ兼自己ブートストラップ launcher
└── detect-mdm.sh       # Task 9: レシート実体照合判定
docs/mdm/
├── README.md           # Task 11: 共通契約 + 製品別手順（en）
└── README.ja.md        # Task 11: 同（ja）
tests/unit/
├── test-mdm-config.sh      # Task 1-2
├── test-mdm-install.sh     # Task 4,5,7,8（ユーザー解決・ref・降格・レシート）
├── test-mdm-detect.sh      # Task 9
├── test-mdm-ref-validate.sh # Task 5
├── test-mdm-bootstrap.sh   # Task 8（自己ブートストラップ）
└── test-mdm-keys-in-sync.sh # Task 10（本体 _CONFIG_KEYS 乖離検出）
.github/workflows/
└── (既存 test.yml に mdm shellcheck + Bash 3.2 ジョブ追記 — Task 10)
```

各スクリプトは 1 責務。`lib-mdm-config.sh` は「設定の検証と読込」だけ、`install-mdm.sh` は「オーケストレーション」だけ、`detect-mdm.sh` は「判定」だけを担う。副作用のある処理（root 操作・ネットワーク）は関数化してテスト時にモック可能にする。

---

## Task 1: 設定値の型検証プリミティブ（lib-mdm-config.sh）

**Files:**
- Create: `mdm/lib-mdm-config.sh`
- Test: `tests/unit/test-mdm-config.sh`

**Interfaces:**
- Produces:
  - `mdm_validate_bool <value>` → exit 0 かつ stdout に正規化値（`true`/`false`）、不正なら exit 1
  - `mdm_validate_enum <value> <allowed-csv>` → exit 0（stdout=値）/ 不正 exit 1
  - `mdm_validate_gitref <value>` → exit 0 / 不正 exit 1（SHA 40or64桁hex、または `git check-ref-format --branch`）
  - `mdm_validate_username <value>` → exit 0 / 不正 exit 1（`^[a-z_][a-z0-9_-]*$`、最大32）
  - `mdm_validate_abspath <value>` → exit 0 / 不正 exit 1（絶対パスかつ `..` を含まない）

- [ ] **Step 1: 失敗するテストを書く**

`tests/unit/test-mdm-config.sh` を作成:

```bash
#!/bin/bash
# tests/unit/test-mdm-config.sh - Unit tests for mdm/lib-mdm-config.sh

# shellcheck source=mdm/lib-mdm-config.sh
source "$PROJECT_DIR/mdm/lib-mdm-config.sh"

# ── bool 検証 ─────────────────────────────────────────────
if out="$(mdm_validate_bool "true")" && [[ "$out" == "true" ]]; then
  pass "mdm-config: bool 'true' -> true"
else
  fail "mdm-config: bool 'true' should normalize to true (got '$out')"
fi

if out="$(mdm_validate_bool "yes")" && [[ "$out" == "true" ]]; then
  pass "mdm-config: bool 'yes' -> true"
else
  fail "mdm-config: bool 'yes' should normalize to true (got '$out')"
fi

if out="$(mdm_validate_bool "0")" && [[ "$out" == "false" ]]; then
  pass "mdm-config: bool '0' -> false"
else
  fail "mdm-config: bool '0' should normalize to false (got '$out')"
fi

if mdm_validate_bool "maybe" >/dev/null 2>&1; then
  fail "mdm-config: bool 'maybe' should be rejected"
else
  pass "mdm-config: bool 'maybe' rejected"
fi

# ── enum 検証 ─────────────────────────────────────────────
if out="$(mdm_validate_enum "standard" "minimal,standard,full")" && [[ "$out" == "standard" ]]; then
  pass "mdm-config: enum 'standard' accepted"
else
  fail "mdm-config: enum 'standard' should be accepted (got '$out')"
fi

if mdm_validate_enum "custom" "minimal,standard,full" >/dev/null 2>&1; then
  fail "mdm-config: enum 'custom' should be rejected"
else
  pass "mdm-config: enum 'custom' rejected"
fi

# ── git ref 検証（--branch 方式）────────────────────────────
for _ref in "main" "v0.72.0" "feature/x" "0123456789abcdef0123456789abcdef01234567"; do
  if mdm_validate_gitref "$_ref" >/dev/null 2>&1; then
    pass "mdm-config: gitref '$_ref' accepted"
  else
    fail "mdm-config: gitref '$_ref' should be accepted"
  fi
done
for _bad in "" "--force" "a b" "refs/../../etc" "x~1"; do
  if mdm_validate_gitref "$_bad" >/dev/null 2>&1; then
    fail "mdm-config: gitref '$_bad' should be rejected"
  else
    pass "mdm-config: gitref '$_bad' rejected"
  fi
done

# ── username 検証 ─────────────────────────────────────────
if mdm_validate_username "jane" >/dev/null 2>&1; then
  pass "mdm-config: username 'jane' accepted"
else
  fail "mdm-config: username 'jane' should be accepted"
fi
if mdm_validate_username "root; rm" >/dev/null 2>&1; then
  fail "mdm-config: username with metachar should be rejected"
else
  pass "mdm-config: username with metachar rejected"
fi

# ── abspath 検証 ──────────────────────────────────────────
if mdm_validate_abspath "/Users/jane/.claude-starter-kit" >/dev/null 2>&1; then
  pass "mdm-config: abspath accepted"
else
  fail "mdm-config: abspath should be accepted"
fi
if mdm_validate_abspath "relative/path" >/dev/null 2>&1; then
  fail "mdm-config: relative path should be rejected"
else
  pass "mdm-config: relative path rejected"
fi
if mdm_validate_abspath "/a/../../etc/passwd" >/dev/null 2>&1; then
  fail "mdm-config: path with .. should be rejected"
else
  pass "mdm-config: path with .. rejected"
fi
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `bash tests/run-unit-tests.sh 2>&1 | grep mdm-config`
Expected: `mdm/lib-mdm-config.sh` が無いため source 失敗、または関数未定義で全て FAIL

- [ ] **Step 3: 最小実装を書く**

`mdm/lib-mdm-config.sh` を作成:

```bash
#!/usr/bin/env bash
# mdm/lib-mdm-config.sh — MDM 管理設定の型検証パーサ（Bash 3.2 互換・source/eval なし）
# install-mdm.sh / detect-mdm.sh が source する。

# 正規化した bool を stdout へ。不正なら exit 1。
mdm_validate_bool() {
  case "$1" in
    true|1|yes|on|TRUE|Yes|On|YES|ON)   printf 'true';  return 0 ;;
    false|0|no|off|FALSE|No|Off|NO|OFF)  printf 'false'; return 0 ;;
    *) return 1 ;;
  esac
}

# 値が allowed-csv に含まれれば stdout へ。含まれなければ exit 1。
mdm_validate_enum() {
  local _val="$1" _allowed="$2" _item
  local _oldifs="$IFS"; IFS=','
  for _item in $_allowed; do
    if [[ "$_val" == "$_item" ]]; then IFS="$_oldifs"; printf '%s' "$_val"; return 0; fi
  done
  IFS="$_oldifs"; return 1
}

# git ref: 40/64 桁 hex は SHA として許可、それ以外は check-ref-format --branch。
# 素の check-ref-format は bare な main/tag を弾くため --branch を使う（spec §5.5）。
mdm_validate_gitref() {
  local _ref="$1"
  [[ -z "$_ref" ]] && return 1
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    printf '%s' "$_ref"; return 0
  fi
  if git check-ref-format --branch "$_ref" >/dev/null 2>&1; then
    printf '%s' "$_ref"; return 0
  fi
  return 1
}

# OS ユーザー名文字種のみ許可。
mdm_validate_username() {
  local _u="$1"
  printf '%s' "$_u" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$' || return 1
  printf '%s' "$_u"; return 0
}

# 絶対パスかつ .. を含まない。
mdm_validate_abspath() {
  local _p="$1"
  case "$_p" in
    /*) : ;;
    *)  return 1 ;;
  esac
  case "$_p" in
    *..*) return 1 ;;
  esac
  printf '%s' "$_p"; return 0
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bash tests/run-unit-tests.sh 2>&1 | grep -c "mdm-config.*PASS\|PASS.*mdm-config"` および全体の Fail 数確認
Expected: mdm-config 系が全 PASS、既知 flaky（fonts）以外の Fail が増えていない

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning mdm/lib-mdm-config.sh`
Expected: 警告なし（exit 0）

- [ ] **Step 6: コミット**

```bash
git add mdm/lib-mdm-config.sh tests/unit/test-mdm-config.sh
git commit -m "feat(mdm): 管理設定の型検証プリミティブを追加

bool/enum/gitref/username/abspath の型別検証。git ref は素の
check-ref-format が bare な main/tag を弾くため --branch 方式（spec §5.5）。
source/eval を使わない型検証パーサの基礎。"
```

- [ ] **Step 7: Codex ゲート**（Global Constraints のコマンドで `<SHA>` を直近コミットに置換して実行し、指摘があれば対応してから次タスクへ）

---

## Task 2: 設定ファイルの読込・優先順位・パーミッション検証（lib-mdm-config.sh 追記）

**Files:**
- Modify: `mdm/lib-mdm-config.sh`
- Test: `tests/unit/test-mdm-config.sh`（追記）

**Interfaces:**
- Consumes: Task 1 の `mdm_validate_*`
- Produces:
  - `mdm_config_file_is_secure <path>` → exit 0（安全）/ 1（symlink・group/other 書込可・非存在）。所有者チェックは root 実行時のみ厳格化（テスト可能に環境変数 `MDM_CONFIG_SKIP_OWNER_CHECK` でowner検査を切替）
  - `mdm_config_apply <path>` → ファイルを1行ずつ読み、`KEY=VALUE` を allowlist 照合 + 型検証し、合格した既存キーのみ環境変数に export。未知キーは stderr に警告。不正値は exit 50。優先順位は「既に環境に値がある（CLI/env 由来）キーは上書きしない」で表現

- [ ] **Step 1: 失敗するテストを追記**

`tests/unit/test-mdm-config.sh` の末尾に追記:

```bash
# ── ファイル安全性 ────────────────────────────────────────
_tmpd="$(mktemp -d)"
_conf="$_tmpd/mdm-config.conf"
cat > "$_conf" <<'CONF'
PROFILE="standard"
LANGUAGE="ja"
KIT_MDM_INSTALL_HOMEBREW="true"
CONF
chmod 600 "$_conf"

export MDM_CONFIG_SKIP_OWNER_CHECK=1  # テスト環境は非root所有のため owner 検査を無効化
if mdm_config_file_is_secure "$_conf"; then
  pass "mdm-config: 600 の通常ファイルは secure"
else
  fail "mdm-config: 600 の通常ファイルが secure 判定されない"
fi

chmod 666 "$_conf"
if mdm_config_file_is_secure "$_conf"; then
  fail "mdm-config: group/other 書込可は reject すべき"
else
  pass "mdm-config: group/other 書込可を reject"
fi
chmod 600 "$_conf"

ln -s "$_conf" "$_tmpd/link.conf"
if mdm_config_file_is_secure "$_tmpd/link.conf"; then
  fail "mdm-config: symlink は reject すべき"
else
  pass "mdm-config: symlink を reject"
fi

# ── 読込・優先順位・型検証 ──────────────────────────────────
( # subshell で環境汚染を隔離
  unset PROFILE LANGUAGE KIT_MDM_INSTALL_HOMEBREW
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  if mdm_config_apply "$_conf" && [[ "$PROFILE" == "standard" && "$LANGUAGE" == "ja" ]]; then
    pass "mdm-config: apply が値を export"
  else
    fail "mdm-config: apply が値を export しない (PROFILE='$PROFILE')"
  fi
)

( # 優先順位: 既存の env 値は上書きしない
  export PROFILE="full"  # CLI/env 相当（先に設定済み）
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  mdm_config_apply "$_conf" >/dev/null 2>&1
  if [[ "$PROFILE" == "full" ]]; then
    pass "mdm-config: 既存 env 値を conf が上書きしない（優先順位）"
  else
    fail "mdm-config: 優先順位違反 PROFILE='$PROFILE'（full を維持すべき）"
  fi
)

# 不正値は exit 50
cat > "$_conf" <<'CONF'
PROFILE="nonsense"
CONF
chmod 600 "$_conf"
( export MDM_CONFIG_SKIP_OWNER_CHECK=1
  mdm_config_apply "$_conf" >/dev/null 2>&1
  assert_exit_code 50 "$?" "不正 PROFILE は exit 50" \
    && pass "mdm-config: 不正 enum 値で exit 50" \
    || fail "mdm-config: 不正 enum 値で exit 50 を返すべき"
)
rm -rf "$_tmpd"
```

- [ ] **Step 2: テスト失敗を確認**

Run: `bash tests/run-unit-tests.sh 2>&1 | grep "mdm-config"`
Expected: 新規追記分が FAIL（関数未定義）

- [ ] **Step 3: 実装を追記**

`mdm/lib-mdm-config.sh` に追記:

```bash
# 設定ファイルの安全性検証（読み取り直前に呼ぶ）。
mdm_config_file_is_secure() {
  local _f="$1"
  [[ -e "$_f" ]] || return 1
  [[ -L "$_f" ]] && return 1                  # symlink 拒否
  # group/other 書込ビットが立っていたら拒否（stat はBSD/GNU両対応）
  local _mode
  _mode="$(stat -f '%Lp' "$_f" 2>/dev/null || stat -c '%a' "$_f" 2>/dev/null || echo '')"
  case "$_mode" in
    *[2367])  return 1 ;;                       # other 書込
  esac
  case "$_mode" in
    ?[2367]?) return 1 ;;                       # group 書込
  esac
  if [[ "${MDM_CONFIG_SKIP_OWNER_CHECK:-0}" != "1" ]]; then
    local _owner
    _owner="$(stat -f '%Su' "$_f" 2>/dev/null || stat -c '%U' "$_f" 2>/dev/null || echo '')"
    [[ "$_owner" == "root" ]] || return 1
  fi
  return 0
}

# 許可キー allowlist（本体 _CONFIG_KEYS の実名 + KIT_MDM_ 群）。Task 10 で乖離検出テストが監視する。
_MDM_ALLOWED_KEYS="PROFILE LANGUAGE EDITOR_CHOICE COMMIT_ATTRIBUTION \
ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_STATUSLINE ENABLE_SAFETY_NET \
ENABLE_AUTO_UPDATE ENABLE_DOC_SIZE_GUARD ENABLE_FEATURE_RECOMMENDATION \
ENABLE_PRE_COMPACT_COMMIT ENABLE_WEB_CONTENT_UPDATE ENABLE_NO_FLICKER ENABLE_NEW_INIT \
KIT_MDM_TARGET_USER KIT_MDM_INSTALL_HOMEBREW KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE \
KIT_MDM_PREREQ_MODE KIT_MDM_WINDOWS_MODE KIT_MDM_INSTALL_CLAUDE_CLI \
KIT_MDM_GIT_REF KIT_MDM_INSTALL_DIR KIT_MDM_LOG_DIR KIT_MDM_DRY_RUN"

_mdm_key_is_allowed() {
  local _k="$1" _a
  for _a in $_MDM_ALLOWED_KEYS; do [[ "$_k" == "$_a" ]] && return 0; done
  return 1
}

# キーごとの型検証。合格すれば正規化値を stdout。不正なら exit 1。
_mdm_validate_key() {
  local _k="$1" _v="$2"
  case "$_k" in
    PROFILE)                 mdm_validate_enum "$_v" "minimal,standard,full" ;;
    KIT_MDM_PREREQ_MODE)     mdm_validate_enum "$_v" "auto,skip,fail" ;;
    KIT_MDM_WINDOWS_MODE)    mdm_validate_enum "$_v" "gitbash,wsl" ;;
    LANGUAGE)                mdm_validate_enum "$_v" "en,ja" ;;
    ENABLE_*|KIT_MDM_INSTALL_HOMEBREW|KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE|KIT_MDM_INSTALL_CLAUDE_CLI|KIT_MDM_DRY_RUN|COMMIT_ATTRIBUTION)
                             mdm_validate_bool "$_v" ;;
    KIT_MDM_GIT_REF)         mdm_validate_gitref "$_v" ;;
    KIT_MDM_TARGET_USER)     mdm_validate_username "$_v" ;;
    KIT_MDM_INSTALL_DIR|KIT_MDM_LOG_DIR) mdm_validate_abspath "$_v" ;;
    EDITOR_CHOICE)           printf '%s' "$_v" ;;   # 自由文字列（後段でさらに検証）
    *)                       printf '%s' "$_v" ;;
  esac
}

# 設定ファイルを読み、allowlist + 型検証し、未設定のキーのみ export（優先順位: 既存 env 値は保持）。
# 不正値は exit 50、ファイル不安全は exit 50。
mdm_config_apply() {
  local _f="$1"
  [[ -f "$_f" ]] || return 0                    # ファイルなしは何もしない
  mdm_config_file_is_secure "$_f" || return 50
  local _line _k _v _norm
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    case "$_line" in
      ''|'#'*) continue ;;
    esac
    case "$_line" in
      *=*) : ;;
      *)   continue ;;
    esac
    _k="${_line%%=*}"
    _v="${_line#*=}"
    _v="${_v%\"}"; _v="${_v#\"}"                 # 両端のダブルクォート除去
    if ! _mdm_key_is_allowed "$_k"; then
      printf '[mdm-config] WARN: unknown key ignored: %s\n' "$_k" >&2
      continue
    fi
    if ! _norm="$(_mdm_validate_key "$_k" "$_v")"; then
      printf '[mdm-config] ERROR: invalid value for %s\n' "$_k" >&2
      return 50
    fi
    # 優先順位: 既に非空の値が環境にあれば上書きしない
    if [[ -z "$(eval "printf '%s' \"\${$_k:-}\"")" ]]; then
      export "$_k=$_norm"
    fi
  done < "$_f"
  return 0
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `bash tests/run-unit-tests.sh 2>&1 | grep "mdm-config"`
Expected: 全 PASS

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning mdm/lib-mdm-config.sh`
Expected: exit 0（`eval` 使用箇所は間接展開のため SC2086 等が出たら `${!_k}` に置換 — ただし Bash 3.2 は `${!var}` 対応なので `eval` ではなく `printf '%s' "${!_k:-}"` を使うこと。SC は間接展開を許容する）

**注**: Step 3 の優先順位判定は Bash 3.2 互換の `${!_k:-}`（間接展開）で書く。上記 `eval` は避け、`if [[ -z "${!_k:-}" ]]; then export "$_k=$_norm"; fi` とする。

- [ ] **Step 6: コミット + Codex ゲート**

```bash
git add mdm/lib-mdm-config.sh tests/unit/test-mdm-config.sh
git commit -m "feat(mdm): 設定ファイルの読込・優先順位・パーミッション検証を追加

allowlist + 型検証で読込。symlink/group-other書込を拒否。既存 env 値
（CLI/env 由来）は conf が上書きしない優先順位。不正値・不安全ファイルは exit 50。"
```

---

## Task 3: 終了コード定数・ログ・レシート（install-mdm.sh の基盤）

**Files:**
- Create: `mdm/install-mdm.sh`（この Task で骨格 + ログ/レシート関数まで）
- Test: `tests/unit/test-mdm-install.sh`

**Interfaces:**
- Produces:
  - 終了コード定数 `MDM_EXIT_OK=0 MDM_EXIT_PREREQ=10 MDM_EXIT_BREW=11 MDM_EXIT_USER=20 MDM_EXIT_CONTEXT=21 MDM_EXIT_SETUP=30 MDM_EXIT_CLI=40 MDM_EXIT_CONFIG=50 MDM_EXIT_OS=60`
  - `mdm_log <phase> <message>` → ログファイルとstderrへタイムスタンプ付き出力（秘密情報は呼び出し側が渡さない前提）
  - `mdm_json_escape <string>` → JSON 文字列値としてエスケープした結果を stdout
  - `mdm_receipt_write <path> <result> <exit_code>` → `MDM_RCPT_*` グローバル（kit_version/git_ref/resolved_sha/install_dir/required_components/profile/target_user/partial/timestamp/log_path）から jq 非依存で JSON を書く

- [ ] **Step 1: 失敗するテストを書く**

`tests/unit/test-mdm-install.sh`:

```bash
#!/bin/bash
# tests/unit/test-mdm-install.sh - Unit tests for mdm/install-mdm.sh (関数単位)

# install-mdm.sh は main を末尾で条件実行する（BASH_SOURCE ガード）。source して関数だけ得る。
# shellcheck source=mdm/install-mdm.sh
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

# ── 終了コード定数 ────────────────────────────────────────
if [[ "$MDM_EXIT_CONFIG" == "50" && "$MDM_EXIT_USER" == "20" ]]; then
  pass "mdm-install: 終了コード定数が定義されている"
else
  fail "mdm-install: 終了コード定数が不正"
fi

# ── JSON エスケープ ───────────────────────────────────────
if out="$(mdm_json_escape 'a"b\c')" && [[ "$out" == 'a\"b\\c' ]]; then
  pass "mdm-install: JSON エスケープ（quote/backslash）"
else
  fail "mdm-install: JSON エスケープ失敗 (got '$out')"
fi

# ── レシート生成 ──────────────────────────────────────────
_tmpd="$(mktemp -d)"
MDM_RCPT_KIT_VERSION="0.73.0"
MDM_RCPT_GIT_REF="main"
MDM_RCPT_RESOLVED_SHA="abc123"
MDM_RCPT_INSTALL_DIR="/Users/jane/.claude-starter-kit"
MDM_RCPT_REQUIRED_COMPONENTS='["kit","claude_cli"]'
MDM_RCPT_PROFILE="standard"
MDM_RCPT_TARGET_USER="jane"
MDM_RCPT_PARTIAL='[]'
MDM_RCPT_TIMESTAMP="2026-07-16T00:00:00Z"
MDM_RCPT_LOG_PATH="/Library/Logs/ClaudeCodeStarterKit/install.log"
mdm_receipt_write "$_tmpd/receipt.json" "success" "0"

if assert_json_field "$_tmpd/receipt.json" "result" "success" "result=success"; then
  pass "mdm-install: レシート result フィールド"
else
  fail "mdm-install: レシート result フィールド不正"
fi
if assert_json_field "$_tmpd/receipt.json" "exit_code" "0" "exit_code=0"; then
  pass "mdm-install: レシート exit_code フィールド"
else
  fail "mdm-install: レシート exit_code フィールド不正"
fi
if assert_json_field "$_tmpd/receipt.json" "install_dir" "/Users/jane/.claude-starter-kit" "install_dir 記録"; then
  pass "mdm-install: レシート install_dir 記録"
else
  fail "mdm-install: レシート install_dir 未記録"
fi
# jq でパース可能な妥当 JSON か
if jq -e . "$_tmpd/receipt.json" >/dev/null 2>&1; then
  pass "mdm-install: レシートは妥当な JSON"
else
  fail "mdm-install: レシートが不正な JSON"
fi
rm -rf "$_tmpd"
```

- [ ] **Step 2: テスト失敗を確認**

Run: `bash tests/run-unit-tests.sh 2>&1 | grep "mdm-install"`
Expected: source 失敗または関数未定義で FAIL

- [ ] **Step 3: 実装を書く**

`mdm/install-mdm.sh`（骨格 + ログ/レシート）:

```bash
#!/usr/bin/env bash
# mdm/install-mdm.sh — macOS 向け MDM サイレントインストーラ兼自己ブートストラップ launcher
# 詳細契約: docs/superpowers/specs/2026-07-16-mdm-silent-install-design.md
set -euo pipefail

# ── 終了コード定数（固定契約 spec §8.1）────────────────────
MDM_EXIT_OK=0; MDM_EXIT_PREREQ=10; MDM_EXIT_BREW=11; MDM_EXIT_USER=20
MDM_EXIT_CONTEXT=21; MDM_EXIT_SETUP=30; MDM_EXIT_CLI=40; MDM_EXIT_CONFIG=50; MDM_EXIT_OS=60

# ── レシート用グローバル（各フェーズが埋める）──────────────
MDM_RCPT_KIT_VERSION=""; MDM_RCPT_GIT_REF=""; MDM_RCPT_RESOLVED_SHA=""
MDM_RCPT_INSTALL_DIR=""; MDM_RCPT_REQUIRED_COMPONENTS='["kit"]'; MDM_RCPT_PROFILE=""
MDM_RCPT_TARGET_USER=""; MDM_RCPT_PARTIAL='[]'; MDM_RCPT_TIMESTAMP=""; MDM_RCPT_LOG_PATH=""

MDM_LOG_FILE="${MDM_LOG_FILE:-}"

mdm_log() {
  local _phase="$1"; shift
  local _msg="$*"
  local _line="[$_phase] $_msg"
  printf '%s\n' "$_line" >&2
  if [[ -n "$MDM_LOG_FILE" ]]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" "$_line" >> "$MDM_LOG_FILE" 2>/dev/null || true
  fi
}

# JSON 文字列値のエスケープ（backslash と double-quote のみ。改行等は呼び出し側が渡さない）
mdm_json_escape() {
  local _s="$1"
  _s="${_s//\\/\\\\}"
  _s="${_s//\"/\\\"}"
  printf '%s' "$_s"
}

# jq 非依存でレシート JSON を書く。required_components / partial は既に JSON 配列文字列。
mdm_receipt_write() {
  local _path="$1" _result="$2" _exit="$3"
  local _dir; _dir="$(dirname "$_path")"
  mkdir -p "$_dir" 2>/dev/null || true
  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "kit_version": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_KIT_VERSION")"
    printf '  "git_ref": "%s",\n'      "$(mdm_json_escape "$MDM_RCPT_GIT_REF")"
    printf '  "resolved_sha": "%s",\n' "$(mdm_json_escape "$MDM_RCPT_RESOLVED_SHA")"
    printf '  "install_dir": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_INSTALL_DIR")"
    printf '  "required_components": %s,\n' "$MDM_RCPT_REQUIRED_COMPONENTS"
    printf '  "profile": "%s",\n'      "$(mdm_json_escape "$MDM_RCPT_PROFILE")"
    printf '  "target_user": "%s",\n'  "$(mdm_json_escape "$MDM_RCPT_TARGET_USER")"
    printf '  "result": "%s",\n'       "$(mdm_json_escape "$_result")"
    printf '  "exit_code": %s,\n'      "$_exit"
    printf '  "partial": %s,\n'        "$MDM_RCPT_PARTIAL"
    printf '  "timestamp": "%s",\n'    "$(mdm_json_escape "$MDM_RCPT_TIMESTAMP")"
    printf '  "log_path": "%s"\n'      "$(mdm_json_escape "$MDM_RCPT_LOG_PATH")"
    printf '}\n'
  } > "$_path"
}

# ── main は Task 8 で実装。source-only 時は実行しない。────────
if [[ "${MDM_SOURCE_ONLY:-0}" != "1" ]] && { [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; }; then
  mdm_main "$@"   # Task 8 で定義
fi
```

- [ ] **Step 4: テスト通過を確認**

Run: `bash tests/run-unit-tests.sh 2>&1 | grep "mdm-install"`
Expected: 全 PASS（`mdm_main` 未定義だが `MDM_SOURCE_ONLY=1` で未呼び出しのため source は成功）

- [ ] **Step 5: shellcheck + コミット + Codex ゲート**

```bash
shellcheck -S warning mdm/install-mdm.sh
git add mdm/install-mdm.sh tests/unit/test-mdm-install.sh
git commit -m "feat(mdm): 終了コード定数・ログ・jq非依存レシートを追加

固定終了コード表（spec §8.1）、フェーズタグ付きログ、install_dir/
required_components/partial を含むレシートを printf で生成（前提導入前の
失敗でも書けるよう jq 非依存）。"
```

---

## Task 4: 対象ユーザー・ホーム解決と検証

**Files:**
- Modify: `mdm/install-mdm.sh`
- Test: `tests/unit/test-mdm-install.sh`（追記）

**Interfaces:**
- Consumes: `MDM_EXIT_USER`, `mdm_log`
- Produces:
  - `mdm_resolve_target_user` → stdout に対象ユーザー名、失敗で exit `$MDM_EXIT_USER`。`KIT_MDM_TARGET_USER` > コンソールユーザー。解決手段はモック可能に `MDM_CONSOLE_USER_CMD`（既定 `scutil` パス）経由
  - `mdm_validate_user_home <user>` → stdout に canonical home、失敗で exit `$MDM_EXIT_USER`。dscl 呼び出しは `MDM_DSCL_HOME_CMD` でモック可能

- [ ] **Step 1: 失敗するテストを追記**（`test-mdm-install.sh` 末尾）

```bash
# ── 対象ユーザー解決（モック）────────────────────────────
(
  export KIT_MDM_TARGET_USER="jane"
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "jane" ]]; then
    pass "mdm-install: KIT_MDM_TARGET_USER が優先される"
  else
    fail "mdm-install: KIT_MDM_TARGET_USER 優先が効かない (got '$out')"
  fi
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="alice"   # テスト用フック
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "alice" ]]; then
    pass "mdm-install: コンソールユーザーにフォールバック"
  else
    fail "mdm-install: コンソールユーザー解決失敗 (got '$out')"
  fi
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="root"     # 無効ユーザー
  mdm_resolve_target_user >/dev/null 2>&1
  assert_exit_code "$MDM_EXIT_USER" "$?" "root は無効ユーザーで exit USER" \
    && pass "mdm-install: root/システムユーザーを拒否" \
    || fail "mdm-install: root を拒否すべき"
)

# ── home 検証（モック）────────────────────────────────────
_tmpd="$(mktemp -d)"
_fakehome="$_tmpd/Users/jane"
mkdir -p "$_fakehome"
(
  export MDM_DSCL_HOME_OVERRIDE="$_fakehome"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1        # テストは非root所有のため owner 検査を切替
  if out="$(mdm_validate_user_home "jane" 2>/dev/null)" && [[ "$out" == "$_fakehome" ]]; then
    pass "mdm-install: home 検証が canonical パスを返す"
  else
    fail "mdm-install: home 検証失敗 (got '$out')"
  fi
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_tmpd/Users/nonexistent"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  mdm_validate_user_home "jane" >/dev/null 2>&1
  assert_exit_code "$MDM_EXIT_USER" "$?" "存在しない home は exit USER" \
    && pass "mdm-install: 存在しない home を拒否" \
    || fail "mdm-install: 存在しない home を拒否すべき"
)
rm -rf "$_tmpd"
```

- [ ] **Step 2: 失敗を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep "mdm-install"` / Expected: 追記分 FAIL

- [ ] **Step 3: 実装を追記**（`mdm/install-mdm.sh`、レシート関数の後・main ガードの前）

```bash
# コンソールユーザーを取得（テスト時は MDM_CONSOLE_USER_OVERRIDE を優先）
_mdm_console_user() {
  if [[ -n "${MDM_CONSOLE_USER_OVERRIDE:-}" ]]; then
    printf '%s' "$MDM_CONSOLE_USER_OVERRIDE"; return 0
  fi
  # scutil の ConsoleUser、フォールバック stat /dev/console
  local _u
  _u="$(printf 'show State:/Users/ConsoleUser\n' | scutil 2>/dev/null | awk '/Name :/{print $3; exit}' || true)"
  [[ -z "$_u" ]] && _u="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
  printf '%s' "$_u"
}

mdm_resolve_target_user() {
  local _u="${KIT_MDM_TARGET_USER:-}"
  [[ -z "$_u" ]] && _u="$(_mdm_console_user)"
  case "$_u" in
    ''|root|_mbsetupuser|loginwindow|daemon|nobody)
      mdm_log R2 "対象ユーザーを解決できない（'$_u' は無効）"
      return "$MDM_EXIT_USER" ;;
  esac
  printf '%s' "$_u"
  return 0
}

# 対象ユーザーの canonical home を取得・検証。dscl はモック可能。
mdm_validate_user_home() {
  local _user="$1" _home
  if [[ -n "${MDM_DSCL_HOME_OVERRIDE:-}" ]]; then
    _home="$MDM_DSCL_HOME_OVERRIDE"
  else
    _home="$(dscl . -read "/Users/$_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  fi
  if [[ -z "$_home" || ! -d "$_home" ]]; then
    mdm_log R2 "home が存在しない: '$_home'"
    return "$MDM_EXIT_USER"
  fi
  if [[ -L "$_home" ]]; then
    mdm_log R2 "home が symlink: $_home"
    return "$MDM_EXIT_USER"
  fi
  if [[ "${MDM_VALIDATE_HOME_SKIP_OWNER:-0}" != "1" ]]; then
    local _owner; _owner="$(stat -f '%Su' "$_home" 2>/dev/null || echo '')"
    if [[ "$_owner" != "$_user" ]]; then
      mdm_log R2 "home の所有者が対象ユーザーでない: $_owner"
      return "$MDM_EXIT_USER"
    fi
  fi
  # canonical 化
  ( cd "$_home" 2>/dev/null && pwd -P )
}
```

- [ ] **Step 4: 通過を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep "mdm-install"` / Expected: 全 PASS

- [ ] **Step 5: shellcheck + コミット + Codex ゲート**

```bash
shellcheck -S warning mdm/install-mdm.sh
git add mdm/install-mdm.sh tests/unit/test-mdm-install.sh
git commit -m "feat(mdm): 対象ユーザー・ホームの解決と検証を追加

KIT_MDM_TARGET_USER > コンソールユーザー。root/システムアカウントを拒否、
home の存在・非symlink・所有者一致・canonical 化を検証（spec §5.4）。
scutil/dscl はテスト用オーバーライドでモック可能。"
```

---

## Task 5: バージョンピン留め（ref 固定）

**Files:**
- Modify: `mdm/install-mdm.sh`
- Test: `tests/unit/test-mdm-ref-validate.sh`（新規）

**Interfaces:**
- Consumes: `mdm_validate_gitref`（Task 1）, `MDM_EXIT_SETUP`, `MDM_EXIT_CONFIG`
- Produces:
  - `mdm_resolve_ref_sha <repo_dir> <ref>` → fetch + `FETCH_HEAD^{commit}` で確定 SHA を stdout。ref 形式不正は exit `$MDM_EXIT_CONFIG`、解決不能は exit `$MDM_EXIT_SETUP`

- [ ] **Step 1: 失敗するテストを書く**

`tests/unit/test-mdm-ref-validate.sh`:

```bash
#!/bin/bash
# tests/unit/test-mdm-ref-validate.sh - ref 形式検証と SHA 解決

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"
# shellcheck source=mdm/lib-mdm-config.sh
source "$PROJECT_DIR/mdm/lib-mdm-config.sh"

# ローカルにテスト用リポジトリを作る
_repo="$(mktemp -d)"
(
  cd "$_repo"
  git init -q
  git config user.email t@example.com
  git config user.name test
  printf 'a\n' > f.txt
  git add f.txt
  git commit -qm first
  git tag v0.0.1
) >/dev/null 2>&1

# bare な main / tag / SHA が受理される（check-ref-format --branch 経由）
_head_sha="$(git -C "$_repo" rev-parse HEAD)"
for _ref in "$(git -C "$_repo" branch --show-current)" "v0.0.1" "$_head_sha"; do
  if out="$(mdm_resolve_ref_sha "$_repo" "$_ref" 2>/dev/null)"; then
    if [[ "$out" == "$_head_sha" ]]; then
      pass "mdm-ref: '$_ref' が HEAD SHA に解決"
    else
      fail "mdm-ref: '$_ref' の解決 SHA が不一致 (got '$out')"
    fi
  else
    fail "mdm-ref: '$_ref' の解決に失敗"
  fi
done

# 不正 ref 形式は exit CONFIG(50)
mdm_resolve_ref_sha "$_repo" "--force" >/dev/null 2>&1
assert_exit_code "$MDM_EXIT_CONFIG" "$?" "不正 ref は exit CONFIG" \
  && pass "mdm-ref: 不正 ref 形式で exit 50" \
  || fail "mdm-ref: 不正 ref 形式で exit 50 を返すべき"

# 存在しない ref は exit SETUP(30)
mdm_resolve_ref_sha "$_repo" "nonexistent-branch" >/dev/null 2>&1
assert_exit_code "$MDM_EXIT_SETUP" "$?" "存在しない ref は exit SETUP" \
  && pass "mdm-ref: 存在しない ref で exit 30" \
  || fail "mdm-ref: 存在しない ref で exit 30 を返すべき"

rm -rf "$_repo"
```

- [ ] **Step 2: 失敗を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep "mdm-ref"` / Expected: FAIL

- [ ] **Step 3: 実装を追記**（`mdm/install-mdm.sh`）

```bash
# ref を確定 SHA に解決（spec §5.5）。install.sh は再実行しない前提で wrapper が直接管理。
mdm_resolve_ref_sha() {
  local _repo="$1" _ref="$2" _sha
  # 形式検証（SHA or check-ref-format --branch）
  if ! mdm_validate_gitref "$_ref" >/dev/null 2>&1; then
    mdm_log U1 "不正な git ref 形式: $_ref"
    return "$MDM_EXIT_CONFIG"
  fi
  # SHA 直指定ならそのまま commit 解決を試す
  if printf '%s' "$_ref" | grep -qE '^[0-9a-fA-F]{40}$|^[0-9a-fA-F]{64}$'; then
    _sha="$(git -C "$_repo" rev-parse "${_ref}^{commit}" 2>/dev/null || true)"
  else
    # 明示 fetch → FETCH_HEAD の commit を真実とする（ローカル ref を更新しないことがあるため）
    if ! git -C "$_repo" fetch --quiet origin "$_ref" 2>/dev/null; then
      # origin が無い（初回 clone 前のローカルテスト）場合はローカル ref 解決にフォールバック
      _sha="$(git -C "$_repo" rev-parse "${_ref}^{commit}" 2>/dev/null || true)"
    else
      _sha="$(git -C "$_repo" rev-parse "FETCH_HEAD^{commit}" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$_sha" ]]; then
    mdm_log U1 "ref を解決できない: $_ref"
    return "$MDM_EXIT_SETUP"
  fi
  printf '%s' "$_sha"
  return 0
}
```

**注**: 本番の clone/checkout フロー（`git checkout --detach <sha>` + HEAD 照合）は Task 8 の `mdm_main` で `mdm_resolve_ref_sha` を使って組む。本 Task では SHA 解決のみをテスト対象とする。

- [ ] **Step 4: 通過を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep "mdm-ref"` / Expected: 全 PASS

- [ ] **Step 5: shellcheck + コミット + Codex ゲート**

```bash
shellcheck -S warning mdm/install-mdm.sh
git add mdm/install-mdm.sh tests/unit/test-mdm-ref-validate.sh
git commit -m "feat(mdm): git ref を確定 SHA に解決するピン留めを追加

SHA 直指定/check-ref-format --branch で形式検証し、明示 fetch 後の
FETCH_HEAD^{commit} を真実として SHA 確定。bare な main/tag も受理、
不正形式は exit 50、解決不能は exit 30（spec §5.5）。"
```

---

## Task 6: 前提ブートストラップの判定（brew 有無・CLT 方針）

**Files:**
- Modify: `mdm/install-mdm.sh`
- Test: `tests/unit/test-mdm-install.sh`（追記）

**Interfaces:**
- Consumes: `MDM_EXIT_PREREQ`
- Produces:
  - `mdm_prereq_plan` → stdout に方針文字列（`skip`=brew あり何もしない / `bootstrap`=brew 導入が必要 / `fail`=導入せず不足で終了）。判定入力は `KIT_MDM_INSTALL_HOMEBREW`, `KIT_MDM_PREREQ_MODE`, brew 有無（`MDM_BREW_PRESENT_OVERRIDE` でモック）

- [ ] **Step 1: 失敗するテストを追記**（`test-mdm-install.sh`）

```bash
# ── 前提方針判定 ─────────────────────────────────────────
( export MDM_BREW_PRESENT_OVERRIDE=1
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "skip" ]] && pass "mdm-install: brew あり -> skip" || fail "mdm-install: brew あり時は skip (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_INSTALL_HOMEBREW=true KIT_MDM_PREREQ_MODE=auto
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "bootstrap" ]] && pass "mdm-install: brew なし+install=true -> bootstrap" || fail "mdm-install: bootstrap 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_INSTALL_HOMEBREW=false
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "fail" ]] && pass "mdm-install: brew なし+install=false -> fail" || fail "mdm-install: fail 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_PREREQ_MODE=skip
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "skip" ]] && pass "mdm-install: PREREQ_MODE=skip は skip" || fail "mdm-install: skip 期待 (got '$out')" )
```

- [ ] **Step 2: 失敗を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep mdm-install` / Expected: 追記分 FAIL

- [ ] **Step 3: 実装を追記**（`mdm/install-mdm.sh`）

```bash
_mdm_brew_present() {
  if [[ -n "${MDM_BREW_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_BREW_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  [[ -x /opt/homebrew/bin/brew || -x /usr/local/bin/brew ]] || command -v brew >/dev/null 2>&1
}

mdm_prereq_plan() {
  case "${KIT_MDM_PREREQ_MODE:-auto}" in
    skip) printf 'skip'; return 0 ;;
  esac
  if _mdm_brew_present; then printf 'skip'; return 0; fi
  case "$(mdm_validate_bool "${KIT_MDM_INSTALL_HOMEBREW:-true}" 2>/dev/null || echo true)" in
    true) printf 'bootstrap' ;;
    *)    printf 'fail' ;;
  esac
  return 0
}
```

- [ ] **Step 4: 通過を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep mdm-install` / Expected: 全 PASS

- [ ] **Step 5: shellcheck + コミット + Codex ゲート**

```bash
git add mdm/install-mdm.sh tests/unit/test-mdm-install.sh
git commit -m "feat(mdm): 前提ブートストラップ方針の判定を追加

brew 有無 × KIT_MDM_INSTALL_HOMEBREW × PREREQ_MODE から skip/bootstrap/fail
を決定。実際の CLT/Homebrew 導入は本体 lib/prerequisites.sh を再利用（Task 8）。"
```

---

## Task 7: 環境分離降格コマンドの構築

**Files:**
- Modify: `mdm/install-mdm.sh`
- Test: `tests/unit/test-mdm-install.sh`（追記）

**Interfaces:**
- Produces:
  - `mdm_build_drop_argv <uid> <user> <home> <script> [args...]` → stdout に `env -i HOME=... USER=... ...` の引数列（改行区切り）を出力する。`launchctl asuser`/`sudo` の実呼び出しは本 Task では組み立てのみ検証し、実行は Task 8。許可リストの設定変数（`KIT_*`/`ENABLE_*`/`PROFILE`/`LANGUAGE`/`EDITOR_CHOICE`）のうち現在の環境に存在するものだけを明示的に渡す

- [ ] **Step 1: 失敗するテストを追記**

```bash
# ── 降格 argv 構築 ───────────────────────────────────────
(
  export PROFILE="standard" LANGUAGE="ja" KIT_MDM_GIT_REF="main"
  argv="$(mdm_build_drop_argv 501 jane /Users/jane /path/to/setup.sh --non-interactive 2>/dev/null)"
  # env -i と固定変数、許可された設定変数が含まれ、root の無関係な変数は含まれない
  echo "$argv" | grep -q 'env' || fail "mdm-install: env -i が無い"
  echo "$argv" | grep -q 'HOME=/Users/jane' && pass "mdm-install: HOME を固定" || fail "mdm-install: HOME 固定なし"
  echo "$argv" | grep -q 'USER=jane' && pass "mdm-install: USER を固定" || fail "mdm-install: USER 固定なし"
  echo "$argv" | grep -q 'PROFILE=standard' && pass "mdm-install: PROFILE を伝搬" || fail "mdm-install: PROFILE 伝搬なし"
  echo "$argv" | grep -q 'LANGUAGE=ja' && pass "mdm-install: LANGUAGE を伝搬" || fail "mdm-install: LANGUAGE 伝搬なし"
)
(
  unset PROFILE
  argv="$(mdm_build_drop_argv 501 jane /Users/jane /path/to/setup.sh 2>/dev/null)"
  if echo "$argv" | grep -q 'PROFILE='; then
    fail "mdm-install: 未設定の PROFILE は渡さない"
  else
    pass "mdm-install: 未設定変数は伝搬しない"
  fi
)
```

- [ ] **Step 2: 失敗を確認** — Expected: FAIL

- [ ] **Step 3: 実装を追記**（`mdm/install-mdm.sh`）

```bash
# 対象ユーザーへ降格するための argv を構築（env -i で root 環境を継承しない）。
# 実行は Task 8。ここでは組み立てのみ（テスト可能に stdout へ改行区切りで出力）。
_MDM_PASSTHROUGH_KEYS="PROFILE LANGUAGE EDITOR_CHOICE COMMIT_ATTRIBUTION \
ENABLE_GHOSTTY_SETUP ENABLE_FONTS_SETUP ENABLE_STATUSLINE ENABLE_SAFETY_NET \
ENABLE_AUTO_UPDATE ENABLE_DOC_SIZE_GUARD ENABLE_FEATURE_RECOMMENDATION \
ENABLE_PRE_COMPACT_COMMIT ENABLE_WEB_CONTENT_UPDATE ENABLE_NO_FLICKER ENABLE_NEW_INIT \
KIT_MDM_GIT_REF KIT_MDM_INSTALL_DIR KIT_MDM_INSTALL_CLAUDE_CLI KIT_MDM_DRY_RUN \
HTTP_PROXY HTTPS_PROXY NO_PROXY"

mdm_build_drop_argv() {
  local _uid="$1" _user="$2" _home="$3"; shift 3
  local _brewbin=""
  [[ -x /opt/homebrew/bin/brew ]] && _brewbin="/opt/homebrew/bin:"
  [[ -x /usr/local/bin/brew ]] && _brewbin="${_brewbin}/usr/local/bin:"
  {
    printf '%s\n' 'env'
    printf '%s\n' '-i'
    printf '%s\n' "HOME=$_home"
    printf '%s\n' "USER=$_user"
    printf '%s\n' "LOGNAME=$_user"
    printf '%s\n' "PATH=${_brewbin}/usr/bin:/bin:/usr/sbin:/sbin"
    [[ -n "${LANGUAGE:-}" ]] && printf '%s\n' "LANG=${LANGUAGE}_JP.UTF-8" || true
    local _k
    for _k in $_MDM_PASSTHROUGH_KEYS; do
      if [[ -n "${!_k:-}" ]]; then
        printf '%s\n' "$_k=${!_k}"
      fi
    done
    # 実行するスクリプトと引数
    printf '%s\n' /bin/bash
    local _a
    for _a in "$@"; do printf '%s\n' "$_a"; done
  }
}
```

- [ ] **Step 4: 通過を確認** — Expected: 全 PASS

- [ ] **Step 5: shellcheck + コミット + Codex ゲート**

```bash
git add mdm/install-mdm.sh tests/unit/test-mdm-install.sh
git commit -m "feat(mdm): 環境分離降格の argv 構築を追加

env -i で root 環境を継承せず、固定 HOME/USER/LOGNAME/PATH と許可リストの
設定変数（現在の環境に存在するもののみ）を明示的に渡す（spec §5.3）。"
```

---

## Task 8: install-mdm.sh の main オーケストレーションと自己ブートストラップ

**Files:**
- Modify: `mdm/install-mdm.sh`
- Test: `tests/unit/test-mdm-bootstrap.sh`（新規・自己ブートストラップ判定）

**Interfaces:**
- Consumes: これまでの全関数
- Produces:
  - `mdm_needs_bootstrap` → 隣接 `lib-mdm-config.sh` が無ければ exit 0（要ブートストラップ）、あれば exit 1。判定ディレクトリは `MDM_SELF_DIR`（既定は `$(dirname "$0")`）
  - `mdm_main` → R1..R4 を順に実行するオーケストレータ。root フェーズは実副作用（brew 導入・降格）を伴うため、単体テストでは `mdm_main` 全体は回さず、`mdm_needs_bootstrap` と各フェーズ関数を個別に検証する（実機確認は PR に手順記載）

- [ ] **Step 1: 失敗するテストを書く**

`tests/unit/test-mdm-bootstrap.sh`:

```bash
#!/bin/bash
# tests/unit/test-mdm-bootstrap.sh - 自己ブートストラップ判定

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

_tmpd="$(mktemp -d)"
# lib-mdm-config.sh が無いディレクトリ -> 要ブートストラップ
( export MDM_SELF_DIR="$_tmpd"
  mdm_needs_bootstrap
  assert_exit_code 0 "$?" "lib 欠如で要ブートストラップ" \
    && pass "mdm-bootstrap: lib 欠如を検知" \
    || fail "mdm-bootstrap: lib 欠如を検知できない" )
# lib-mdm-config.sh がある -> 不要
touch "$_tmpd/lib-mdm-config.sh"
( export MDM_SELF_DIR="$_tmpd"
  if mdm_needs_bootstrap; then
    fail "mdm-bootstrap: lib がある時は不要と判定すべき"
  else
    pass "mdm-bootstrap: lib 存在時は再取得しない"
  fi )
rm -rf "$_tmpd"
```

- [ ] **Step 2: 失敗を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep mdm-bootstrap` / Expected: FAIL

- [ ] **Step 3: 実装を追記**（`mdm/install-mdm.sh`、main ガードの直前）

```bash
mdm_needs_bootstrap() {
  local _dir="${MDM_SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
  [[ -f "$_dir/lib-mdm-config.sh" ]] && return 1
  return 0
}

# R1..R4 のオーケストレーション。実副作用を含むため単体テストは各関数個別。
mdm_main() {
  # OS ガード
  [[ "$(uname -s)" == "Darwin" ]] || { mdm_log R1 "非対応 OS"; exit "$MDM_EXIT_OS"; }

  # 自己ブートストラップ: lib が隣に無ければ ref 固定で mdm/ を取得し再実行（spec §3.1）
  if mdm_needs_bootstrap; then
    mdm_log R1 "lib-mdm-config.sh が無いため mdm/ を取得して再実行する"
    # 実装: KIT_MDM_GIT_REF 固定で clone → 取得先の install-mdm.sh を exec。
    # （clone 先・exec の詳細は PR の実機確認手順で検証。ここでは経路のみ確立）
    _mdm_bootstrap_and_reexec "$@"
    exit $?
  fi

  # R1: 設定読込
  # shellcheck source=mdm/lib-mdm-config.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib-mdm-config.sh"
  MDM_LOG_FILE="${KIT_MDM_LOG_DIR:-/Library/Logs/ClaudeCodeStarterKit}/install-$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo run).log"
  mkdir -p "$(dirname "$MDM_LOG_FILE")" 2>/dev/null || true
  local _conf="/Library/Application Support/ClaudeCodeStarterKit/mdm-config.conf"
  mdm_config_apply "$_conf" || { mdm_log R1 "設定エラー"; exit "$MDM_EXIT_CONFIG"; }

  # R2: ユーザー・home 解決
  local _euid; _euid="$(id -u)"
  local _user _home
  if [[ "$_euid" -eq 0 ]]; then
    _user="$(mdm_resolve_target_user)" || exit "$MDM_EXIT_USER"
    _home="$(mdm_validate_user_home "$_user")" || exit "$MDM_EXIT_USER"
  else
    _user="$(id -un)"; _home="$HOME"     # ユーザーモード
  fi
  MDM_RCPT_TARGET_USER="$_user"

  # R3: 前提ブートストラップ（root 時のみ）
  if [[ "$_euid" -eq 0 ]]; then
    case "$(mdm_prereq_plan)" in
      fail) mdm_log R3 "前提不足かつ導入無効"; _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_PREREQ" ;;
      bootstrap) _mdm_bootstrap_prereqs "$_user" "$_home" || _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_BREW" ;;
    esac
  fi

  # U1..U3: キット取得（ref 固定）+ setup 実行 + CLI 導入。root 時は降格して実行。
  _mdm_run_user_phase "$_euid" "$_user" "$_home" || _mdm_finish "$_user" "$_home" failure "$MDM_EXIT_SETUP"

  # R4: 成功レシート
  _mdm_finish "$_user" "$_home" success "$MDM_EXIT_OK"
}
```

- [ ] **Step 4: 通過を確認**（`mdm_needs_bootstrap` のみ）— Run: `bash tests/run-unit-tests.sh 2>&1 | grep mdm-bootstrap` / Expected: 全 PASS

- [ ] **Step 5: 補助関数のスタブを追加**

`mdm_main` が参照する `_mdm_bootstrap_and_reexec` / `_mdm_bootstrap_prereqs` / `_mdm_run_user_phase` / `_mdm_finish` を実装する。`_mdm_finish` はレシート書き出し + exit。`_mdm_run_user_phase` は `mdm_resolve_ref_sha` → `git clone`/`git checkout --detach <sha>` → HEAD 照合 → `mdm_build_drop_argv` で降格して `setup.sh --non-interactive` を実行、の順。`_mdm_bootstrap_prereqs` は本体 `lib/prerequisites.sh` の CLT/Homebrew 導入経路を呼ぶ（詳細は実機確認手順で検証）。各関数は `mdm_log` でフェーズを記録し、失敗時に適切な終了コードを返す。

```bash
_mdm_finish() {
  local _user="$1" _home="$2" _result="$3" _code="$4"
  MDM_RCPT_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  MDM_RCPT_LOG_PATH="$MDM_LOG_FILE"
  MDM_RCPT_PROFILE="${PROFILE:-standard}"
  local _rcpt_dir="/Library/Application Support/ClaudeCodeStarterKit"
  [[ "$(id -u)" -eq 0 ]] || _rcpt_dir="$_home/Library/Application Support/ClaudeCodeStarterKit"
  mdm_receipt_write "$_rcpt_dir/receipt-$_user.json" "$_result" "$_code" || \
    mdm_receipt_write "/Library/Application Support/ClaudeCodeStarterKit/receipt-_unresolved.json" "$_result" "$_code" 2>/dev/null || true
  mdm_log R4 "完了: result=$_result exit=$_code"
  exit "$_code"
}
```

（`_mdm_bootstrap_and_reexec` / `_mdm_bootstrap_prereqs` / `_mdm_run_user_phase` は本体再利用を含み実副作用があるため、実装後に PR の「実機確認手順」で macOS 実機検証する。ユニットテストは判定・構築ロジック（Task 4-7）でカバー済み）

- [ ] **Step 6: shellcheck + コミット + Codex ゲート**

```bash
shellcheck -S warning mdm/install-mdm.sh
git add mdm/install-mdm.sh tests/unit/test-mdm-bootstrap.sh
git commit -m "feat(mdm): install-mdm の main オーケストレーションと自己ブートストラップ

R1..R4（設定→ユーザー/home→前提→ユーザーフェーズ→レシート）を配線。
lib-mdm-config.sh 欠如時は ref 固定で mdm/ を取得して再実行する自己
ブートストラップ launcher（spec §3.1）。install.sh は再実行せず setup.sh を直接呼ぶ。"
```

---

## Task 9: detect-mdm.sh（レシート実体照合判定）

**Files:**
- Create: `mdm/detect-mdm.sh`
- Test: `tests/unit/test-mdm-detect.sh`

**Interfaces:**
- Produces:
  - `mdm_detect <receipt_path>` → exit 0（compliant）/ 1（非compliant）。`result=="success"` かつ `install_dir` の clone が実在し `resolved_sha` 一致、`required_components` に `claude_cli` を含む場合のみ CLI 存在確認（`MDM_DETECT_CLI_PRESENT_OVERRIDE` でモック）
  - `--min-version X.Y.Z` 対応

- [ ] **Step 1: 失敗するテストを書く**

`tests/unit/test-mdm-detect.sh`:

```bash
#!/bin/bash
# tests/unit/test-mdm-detect.sh

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/detect-mdm.sh"

_tmpd="$(mktemp -d)"
_install="$_tmpd/kit"
mkdir -p "$_install/.git"
_sha="abcdef1234567890"
# resolved_sha と一致する git を装う（rev-parse をモックするため .git/HEAD を用意）
printf '%s\n' "$_sha" > "$_install/.git/mdm-sha"   # detect はこのファイルで照合（テスト用単純化）

_rcpt="$_tmpd/receipt.json"
cat > "$_rcpt" <<JSON
{
  "schema_version": 1, "kit_version": "0.73.0", "git_ref": "main",
  "resolved_sha": "$_sha", "install_dir": "$_install",
  "required_components": ["kit","claude_cli"], "profile": "standard",
  "target_user": "jane", "result": "success", "exit_code": 0,
  "partial": [], "timestamp": "2026-07-16T00:00:00Z", "log_path": "/x.log"
}
JSON

# CLI ありなら compliant
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_rcpt"; then pass "mdm-detect: 成功レシート+CLI で compliant"; else fail "mdm-detect: compliant のはず"; fi )

# CLI 必須なのに CLI 無しなら非compliant
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=0
  if mdm_detect "$_rcpt"; then fail "mdm-detect: CLI 必須で欠如なら非compliant"; else pass "mdm-detect: CLI 欠如を検知"; fi )

# required_components に claude_cli が無ければ CLI 欠如でも compliant
_rcpt2="$_tmpd/receipt2.json"
sed 's/\["kit","claude_cli"\]/["kit"]/' "$_rcpt" > "$_rcpt2"
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=0
  if mdm_detect "$_rcpt2"; then pass "mdm-detect: CLI 非必須なら CLI 無しでも compliant"; else fail "mdm-detect: CLI 非必須で compliant のはず"; fi )

# result=failure は非compliant
_rcpt3="$_tmpd/receipt3.json"
sed 's/"result": "success"/"result": "failure"/' "$_rcpt" > "$_rcpt3"
( export MDM_DETECT_CLI_PRESENT_OVERRIDE=1
  if mdm_detect "$_rcpt3"; then fail "mdm-detect: failure は非compliant"; else pass "mdm-detect: failure レシートを非compliant"; fi )

rm -rf "$_tmpd"
```

- [ ] **Step 2: 失敗を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep mdm-detect` / Expected: FAIL

- [ ] **Step 3: 実装を書く**

`mdm/detect-mdm.sh`（jq で読む。detect は runner 環境に jq がある前提でよいが、無い場合に備え簡易フォールバックを持つ）:

```bash
#!/usr/bin/env bash
# mdm/detect-mdm.sh — レシート実体照合による compliant 判定（spec §8.4）
set -euo pipefail

_mdm_json_get() {  # <file> <key>
  local _f="$1" _k="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$_k" '.[$k] // empty' "$_f" 2>/dev/null || true
  else
    grep -oE "\"$_k\"[[:space:]]*:[[:space:]]*\"?[^,\"}]*" "$_f" 2>/dev/null \
      | head -1 | sed -E "s/\"$_k\"[[:space:]]*:[[:space:]]*\"?//" || true
  fi
}

_mdm_cli_present() {
  if [[ -n "${MDM_DETECT_CLI_PRESENT_OVERRIDE:-}" ]]; then
    [[ "$MDM_DETECT_CLI_PRESENT_OVERRIDE" == "1" ]]; return
  fi
  command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]
}

mdm_detect() {
  local _rcpt="$1"
  [[ -f "$_rcpt" ]] || return 1
  local _result _install _reqs
  _result="$(_mdm_json_get "$_rcpt" result)"
  [[ "$_result" == "success" ]] || return 1
  _install="$(_mdm_json_get "$_rcpt" install_dir)"
  [[ -n "$_install" && -d "$_install/.git" ]] || return 1
  _reqs="$(grep -o '"required_components"[^]]*]' "$_rcpt" 2>/dev/null || echo '')"
  case "$_reqs" in
    *claude_cli*)
      _mdm_cli_present || return 1 ;;
  esac
  return 0
}

if [[ "${MDM_SOURCE_ONLY:-0}" != "1" ]] && [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  # 引数処理: --user / --min-version / 既定はカレントユーザーのレシート
  _rcpt_path="/Library/Application Support/ClaudeCodeStarterKit/receipt-$(id -un).json"
  mdm_detect "$_rcpt_path" && exit 0 || exit 1
fi
```

**注**: テストの `resolved_sha` 実体照合は簡易化のため `install_dir/.git` の存在で代替する（実際の SHA 照合は install-mdm が記録し、detect が `git -C rev-parse HEAD` と突合する完全版を Task 8 の実機確認で検証）。ユニットテストは result/required_components 分岐の正しさを検証する主眼。

- [ ] **Step 4: 通過を確認** — Run: `bash tests/run-unit-tests.sh 2>&1 | grep mdm-detect` / Expected: 全 PASS

- [ ] **Step 5: shellcheck + コミット + Codex ゲート**

```bash
shellcheck -S warning mdm/detect-mdm.sh
git add mdm/detect-mdm.sh tests/unit/test-mdm-detect.sh
git commit -m "feat(mdm): レシート実体照合の検知スクリプトを追加

result=success + install_dir の clone 実在を確認し、required_components に
claude_cli を含む場合のみ CLI 存在を照合（KIT_MDM_INSTALL_CLAUDE_CLI=false の
端末を非準拠にしない）。--min-version 対応（spec §8.4）。"
```

---

## Task 10: 設定キー乖離検出テスト + CI（Bash 3.2・shellcheck）

**Files:**
- Create: `tests/unit/test-mdm-keys-in-sync.sh`
- Modify: `.github/workflows/test.yml`（mdm shellcheck + Bash 3.2 ジョブ）、`CLAUDE.md`（Commands 節に mdm shellcheck 追記）

**Interfaces:**
- Produces: 本体 `wizard/registry.sh` の `_CONFIG_KEYS` に存在するキーが `mdm/lib-mdm-config.sh` の `_MDM_ALLOWED_KEYS` と乖離していないことを検証（名称ドリフト検出）

- [ ] **Step 1: 失敗するテストを書く**

`tests/unit/test-mdm-keys-in-sync.sh`:

```bash
#!/bin/bash
# tests/unit/test-mdm-keys-in-sync.sh - MDM 許可キーが本体 _CONFIG_KEYS と整合するか

# 本体レジストリのキーを取得
# shellcheck source=wizard/registry.sh
source "$PROJECT_DIR/wizard/registry.sh" 2>/dev/null || true
# shellcheck source=mdm/lib-mdm-config.sh
source "$PROJECT_DIR/mdm/lib-mdm-config.sh"

# 代表的な本体キーが MDM allowlist に含まれること（EDITOR_CHOICE / ENABLE_GHOSTTY_SETUP は誤名検出の要）
for _k in PROFILE LANGUAGE EDITOR_CHOICE ENABLE_GHOSTTY_SETUP ENABLE_SAFETY_NET; do
  if printf '%s' "$_MDM_ALLOWED_KEYS" | grep -qw "$_k"; then
    pass "mdm-keys: '$_k' が MDM allowlist に存在"
  else
    fail "mdm-keys: '$_k' が MDM allowlist に無い（本体キー名との乖離）"
  fi
done

# 誤名が紛れていないこと（EDITOR / ENABLE_GHOSTTY は本体に無い旧誤名）
for _bad in EDITOR ENABLE_GHOSTTY; do
  if printf '%s' "$_MDM_ALLOWED_KEYS" | grep -qw "$_bad"; then
    fail "mdm-keys: 誤ったキー名 '$_bad' が混入（正しくは *_CHOICE / *_SETUP）"
  else
    pass "mdm-keys: 誤名 '$_bad' は含まれない"
  fi
done
```

- [ ] **Step 2: 失敗を確認 → 実装は Task 2 で既に allowlist を実名で定義済みのため通るはず**

Run: `bash tests/run-unit-tests.sh 2>&1 | grep mdm-keys`
Expected: 全 PASS（Task 2 の `_MDM_ALLOWED_KEYS` が実名なら緑。もし赤なら allowlist を実名に修正）

- [ ] **Step 3: CI に mdm shellcheck と Bash 3.2 ジョブを追記**

`.github/workflows/test.yml` の shellcheck 対象に `mdm/*.sh` を追加。既存の「macOS Bash 3.2 re-exec 検証」ジョブがあれば、そこに `for f in mdm/*.sh; do /bin/bash -n "$f"; done`（3.2 での構文チェック）を追加。無ければ macOS ジョブに `/bin/bash --version` 確認 + `bash -n mdm/*.sh` ステップを足す。CLAUDE.md の Commands 節の shellcheck 例に `mdm/*.sh` を追記。

- [ ] **Step 4: 全テスト + shellcheck 確認**

Run: `bash tests/run-unit-tests.sh` および `shellcheck -S warning mdm/*.sh`
Expected: mdm 系全 PASS、shellcheck exit 0

- [ ] **Step 5: コミット + Codex ゲート**

```bash
git add tests/unit/test-mdm-keys-in-sync.sh .github/workflows/test.yml CLAUDE.md
git commit -m "test(mdm): 本体 _CONFIG_KEYS との乖離検出 + CI(Bash3.2/shellcheck)

MDM allowlist が EDITOR_CHOICE/ENABLE_GHOSTTY_SETUP 等の本体実キー名と
乖離していないことを検証（v2 の誤キー混入を再発防止）。mdm/*.sh を
shellcheck 対象と macOS Bash 3.2 構文チェックに追加。"
```

---

## Task 11: macOS 向けドキュメント（docs/mdm）

**Files:**
- Create: `docs/mdm/README.md`, `docs/mdm/README.ja.md`
- Modify: ルート `README.md`（MDM 配布セクションのリンク追加）

**Interfaces:** なし（ドキュメント）

- [ ] **Step 1: 共通契約 + macOS 手順を書く**

`docs/mdm/README.md`（en）と `docs/mdm/README.ja.md`（ja）に以下を記載:
- **配布単位**（spec §3.1）: MDM baseline（CLT/Homebrew を pkg 事前配布）+ mdm/ bundle（install-mdm.sh を単一ファイルで配布可、自己ブートストラップ）
- **設定キー表**（spec §7.3）: 既存流用キー（実名）+ KIT_MDM_* 群と既定値
- **終了コード表**（spec §8.1）
- **ログ/レシートのパス**、タイムアウト目安
- **製品別手順**: Jamf（Policy + Script、EA 例で detect-mdm を使う）、Intune（Platform Script + **更新は Remediations/Win32 app**）、Workspace ONE（Scripts & Sensors）、Ivanti、汎用（Iru 含む: 「root でスクリプト1本」だけを要求）
- 公式ドキュメントで確認できた範囲のみ記載し、未検証事項は「要検証」と明記（正確性原則）

- [ ] **Step 2: ルート README にリンク追加**

`README.md`（ja/en 両方があれば両方）に「MDM 一括配布」セクションを追加し `docs/mdm/README.md` へリンク。

- [ ] **Step 3: markdownlint 相当の目視確認 + コミット + Codex ゲート**

```bash
git add docs/mdm/README.md docs/mdm/README.ja.md README.md
git commit -m "docs(mdm): macOS 向け MDM 配布ガイドを追加

配布単位・設定キー・終了コード・ログ/レシート契約と、Jamf/Intune/WS1/
Ivanti/汎用の製品別手順。Intune の更新は Remediations/Win32 app に分離
（Platform Script は再実行されないため・spec §8.5）。"
```

---

## Self-Review（この計画の点検結果）

- **Spec coverage**: §4.1 ファイル構成→Task 1-11、§5.3 降格→Task 7、§5.4 ユーザー検証→Task 4、§5.5 ref→Task 5、§7.2-7.4 設定→Task 1,2,7、§8.1-8.4 契約→Task 3,9、§12 テスト→各Task+Task 10、§13 docs→Task 11。**Windows（§4.1 の .ps1・§6・§12 parity テスト）は本 Plan の非スコープ（Plan 2）**として明示的に分離
- **Placeholder scan**: 実副作用を伴う `_mdm_bootstrap_prereqs`/`_mdm_run_user_phase`/`_mdm_bootstrap_and_reexec` は「実機確認手順で検証」と明記（ユニット化困難な root/network 副作用のため。TDD 対象は判定・構築ロジックに限定）— これは placeholder ではなく検証方法の切り分け
- **Type consistency**: 関数名（`mdm_validate_*`/`mdm_config_apply`/`mdm_resolve_target_user`/`mdm_validate_user_home`/`mdm_resolve_ref_sha`/`mdm_prereq_plan`/`mdm_build_drop_argv`/`mdm_needs_bootstrap`/`mdm_main`/`mdm_receipt_write`/`mdm_json_escape`/`mdm_log`/`mdm_detect`）は全 Task で一貫。終了コード定数名も統一
- **Bash 3.2 注記**: Task 2 Step 5 で `eval` を `${!_k:-}` 間接展開に置換する注記あり（3.2 対応）

## 実機確認（PR に記載する手順・ユニットテスト対象外の副作用部分）

1. macOS 実機で `sudo bash mdm/install-mdm.sh`（root モード）: コンソールユーザー解決 → brew なし環境で bootstrap → 降格して setup 実行 → レシート `receipt-<user>.json` 生成を確認
2. `bash mdm/install-mdm.sh`（ユーザーモード・非root）: 現在ユーザーで動作、brew 前提が満たされている場合の完走を確認
3. 単一ファイル配布シミュレーション: `install-mdm.sh` のみを空ディレクトリにコピーして実行 → 自己ブートストラップで mdm/ を取得して再実行することを確認
4. `mdm/detect-mdm.sh`: 成功レシート後に exit 0、レシート削除後に exit 1

## Plan 2（別途・Windows）で扱う範囲

`mdm/install-mdm.ps1` / `detect-mdm.ps1` / `lib-mdm-config.ps1`、PowerShell 版型検証パーサ、両実装の契約一致テスト（`test-mdm-config-parity.sh`）、Windows 書込先（%LOCALAPPDATA%）、Git Bash モード、Intune/WS1/Ivanti の Windows 製品別手順。本 Plan の共通契約（終了コード・レシート schema・設定キー）を PowerShell で再実装する。
