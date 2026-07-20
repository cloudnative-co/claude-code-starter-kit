#!/bin/bash
# tests/unit/test-mdm-keys-in-sync.sh - MDM の設定キー契約を本体レジストリと照合

# shellcheck source=wizard/registry.sh
source "$PROJECT_DIR/wizard/registry.sh"
# 実運用で使う installer 内蔵 parser と renderer 呼び出しを取得する。
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

_test_mdm_keys_in_sync_main() {
  local _key _profile _line _profile_key _found _python _tmp _render_rc
  local _canonical="" _profile_keys="" _missing="" _extra="" _drift="" _invalid=""
  local _renderer_function _renderer_compact _renderer_contract=0 _forced_ok=0
  local _args=()

  # wizard の non-legacy 設定から、MDM が運べる設定の全体集合を作る。
  # SELECTED_PLUGINS / DISMISSED_FEATURES は MDM の直接設定対象ではない。
  for _key in "${_CONFIG_KEYS[@]}"; do
    [[ -n "$_key" ]] || continue
    [[ " $_CONFIG_LEGACY_KEYS " != *" $_key "* ]] || continue
    case "$_key" in
      PROFILE|LANGUAGE|EDITOR_CHOICE|COMMIT_ATTRIBUTION|ENABLE_*|INSTALL_*)
        _canonical="${_canonical}${_canonical:+ }$_key" ;;
    esac
  done

  # 全 profile は同じ ENABLE_*/INSTALL_* スキーマを持ち、その集合は
  # wizard registry の non-legacy 設定と完全一致しなければならない。
  for _profile in minimal standard full; do
    _profile_keys=""
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      case "$_line" in ''|'#'*) continue ;; esac
      if [[ "$_line" =~ ^(ENABLE_[A-Z0-9_]*|INSTALL_[A-Z0-9_]*)=(true|false)$ ]]; then
        _profile_key="${BASH_REMATCH[1]}"
        [[ " $_profile_keys " != *" $_profile_key "* ]] \
          || _drift="$_drift $_profile:duplicate:$_profile_key"
        _profile_keys="${_profile_keys}${_profile_keys:+ }$_profile_key"
        [[ " $_canonical " == *" $_profile_key "* ]] \
          || _drift="$_drift $_profile:unknown:$_profile_key"
      else
        _drift="$_drift $_profile:invalid-line"
      fi
    done < "$PROJECT_DIR/profiles/$_profile.conf"
    for _key in $_canonical; do
      case "$_key" in ENABLE_*|INSTALL_*)
        [[ " $_profile_keys " == *" $_key "* ]] \
          || _drift="$_drift $_profile:missing:$_key" ;;
      esac
    done
  done
  if [[ -z "$_drift" ]]; then
    pass "mdm-keys: profiles と non-legacy wizard registry の設定集合が完全一致"
  else
    fail "mdm-keys: profiles / wizard registry の設定集合が不一致:$_drift"
  fi
  _drift=""

  # root parser と降格実行の双方が、canonical 設定を漏れなく運ぶこと。
  for _key in $_canonical; do
    _mdm_root_key_allowed "$_key" || _missing="$_missing $_key"
  done
  for _key in $_MDM_ROOT_ALLOWED_KEYS; do
    case "$_key" in
      PROFILE|LANGUAGE|EDITOR_CHOICE|COMMIT_ATTRIBUTION|ENABLE_*|INSTALL_*)
        [[ " $_canonical " == *" $_key "* ]] || _extra="$_extra $_key" ;;
    esac
  done
  if [[ -z "$_missing$_extra" ]]; then
    pass "mdm-keys: root allowlist が canonical 設定を過不足なく網羅"
  else
    fail "mdm-keys: root allowlist が canonical 設定と不一致 (missing:$_missing; extra:$_extra)"
  fi

  for _key in $_canonical; do
    case "$_key" in
      PROFILE) _line=minimal ;;
      LANGUAGE) _line=en ;;
      EDITOR_CHOICE) _line=none ;;
      *) _line=false ;;
    esac
    [[ "$(_mdm_root_value "$_key" "$_line" 2>/dev/null)" == "$_line" ]] \
      || _invalid="$_invalid $_key"
  done
  if [[ -z "$_invalid" ]]; then
    pass "mdm-keys: root parser が全 canonical 設定値を正規化"
  else
    fail "mdm-keys: allowlist 上は存在するが root parser が拒否する設定:$_invalid"
  fi

  _missing=""; _extra=""
  for _key in $_canonical; do
    [[ " $_MDM_PASSTHROUGH_KEYS " == *" $_key "* ]] || _missing="$_missing $_key"
  done
  for _key in $_MDM_PASSTHROUGH_KEYS; do
    case "$_key" in
      PROFILE|LANGUAGE|EDITOR_CHOICE|COMMIT_ATTRIBUTION|ENABLE_*|INSTALL_*)
        [[ " $_canonical " == *" $_key "* ]] || _extra="$_extra $_key" ;;
    esac
    _mdm_root_key_allowed "$_key" || _drift="$_drift passthrough-not-allowed:$_key"
  done
  if [[ -z "$_missing$_extra$_drift" ]]; then
    pass "mdm-keys: passthrough が canonical 設定と root allowlist に完全同期"
  else
    fail "mdm-keys: passthrough 契約が不一致 (missing:$_missing; extra:$_extra; drift:$_drift)"
  fi

  # PROFILE/LANGUAGE/EDITOR_CHOICE は専用引数、それ以外の canonical boolean は
  # root allowlist から動的抽出して renderer の --override へ渡す実装を固定する。
  _renderer_function="$(declare -f _mdm_prepare_expected_state)"
  _renderer_compact="$(printf '%s' "$_renderer_function" | tr -d '[:space:]')"
  if [[ "$_renderer_compact" == *'for_keyin$_MDM_ROOT_ALLOWED_KEYS;'* \
    && "$_renderer_compact" == *'ENABLE_*|INSTALL_*|COMMIT_ATTRIBUTION)'* \
    && "$_renderer_compact" == *'--override'* ]]; then
    _renderer_contract=1
  fi
  [[ "$_renderer_contract" -eq 1 ]] \
    && pass "mdm-keys: installer は root allowlist から renderer override を動的抽出" \
    || fail "mdm-keys: installer の renderer override 抽出契約が失われた"

  # renderer 自身にも全 boolean override を一度に渡し、単なる shell 側の
  # allowlist 一致ではなく end-to-end の受理と policy 反映まで確認する。
  _python="${MDM_SYSTEM_PYTHON_OVERRIDE:-/usr/bin/python3}"
  [[ -x "$_python" ]] || _python="$(command -v python3 2>/dev/null || true)"
  _tmp="$(mktemp -d)"
  chmod 700 "$_tmp"
  _args=("$_python" "$PROJECT_DIR/mdm/render-expected.py"
    --checkout "$PROJECT_DIR" --output "$_tmp/rendered"
    --profile minimal --language ja --editor zed
    --claude-cli-required false --logical-home /Users/mdm-keys)
  for _key in $_canonical; do
    case "$_key" in PROFILE|LANGUAGE|EDITOR_CHOICE) continue ;; esac
    _args[${#_args[@]}]=--override
    _args[${#_args[@]}]="$_key=false"
  done
  _render_rc=0
  if [[ -n "$_python" && -x "$_python" ]]; then
    "${_args[@]}" >/dev/null 2>&1 || _render_rc=$?
  else
    _render_rc=127
  fi
  if [[ "$_render_rc" -eq 0 ]] && "$_python" - "$_tmp/rendered/policy.json" $_canonical <<'PY'
import json
import sys

with open(sys.argv[1], encoding="ascii") as source:
    policy = json.load(source)
assert policy["profile"] == "minimal"
assert policy["language"] == "ja"
assert policy["editor_choice"] == "zed"
assert policy["commit_attribution"] is False
for key in sys.argv[2:]:
    if key.startswith(("ENABLE_", "INSTALL_")):
        assert policy["values"][key] is False
PY
  then
    pass "mdm-keys: renderer が全 canonical boolean override を受理し policy に反映"
  else
    fail "mdm-keys: renderer の canonical override 契約が不完全 (rc=$_render_rc)"
  fi
  rm -rf "$_tmp"

  # 自己更新を起こす3キーは true を拒否するが、設定面から消してはならない。
  _forced_ok=0
  for _key in ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE ENABLE_CODEX_PLUGIN; do
    if _mdm_root_key_allowed "$_key" \
      && [[ " $_MDM_PASSTHROUGH_KEYS " == *" $_key "* ]] \
      && [[ " $_canonical " == *" $_key "* ]] \
      && [[ "$(_mdm_root_value "$_key" false 2>/dev/null)" == false ]] \
      && ! _mdm_root_value "$_key" true >/dev/null 2>&1; then
      _forced_ok=$((_forced_ok + 1))
    fi
  done
  [[ "$_forced_ok" -eq 3 ]] \
    && pass "mdm-keys: 強制false 3キーも全契約に残り true は fail-closed" \
    || fail "mdm-keys: 強制false キーの allow/passthrough/renderer 契約が欠落"

  # 旧誤名・legacy キーは新しい MDM 契約へ逆流させない。
  _found=0
  for _key in EDITOR ENABLE_GHOSTTY $_CONFIG_LEGACY_KEYS; do
    if _mdm_root_key_allowed "$_key" \
      || [[ " $_MDM_PASSTHROUGH_KEYS " == *" $_key "* ]]; then
      _found=1
    fi
  done
  [[ "$_found" -eq 0 ]] \
    && pass "mdm-keys: 誤名と legacy 設定は新規 MDM 契約へ混入しない" \
    || fail "mdm-keys: 誤名または legacy 設定が MDM 契約へ混入"
}

_test_mdm_keys_in_sync_main
unset -f _test_mdm_keys_in_sync_main

mdm_test_reached_end
