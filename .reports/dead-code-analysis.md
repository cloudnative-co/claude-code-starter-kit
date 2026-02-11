# Dead Code Analysis Report

**Project**: claude-code-starter-kit
**Date**: 2026-02-12
**Scope**: All shell scripts (`**/*.sh`)
**Total Functions Analyzed**: 114
**Dead Functions Found**: 6

---

## Analysis Method

Shell プロジェクトのため、knip/depcheck/ts-prune は適用外。
代替として以下を実施:

1. 全 `.sh` ファイルの関数定義を抽出（`grep` で `^[a-z_]+()` パターン）
2. 各関数名でプロジェクト全体を検索し、定義箇所以外での呼び出しを確認
3. feature ディレクトリ・profile 設定・i18n 文字列の参照整合性を確認

---

## Dead Code Findings

### 1. `step()` — lib/colors.sh:52-56

**Severity**: SAFE
**Type**: 未使用ユーティリティ関数
**Lines**: 6行

```bash
step() {
  local label="$1"
  shift
  printf "${CYAN}${BOLD}[%s]${NC} %s\n" "$label" "$*"
}
```

**Analysis**: マルチステッププロセス用のインジケータ関数。定義されているが、プロジェクト内で一度も呼ばれていない。実際のステップ表示には `section()` が使われている。

---

### 2. `is_wsl2()` — lib/detect.sh:164-166

**Severity**: SAFE
**Type**: 未使用ヘルパー関数
**Lines**: 3行

```bash
is_wsl2() {
  is_wsl && [[ "$WSL_BUILD" -ge 19041 ]] 2>/dev/null
}
```

**Analysis**: WSL2 判定の純粋な述語関数。`is_wsl()` は使われているが、`is_wsl2()` を呼ぶコードはない。WSL2 固有の機能分岐が現在のコードに存在しないため不要。

---

### 3. `print_detect_summary()` — lib/detect.sh:169-171

**Severity**: SAFE
**Type**: 未使用デバッグ関数
**Lines**: 3行

```bash
print_detect_summary() {
  echo "OS=$OS  ARCH=$ARCH  DISTRO=$DISTRO  FAMILY=$DISTRO_FAMILY  WSL=$IS_WSL  WSL_BUILD=$WSL_BUILD"
}
```

**Analysis**: 環境検出結果の要約表示関数。デバッグ用途と思われるが、どこからも呼ばれていない。

---

### 4. `process_template_string()` — lib/template.sh:134-146

**Severity**: SAFE
**Type**: 未使用ユーティリティ関数
**Lines**: 13行

```bash
process_template_string() {
  local template="$1"
  shift
  local content="$template"
  for assignment in "$@"; do
    local key="${assignment%%=*}"
    local value="${assignment#*=}"
    content="${content//\{\{${key}\}\}/${value}}"
  done
  printf '%s' "$content"
}
```

**Analysis**: 文字列ベースのテンプレート処理関数。ファイルベースの `process_template()` は使われているが、この文字列版は未使用。

---

### 5. `filter_plugins()` — lib/json-builder.sh:130-162

**Severity**: SAFE
**Type**: 未使用ユーティリティ関数
**Lines**: 33行

**Analysis**: JSON プラグイン配列をフィルタリングする関数。プラグイン機能は `build_settings_json()` 内で直接処理されており、この汎用フィルタ関数は使われていない。

---

### 6. `merge_json_files()` — lib/json-builder.sh:171-195

**Severity**: SAFE
**Type**: 未使用ユーティリティ関数
**Lines**: 25行

**Analysis**: 複数 JSON ファイルの汎用ディープマージ関数。`build_settings_json()` が独自のマージロジックを持っているため、この汎用版は未使用。

---

## Summary

| # | Function | File | Lines | Severity | Action |
|---|----------|------|-------|----------|--------|
| 1 | `step()` | lib/colors.sh:52 | 6 | SAFE | Delete |
| 2 | `is_wsl2()` | lib/detect.sh:164 | 3 | SAFE | Delete |
| 3 | `print_detect_summary()` | lib/detect.sh:169 | 3 | SAFE | Delete |
| 4 | `process_template_string()` | lib/template.sh:134 | 13 | SAFE | Delete |
| 5 | `filter_plugins()` | lib/json-builder.sh:130 | 33 | SAFE | Delete |
| 6 | `merge_json_files()` | lib/json-builder.sh:171 | 25 | SAFE | Delete |

**Total dead lines**: 83行
**Risk level**: すべて SAFE（副作用なし、他の関数から依存なし）

---

## Additional Observations

- **テストなし**: プロジェクトにテストスイートがないため、shellcheck による構文検証で代替
- **重複定義**: `info()`/`ok()`/`warn()`/`error()` が `install.sh`, `uninstall.sh`, `lib/colors.sh` に重複定義されているが、これはスタンドアロンスクリプトとして意図的な設計
- **大きなファイル**: `wizard.sh` (852行) と `setup.sh` (887行) は推奨上限（800行）をやや超過しているが、今回のスコープ外
