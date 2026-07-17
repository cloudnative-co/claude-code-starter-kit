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
# NOTE: 以下の MDM_RCPT_* はこのファイルでは直接参照せず mdm_receipt_write
# 側が間接参照するグローバル。shellcheck は静的にそれを追えないため、Task 3
# の install-mdm.sh 自身の終了コード定数と同じ「1行1定数+個別disable」方式で
# 個別に SC2034 を無効化する。
_tmpd="$(mktemp -d)"
# shellcheck disable=SC2034
MDM_RCPT_KIT_VERSION="0.73.0"
# shellcheck disable=SC2034
MDM_RCPT_GIT_REF="main"
# shellcheck disable=SC2034
MDM_RCPT_RESOLVED_SHA="abc123"
# shellcheck disable=SC2034
MDM_RCPT_INSTALL_DIR="/Users/jane/.claude-starter-kit"
# shellcheck disable=SC2034
MDM_RCPT_REQUIRED_COMPONENTS='["kit","claude_cli"]'
# shellcheck disable=SC2034
MDM_RCPT_PROFILE="standard"
# shellcheck disable=SC2034
MDM_RCPT_LANGUAGE="ja"
# shellcheck disable=SC2034
MDM_RCPT_MANIFEST_PATH="/Users/jane/.claude/.starter-kit-manifest.json"
# shellcheck disable=SC2034
MDM_RCPT_MANIFEST_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# shellcheck disable=SC2034
MDM_RCPT_DEPLOYMENT_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
# shellcheck disable=SC2034
MDM_RCPT_TARGET_USER="jane"
# shellcheck disable=SC2034
MDM_RCPT_PARTIAL='[]'
# shellcheck disable=SC2034
MDM_RCPT_TIMESTAMP="2026-07-16T00:00:00Z"
# shellcheck disable=SC2034
MDM_RCPT_LOG_PATH="/Library/Logs/ClaudeCodeStarterKit/install.log"
MDM_EUID_OVERRIDE=501 mdm_receipt_write "$_tmpd/receipt.json" "success" "0"

# NOTE: assert_json_field は field を `jq -r "$field"` にそのまま渡すため、
# フィルタ式として先頭ドット (.result 等) が必須。ドット無し ("result") は
# jq のコンパイルエラーになり __JQ_ERROR__ 比較で常に失敗する。
if assert_json_field "$_tmpd/receipt.json" ".result" "success" "result=success"; then
  pass "mdm-install: レシート result フィールド"
else
  fail "mdm-install: レシート result フィールド不正"
fi
if assert_json_field "$_tmpd/receipt.json" ".exit_code" "0" "exit_code=0"; then
  pass "mdm-install: レシート exit_code フィールド"
else
  fail "mdm-install: レシート exit_code フィールド不正"
fi
if assert_json_field "$_tmpd/receipt.json" ".install_dir" "/Users/jane/.claude-starter-kit" "install_dir 記録"; then
  pass "mdm-install: レシート install_dir 記録"
else
  fail "mdm-install: レシート install_dir 未記録"
fi
if assert_json_field "$_tmpd/receipt.json" ".schema_version" "2" "schema_version=2" \
  && assert_json_field "$_tmpd/receipt.json" ".language" "ja" "language=ja" \
  && assert_json_field "$_tmpd/receipt.json" ".manifest_path" "/Users/jane/.claude/.starter-kit-manifest.json" "manifest_path 記録" \
  && assert_json_field "$_tmpd/receipt.json" ".manifest_sha256" "$MDM_RCPT_MANIFEST_SHA256" "manifest_sha256 記録" \
  && assert_json_field "$_tmpd/receipt.json" ".deployment_sha256" "$MDM_RCPT_DEPLOYMENT_SHA256" "deployment_sha256 記録"; then
  pass "mdm-install: レシート v2 が manifest 証跡を記録"
else
  fail "mdm-install: レシート v2 の manifest 証跡が不正"
fi
# jq でパース可能な妥当 JSON か
if jq -e . "$_tmpd/receipt.json" >/dev/null 2>&1; then
  pass "mdm-install: レシートは妥当な JSON"
else
  fail "mdm-install: レシートが不正な JSON"
fi

# ══ R2-High: レシートは umask に依存せず 644/755 で作成され、symlink を辿らない ══
(
  # MDM agent の umask が 000 でもレシート 644 / ディレクトリ 755。
  # 666 のレシートは一般ユーザーが書き換え可能になり detect-mdm の compliant
  # 偽装（任意 repo を導入済みキットとして通す）に直結する。
  umask 000
  _u0dir="$_tmpd/umask0/sub"
  MDM_EUID_OVERRIDE=501 mdm_receipt_write "$_u0dir/receipt-jane.json" success 0
  _fmode="$(test_stat_mode "$_u0dir/receipt-jane.json")"
  _dmode="$(test_stat_mode "$_u0dir")"
  [[ "$_fmode" == "644" ]] \
    && pass "mdm-install: umask 000 でもレシートは 644" \
    || fail "mdm-install: umask 000 でレシートが ${_fmode}（書換可能な contract 違反）"
  [[ "$_dmode" == "755" ]] \
    && pass "mdm-install: umask 000 でもレシート dir は 755" \
    || fail "mdm-install: umask 000 でレシート dir が $_dmode"
)
(
  # レシートパスに先置きされた symlink を辿らない（標的ファイル無傷 + 実体化）
  _sldir="$_tmpd/rcpt-symlink"
  mkdir -p "$_sldir"
  printf 'victim\n' > "$_sldir/victim-file"
  ln -s "$_sldir/victim-file" "$_sldir/receipt-jane.json"
  MDM_EUID_OVERRIDE=501 mdm_receipt_write "$_sldir/receipt-jane.json" success 0
  if [[ ! -L "$_sldir/receipt-jane.json" && -f "$_sldir/receipt-jane.json" ]] \
     && [[ "$(cat "$_sldir/victim-file")" == "victim" ]]; then
    pass "mdm-install: レシート書込は symlink を辿らない（標的無傷・実体化）"
  else
    fail "mdm-install: レシート書込が symlink を辿る/実体化しない"
  fi
)
rm -rf "$_tmpd"

# ── JSON エスケープ: 制御文字（Medium: 無検証環境値の改行等で JSON が壊れない）──
(
  out="$(mdm_json_escape "$(printf 'a\nb\tc')")"
  if [[ "$out" == 'a\nb\tc' ]]; then
    pass "mdm-install: JSON エスケープが改行/タブを \\n \\t に変換"
  else
    fail "mdm-install: 制御文字のエスケープが不正 (got '$out')"
  fi
)

# ── 終了コード契約: CLT 不足=10 / Homebrew 失敗=11 を区別 ──
(
  export MDM_CLT_PRESENT_OVERRIDE=0 KIT_MDM_ALLOW_CLT_SOFTWAREUPDATE=false
  _rc=0
  _mdm_bootstrap_prereqs jane >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_PREREQ" "$_rc" "CLT 不足は exit 10" \
    && pass "mdm-install: CLT 不足を exit 10（前提不足）で返す" \
    || fail "mdm-install: CLT 不足の終了コードが不正 (got $_rc)"
)
(
  export MDM_CLT_PRESENT_OVERRIDE=1 MDM_BREW_PRESENT_OVERRIDE=0
  export MDM_BREW_RELEASES_JSON_OVERRIDE=/nonexistent-brew-json
  _rc=0
  _mdm_bootstrap_prereqs jane >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_BREW" "$_rc" "brew 失敗は exit 11" \
    && pass "mdm-install: Homebrew 失敗を exit 11 で返す" \
    || fail "mdm-install: Homebrew 失敗の終了コードが不正 (got $_rc)"
)

# ── 設定・ユーザー解決失敗時の best-effort _unresolved レシート ──
(
  _tmpu="$(mktemp -d)"
  export MDM_UNRESOLVED_RCPT_DIR_OVERRIDE="$_tmpu"
  _rc=0
  ( MDM_LOG_FILE=""; _mdm_fail_unresolved 50 ) >/dev/null 2>&1 || _rc=$?
  assert_exit_code 50 "$_rc" "_mdm_fail_unresolved は指定コードで exit" \
    && pass "mdm-install: _mdm_fail_unresolved が指定コードで終了" \
    || fail "mdm-install: _mdm_fail_unresolved の exit code 不一致 (got $_rc)"
  if assert_json_field "$_tmpu/receipt-_unresolved.json" ".result" "failure" "result=failure" 2>/dev/null; then
    pass "mdm-install: _unresolved レシートが best-effort で書かれる"
  else
    fail "mdm-install: _unresolved レシートが生成されない"
  fi
  rm -rf "$_tmpu"
)

# ── 成功時は trusted receipt の書込成功までを postcondition とする ──
(
  _finish_rc=0
  (
    mdm_receipt_write() { return 1; }
    MDM_LOG_FILE=""
    MDM_LOG_FD_OPEN=0
    _mdm_finish jane /tmp/mdm-finish-home success "$MDM_EXIT_OK"
  ) >/dev/null 2>&1 || _finish_rc=$?
  assert_exit_code "$MDM_EXIT_SETUP" "$_finish_rc" "success receipt 書込失敗は exit 30" \
    && pass "mdm-install: success receipt 書込失敗を exit 30 に変換" \
    || fail "mdm-install: success receipt 書込失敗の終了コードが不正 (got $_finish_rc)"
)

# ── root launcher の data-only config parser は曖昧な入力を拒否 ──
(
  _root_cfg_tmp="$(mktemp -d)"
  _root_cfg="$_root_cfg_tmp/mdm-config.conf"
  chmod 700 "$_root_cfg_tmp"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  for _root_case in unknown malformed duplicate invalid-editor; do
    case "$_root_case" in
      unknown)
        printf 'UNKNOWN_ROOT_KEY=true\n' > "$_root_cfg"
        _root_label="unknown key" ;;
      malformed)
        printf 'PROFILE\n' > "$_root_cfg"
        _root_label="malformed line" ;;
      duplicate)
        printf 'PROFILE=standard\nPROFILE=full\n' > "$_root_cfg"
        _root_label="duplicate key" ;;
      invalid-editor)
        printf 'EDITOR_CHOICE=arbitrary\n' > "$_root_cfg"
        _root_label="invalid editor enum" ;;
    esac
    chmod 600 "$_root_cfg"
    _root_rc=0
    _mdm_root_config_apply "$_root_cfg" >/dev/null 2>&1 || _root_rc=$?
    if [[ "$_root_rc" -eq "$MDM_EXIT_CONFIG" ]]; then
      pass "mdm-install: root config parser が $_root_label を exit 50 で拒否"
    else
      fail "mdm-install: root config parser が $_root_label を許可 (got $_root_rc)"
    fi
  done
  rm -rf "$_root_cfg_tmp"
)

# MDM cannot delegate lifecycle control back to user-scope updaters/plugins.
(
  _root_fixed_rc=0
  for _root_fixed_key in ENABLE_AUTO_UPDATE ENABLE_WEB_CONTENT_UPDATE ENABLE_CODEX_PLUGIN; do
    if _mdm_root_value "$_root_fixed_key" true >/dev/null 2>&1 \
      || [[ "$(_mdm_root_value "$_root_fixed_key" false)" != false ]]; then
      _root_fixed_rc=1
    fi
  done
  if [[ "$_root_fixed_rc" -eq 0 ]]; then
    pass "mdm-install: 自己更新・user plugin の true 指定を拒否し false のみ許可"
  else
    fail "mdm-install: MDM 固定 false コンポーネントの parser 契約が不正"
  fi
)

# ── root parser の省略値は fresh/update とも明示 export ──
(
  _defaults_tmp="$(mktemp -d)"
  _defaults_home="$_defaults_tmp/home"
  mkdir -p "$_defaults_home/.claude"
  unset PROFILE LANGUAGE KIT_MDM_DRY_RUN
  _mdm_root_config_apply "$_defaults_tmp/no-config" >/dev/null 2>&1 \
    || fail "mdm-install: 省略設定の root parser が失敗"
  if [[ "$PROFILE" == standard && "$LANGUAGE" == en ]] \
    && /usr/bin/env | grep -qx 'PROFILE=standard' \
    && /usr/bin/env | grep -qx 'LANGUAGE=en'; then
    pass "mdm-install: root parser は省略 PROFILE/LANGUAGE を standard/en で export"
  else
    fail "mdm-install: root parser の省略 PROFILE/LANGUAGE が不正"
  fi

  for _defaults_state in fresh update; do
    rm -f "$_defaults_home/.claude/.starter-kit-manifest.json"
    [[ "$_defaults_state" == update ]] && : > "$_defaults_home/.claude/.starter-kit-manifest.json"
    mdm_build_setup_argv "$_defaults_home"
    mdm_build_drop_argv 501 jane "$_defaults_home" /bin/bash /auth/setup.sh "${MDM_SETUP_ARGV[@]}"
    _defaults_profile=0; _defaults_language=0; _defaults_update=0
    for _defaults_arg in "${MDM_DROP_ARGV[@]}"; do
      [[ "$_defaults_arg" == PROFILE=standard ]] && _defaults_profile=1
      [[ "$_defaults_arg" == LANGUAGE=en ]] && _defaults_language=1
      [[ "$_defaults_arg" == --update ]] && _defaults_update=1
    done
    if [[ "$_defaults_profile" -eq 1 && "$_defaults_language" -eq 1 ]] \
      && { [[ "$_defaults_state" == fresh && "$_defaults_update" -eq 0 ]] \
        || [[ "$_defaults_state" == update && "$_defaults_update" -eq 1 ]]; }; then
      pass "mdm-install: $_defaults_state setup に既定 standard/en を明示伝搬"
    else
      fail "mdm-install: $_defaults_state setup の既定値/update argv が不正"
    fi
  done
  rm -rf "$_defaults_tmp"
)

# proxy は credential/query/空 authority を拒否し、検証済み値だけ auth Git へ渡す。
(
  for _proxy_bad in \
    'http://user:pass@proxy.example:8080' \
    'https://proxy.example:8080?x=1' \
    'http://' \
    'http://:8080' \
    'http://bad proxy:8080'; do
    if _mdm_root_value HTTP_PROXY "$_proxy_bad" >/dev/null 2>&1; then
      fail "mdm-install: 危険な proxy URL を許可 ($_proxy_bad)"
    else
      pass "mdm-install: 危険な proxy URL を拒否"
    fi
  done
  export HTTP_PROXY=http://proxy.example:8080 HTTPS_PROXY=https://proxy.example:8443
  export NO_PROXY=localhost,.example.invalid
  _proxy_env="$(_mdm_auth_git -c 'alias.mdm-env=!/usr/bin/env' mdm-env 2>/dev/null || true)"
  if printf '%s\n' "$_proxy_env" | grep -qx "HTTP_PROXY=$HTTP_PROXY" \
    && printf '%s\n' "$_proxy_env" | grep -qx "HTTPS_PROXY=$HTTPS_PROXY" \
    && printf '%s\n' "$_proxy_env" | grep -qx "NO_PROXY=$NO_PROXY"; then
    pass "mdm-install: 検証済み proxy だけを isolated auth Git へ伝搬"
  else
    fail "mdm-install: auth Git への proxy 伝搬が不正"
  fi
)

# ── receipt は EUID に関係なく system/root 契約のみ ─────
(
  unset MDM_SYSTEM_RCPT_DIR_OVERRIDE
  MDM_EUID_OVERRIDE=0; _root_receipt="$(_mdm_receipt_dir_for /tmp/fake-home)"
  MDM_EUID_OVERRIDE=501; _user_receipt="$(_mdm_receipt_dir_for /tmp/fake-home)"
  if [[ "$_root_receipt" == "/Library/Application Support/ClaudeCodeStarterKit" \
    && "$_user_receipt" == "$_root_receipt" ]]; then
    pass "mdm-install: 成功/失敗 receipt は system root パスだけを使用"
  else
    fail "mdm-install: user-owned receipt パスが残存"
  fi
)

# ── non-root 通常実行は副作用前に exit 21、dry-run のみ別契約 ──
(
  _context_tmp="$(mktemp -d)"
  _context_home="$_context_tmp/home"; mkdir -p "$_context_home"
  printf 'unchanged\n' > "$_context_home/sentinel"
  unset KIT_MDM_DRY_RUN KIT_MDM_INSTALL_DIR
  _context_rc=0
  _mdm_run_user_phase 501 "$(/usr/bin/id -un)" "$_context_home" \
    >/dev/null 2>&1 || _context_rc=$?
  if [[ "$_context_rc" -eq "$MDM_EXIT_CONTEXT" ]] \
    && [[ "$(cat "$_context_home/sentinel")" == unchanged ]] \
    && [[ ! -e "$_context_home/.claude-starter-kit" ]]; then
    pass "mdm-install: non-root remediation は副作用前に exit 21"
  else
    fail "mdm-install: non-root remediation の root-only 契約が不正 (rc=$_context_rc)"
  fi
  rm -rf "$_context_tmp"
)

# ── 対象ユーザー解決（モック）────────────────────────────
# ── launcher は sticky bit と fd snapshot を platform 正しく扱う ──
(
  _launcher_tmp="$(mktemp -d)"
  _launcher_sticky="$_launcher_tmp/sticky"
  mkdir -p "$_launcher_sticky/root-entry"
  printf '#!/bin/bash\nexit 0\n' > "$_launcher_sticky/root-entry/install-mdm.sh"
  chmod 755 "$_launcher_sticky/root-entry/install-mdm.sh"
  _mdm_launcher_stat_uid() { printf '0'; }
  _mdm_launcher_stat_mode() {
    if [[ "$1" == "$_launcher_sticky" ]]; then printf '1777'; else printf '755'; fi
  }
  _mdm_launcher_acl_safe() { return 0; }
  if _mdm_launcher_path_trusted "$_launcher_sticky/root-entry/install-mdm.sh"; then
    pass "mdm-install: root-owned entry は physical sticky parent 配下で信頼可能"
  else
    fail "mdm-install: sticky parent の root-owned entry を誤拒否"
  fi
  rm -rf "$_launcher_tmp"
)
(
  _launcher_sticky_base=/tmp
  [[ -d /private/tmp && ! -L /private/tmp ]] && _launcher_sticky_base=/private/tmp
  _launcher_mode="$(_mdm_launcher_stat_mode "$_launcher_sticky_base")"
  if [[ "$_launcher_mode" == 1777 ]]; then
    pass "mdm-install: launcher stat は sticky mode 1777 を保持"
  else
    fail "mdm-install: launcher stat が sticky bit を欠落 (got $_launcher_mode)"
  fi
)
(
  _launcher_tmp="$(mktemp -d)"; _launcher_src="$_launcher_tmp/source.sh"
  printf '#!/bin/bash\nprintf snapshot\n' > "$_launcher_src"
  _launcher_copy="$(_mdm_launcher_snapshot "$_launcher_src")"
  if [[ -f "$_launcher_copy" && "$(cat "$_launcher_copy")" == "$(cat "$_launcher_src")" ]] \
    && ! grep -Fq '/proc/$$/fd/9' "$PROJECT_DIR/mdm/install-mdm.sh"; then
    pass "mdm-install: launcher snapshot は inherited /dev/fd を照合"
  else
    fail "mdm-install: launcher fd snapshot 契約が不正"
  fi
  rm -f "$_launcher_copy"; rm -rf "$_launcher_tmp"
)

# ── detached HEAD は fd-bound 41 byte full SHA のみ許可 ──
(
  _head_tmp="$(mktemp -d)"; mkdir -p "$_head_tmp/.git"
  _head_sha=0123456789abcdef0123456789abcdef01234567
  printf '%s\n' "$_head_sha" > "$_head_tmp/.git/HEAD"
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha"; then
    pass "mdm-install: fd-bound detached HEAD の full SHA を許可"
  else
    fail "mdm-install: 正常な detached HEAD を拒否"
  fi
  printf 'ref: refs/heads/main\n' > "$_head_tmp/.git/HEAD"
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha"; then
    fail "mdm-install: symbolic HEAD を許可"
  else
    pass "mdm-install: symbolic/非41byte HEAD を拒否"
  fi
  rm -f "$_head_tmp/.git/HEAD"
  printf '%s\n' "$_head_sha" > "$_head_tmp/target"
  ln -s "$_head_tmp/target" "$_head_tmp/.git/HEAD"
  if _mdm_detached_head_matches "$_head_tmp" "$_head_sha"; then
    fail "mdm-install: symlink HEAD を許可"
  else
    pass "mdm-install: symlink HEAD を拒否"
  fi
  rm -rf "$_head_tmp"
)

# Repository content must not make root chmod follow setup.sh outside the
# authoritative checkout.
(
  _auth_link_tmp="$(mktemp -d)"
  mkdir -p "$_auth_link_tmp/tree"
  printf '#!/bin/bash\n' > "$_auth_link_tmp/external.sh"
  chmod 600 "$_auth_link_tmp/external.sh"
  ln -s "$_auth_link_tmp/external.sh" "$_auth_link_tmp/tree/setup.sh"
  _auth_link_rc=0
  _mdm_normalize_auth_tree "$_auth_link_tmp/tree" >/dev/null 2>&1 || _auth_link_rc=$?
  if [[ "$_auth_link_rc" -ne 0 ]] \
    && [[ "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_auth_link_tmp/external.sh")")" == 0600 ]]; then
    pass "mdm-install: authoritative setup symlink を chmod せず拒否"
  else
    fail "mdm-install: authoritative setup symlink の参照先 mode を変更し得る"
  fi
  rm -rf "$_auth_link_tmp"
)

# A target-user race that swaps HEAD to a FIFO must fail within the watchdog
# window instead of blocking privileged remediation indefinitely.
(
  _head_fifo_tmp="$(mktemp -d)"; mkdir -p "$_head_fifo_tmp/.git"
  _head_fifo_sha=0123456789abcdef0123456789abcdef01234567
  _head_fifo_path="$_head_fifo_tmp/.git/HEAD"
  _head_fifo_seen="$_head_fifo_tmp/seen"
  _head_fifo_swapped="$_head_fifo_tmp/swapped"
  printf '%s\n' "$_head_fifo_sha" > "$_head_fifo_path"
  export MDM_SNAPSHOT_WATCHDOG_SECONDS_OVERRIDE=1
  _mdm_stat_identity() {
    local _path="$1" _identity
    if [[ "$_path" == "$_head_fifo_path" && ! -e "$_head_fifo_seen" ]]; then
      if _mdm_is_darwin; then
        _identity="$(/usr/bin/stat -f '%i:%HT:%z' "$_path")"
      else
        _identity="$(/usr/bin/stat -c '%i:%F:%s' "$_path")"
      fi
      : > "$_head_fifo_seen"; printf '%s' "$_identity"
    elif [[ "$_path" == "$_head_fifo_path" && ! -e "$_head_fifo_swapped" ]]; then
      if _mdm_is_darwin; then
        _identity="$(/usr/bin/stat -f '%i:%HT:%z' "$_path")"
      else
        _identity="$(/usr/bin/stat -c '%i:%F:%s' "$_path")"
      fi
      rm -f "$_path"; /usr/bin/mkfifo "$_path"; : > "$_head_fifo_swapped"
      printf '%s' "$_identity"
    elif _mdm_is_darwin; then
      /usr/bin/stat -f '%i:%HT:%z' "$_path" 2>/dev/null
    else
      /usr/bin/stat -c '%i:%F:%s' "$_path" 2>/dev/null
    fi
  }
  _head_fifo_start="$SECONDS"; _head_fifo_rc=0
  _mdm_detached_head_matches "$_head_fifo_tmp" "$_head_fifo_sha" \
    "$(/usr/bin/id -u)" >/dev/null 2>&1 || _head_fifo_rc=$?
  _head_fifo_elapsed=$((SECONDS - _head_fifo_start))
  if [[ "$_head_fifo_rc" -ne 0 && "$_head_fifo_elapsed" -le 4 ]]; then
    pass "mdm-install: target-user HEAD の FIFO race を watchdog で拒否"
  else
    fail "mdm-install: target-user HEAD の FIFO race が bounded でない"
  fi
  rm -f "$_head_fifo_path"; rm -rf "$_head_fifo_tmp"
)

# Bind ENOENT to the current pathname, not to a directory inode renamed out
# from under the walk.  The Python wrapper pauses immediately after the helper
# opens the original directory, so renamex_np can atomically replace the live
# entry with a different real directory that contains the allegedly absent
# target.  The helper must rebind and fail closed.
if _mdm_is_darwin && [[ -x /usr/bin/python3 ]]; then
  (
    _absence_tmp="$(mktemp -d)"
    _absence_root="$_absence_tmp/root"
    _absence_slot="$_absence_root/slot"
    _absence_spare="$_absence_root/spare"
    _absence_wrapper="$_absence_tmp/python-wrapper"
    mkdir -p "$_absence_slot" "$_absence_spare"
    : > "$_absence_spare/target"
    cat > "$_absence_wrapper" <<'WRAPPER'
#!/bin/bash
[[ "$#" -eq 6 && "$1" == -I && "$2" == -B && "$3" == -c ]] || exit 64
exec /usr/bin/python3 -I -B -c '
import os
import sys
import time

root, relative, original_code = sys.argv[1], sys.argv[2], sys.argv[3]
real_open = os.open
ready = os.path.join(root, ".absence-ready")
proceed = os.path.join(root, ".absence-proceed")
blocked = False

def controlled_open(path, flags, *args, **kwargs):
    global blocked
    descriptor = real_open(path, flags, *args, **kwargs)
    if (
        not blocked
        and path == relative.split("/", 1)[0]
        and kwargs.get("dir_fd") is not None
    ):
        blocked = True
        marker = real_open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(marker)
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                raise SystemExit(70)
            time.sleep(0.005)
    return descriptor

os.open = controlled_open
exec(compile(original_code, "<absence-helper>", "exec"))
' "$5" "$6" "$4"
WRAPPER
    chmod 700 "$_absence_wrapper"
    _absence_python_saved="${_MDM_ABSENCE_PYTHON:-}"
    _MDM_ABSENCE_PYTHON="$_absence_wrapper"
    _mdm_path_is_absent_with_real_parents \
      "$_absence_root" slot/target >/dev/null 2>&1 &
    _absence_pid=$!
    _absence_wait=0
    while [[ ! -e "$_absence_root/.absence-ready" && "$_absence_wait" -lt 500 ]]; do
      /bin/sleep 0.01
      _absence_wait=$((_absence_wait + 1))
    done
    _absence_swap_rc=1
    if [[ -e "$_absence_root/.absence-ready" ]]; then
      /usr/bin/python3 -I -B -c '
import ctypes
import sys

renamex_np = ctypes.CDLL(None).renamex_np
renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
renamex_np.restype = ctypes.c_int
raise SystemExit(0 if renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2) == 0 else 1)
' "$_absence_slot" "$_absence_spare" && _absence_swap_rc=0
    fi
    : > "$_absence_root/.absence-proceed"
    _absence_rc=0
    wait "$_absence_pid" || _absence_rc=$?
    _MDM_ABSENCE_PYTHON="$_absence_python_saved"
    if [[ "$_absence_swap_rc" -ne 0 ]]; then
      skip "mdm-install: absent path is rebound after a real-parent swap" \
        "renamex_np fixture unavailable"
    elif [[ "$_absence_rc" -ne 0 && -f "$_absence_slot/target" ]]; then
      pass "mdm-install: absent path is rebound after a real-parent swap"
    else
      fail "mdm-install: renamed-away parent produced false absence (rc=$_absence_rc)"
    fi
    rm -rf "$_absence_tmp"
  )
else
  skip "mdm-install: absent path is rebound after a real-parent swap" \
    "Darwin renamex_np fixture only"
fi

# 実在するローカルアカウント（dscl 実在確認）かつ UID >= 501 を要求。
# テストは MDM_DSCL_UID_OVERRIDE で UID をモックする。
(
  export KIT_MDM_TARGET_USER="jane" MDM_DSCL_UID_OVERRIDE=501
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "jane" ]]; then
    pass "mdm-install: KIT_MDM_TARGET_USER が優先される"
  else
    fail "mdm-install: KIT_MDM_TARGET_USER 優先が効かない (got '$out')"
  fi
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="alice" MDM_DSCL_UID_OVERRIDE=502   # テスト用フック
  if out="$(mdm_resolve_target_user 2>/dev/null)" && [[ "$out" == "alice" ]]; then
    pass "mdm-install: コンソールユーザーにフォールバック"
  else
    fail "mdm-install: コンソールユーザー解決失敗 (got '$out')"
  fi
)
# UID < 501（システムアカウント）は明示指定でも拒否（最終レビュー High#8）
(
  export KIT_MDM_TARGET_USER="svcaccount" MDM_DSCL_UID_OVERRIDE=89
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "UID<501 は exit USER" \
    && pass "mdm-install: UID<501 のシステムアカウントを拒否" \
    || fail "mdm-install: UID<501 を拒否すべき (got $_rc)"
)
# 実在しないユーザー（dscl 解決不能 = UID 空）は拒否
(
  export KIT_MDM_TARGET_USER="mdm-no-such-user-x"
  unset MDM_DSCL_UID_OVERRIDE
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "実在しないユーザーは exit USER" \
    && pass "mdm-install: 実在しないユーザーを拒否" \
    || fail "mdm-install: 実在しないユーザーを拒否すべき (got $_rc)"
)
# username 文字種違反は拒否（injection/パス操作防止）
(
  export KIT_MDM_TARGET_USER='bad;user' MDM_DSCL_UID_OVERRIDE=501
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "文字種違反は exit USER" \
    && pass "mdm-install: username 文字種違反を拒否" \
    || fail "mdm-install: username 文字種違反を拒否すべき (got $_rc)"
)
(
  unset KIT_MDM_TARGET_USER
  export MDM_CONSOLE_USER_OVERRIDE="root"     # 無効ユーザー
  # NOTE: 関数呼び出しを裸のステートメントとして書き $? を後で参照すると、
  # 失敗時(20)に継承された set -e でこのサブシェルが assert 行の手前で
  # 即終了し、外側の test runner (set -euo pipefail 下で source) まで
  # 停止する。`|| _rc=$?` で明示的に捕捉して errexit を回避する。
  _rc=0
  mdm_resolve_target_user >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "root は無効ユーザーで exit USER" \
    && pass "mdm-install: root/システムユーザーを拒否" \
    || fail "mdm-install: root を拒否すべき"
)

# ── home 検証（モック）────────────────────────────────────
_tmpd="$(mktemp -d)"
# macOS では mktemp -d が /var/... (実体は /private/var/... へのシンボリックリンク)
# を返すため、実装側の canonical 化 (cd && pwd -P) と比較する前に _tmpd 自体も
# 正規化しておかないと期待値がシンボリックリンク経由のパスのままズレる。
_tmpd="$(cd "$_tmpd" && pwd -P)"
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
  _rc=0
  mdm_validate_user_home "jane" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "存在しない home は exit USER" \
    && pass "mdm-install: 存在しない home を拒否" \
    || fail "mdm-install: 存在しない home を拒否すべき"
)
(
  ln -s "$_tmpd/Users" "$_tmpd/home-link"
  export MDM_DSCL_HOME_OVERRIDE="$_tmpd/home-link/jane"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  _rc=0
  mdm_validate_user_home "jane" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "祖先 symlink の home は exit USER" \
    && pass "mdm-install: 祖先 symlink を含む home を拒否" \
    || fail "mdm-install: 祖先 symlink の home を拒否すべき"
)
(
  export MDM_DSCL_HOME_OVERRIDE="$_tmpd/Users/../Users/jane"
  export MDM_VALIDATE_HOME_SKIP_OWNER=1
  _rc=0
  mdm_validate_user_home "jane" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_USER" "$_rc" "非canonical home は exit USER" \
    && pass "mdm-install: .. を含む非canonical home を拒否" \
    || fail "mdm-install: 非canonical home を拒否すべき"
)
rm -rf "$_tmpd"

# ── CLT marker の安全な作成（R2-High: /tmp 固定パスの symlink 追随排除）──
(
  _mk_tmpd="$(mktemp -d)"
  printf 'victim\n' > "$_mk_tmpd/victim"
  export MDM_CLT_MARKER_OVERRIDE="$_mk_tmpd/marker"
  ln -s "$_mk_tmpd/victim" "$MDM_CLT_MARKER_OVERRIDE"
  _rc=0
  _mdm_create_clt_marker >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && ! -L "$MDM_CLT_MARKER_OVERRIDE" && -f "$MDM_CLT_MARKER_OVERRIDE" ]] \
     && [[ "$(cat "$_mk_tmpd/victim")" == "victim" ]]; then
    pass "mdm-install: CLT marker が先置き symlink を辿らず実体作成される"
  else
    fail "mdm-install: CLT marker 作成が symlink を辿る/失敗する (rc=$_rc)"
  fi
  rm -rf "$_mk_tmpd"
)
(
  _mk_tmpd="$(mktemp -d)"
  export MDM_CLT_MARKER_OVERRIDE="$_mk_tmpd/marker"
  _rc=0
  _mdm_create_clt_marker >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 && -f "$MDM_CLT_MARKER_OVERRIDE" ]] \
    && pass "mdm-install: CLT marker の通常作成が成功する" \
    || fail "mdm-install: CLT marker の通常作成に失敗 (rc=$_rc)"
  rm -rf "$_mk_tmpd"
)
(
  _cleanup_tmp="$(mktemp -d)"
  export MDM_EUID_OVERRIDE=501 TMPDIR="$_cleanup_tmp"
  export MDM_BREW_PLIST_OVERRIDE="$_cleanup_tmp/homebrew.plist"
  export MDM_CLT_MARKER_OVERRIDE="$_cleanup_tmp/clt.marker"
  _MDM_ACTIVE_BREW_PKG="$_cleanup_tmp/mdm-homebrew-pkg.fixture"
  _MDM_ACTIVE_BREW_PLIST="$MDM_BREW_PLIST_OVERRIDE"
  _MDM_ACTIVE_CLT_MARKER="$MDM_CLT_MARKER_OVERRIDE"
  : > "$_MDM_ACTIVE_BREW_PKG"; : > "$_MDM_ACTIVE_BREW_PLIST"; : > "$_MDM_ACTIVE_CLT_MARKER"
  _mdm_arm_transient_cleanup
  _mdm_cleanup_transient_checkouts
  if [[ ! -e "$_cleanup_tmp/mdm-homebrew-pkg.fixture" \
    && ! -e "$MDM_BREW_PLIST_OVERRIDE" && ! -e "$MDM_CLT_MARKER_OVERRIDE" ]] \
    && [[ -z "$_MDM_ACTIVE_BREW_PKG$_MDM_ACTIVE_BREW_PLIST$_MDM_ACTIVE_CLT_MARKER" ]]; then
    pass "mdm-install: pkg/plist/CLT marker を統一 EXIT/INT/TERM cleanup"
  else
    fail "mdm-install: prerequisite 一時 artifact cleanup が不完全"
  fi
  rm -rf "$_cleanup_tmp"
)

# ── 前提方針判定 ─────────────────────────────────────────
(
  _mdm_clt_present() { return 1; }
  mdm_log() { :; }
  _dry_prereq_rc=0
  _mdm_check_dryrun_prerequisites || _dry_prereq_rc=$?
  if [[ "$_dry_prereq_rc" -eq "$MDM_EXIT_PREREQ" ]]; then
    pass "mdm-install: root/non-root dry-run は CLT 不足を exit 10 で報告"
  else
    fail "mdm-install: dry-run CLT 不足の終了コードが不正 (got $_dry_prereq_rc)"
  fi
)
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
( export MDM_BREW_PRESENT_OVERRIDE=0 KIT_MDM_PREREQ_MODE=fail
  out="$(mdm_prereq_plan 2>/dev/null)"
  [[ "$out" == "fail" ]] && pass "mdm-install: PREREQ_MODE=fail は不足時 fail" || fail "mdm-install: fail mode 期待 (got '$out')" )
( export MDM_BREW_PRESENT_OVERRIDE=1 KIT_MDM_PREREQ_MODE=auto
  out="$(mdm_prereq_plan false 2>/dev/null)"
  [[ "$out" == "bootstrap" ]] && pass "mdm-install: 対象ユーザーで非writableな brew は bootstrap" || fail "mdm-install: target unusable brew は bootstrap 期待 (got '$out')" )
(
  _brew_tmp="$(mktemp -d)"
  _mdm_brew_present() { return 0; }
  _mdm_resolve_brew_pkg_url() { : > "$_brew_tmp/pkg-resolution-called"; return 1; }
  if ! _mdm_bootstrap_homebrew jane >/dev/null 2>&1 \
    && [[ -e "$_brew_tmp/pkg-resolution-called" ]]; then
    pass "mdm-install: unusableな既存brewにも公式pkg再適用を試行"
  else
    fail "mdm-install: 既存brewの存在だけでpkg再適用をskip"
  fi
  rm -rf "$_brew_tmp"
)
(
  _MDM_TEST_MODE=0
  if _mdm_root_value KIT_MDM_PREREQ_MODE skip >/dev/null 2>&1; then
    fail "mdm-install: production parser が PREREQ_MODE=skip を許可"
  else
    pass "mdm-install: production parser は PREREQ_MODE=skip を拒否"
  fi
)
(
  _mdm_exec_as_user() {
    [[ "$1" == 501 && "$2" == jane && "$3" == /Users/jane \
      && "$4" == /bin/bash && "$5" == --noprofile && "$6" == --norc \
      && "$7" == -c && "$8" == *'/opt/homebrew/bin/brew'* \
      && "$8" == *'-w "$_prefix"'* ]]
  }
  if _mdm_brew_usable_for_user 501 jane /Users/jane; then
    pass "mdm-install: brew usability は対象ユーザーの clean shell で検証"
  else
    fail "mdm-install: brew usability の降格 argv が不正"
  fi
)

# ── 降格 argv 構築（グローバル配列 MDM_DROP_ARGV へ直接構築。最終レビュー High#4）──
# 旧実装の「改行区切り stdout → read -r で配列化」は、改行を含む値（env 由来
# EDITOR_CHOICE 等）で env のコマンド位置に任意コマンドを注入できたため廃止。
(
  export PROFILE="standard" LANGUAGE="ja" KIT_MDM_GIT_REF="main"
  export KIT_MDM_PREREQ_MODE="fail"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh --non-interactive 2>/dev/null \
    || fail "mdm-install: mdm_build_drop_argv が失敗した"
  [[ "${MDM_DROP_ARGV[0]}" == "/usr/bin/env" && "${MDM_DROP_ARGV[1]}" == "-i" ]] \
    && pass "mdm-install: /usr/bin/env -i を絶対パスで先頭に置く" \
    || fail "mdm-install: env -i が絶対パスで先頭に無い (got '${MDM_DROP_ARGV[0]}' '${MDM_DROP_ARGV[1]:-}')"
  _has() { local _e; for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == "$1" ]] && return 0; done; return 1; }
  _has 'HOME=/Users/jane' && pass "mdm-install: HOME を固定" || fail "mdm-install: HOME 固定なし"
  _has 'KIT_MDM_MANAGED=true' && pass "mdm-install: KIT_MDM_MANAGED を注入" || fail "mdm-install: KIT_MDM_MANAGED 注入なし（update 復元で MDM 設定が巻き戻る）"
  _has 'USER=jane' && pass "mdm-install: USER を固定" || fail "mdm-install: USER 固定なし"
  _has 'PROFILE=standard' && pass "mdm-install: PROFILE を伝搬" || fail "mdm-install: PROFILE 伝搬なし"
  _has 'LANGUAGE=ja' && pass "mdm-install: LANGUAGE を伝搬" || fail "mdm-install: LANGUAGE 伝搬なし"
  _has 'KIT_MDM_PREREQ_MODE=fail' \
    && pass "mdm-install: 正規化済みPREREQ_MODEを対象ユーザーへ伝搬" \
    || fail "mdm-install: PREREQ_MODE の対象ユーザー伝搬なし"
  # 実行コマンドは呼び出し側指定の位置に単一要素で並ぶ
  _has '/bin/bash' && _has '/path/to/setup.sh' && _has '--non-interactive' \
    && pass "mdm-install: 実行コマンドと引数が argv に含まれる" \
    || fail "mdm-install: 実行コマンド/引数が argv に無い"
)

(
  _mdm_run_root_user_phase() { return "$MDM_EXIT_PREREQ"; }
  _phase_rc=0
  _mdm_run_user_phase 0 jane /Users/jane >/dev/null 2>&1 || _phase_rc=$?
  if [[ "$_phase_rc" -eq "$MDM_EXIT_PREREQ" ]]; then
    pass "mdm-install: root user phase は setup 前提不足の exit 10 を保持"
  else
    fail "mdm-install: root user phase が exit 10 を変換 (got $_phase_rc)"
  fi
)

(
  _phase_tmp="$(mktemp -d)"
  _phase_user="$(/usr/bin/id -un)"
  _mdm_root_ref_allowed() { return 0; }
  _mdm_prepare_authoritative_checkout() {
    _MDM_AUTH_CHECKOUT="$_phase_tmp/authoritative"
    MDM_RCPT_RESOLVED_SHA=0123456789abcdef0123456789abcdef01234567
    return 0
  }
  _mdm_exec_as_user() { return "$MDM_EXIT_PREREQ"; }
  mdm_log() { printf '%s\n' "$*" >> "$_phase_tmp/wrapper.log"; }
  export KIT_MDM_DRY_RUN=true KIT_MDM_GIT_REF=main KIT_MDM_INSTALL_CLAUDE_CLI=false
  _phase_rc=0
  _mdm_run_root_user_phase "$_phase_user" "$_phase_tmp/home" >/dev/null 2>&1 || _phase_rc=$?
  if [[ "$_phase_rc" -eq "$MDM_EXIT_PREREQ" ]] \
    && grep -q 'setup.sh の実行に失敗 (exit=10)' "$_phase_tmp/wrapper.log"; then
    pass "mdm-install: authoritative setup の exit 10 を root user phase が保持"
  else
    fail "mdm-install: authoritative setup の exit 10 が失われた (got $_phase_rc)"
  fi
  rm -rf "$_phase_tmp"
)

(
  if [[ "$(_mdm_user_phase_exit_code "$MDM_EXIT_PREREQ" false)" == "$MDM_EXIT_PREREQ" \
    && "$(_mdm_user_phase_exit_code "$MDM_EXIT_PREREQ" true)" == "$MDM_EXIT_PREREQ" \
    && "$(_mdm_user_phase_exit_code 1 false)" == "$MDM_EXIT_SETUP" \
    && "$(_mdm_user_phase_exit_code "$MDM_EXIT_CONFIG" true)" == "$MDM_EXIT_CONFIG" ]]; then
    pass "mdm-install: main exit mapping は前提不足10を保持し他setup失敗を30化"
  else
    fail "mdm-install: main user-phase exit mapping が不正"
  fi
)
(
  unset PROFILE
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do case "$_e" in PROFILE=*) _found=1 ;; esac; done
  if [[ "$_found" -eq 1 ]]; then
    fail "mdm-install: 未設定の PROFILE は渡さない"
  else
    pass "mdm-install: 未設定変数は伝搬しない"
  fi
)
# 注入回帰: 改行を含む passthrough 値は拒否する（env のコマンド位置注入防止）
(
  export EDITOR_CHOICE=$'none\n/usr/bin/id'
  _rc=0
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: 改行を含む passthrough 値を拒否"
  else
    fail "mdm-install: 改行を含む passthrough 値が argv に混入し得る（注入回帰）"
  fi
)
# 空白を含む値は単一の argv 要素のまま保持される（word splitting されない）
(
  export EDITOR_CHOICE='none plus extra'
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null \
    || fail "mdm-install: 空白入り値で失敗した"
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'EDITOR_CHOICE=none plus extra' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: 空白入り値が単一要素で保持される" \
    || fail "mdm-install: 空白入り値が単一要素で保持されない"
)

# root authoritative setup だけに ephemeral safe.directory を注入する。
(
  export PROFILE=standard LANGUAGE=en
  _MDM_GIT_SAFE_DIRECTORY=/private/tmp/claude-kit-mdm-auth.fixture
  mdm_build_drop_argv 501 jane /Users/jane \
    /bin/bash "$_MDM_GIT_SAFE_DIRECTORY/setup.sh" --non-interactive
  _safe_count=0; _safe_key=0; _safe_value=0; _auth_setup=0; _persistent_setup=0
  for _safe_arg in "${MDM_DROP_ARGV[@]}"; do
    [[ "$_safe_arg" == GIT_CONFIG_COUNT=1 ]] && _safe_count=$((_safe_count + 1))
    [[ "$_safe_arg" == GIT_CONFIG_KEY_0=safe.directory ]] && _safe_key=1
    [[ "$_safe_arg" == "GIT_CONFIG_VALUE_0=$_MDM_GIT_SAFE_DIRECTORY" ]] && _safe_value=1
    [[ "$_safe_arg" == "$_MDM_GIT_SAFE_DIRECTORY/setup.sh" ]] && _auth_setup=1
    [[ "$_safe_arg" == /Users/jane/.claude-starter-kit/setup.sh ]] && _persistent_setup=1
  done
  _MDM_GIT_SAFE_DIRECTORY=""
  if [[ "$_safe_count" -eq 1 && "$_safe_key" -eq 1 && "$_safe_value" -eq 1 \
    && "$_auth_setup" -eq 1 && "$_persistent_setup" -eq 0 ]]; then
    pass "mdm-install: env config は authoritative dir だけを safe.directory 化"
  else
    fail "mdm-install: safe.directory/setup authority argv が不正"
  fi
)

# ── LANG マッピング回帰テスト（Task 8 バグ修正）─────────────
# 旧実装は "LANG=${LANGUAGE}_JP.UTF-8" と決め打ちしており、LANGUAGE=en のとき
# 不正ロケール "en_JP.UTF-8" を生成していた。_mdm_lang_to_locale 経由で
# en->en_US.UTF-8 / ja->ja_JP.UTF-8 に正しくマップされることを確認する。
(
  export LANGUAGE="en"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'LANG=en_US.UTF-8' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: LANGUAGE=en は LANG=en_US.UTF-8 にマップ" \
    || fail "mdm-install: LANGUAGE=en の LANG マッピングが不正"
)
(
  export LANGUAGE="ja"
  mdm_build_drop_argv 501 jane /Users/jane /bin/bash /path/to/setup.sh 2>/dev/null || true
  _found=0
  for _e in "${MDM_DROP_ARGV[@]}"; do [[ "$_e" == 'LANG=ja_JP.UTF-8' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: LANGUAGE=ja は LANG=ja_JP.UTF-8 にマップ" \
    || fail "mdm-install: LANGUAGE=ja の LANG マッピングが不正"
)

# ── _mdm_exec_as_user は launchctl/sudo を絶対パスで組み立てる ──
# MDM_EXEC_AS_USER_DRYRUN=1 で実行せず argv を表示のみ（表示は再パースされない）。
(
  export MDM_EXEC_AS_USER_DRYRUN=1
  out="$(_mdm_exec_as_user 501 jane /Users/jane /bin/bash /path/to/setup.sh --non-interactive 2>/dev/null)"
  printf '%s' "$out" | head -1 | grep -q '^/bin/launchctl$' \
    && pass "mdm-install: launchctl を絶対パスで起動" \
    || fail "mdm-install: launchctl が絶対パスでない (out: $(printf '%s' "$out" | head -1))"
  printf '%s\n' "$out" | grep -q '^/usr/bin/sudo$' \
    && pass "mdm-install: sudo を絶対パスで起動" \
    || fail "mdm-install: sudo が絶対パスでない"
)

# ══ CRITICAL 回帰（最終レビュー #2）: root は対象ユーザー所有 repo を直接
#    git 操作しない。git は _mdm_git 経由で検証済みユーザーへ降格する ══
(
  # 降格コンテキスト設定時: /usr/bin/git が sudo -u <user> 配下で組み立てられる
  export MDM_EXEC_AS_USER_DRYRUN=1
  _MDM_GIT_DROP_UID=501; _MDM_GIT_DROP_USER=jane; _MDM_GIT_DROP_HOME=/Users/jane
  # NOTE: 未実装時（関数未定義 = 127）に set -e でサブシェルごと即死しないよう捕捉
  out="$(_mdm_git -C /Users/jane/.claude-starter-kit fetch origin main 2>/dev/null)" || true
  printf '%s\n' "$out" | grep -q '^/usr/bin/sudo$' \
    && printf '%s\n' "$out" | grep -q '^/usr/bin/git$' \
    && pass "mdm-install: _mdm_git が root 時に降格 argv で git を実行" \
    || fail "mdm-install: _mdm_git の降格が効いていない (out: $out)"
  printf '%s\n' "$out" | grep -q '^-u$' && printf '%s\n' "$out" | grep -q '^jane$' \
    && pass "mdm-install: _mdm_git の降格先が対象ユーザー" \
    || fail "mdm-install: _mdm_git の降格先が不正"
)
(
  # 降格コンテキスト未設定時（非 root）: 直接実行される
  _MDM_GIT_DROP_UID=""
  out="$(_mdm_git --version 2>/dev/null)" || true
  printf '%s' "$out" | grep -q 'git version' \
    && pass "mdm-install: _mdm_git が非 root 時は直接実行" \
    || fail "mdm-install: _mdm_git の直接実行が失敗 (out: $out)"
)
# chown -R は撤去済み（clone を初回からユーザー実行するため不要になった）
if grep -q 'chown -R' "$PROJECT_DIR/mdm/install-mdm.sh"; then
  fail "mdm-install: chown -R が残存している（root の任意 repo chown 経路）"
else
  pass "mdm-install: chown -R が撤去されている"
fi

# ── KIT_MDM_INSTALL_DIR は対象ユーザーの canonical home 配下に制約 ──
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_fakehome="$_tmpd/Users/jane"; mkdir -p "$_fakehome"
(
  export KIT_MDM_INSTALL_DIR="$_tmpd/outside-home"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 0 "$(/usr/bin/id -un)" "$_fakehome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "home 外 install_dir は exit 50" \
    && pass "mdm-install: home 外の KIT_MDM_INSTALL_DIR を拒否" \
    || fail "mdm-install: home 外の KIT_MDM_INSTALL_DIR を拒否すべき (got $_rc)"
)
(
  export KIT_MDM_INSTALL_DIR="$_fakehome/../escape"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 0 "$(/usr/bin/id -un)" "$_fakehome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" ".. 含みの install_dir は exit 50" \
    && pass "mdm-install: .. を含む KIT_MDM_INSTALL_DIR を拒否" \
    || fail "mdm-install: .. を含む KIT_MDM_INSTALL_DIR を拒否すべき (got $_rc)"
)
(
  # home そのもの（配下でなく一致）も拒否
  export KIT_MDM_INSTALL_DIR="$_fakehome"
  export MDM_KIT_REPO_URL_OVERRIDE="$_tmpd/no-such-repo"
  _rc=0
  _mdm_run_user_phase 0 "$(/usr/bin/id -un)" "$_fakehome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "home 自体は exit 50" \
    && pass "mdm-install: home 自体を install_dir にするのを拒否" \
    || fail "mdm-install: home 自体の install_dir を拒否すべき (got $_rc)"
)
rm -rf "$_tmpd"

# ── Homebrew pkg URL 解決（GitHub API レスポンスのモック。jq 非依存 grep/sed）──
_brew_tmpd="$(mktemp -d)"
_brew_fixture_ok="$_brew_tmpd/release-ok.json"
cat > "$_brew_fixture_ok" <<'EOF'
{
  "tag_name": "4.6.15",
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg.sha256",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg.sha256"
    },
    {
      "name": "Homebrew-4.6.15.pkg",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_ok"
  out="$(_mdm_resolve_brew_pkg_url 2>/dev/null)"
  if [[ "$out" == "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg" ]]; then
    pass "mdm-install: brew pkg URL を .pkg アセットから解決"
  else
    fail "mdm-install: brew pkg URL 解決が不正 (got '$out')"
  fi
)

_brew_fixture_nopkg="$_brew_tmpd/release-nopkg.json"
cat > "$_brew_fixture_nopkg" <<'EOF'
{
  "tag_name": "4.6.15",
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg.sha256",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/4.6.15/Homebrew-4.6.15.pkg.sha256"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_nopkg"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: .pkg アセットが無い場合は失敗を返す"
  else
    fail "mdm-install: .pkg アセットが無いのに成功してしまう"
  fi
)

(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_tmpd/does-not-exist.json"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: JSON 取得不可（空応答）時は失敗を返す"
  else
    fail "mdm-install: 空応答なのに成功してしまう"
  fi
)

# ══ Homebrew 導入経路の固定（最終レビュー High#7）══

# URL は https://github.com/Homebrew/brew/releases/download/ 配下の
# Homebrew*.pkg のみ許可（API 応答が改ざん/汚染されても他ホストへ飛ばない）
_brew_fixture_evil="$_brew_tmpd/release-evil.json"
cat > "$_brew_fixture_evil" <<'EOF'
{
  "assets": [
    {
      "name": "Homebrew-4.6.15.pkg",
      "browser_download_url": "https://evil.example.com/Homebrew-4.6.15.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_evil"
  _rc=0
  _mdm_resolve_brew_pkg_url >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: 公式リリース URL 以外の .pkg を拒否"
  else
    fail "mdm-install: 非公式ホストの .pkg URL を許容してしまう"
  fi
)
# 現行リリースの実アセット名（バージョンなし Homebrew.pkg・6.0.11 で実測）も許可
_brew_fixture_new="$_brew_tmpd/release-new.json"
cat > "$_brew_fixture_new" <<'EOF'
{
  "assets": [
    {
      "name": "Homebrew.pkg",
      "browser_download_url": "https://github.com/Homebrew/brew/releases/download/6.0.11/Homebrew.pkg"
    }
  ]
}
EOF
(
  export MDM_BREW_RELEASES_JSON_OVERRIDE="$_brew_fixture_new"
  out="$(_mdm_resolve_brew_pkg_url 2>/dev/null)" || true
  [[ "$out" == "https://github.com/Homebrew/brew/releases/download/6.0.11/Homebrew.pkg" ]] \
    && pass "mdm-install: バージョンなしアセット名 Homebrew.pkg を許容" \
    || fail "mdm-install: 現行アセット名 Homebrew.pkg が拒否される (got '$out')"
)

# 署名検証は Homebrew の Team ID (927JGANW46) に pin する
# （2026-07-17 に release 6.0.11 の pkgutil --check-signature で実測:
#  "Developer ID Installer: Patrick Linnane (927JGANW46)" + notarized）
(
  _sig_ok='Package "Homebrew.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Notarization: trusted by the Apple notary service
   Certificate Chain:
    1. Developer ID Installer: Patrick Linnane (927JGANW46)'
  _rc=0
  _mdm_check_brew_signature_output "$_sig_ok" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 ]] \
    && pass "mdm-install: 正規 Team ID の署名を許容" \
    || fail "mdm-install: 正規 Team ID の署名が拒否される"
)
(
  _sig_evil='Package "Homebrew.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Certificate Chain:
    1. Developer ID Installer: Evil Corp (EVIL123456)'
  _rc=0
  _mdm_check_brew_signature_output "$_sig_evil" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 ]] \
    && pass "mdm-install: 別 Team ID の Developer ID 署名を拒否" \
    || fail "mdm-install: 別 Team ID の署名を許容してしまう（pin 不成立）"
)

# HOMEBREW_PKG_USER plist は symlink を辿らず root 所有 0600 で安全に作成する
# （Homebrew 側 homebrew-package-user は「非symlink 通常ファイル・root 所有・
#  mode 0600・ACL 無し」の場合のみ plist を尊重する — brew 実装で確認済み）
(
  _pl_tmpd="$(mktemp -d)"
  _victim="$_pl_tmpd/victim-file"
  printf 'original\n' > "$_victim"
  export MDM_BREW_PLIST_OVERRIDE="$_pl_tmpd/pkg_user.plist"
  ln -s "$_victim" "$MDM_BREW_PLIST_OVERRIDE"
  _rc=0
  _mdm_write_brew_pkg_user_plist "jane" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -eq 0 && ! -L "$MDM_BREW_PLIST_OVERRIDE" && -f "$MDM_BREW_PLIST_OVERRIDE" ]] \
     && [[ "$(cat "$_victim")" == "original" ]]; then
    pass "mdm-install: 先回り symlink を辿らず plist を作成（標的ファイル無傷）"
  else
    fail "mdm-install: plist 作成が symlink を辿る/失敗する (rc=$_rc)"
  fi
  grep -q '<string>jane</string>' "$MDM_BREW_PLIST_OVERRIDE" 2>/dev/null \
    && pass "mdm-install: plist に対象ユーザーが記録される" \
    || fail "mdm-install: plist の内容が不正"
  _mode="$(test_stat_mode "$MDM_BREW_PLIST_OVERRIDE")"
  [[ "$_mode" == "600" ]] \
    && pass "mdm-install: plist が mode 600 で作成される（brew 側の受理条件）" \
    || fail "mdm-install: plist の mode が 600 でない (got $_mode)"
  rm -rf "$_pl_tmpd"
)
rm -rf "$_brew_tmpd"

# ── ログ出力先の決定（最終レビュー High#3: 設定確定後に決定・許可プレフィックス制約）──
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_loghome="$_tmpd/Users/jane"; mkdir -p "$_loghome"
(
  # 非 root（ユーザーモード）の既定は ~/Library/Logs 配下
  unset KIT_MDM_LOG_DIR
  MDM_LOG_FILE=""
  _mdm_setup_log_file 501 "$_loghome" 2>/dev/null || fail "mdm-install: ログ既定パスの決定に失敗"
  case "$MDM_LOG_FILE" in
    "$_loghome/Library/Logs/ClaudeCodeStarterKit/install-"*.log)
      pass "mdm-install: ユーザーモードのログ既定が ~/Library/Logs 配下" ;;
    *)
      fail "mdm-install: ユーザーモードのログ既定が不正 (got '$MDM_LOG_FILE')" ;;
  esac
)
(
  # root の既定は /Library/Logs 配下（実 I/O を伴わない dir 決定のみ検証。
  # 実ファイル準備は root 権限が要り非 root テスト環境では走らせられない）
  unset KIT_MDM_LOG_DIR
  out="$(_mdm_log_dir_for 0 "$_loghome" 2>/dev/null)" || fail "mdm-install: root ログ dir 決定に失敗"
  [[ "$out" == "/Library/Logs/ClaudeCodeStarterKit" ]] \
    && pass "mdm-install: root のログ既定が /Library/Logs 配下" \
    || fail "mdm-install: root のログ既定が不正 (got '$out')"
)
(
  # KIT_MDM_LOG_DIR の明示指定（許可プレフィックス配下）は尊重される
  export KIT_MDM_LOG_DIR="$_loghome/Library/Logs/CustomDir"
  MDM_LOG_FILE=""
  _mdm_setup_log_file 501 "$_loghome" 2>/dev/null || fail "mdm-install: LOG_DIR 明示指定の決定に失敗"
  case "$MDM_LOG_FILE" in
    "$_loghome/Library/Logs/CustomDir/install-"*.log)
      pass "mdm-install: KIT_MDM_LOG_DIR 明示指定がログパスに反映される" ;;
    *)
      fail "mdm-install: KIT_MDM_LOG_DIR 明示指定が反映されない (got '$MDM_LOG_FILE')" ;;
  esac
)
(
  # 許可プレフィックス外の KIT_MDM_LOG_DIR は exit 50（root 書込先の制約）
  export KIT_MDM_LOG_DIR="/etc/evil-logs"
  _rc=0
  _mdm_setup_log_file 0 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "許可外 LOG_DIR は exit 50" \
    && pass "mdm-install: 許可プレフィックス外の LOG_DIR を拒否" \
    || fail "mdm-install: 許可外 LOG_DIR を拒否すべき (got $_rc)"
)
(
  # root はユーザー home 配下の LOG_DIR を指定できない（ユーザーが植えた
  # symlink を root が辿って任意 append する経路を塞ぐ）
  export KIT_MDM_LOG_DIR="$_loghome/Library/Logs/UserControlled"
  _rc=0
  _mdm_setup_log_file 0 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "root は home 配下 LOG_DIR 不可" \
    && pass "mdm-install: root 時にユーザー home 配下の LOG_DIR を拒否" \
    || fail "mdm-install: root 時の home 配下 LOG_DIR を拒否すべき (got $_rc)"
)
(
  # 非 root はシステム領域 /Library/Logs を指定できない（書けないだけでなく契約外）
  export KIT_MDM_LOG_DIR="/Library/Logs/ClaudeCodeStarterKit"
  _rc=0
  _mdm_setup_log_file 501 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "非rootはシステム LOG_DIR 不可" \
    && pass "mdm-install: 非 root 時にシステム領域の LOG_DIR を拒否" \
    || fail "mdm-install: 非 root 時のシステム LOG_DIR を拒否すべき (got $_rc)"
)
# ── ログファイルは umask 非依存で実体作成され、fd を保持する（R3/R4-High）──
(
  umask 000
  unset KIT_MDM_LOG_DIR
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _mdm_setup_log_file 501 "$_loghome" 2>/dev/null || fail "mdm-install: ログ準備に失敗"
  _dmode="$(test_stat_mode "$(dirname "$MDM_LOG_FILE")")"
  [[ "$_dmode" == "755" ]] \
    && pass "mdm-install: umask 000 でもログ dir は 755" \
    || fail "mdm-install: umask 000 でログ dir が ${_dmode}"
  [[ -f "$MDM_LOG_FILE" && ! -L "$MDM_LOG_FILE" ]] \
    && pass "mdm-install: ログファイルが実体で作成される" \
    || fail "mdm-install: ログファイルが実体作成されない"
  _fmode="$(test_stat_mode "$MDM_LOG_FILE")"
  [[ "$_fmode" == "644" ]] \
    && pass "mdm-install: umask 000 でもログファイルは 644" \
    || fail "mdm-install: umask 000 でログファイルが ${_fmode}"
  [[ "$MDM_LOG_FD_OPEN" == "1" ]] \
    && pass "mdm-install: ログは保持 fd 経由（MDM_LOG_FD_OPEN=1）" \
    || fail "mdm-install: ログ fd が保持されていない"
  exec 7>&- 2>/dev/null || true
  MDM_LOG_FD_OPEN=0
)
(
  # ログパスに symlink dir を指定したら拒否（exit 50）
  _evildir="$_loghome/Library/Logs/EvilLink"
  ln -s "/etc" "$_evildir"
  export KIT_MDM_LOG_DIR="$_evildir"
  MDM_LOG_FILE=""
  _rc=0
  _mdm_setup_log_file 501 "$_loghome" >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "symlink のログ dir は exit 50" \
    && pass "mdm-install: symlink のログディレクトリを拒否" \
    || fail "mdm-install: symlink のログディレクトリを拒否すべき (got $_rc)"
)

# ── stderr が open 後も生きている（R5-Medium 回帰: exec ... 2>/dev/null の fd2 汚染）──
(
  _od="$_loghome/Library/Logs/stderrprobe"; mkdir -p "$_od"
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _errf="$(mktemp)"
  (
    exec 2>"$_errf"
    _mdm_open_log_fd "$_od/probe.log"
    printf 'PROBE_AFTER_OPEN\n' >&2
  )
  if grep -q 'PROBE_AFTER_OPEN' "$_errf"; then
    pass "mdm-install: ログ fd open 後も stderr が生きている"
  else
    fail "mdm-install: open 後に stderr が /dev/null へ汚染された（R5-M 回帰）"
  fi
  rm -f "$_errf"
  exec 7>&- 2>/dev/null || true; MDM_LOG_FD_OPEN=0
)

# ── 信頼チェーン検証（R5/R6-High）──
(
  # チェーン中の symlink コンポーネントを拒否（owner 検査は skip して symlink 判定に到達させる）
  _cd="$_tmpd/chain"; mkdir -p "$_cd/Library/Logs"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs"
  ln -s /tmp "$_cd/Library/Logs/app"
  export MDM_LOG_SKIP_OWNER_CHECK=1
  if _mdm_verify_dir_chain "$_cd/Library/Logs/app" "$_cd/Library/Logs"; then
    fail "mdm-install: チェーン中の symlink コンポーネントを許容してしまう"
  else
    pass "mdm-install: チェーン中の symlink コンポーネントを拒否"
  fi
  unset MDM_LOG_SKIP_OWNER_CHECK
)
(
  # owner 不一致（非 root 所有）コンポーネントを拒否（owner 検査有効）
  _cd="$_tmpd/chain-owner"; mkdir -p "$_cd/Library/Logs/app"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs" "$_cd/Library/Logs/app"
  # テスト実行者（非 root）所有なので owner 検査で拒否されるべき
  if _mdm_verify_dir_chain "$_cd/Library/Logs/app" "$_cd/Library/Logs"; then
    fail "mdm-install: 非 root 所有コンポーネントを許容してしまう"
  else
    pass "mdm-install: 非 root 所有コンポーネントを拒否（owner 検査）"
  fi
)
(
  # glob 文字（*）を含むコンポーネントも word splitting/glob 展開で
  # 見逃さず検証する。cwd に glob がマッチするファイルを置き、未クォート
  # 分割なら検証対象がすり替わって symlink を見逃す状況を再現する。
  _cd="$_tmpd/chain-glob"; mkdir -p "$_cd/Library/Logs"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs"
  ln -s /tmp "$_cd/Library/Logs/a*b"
  mkdir -p "$_tmpd/globcwd"; : > "$_tmpd/globcwd/aXb"
  export MDM_LOG_SKIP_OWNER_CHECK=1
  _rc_glob=0
  ( cd "$_tmpd/globcwd" && _mdm_verify_dir_chain "$_cd/Library/Logs/a*b" "$_cd/Library/Logs" ) || _rc_glob=$?
  if [[ "$_rc_glob" -eq 0 ]]; then
    fail "mdm-install: glob 文字を含む symlink コンポーネントを見逃す（迂回可能）"
  else
    pass "mdm-install: glob 文字を含むコンポーネントも正しく検証"
  fi
  unset MDM_LOG_SKIP_OWNER_CHECK
)
(
  # 全コンポーネントが非 symlink（owner 検査は skip して mode のみ）なら許容
  _cd="$_tmpd/chain-ok"; mkdir -p "$_cd/Library/Logs/app"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs" "$_cd/Library/Logs/app"
  export MDM_LOG_SKIP_OWNER_CHECK=1
  if _mdm_verify_dir_chain "$_cd/Library/Logs/app" "$_cd/Library/Logs"; then
    pass "mdm-install: 健全なチェーン（非symlink・755）は許容"
  else
    fail "mdm-install: 健全なチェーンが拒否される"
  fi
  unset MDM_LOG_SKIP_OWNER_CHECK
)
(
  # group/other 書込可のコンポーネントを拒否
  _cd="$_tmpd/chain-writable"; mkdir -p "$_cd/Library/Logs/app"
  chmod 755 "$_cd/Library" "$_cd/Library/Logs"
  chmod 777 "$_cd/Library/Logs/app"
  export MDM_LOG_SKIP_OWNER_CHECK=1
  if _mdm_verify_dir_chain "$_cd/Library/Logs/app" "$_cd/Library/Logs"; then
    fail "mdm-install: 777 コンポーネントを許容してしまう"
  else
    pass "mdm-install: 書込可能コンポーネントを拒否"
  fi
  unset MDM_LOG_SKIP_OWNER_CHECK
)

# ── _mdm_open_log_fd: 既存 regular file は再利用せず別名・symlink は辿らない（R4-High）──
(
  _od="$_loghome/Library/Logs/openfd"; mkdir -p "$_od"
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _mdm_open_log_fd "$_od/install-x.log" 2>/dev/null || fail "mdm-install: open_log_fd 失敗"
  [[ "$MDM_LOG_FILE" == "$_od/install-x.log" && -f "$MDM_LOG_FILE" && ! -L "$MDM_LOG_FILE" ]] \
    && pass "mdm-install: open_log_fd が新規ログを排他作成" \
    || fail "mdm-install: open_log_fd の新規作成が不正 (got '$MDM_LOG_FILE')"
  exec 7>&- 2>/dev/null || true; MDM_LOG_FD_OPEN=0
)
(
  # 攻撃者が予測パスに regular file を先置き → 再利用せず別名を作る
  _od="$_loghome/Library/Logs/openfd2"; mkdir -p "$_od"
  printf 'attacker\n' > "$_od/install-y.log"
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _mdm_open_log_fd "$_od/install-y.log" 2>/dev/null || fail "mdm-install: open_log_fd(既存) 失敗"
  if [[ "$MDM_LOG_FILE" != "$_od/install-y.log" && -f "$MDM_LOG_FILE" ]] \
     && [[ "$(cat "$_od/install-y.log")" == "attacker" ]]; then
    pass "mdm-install: 既存 regular file を再利用せず別名で作成（先置き無視）"
  else
    fail "mdm-install: 既存ファイルを再利用してしまう (got '$MDM_LOG_FILE')"
  fi
  exec 7>&- 2>/dev/null || true; MDM_LOG_FD_OPEN=0
)
(
  # 攻撃者が予測パスに symlink を先置き → 辿らず標的無傷・実体化
  _od="$_loghome/Library/Logs/openfd3"; mkdir -p "$_od"
  printf 'victim\n' > "$_od/victim"
  ln -s "$_od/victim" "$_od/install-z.log"
  MDM_LOG_FILE=""; MDM_LOG_FD_OPEN=0
  _mdm_open_log_fd "$_od/install-z.log" 2>/dev/null || fail "mdm-install: open_log_fd(symlink) 失敗"
  if [[ ! -L "$MDM_LOG_FILE" && -f "$MDM_LOG_FILE" ]] \
     && [[ "$(cat "$_od/victim")" == "victim" ]]; then
    pass "mdm-install: 先置き symlink を辿らず実体化（標的無傷）"
  else
    fail "mdm-install: 先置き symlink を辿る/実体化しない"
  fi
  exec 7>&- 2>/dev/null || true; MDM_LOG_FD_OPEN=0
)
rm -rf "$_tmpd"

# ── MDM 既定値の適用（Ghostty は MDM 既定 off）──────────
# _mdm_root_config_apply と同じ「既存値は上書きしない」優先順位を踏襲する
# ことを確認する: 未設定時のみ false を既定にし、conf/env で明示済みの
# true/false はそのまま維持されなければならない。
(
  unset ENABLE_GHOSTTY_SETUP
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "false" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP 未設定時は既定 false"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP 未設定時の既定が不正 (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)
(
  export ENABLE_GHOSTTY_SETUP=true
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "true" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP=true の明示指定を維持"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP=true の明示指定が上書きされた (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)
(
  export ENABLE_GHOSTTY_SETUP=false
  _mdm_apply_mdm_defaults
  if [[ "$ENABLE_GHOSTTY_SETUP" == "false" ]]; then
    pass "mdm-install: ENABLE_GHOSTTY_SETUP=false の明示指定を維持"
  else
    fail "mdm-install: ENABLE_GHOSTTY_SETUP=false の明示指定が上書きされた (got '$ENABLE_GHOSTTY_SETUP')"
  fi
)

# ══ update 経路 + CLI 無効化の setup.sh 接続（最終レビュー High#5）══

# 既存インストール（対象ユーザーの manifest）検出時は --update を付与
_tmpd="$(mktemp -d)"; _tmpd="$(cd "$_tmpd" && pwd -P)"
_updhome="$_tmpd/Users/jane"
mkdir -p "$_updhome/.claude"
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv "$_updhome" 2>/dev/null || true
  _found=0
  for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == '--update' ]] && _found=1; done
  if [[ "$_found" -eq 1 ]]; then
    fail "mdm-install: manifest 無しなのに --update が付与された"
  else
    pass "mdm-install: manifest 無しでは --update を付けない"
  fi
)
touch "$_updhome/.claude/.starter-kit-manifest.json"
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv "$_updhome" 2>/dev/null || true
  _found=0
  for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == '--update' ]] && _found=1; done
  [[ "$_found" -eq 1 ]] \
    && pass "mdm-install: 既存 manifest 検出で --update を付与" \
    || fail "mdm-install: 既存 manifest 検出でも --update が付かない (argv: ${MDM_SETUP_ARGV[*]})"
)

# root 実行時の CLI 確認は root の PATH を成功扱いにしない
(
  export MDM_EUID_OVERRIDE=0
  _rc=0
  _mdm_cli_present_for_home "$_updhome" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 ]]; then
    pass "mdm-install: root 時は PATH 上の claude を成功扱いにしない"
  else
    fail "mdm-install: root 時に root PATH の claude で成功扱いになる"
  fi
)
(
  export MDM_EUID_OVERRIDE=0
  mkdir -p "$_updhome/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$_updhome/.local/bin/claude"
  chmod +x "$_updhome/.local/bin/claude"
  _rc=0
  _mdm_cli_present_for_home "$_updhome" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 ]] \
    && pass "mdm-install: 対象ユーザーの fake claude を拒否" \
    || fail "mdm-install: 未署名 fake claude を成功扱いにした"
  export MDM_CLAUDE_CLI_TRUST_OVERRIDE=1
  _mdm_cli_present_for_home "$_updhome" \
    && pass "mdm-install: source-only CLI trust override はテスト可能" \
    || fail "mdm-install: source-only CLI trust override が効かない"
)

# Identifier/TeamIdentifier/Authority are display fields, not a trust anchor.
# The verifier must pass an external Apple-anchored Developer ID requirement.
(
  _cli_requirement_log="$_updhome/cli-requirement.log"
  _cli_requirement="$(_mdm_claude_cli_codesign_requirement)"
  _mdm_claude_codesign() {
    if [[ "$1" == --verify ]]; then
      printf '%s\n' "$@" > "$_cli_requirement_log"
      return 0
    fi
    printf '%s\n' \
      'Identifier=com.anthropic.claude-code' \
      'Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)' \
      'TeamIdentifier=Q6L2SF6YDW'
  }
  if _mdm_claude_cli_signature_trusted /dev/null \
    && /usr/bin/grep -Fxq -- '-R' "$_cli_requirement_log" \
    && /usr/bin/grep -Fxq -- "$_cli_requirement" "$_cli_requirement_log" \
    && [[ "$_cli_requirement" == *'anchor apple generic'* ]] \
    && [[ "$_cli_requirement" == *'certificate 1[field.1.2.840.113635.100.6.2.6]'* ]] \
    && [[ "$_cli_requirement" == *'certificate leaf[field.1.2.840.113635.100.6.1.13]'* ]]; then
    pass "mdm-install: Claude CLI は明示 Apple Developer ID requirement で検証"
  else
    fail "mdm-install: Claude CLI codesign に外部 trust requirement がない"
  fi
)
(
  _spoof_details=$'Identifier=com.anthropic.claude-code\nAuthority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)\nTeamIdentifier=Q6L2SF6YDW'
  _mdm_claude_codesign() {
    [[ "$1" == --verify ]] && return 3
    printf '%s\n' "$_spoof_details"
  }
  if [[ "$_spoof_details" == *'TeamIdentifier=Q6L2SF6YDW'* ]] \
    && ! _mdm_claude_cli_signature_trusted /dev/null; then
    pass "mdm-install: 表示文字列を模倣した自己署名 CLI を拒否"
  else
    fail "mdm-install: 表示文字列だけで自己署名 CLI を許容し得る"
  fi
)
rm -rf "$_tmpd"

# setup.sh: KIT_MDM_INSTALL_CLAUDE_CLI=false で CLI 導入をスキップ。
# 隔離 bash プロセスで setup.sh を source し、導入関数をスタブして挙動を検証する。
_setup_cli_probe() {  # $1 = KIT_MDM_INSTALL_CLAUDE_CLI の値（"__unset__" で未設定）
  PROJECT_DIR="$PROJECT_DIR" KIT_CLI_VAL="$1" bash -c '
    source "$PROJECT_DIR/setup.sh"
    set +u   # STR_*（i18n）はスタブ実行では未ロードのため
    info(){ :; }; ok(){ :; }; warn(){ :; }
    _need_claude_cli_install(){ return 0; }
    _install_claude_cli(){ echo INSTALL_CALLED; }
    _add_to_path_now_and_persist(){ :; }
    if [[ "$KIT_CLI_VAL" != "__unset__" ]]; then
      export KIT_MDM_INSTALL_CLAUDE_CLI="$KIT_CLI_VAL"
    fi
    install_claude_cli_if_needed
  ' 2>/dev/null
}
(
  out="$(_setup_cli_probe false)" || true
  if printf '%s' "$out" | grep -q 'INSTALL_CALLED'; then
    fail "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI=false でも CLI 導入が実行される"
  else
    pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI=false で CLI 導入をスキップ"
  fi
)
(
  out="$(_setup_cli_probe __unset__)" || true
  printf '%s' "$out" | grep -q 'INSTALL_CALLED' \
    && pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI 未設定では従来どおり導入" \
    || fail "mdm-install: 未設定なのに CLI 導入がスキップされた"
)
(
  # 不正値は fail-closed（導入する）— 検証済みでない値で機能を黙って無効化しない
  out="$(_setup_cli_probe garbage)" || true
  printf '%s' "$out" | grep -q 'INSTALL_CALLED' \
    && pass "mdm-install: KIT_MDM_INSTALL_CLAUDE_CLI 不正値は fail-closed で導入" \
    || fail "mdm-install: 不正値で CLI 導入がスキップされた（fail-open）"
)

# ── setup.sh 引数の組み立て（グローバル配列 MDM_SETUP_ARGV へ直接構築）──
# 実 setup.sh 実行は副作用があるため、argv 組み立て (mdm_build_setup_argv)
# のみを検証する。
_setup_argv_has() { local _e; for _e in "${MDM_SETUP_ARGV[@]}"; do [[ "$_e" == "$1" ]] && return 0; done; return 1; }
(
  unset KIT_MDM_DRY_RUN
  mdm_build_setup_argv 2>/dev/null
  _setup_argv_has '--non-interactive' \
    && pass "mdm-install: setup.sh argv に --non-interactive を含む" \
    || fail "mdm-install: setup.sh argv に --non-interactive が無い (argv: ${MDM_SETUP_ARGV[*]})"
  if _setup_argv_has '--dry-run'; then
    fail "mdm-install: KIT_MDM_DRY_RUN 未設定なのに --dry-run が含まれる"
  else
    pass "mdm-install: KIT_MDM_DRY_RUN 未設定時は --dry-run を含まない"
  fi
)
(
  export KIT_MDM_DRY_RUN=true
  mdm_build_setup_argv 2>/dev/null
  _setup_argv_has '--dry-run' \
    && pass "mdm-install: KIT_MDM_DRY_RUN=true で --dry-run を配線" \
    || fail "mdm-install: KIT_MDM_DRY_RUN=true なのに --dry-run が無い (argv: ${MDM_SETUP_ARGV[*]})"
)
(
  export KIT_MDM_DRY_RUN=false
  mdm_build_setup_argv 2>/dev/null
  if _setup_argv_has '--dry-run'; then
    fail "mdm-install: KIT_MDM_DRY_RUN=false なのに --dry-run が含まれる"
  else
    pass "mdm-install: KIT_MDM_DRY_RUN=false 時は --dry-run を含まない"
  fi
)

# CLI trust verification reads only an fd-bound, UID-checked private snapshot;
# hard-linked binaries are not accepted as an attestation source.
(
  _cli_bound_tmp="$(mktemp -d)"
  _cli_bound_src="$_cli_bound_tmp/claude"
  _cli_bound_dst="$_cli_bound_tmp/claude-copy"
  printf '#!/bin/sh\nexit 0\n' > "$_cli_bound_src"; chmod 500 "$_cli_bound_src"
  : > "$_cli_bound_dst"
  _cli_bound_uid="$(/usr/bin/id -u)"; _cli_bound_rc=0
  _mdm_snapshot_bound_to "$_cli_bound_src" "$_cli_bound_dst" cli \
    "$_cli_bound_uid" || _cli_bound_rc=$?
  _cli_bound_mode="$_MDM_BOUND_SNAPSHOT_MODE"
  _cli_bound_hard_rc=0
  ln "$_cli_bound_src" "$_cli_bound_tmp/claude-hard"
  : > "$_cli_bound_tmp/hard-copy"
  _mdm_snapshot_bound_to "$_cli_bound_src" "$_cli_bound_tmp/hard-copy" cli \
    "$_cli_bound_uid" >/dev/null 2>&1 || _cli_bound_hard_rc=$?
  if [[ "$_cli_bound_rc" -eq 0 && "$_cli_bound_mode" == 0500 ]] \
    && cmp -s "$_cli_bound_src" "$_cli_bound_dst" \
    && [[ "$_cli_bound_hard_rc" -ne 0 ]]; then
    pass "mdm-install: Claude CLI snapshot は UID/bytes を固定し hardlink を拒否"
  else
    fail "mdm-install: Claude CLI fd-bound snapshot 契約が不正"
  fi
  rm -rf "$_cli_bound_tmp"
)

# fd open が FIFO に差し替わっても watchdog で bounded に失敗する。
(
  _bound_tmp="$(mktemp -d)"; _bound_src="$_bound_tmp/source"; _bound_dst="$_bound_tmp/copy"
  _bound_swap="$_bound_tmp/swapped"
  printf 'regular\n' > "$_bound_src"; : > "$_bound_dst"
  export MDM_SNAPSHOT_WATCHDOG_SECONDS_OVERRIDE=1
  _mdm_stat_identity() {
    local _path="$1" _identity
    if [[ "$_path" == "$_bound_src" && ! -e "$_bound_swap" ]]; then
      if _mdm_is_darwin; then
        _identity="$(/usr/bin/stat -f '%i:%HT:%z' "$_path")"
      else
        _identity="$(/usr/bin/stat -c '%i:%F:%s' "$_path")"
      fi
      rm -f "$_path"; /usr/bin/mkfifo "$_path"; : > "$_bound_swap"
      printf '%s' "$_identity"
    elif _mdm_is_darwin; then
      /usr/bin/stat -f '%i:%HT:%z' "$_path" 2>/dev/null
    else
      /usr/bin/stat -c '%i:%F:%s' "$_path" 2>/dev/null
    fi
  }
  _bound_start="$SECONDS"; _bound_rc=0
  _mdm_snapshot_bound_to "$_bound_src" "$_bound_dst" manifest >/dev/null 2>&1 || _bound_rc=$?
  _bound_elapsed=$((SECONDS - _bound_start))
  if [[ "$_bound_rc" -ne 0 && "$_bound_elapsed" -le 4 && ! -e "$_bound_dst" ]] \
    && grep -Fq '/usr/bin/head -c "$_copy_limit"' "$PROJECT_DIR/mdm/install-mdm.sh" \
    && grep -Fq '[[ "$_copied_size" == "$_size" ]]' "$PROJECT_DIR/mdm/install-mdm.sh"; then
    pass "mdm-install: stable snapshot は FIFO/open と append を watchdog+bounded size で拒否"
  else
    fail "mdm-install: stable snapshot の bounded copy 契約が不正 (rc=$_bound_rc elapsed=$_bound_elapsed)"
  fi
  rm -f "$_bound_src"; rm -rf "$_bound_tmp"
)

# ── 成功レシート前の postcondition 検証 ──────────────────
(
  _post_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _post_home="$_post_tmp/home"
  _post_claude="$_post_home/.claude"
  _post_snapshot="$_post_claude/.starter-kit-snapshot"
  _post_manifest="$_post_claude/.starter-kit-manifest.json"
  _post_uid="$(/usr/bin/id -u)"
  _post_expected="$_post_tmp/expected"
  export MDM_AUTH_OWNER_UID_OVERRIDE="$_post_uid"
  export MDM_AUTH_TMPDIR_OVERRIDE="$_post_tmp"
  _MDM_EXPECTED_OUTPUT="$_post_expected"
  mkdir -p "$_post_snapshot" "$_post_expected/tree"
  printf '{}\n' > "$_post_claude/settings.json"
  cat > "$_post_claude/CLAUDE.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# managed
<!-- END STARTER-KIT-MANAGED -->

# User Settings
personal
MD
  printf '{}\n' > "$_post_snapshot/settings.json"
  cat > "$_post_snapshot/CLAUDE.md" <<'MD'
<!-- BEGIN STARTER-KIT-MANAGED -->
# managed
<!-- END STARTER-KIT-MANAGED -->
MD
  cp "$_post_snapshot/CLAUDE.md" "$_post_expected/tree/CLAUDE.md"
  cp "$_post_snapshot/settings.json" "$_post_expected/tree/settings.json"
  printf 'CLAUDE.md\t0600\t0600\nsettings.json\t0600\t0600\n' > "$_post_expected/modes.tsv"
  jq -n '{profile:"standard",language:"ja",files:["CLAUDE.md","settings.json"],absent_files:[]}' \
    > "$_post_expected/manifest.json"
  chmod 700 "$_post_expected" "$_post_expected/tree"
  chmod 600 "$_post_claude/settings.json" "$_post_claude/CLAUDE.md" \
    "$_post_snapshot/settings.json" "$_post_snapshot/CLAUDE.md" \
    "$_post_expected/tree/CLAUDE.md" "$_post_expected/tree/settings.json" \
    "$_post_expected/modes.tsv" "$_post_expected/manifest.json"
  jq -n \
    --arg commit abcdef0 \
    --arg profile standard \
    --arg language ja \
    --arg claude_dir "$_post_claude" \
    --arg snapshot_dir "$_post_snapshot" \
    --arg settings "$_post_claude/settings.json" \
    --arg claude_md "$_post_claude/CLAUDE.md" \
    '{version:"2", mdm_managed:true, kit_commit:$commit, profile:$profile, language:$language,
      claude_dir:$claude_dir, snapshot_dir:$snapshot_dir,
      files:[$claude_md,$settings], mdm_absent_files:[]}' > "$_post_manifest"

  MDM_RCPT_RESOLVED_SHA="abcdef0123456789abcdef0123456789abcdef01"
  PROFILE=standard
  LANGUAGE=ja
  if _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    && [[ "$MDM_RCPT_MANIFEST_PATH" == "$_post_manifest" ]] \
    && [[ "$MDM_RCPT_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$MDM_RCPT_DEPLOYMENT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$MDM_RCPT_PROFILE" == "standard" && "$MDM_RCPT_LANGUAGE" == "ja" ]]; then
    pass "mdm-install: postcondition が manifest v2 と配備実体をレシートへ固定"
  else
    fail "mdm-install: 正常な postcondition を検証できない"
  fi

  _post_digest_initial="$MDM_RCPT_DEPLOYMENT_SHA256"
  jq '.absent_files=["commands/retired.md"]' \
    "$_post_expected/manifest.json" > "$_post_tmp/expected-with-absent"
  mv "$_post_tmp/expected-with-absent" "$_post_expected/manifest.json"
  jq '.mdm_absent_files=["commands/retired.md"]' \
    "$_post_manifest" > "$_post_tmp/manifest-with-absent"
  mv "$_post_tmp/manifest-with-absent" "$_post_manifest"
  _post_absent_ok=0
  _mdm_capture_postcondition "$_post_home" "$_post_uid" || _post_absent_ok=$?
  mkdir -p "$_post_claude/commands"; printf 'stale\n' \
    > "$_post_claude/commands/retired.md"
  _post_absent_live_rc=0
  _mdm_capture_postcondition "$_post_home" "$_post_uid" >/dev/null 2>&1 \
    || _post_absent_live_rc=$?
  rm -rf "$_post_claude/commands"
  mkdir -p "$_post_snapshot/commands"; printf 'stale\n' \
    > "$_post_snapshot/commands/retired.md"
  _post_absent_snapshot_rc=0
  _mdm_capture_postcondition "$_post_home" "$_post_uid" >/dev/null 2>&1 \
    || _post_absent_snapshot_rc=$?
  rm -rf "$_post_snapshot/commands"
  if [[ "$_post_absent_ok" -eq 0 && "$_post_absent_live_rc" -ne 0 \
    && "$_post_absent_snapshot_rc" -ne 0 ]]; then
    pass "mdm-install: postcondition は live/snapshot の absent path を固定"
  else
    fail "mdm-install: postcondition の absent path 契約が不正"
  fi
  jq '.absent_files=[]' "$_post_expected/manifest.json" \
    > "$_post_tmp/expected-without-absent"
  mv "$_post_tmp/expected-without-absent" "$_post_expected/manifest.json"
  jq '.mdm_absent_files=[]' "$_post_manifest" > "$_post_tmp/manifest-without-absent"
  mv "$_post_tmp/manifest-without-absent" "$_post_manifest"

  printf '{"live":"changed"}\n' > "$_post_claude/settings.json"
  chmod 600 "$_post_claude/settings.json"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: expectedと異なるlive内容を許可"
  else
    pass "mdm-install: expectedと異なるlive内容を拒否"
  fi

  printf '{}\n' > "$_post_claude/settings.json"
  chmod 600 "$_post_claude/settings.json"
  printf '{"snapshot":"changed"}\n' > "$_post_snapshot/settings.json"
  chmod 600 "$_post_snapshot/settings.json"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: expectedと異なるsnapshot内容を許可"
  else
    pass "mdm-install: expectedと異なるsnapshot内容を拒否"
  fi
  printf '{}\n' > "$_post_snapshot/settings.json"
  chmod 600 "$_post_snapshot/settings.json"

  chmod 644 "$_post_claude/settings.json"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: expectedと異なるmodeを許可"
  else
    pass "mdm-install: live/snapshot modeを期待値と照合"
  fi
  chmod 600 "$_post_claude/settings.json"

  printf 'changed personal section\n' >> "$_post_claude/CLAUDE.md"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid" \
    && [[ "$MDM_RCPT_DEPLOYMENT_SHA256" == "$_post_digest_initial" ]]; then
    pass "mdm-install: CLAUDE user sectionはattestation対象外"
  else
    fail "mdm-install: CLAUDE user sectionがdeployment digestを変えた"
  fi

  cp "$_post_claude/CLAUDE.md" "$_post_tmp/claude.lf"
  /usr/bin/awk '{ printf "%s\r\n", $0 }' "$_post_tmp/claude.lf" \
    > "$_post_claude/CLAUDE.md"
  chmod 600 "$_post_claude/CLAUDE.md"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: CLAUDE managed section の CRLF drift を許可"
  else
    pass "mdm-install: CLAUDE managed section は byte-exact に CRLF drift を拒否"
  fi
  mv "$_post_tmp/claude.lf" "$_post_claude/CLAUDE.md"
  chmod 600 "$_post_claude/CLAUDE.md"

  cp "$_post_manifest" "$_post_tmp/manifest.backup"
  printf 'attacker-controlled\n' > "$_post_claude/forged.txt"
  printf 'attacker-controlled\n' > "$_post_snapshot/forged.txt"
  chmod 600 "$_post_claude/forged.txt" "$_post_snapshot/forged.txt"
  jq -n \
    --arg commit abcdef0 \
    --arg profile standard \
    --arg language ja \
    --arg claude_dir "$_post_claude" \
    --arg snapshot_dir "$_post_snapshot" \
    --arg forged "$_post_claude/forged.txt" \
    '{version:"2", mdm_managed:true, kit_commit:$commit, profile:$profile, language:$language,
      claude_dir:$claude_dir, snapshot_dir:$snapshot_dir, files:[$forged], mdm_absent_files:[]}' > "$_post_manifest"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: forged manifest と一致する配備を許可"
  else
    pass "mdm-install: forged manifest は root 期待状態との差分として拒否"
  fi
  mv "$_post_tmp/manifest.backup" "$_post_manifest"
  rm -f "$_post_claude/forged.txt" "$_post_snapshot/forged.txt"

  _post_wrong_uid=$((_post_uid + 1))
  if _mdm_capture_postcondition "$_post_home" "$_post_wrong_uid"; then
    fail "mdm-install: target UID 不一致の managed file を許可"
  else
    pass "mdm-install: live/snapshot の target UID 不一致を拒否"
  fi

  rm -f "$_post_snapshot/settings.json"
  ln "$_post_claude/settings.json" "$_post_snapshot/settings.json"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: hardlink managed file を許可"
  else
    pass "mdm-install: live/snapshot の nlink!=1 を拒否"
  fi
  rm -f "$_post_snapshot/settings.json"; printf '{}\n' > "$_post_snapshot/settings.json"
  chmod 600 "$_post_snapshot/settings.json"

  if (
    _mdm_has_extended_acl() { [[ "$1" == "$_post_claude/settings.json" ]]; }
    _mdm_capture_postcondition "$_post_home" "$_post_uid"
  ); then
    fail "mdm-install: ACL 付き managed file を許可"
  else
    pass "mdm-install: live/snapshot の ACL を拒否"
  fi

  PROFILE=full
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: profile 不一致を postcondition が許可"
  else
    pass "mdm-install: profile 不一致を postcondition が拒否"
  fi
  PROFILE=standard
  LANGUAGE=en
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: language 不一致を postcondition が許可"
  else
    pass "mdm-install: language 不一致を postcondition が拒否"
  fi
  LANGUAGE=ja

  rm -f "$_post_claude/CLAUDE.md"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: manifest 記載ファイル欠落を postcondition が許可"
  else
    pass "mdm-install: manifest 記載ファイル欠落を postcondition が拒否"
  fi
  cp "$_post_snapshot/CLAUDE.md" "$_post_claude/CLAUDE.md"
  chmod 600 "$_post_claude/CLAUDE.md"
  # implementation reads this receipt global indirectly
  # shellcheck disable=SC2034
  MDM_RCPT_RESOLVED_SHA="1111111111111111111111111111111111111111"
  if _mdm_capture_postcondition "$_post_home" "$_post_uid"; then
    fail "mdm-install: manifest kit_commit 不一致を postcondition が許可"
  else
    pass "mdm-install: manifest kit_commit 不一致を postcondition が拒否"
  fi
  rm -rf "$_post_tmp"
)

# ── root authority: private checkout を実行し、persistent clone は保持専用 ──
(
  _auth_tmp="$(mktemp -d)"; _auth_tmp="$(builtin cd -P "$_auth_tmp" && printf '%s' "$PWD")"
  _auth_repo="$_auth_tmp/repo"; _auth_home="$_auth_tmp/home"; _auth_base="$_auth_tmp/auth-base"
  mkdir -p "$_auth_repo" "$_auth_home" "$_auth_base"
  chmod 700 "$_auth_base"
  /usr/bin/git -C "$_auth_repo" init -q
  printf '%s\n' \
    '#!/bin/bash' \
    'set -eu' \
    'auth_dir=$(/usr/bin/dirname "$0")' \
    'printf "%s\n" "$0" > "$HOME/root-authority-path"' \
    'printf "%s\n" "${PROFILE:-}" > "$HOME/root-authority-profile"' \
    'printf "%s\n" "${LANGUAGE:-}" > "$HOME/root-authority-language"' \
    'printf "%s\n" "$@" > "$HOME/root-authority-args"' \
    '/usr/bin/git -C "$auth_dir" rev-parse --verify HEAD > "$HOME/root-authority-head"' \
    'if /usr/bin/touch "$auth_dir/target-write-probe" 2>/dev/null; then exit 88; fi' \
    > "$_auth_repo/setup.sh"
  printf '# fixture\n' > "$_auth_repo/CLAUDE.md"
  ln -s CLAUDE.md "$_auth_repo/AGENTS.md"
  chmod +x "$_auth_repo/setup.sh"
  /usr/bin/git -C "$_auth_repo" add setup.sh CLAUDE.md AGENTS.md
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_auth_repo" commit -q -m fixture
  _auth_sha="$(/usr/bin/git -C "$_auth_repo" rev-parse HEAD)"
  _auth_user="$(/usr/bin/id -un)"; _auth_uid="$(/usr/bin/id -u)"

  _mdm_exec_as_user() {
    local _uid="$1" _user="$2" _home="$3"; shift 3
    mdm_build_drop_argv "$_uid" "$_user" "$_home" "$@" || return 1
    "${MDM_DROP_ARGV[@]}"
  }
  _mdm_prepare_expected_state() { return 0; }
  _mdm_persist_managed_history() { return 0; }
  _auth_python_cmd="$(command -v python3)"
  _auth_python="$($_auth_python_cmd -c 'import os, sys; print(os.path.realpath(sys.executable))')"
  _mdm_system_python() { printf '%s' "$_auth_python"; }
  unset PROFILE LANGUAGE
  _mdm_root_config_apply "$_auth_tmp/no-config" >/dev/null 2>&1 || exit 1
  export MDM_AUTH_TMPDIR_OVERRIDE="$_auth_base"
  export MDM_AUTH_OWNER_UID_OVERRIDE="$_auth_uid"
  export MDM_AUTH_PRIVACY_UID_OVERRIDE=99999
  export MDM_AUTH_READONLY_OWNER_TEST=1
  export MDM_KIT_REPO_URL_OVERRIDE="$_auth_repo"
  export KIT_MDM_GIT_REF="$_auth_sha"
  export KIT_MDM_INSTALL_CLAUDE_CLI=false
  export KIT_MDM_DRY_RUN=false
  unset KIT_MDM_INSTALL_DIR

  _auth_rc=0
  _mdm_run_user_phase 0 "$_auth_user" "$_auth_home" >/dev/null 2>&1 || _auth_rc=$?
  _auth_path="$(cat "$_auth_home/root-authority-path" 2>/dev/null || true)"
  _auth_persistent="$_auth_home/.claude-starter-kit"
  if [[ "$_auth_rc" -eq 0 && "$_auth_path" == "$_auth_base"/claude-kit-mdm-auth.*/setup.sh ]] \
    && [[ "$_auth_path" != "$_auth_persistent/setup.sh" ]] \
    && [[ "$(cat "$_auth_home/root-authority-head")" == "$_auth_sha" ]] \
    && [[ "$(cat "$_auth_home/root-authority-profile")" == standard ]] \
    && [[ "$(cat "$_auth_home/root-authority-language")" == en ]] \
    && [[ ! -e "${_auth_path%/setup.sh}" && -z "$_MDM_AUTH_CHECKOUT" ]] \
    && _mdm_detached_head_matches "$_auth_persistent" "$_auth_sha" \
    && _mdm_persistent_marker_trusted "$_auth_persistent" "$_auth_uid"; then
    pass "mdm-install: root は private authoritative setup のみを対象ユーザー実行"
    pass "mdm-install: target user は authoritative tree に書込不能、Git read は成功"
  else
    fail "mdm-install: root authoritative/persistent 分離が不正 (rc=$_auth_rc path=$_auth_path)"
  fi
  if grep -qx -- --non-interactive "$_auth_home/root-authority-args" \
    && ! grep -qx -- --update "$_auth_home/root-authority-args"; then
    pass "mdm-install: fresh authoritative setup argv が正しい"
  else
    fail "mdm-install: fresh authoritative setup argv が不正"
  fi

  printf 'stale\n' > "$_auth_persistent/stale-user-file"
  mkdir -p "$_auth_home/.claude"; printf '{}\n' > "$_auth_home/.claude/.starter-kit-manifest.json"
  _auth_rc=0
  _mdm_run_user_phase 0 "$_auth_user" "$_auth_home" >/dev/null 2>&1 || _auth_rc=$?
  if [[ "$_auth_rc" -eq 0 && ! -e "$_auth_persistent/stale-user-file" ]] \
    && grep -qx -- --update "$_auth_home/root-authority-args" \
    && [[ "$(cat "$_auth_home/root-authority-profile")" == standard ]] \
    && [[ "$(cat "$_auth_home/root-authority-language")" == en ]]; then
    pass "mdm-install: update も fresh persistent clone と既定 standard/en を維持"
  else
    fail "mdm-install: update persistent/default 契約が不正 (rc=$_auth_rc)"
  fi

  printf 'keep\n' > "$_auth_persistent/dryrun-sentinel"
  _auth_head_before="$(cat "$_auth_persistent/.git/HEAD")"
  export KIT_MDM_DRY_RUN=true
  _auth_rc=0
  _mdm_run_user_phase 0 "$_auth_user" "$_auth_home" >/dev/null 2>&1 || _auth_rc=$?
  _auth_dry_path="$(cat "$_auth_home/root-authority-path" 2>/dev/null || true)"
  if [[ "$_auth_rc" -eq 0 && "$(cat "$_auth_persistent/dryrun-sentinel")" == keep ]] \
    && [[ "$(cat "$_auth_persistent/.git/HEAD")" == "$_auth_head_before" ]] \
    && grep -qx -- --dry-run "$_auth_home/root-authority-args" \
    && [[ "$_auth_dry_path" == "$_auth_base"/claude-kit-mdm-auth.*/setup.sh ]] \
    && [[ ! -e "${_auth_dry_path%/setup.sh}" ]]; then
    pass "mdm-install: root dry-run は auth temp だけを実行し persistent を不変化"
  else
    fail "mdm-install: root dry-run が persistent を変更 (rc=$_auth_rc)"
  fi
  rm -rf "$_auth_tmp"
)

# 既存 persistent directory は管理 marker が無ければ削除しない。
(
  _marker_tmp="$(mktemp -d)"; _marker_home="$_marker_tmp/home"
  mkdir -p "$_marker_home/.claude-starter-kit"
  printf 'preserve\n' > "$_marker_home/.claude-starter-kit/user-data"
  export KIT_MDM_DRY_RUN=false KIT_MDM_GIT_REF=0123456789abcdef0123456789abcdef01234567
  unset KIT_MDM_INSTALL_DIR
  _marker_rc=0
  _mdm_run_user_phase 0 "$(/usr/bin/id -un)" "$_marker_home" >/dev/null 2>&1 || _marker_rc=$?
  if [[ "$_marker_rc" -eq "$MDM_EXIT_CONFIG" \
    && "$(cat "$_marker_home/.claude-starter-kit/user-data")" == preserve ]]; then
    pass "mdm-install: 管理 marker 無し既存 checkout を fail-closed で保持"
  else
    fail "mdm-install: marker 無し checkout を削除/許可 (rc=$_marker_rc)"
  fi
  rm -rf "$_marker_tmp"
)

# target-user writable checkout 配下へ root が marker を直接書かない。
(
  _marker_tmp="$(mktemp -d)"
  _marker_install="$_marker_tmp/.claude-starter-kit"
  mkdir -p "$_marker_install"
  _marker_drop_called=0
  _mdm_run_maybe_as_user() { _marker_drop_called=1; return 77; }
  if ! _mdm_create_persistent_marker "$_marker_install" "$(/usr/bin/id -u)" \
    && [[ "$_marker_drop_called" -eq 1 ]] \
    && [[ ! -e "$_marker_install/.claude-starter-kit-mdm-managed" ]]; then
    pass "mdm-install: persistent marker 作成は対象ユーザー権限へ降格"
  else
    fail "mdm-install: persistent marker を root で直接作成し得る"
  fi
  rm -rf "$_marker_tmp"
)

# 保持用 checkout は stage 完成前に既存状態を破壊せず、失敗後も再試行可能。
(
  _txn_tmp="$(mktemp -d)"
  _txn_tmp="$(builtin cd -P "$_txn_tmp" && printf '%s' "$PWD")"
  _txn_repo="$_txn_tmp/repo"
  _txn_home="$_txn_tmp/home"
  _txn_install="$_txn_home/.claude-starter-kit"
  _txn_uid="$(/usr/bin/id -u)"
  mkdir -p "$_txn_repo" "$_txn_home"
  /usr/bin/git -C "$_txn_repo" init -q
  printf 'transaction fixture\n' > "$_txn_repo/payload.txt"
  /usr/bin/git -C "$_txn_repo" add payload.txt
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git -C "$_txn_repo" commit -q -m fixture
  _txn_sha="$(/usr/bin/git -C "$_txn_repo" rev-parse HEAD)"
  /usr/bin/git clone --quiet --no-checkout --no-local "$_txn_repo" "$_txn_install"
  /usr/bin/git -C "$_txn_install" checkout --quiet --force --detach "$_txn_sha"
  _MDM_GIT_DROP_UID=""
  _MDM_GIT_DROP_USER=""
  _MDM_GIT_DROP_HOME=""
  _MDM_TEST_MODE=1
  _txn_python_cmd="$(command -v python3)"
  MDM_SYSTEM_PYTHON_OVERRIDE="$($_txn_python_cmd -c \
    'import os, sys; print(os.path.realpath(sys.executable))')"
  export MDM_SYSTEM_PYTHON_OVERRIDE
  _mdm_create_persistent_marker "$_txn_install" "$_txn_uid" || exit 1
  printf 'old checkout\n' > "$_txn_install/old-sentinel"
  _txn_old_head="$(cat "$_txn_install/.git/HEAD")"

  _txn_fail_fetch=0
  _txn_swap_install=1
  _txn_displaced="$_txn_home/displaced-managed-checkout"
  _mdm_git() {
    local _txn_arg _txn_is_status=0 _txn_git_rc=0
    for _txn_arg in "$@"; do
      if [[ "$_txn_fail_fetch" == 1 && "$_txn_arg" == fetch ]]; then
        return 86
      fi
      [[ "$_txn_arg" == status ]] && _txn_is_status=1
    done
    if [[ "$_txn_swap_install" == 1 && "$_txn_is_status" == 1 ]]; then
      /usr/bin/git "$@" || _txn_git_rc=$?
      /bin/mv "$_txn_install" "$_txn_displaced" || return 87
      /bin/mkdir "$_txn_install" || return 88
      printf 'unmanaged replacement\n' > "$_txn_install/user-data"
      _txn_swap_install=0
      return "$_txn_git_rc"
    fi
    /usr/bin/git "$@"
  }

  _txn_rc=0
  _mdm_rebuild_persistent_checkout \
    "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 \
    && "$(cat "$_txn_install/user-data" 2>/dev/null || true)" == 'unmanaged replacement' \
    && "$(cat "$_txn_displaced/old-sentinel" 2>/dev/null || true)" == 'old checkout' ]] \
    && _mdm_persistent_marker_trusted "$_txn_displaced" "$_txn_uid" \
    && ! /usr/bin/find "$_txn_home" -maxdepth 1 \
      -name '.claude-starter-kit.mdm-stage.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: pre-swap identity 差替え時は未管理 directory を削除しない"
  else
    fail "mdm-install: pre-swap TOCTOU で未管理 directory を削除し得る"
  fi
  /bin/rm -rf "$_txn_install"
  /bin/mv "$_txn_displaced" "$_txn_install"

  _txn_fail_fetch=1
  _txn_swap_install=0
  _txn_rc=0
  _mdm_rebuild_persistent_checkout \
    "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 \
    && "$(cat "$_txn_install/old-sentinel" 2>/dev/null || true)" == 'old checkout' \
    && "$(cat "$_txn_install/.git/HEAD" 2>/dev/null || true)" == "$_txn_old_head" ]] \
    && _mdm_persistent_marker_trusted "$_txn_install" "$_txn_uid" \
    && ! /usr/bin/find "$_txn_home" -maxdepth 1 \
      -name '.claude-starter-kit.mdm-stage.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: rebuild 失敗時は既存 persistent checkout を不変保持"
  else
    fail "mdm-install: rebuild 失敗が既存 persistent checkout を破壊"
  fi

  _txn_fail_fetch=0
  if _mdm_rebuild_persistent_checkout \
      "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" \
    && [[ ! -e "$_txn_install/old-sentinel" ]] \
    && _mdm_persistent_marker_trusted "$_txn_install" "$_txn_uid" \
    && _mdm_detached_head_matches "$_txn_install" "$_txn_sha" "$_txn_uid" \
    && ! /usr/bin/find "$_txn_home" -maxdepth 1 \
      -name '.claude-starter-kit.mdm-stage.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: 完成済み stage を原子的に persistent checkout へ切替"
  else
    fail "mdm-install: transactional rebuild の成功切替が不正"
  fi

  /bin/rm -rf "$_txn_install"
  _txn_fail_fetch=1
  _txn_rc=0
  _mdm_rebuild_persistent_checkout \
    "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 && ! -e "$_txn_install" && ! -L "$_txn_install" ]] \
    && ! /usr/bin/find "$_txn_home" -maxdepth 1 \
      -name '.claude-starter-kit.mdm-stage.*' -print -quit | /usr/bin/grep -q .; then
    pass "mdm-install: 初回 rebuild 失敗は marker 無し残骸を残さない"
  else
    fail "mdm-install: 初回 rebuild 失敗が再試行不能な残骸を作成"
  fi

  _txn_fail_fetch=0
  if _mdm_rebuild_persistent_checkout \
      "$_txn_install" "$_txn_repo" "$_txn_sha" "$_txn_uid" \
    && _mdm_persistent_marker_trusted "$_txn_install" "$_txn_uid" \
    && _mdm_detached_head_matches "$_txn_install" "$_txn_sha" "$_txn_uid"; then
    pass "mdm-install: 初回途中失敗の次回 remediation で自動復旧"
  else
    fail "mdm-install: 初回途中失敗後に自動復旧できない"
  fi

  _txn_fresh_install="$_txn_home/fresh-raced-install"
  _txn_fresh_stage="$_txn_home/.claude-starter-kit.mdm-stage.fresh-race"
  /bin/mkdir "$_txn_fresh_install"
  printf 'unmanaged fresh replacement\n' > "$_txn_fresh_install/user-data"
  _MDM_PERSISTENT_STAGE="$_txn_fresh_stage"
  _MDM_PERSISTENT_STAGE_IDENTITY='0:0:directory'
  _txn_rc=0
  _mdm_retract_initial_persistent_checkout \
    "$_txn_fresh_stage" "$_txn_fresh_install" '0:0:directory' || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 \
    && "$(cat "$_txn_fresh_install/user-data" 2>/dev/null || true)" \
      == 'unmanaged fresh replacement' \
    && ! -e "$_txn_fresh_stage" && ! -L "$_txn_fresh_stage" \
    && -z "$_MDM_PERSISTENT_STAGE" && -z "$_MDM_PERSISTENT_STAGE_IDENTITY" ]]; then
    pass "mdm-install: fresh post-swap identity 差替えは固定pathへ復元し削除しない"
  else
    fail "mdm-install: fresh post-swap TOCTOU で未管理 directory を削除し得る"
  fi

  _txn_rollback_install="$_txn_home/rollback-active"
  _txn_rollback_stage="$_txn_home/.claude-starter-kit.mdm-stage.rollback"
  /bin/mkdir "$_txn_rollback_install" "$_txn_rollback_stage"
  printf 'rejected candidate\n' > "$_txn_rollback_install/new"
  printf 'previous checkout\n' > "$_txn_rollback_stage/old"
  _MDM_PERSISTENT_STAGE="$_txn_rollback_stage"
  _MDM_PERSISTENT_STAGE_IDENTITY="$(_mdm_persistent_dir_identity "$_txn_rollback_stage")"
  _mdm_promote_persistent_stage() { return 89; }
  _txn_rc=0
  _mdm_restore_previous_persistent_checkout \
    "$_txn_rollback_stage" "$_txn_rollback_install" "$_txn_uid" \
    "$(_mdm_persistent_dir_identity "$_txn_rollback_install")" \
    "$(_mdm_persistent_dir_identity "$_txn_rollback_stage")" || _txn_rc=$?
  if [[ "$_txn_rc" -ne 0 \
    && "$(cat "$_txn_rollback_stage/old" 2>/dev/null || true)" == 'previous checkout' \
    && "$(cat "$_txn_rollback_install/new" 2>/dev/null || true)" == 'rejected candidate' \
    && -z "$_MDM_PERSISTENT_STAGE" && -z "$_MDM_PERSISTENT_STAGE_IDENTITY" ]]; then
    pass "mdm-install: rollback swap 失敗時は旧 checkout を recovery stage に保持"
  else
    fail "mdm-install: rollback swap 失敗時に旧 checkout を削除"
  fi
  rm -rf "$_txn_tmp"
)

# production remediation は named ref で authority を曖昧にしない。
(
  _MDM_TEST_MODE=0
  _sha_full=0123456789abcdef0123456789abcdef01234567
  if ! _mdm_root_ref_allowed main false \
    && _mdm_root_ref_allowed main true \
    && _mdm_root_ref_allowed "$_sha_full" false; then
    pass "mdm-install: production root remediation は 40桁 SHA 必須、dry-run は named ref 可"
  else
    fail "mdm-install: production ref/dry-run 契約が不正"
  fi
)

# ── dry-run は一時 checkout のみを使い、終了時に除去 ─────
(
  _dry_tmp="$(mktemp -d)"
  _dry_repo="$_dry_tmp/repo"
  _dry_home="$_dry_tmp/home"
  mkdir -p "$_dry_repo" "$_dry_home"
  git -C "$_dry_repo" init -q
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$HOME/mdm-dryrun-args"\n' > "$_dry_repo/setup.sh"
  chmod +x "$_dry_repo/setup.sh"
  git -C "$_dry_repo" add setup.sh
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    git -C "$_dry_repo" commit -q -m fixture
  _dry_sha="$(git -C "$_dry_repo" rev-parse HEAD)"

  export HOME="$_dry_home"
  export MDM_KIT_REPO_URL_OVERRIDE="$_dry_repo"
  export KIT_MDM_GIT_REF="$_dry_sha"
  export KIT_MDM_DRY_RUN=true
  export KIT_MDM_INSTALL_CLAUDE_CLI=false
  export KIT_MDM_INSTALL_DIR="$_dry_home/should-not-be-used"
  _MDM_GIT_DROP_UID=""; _MDM_GIT_DROP_USER=""; _MDM_GIT_DROP_HOME=""

  _dry_rc=0
  _mdm_run_user_phase 501 "$(/usr/bin/id -un)" "$_dry_home" >/dev/null 2>&1 || _dry_rc=$?
  _dry_checkout="$_MDM_DRYRUN_CHECKOUT"
  if [[ "$_dry_rc" -eq 0 && -d "$_dry_checkout" ]] \
    && grep -qx -- '--dry-run' "$_dry_home/mdm-dryrun-args" \
    && [[ ! -e "$_dry_home/should-not-be-used" ]]; then
    pass "mdm-install: dry-run は対象 home 外の一時 checkout で setup を実行"
  else
    fail "mdm-install: dry-run の一時 checkout 契約が不正 (rc=$_dry_rc)"
  fi
  _mdm_cleanup_dryrun_checkout
  if [[ -n "$_dry_checkout" && ! -e "$_dry_checkout" && -z "$_MDM_DRYRUN_CHECKOUT" ]]; then
    pass "mdm-install: dry-run 一時 checkout を完了時に除去"
  else
    fail "mdm-install: dry-run 一時 checkout が残存"
  fi

  export KIT_MDM_INSTALL_CLAUDE_CLI=true
  _mdm_cli_present_for_home() { return 1; }
  _dry_cli_rc=0
  _mdm_run_user_phase 501 "$(/usr/bin/id -un)" "$_dry_home" \
    >/dev/null 2>&1 || _dry_cli_rc=$?
  _mdm_cleanup_dryrun_checkout
  if [[ "$_dry_cli_rc" -eq 0 ]]; then
    pass "mdm-install: non-root dry-run は未導入 CLI を失敗扱いにしない"
  else
    fail "mdm-install: non-root dry-run が未導入 CLI で失敗 (rc=$_dry_cli_rc)"
  fi
  rm -rf "$_dry_tmp"
)

# Log setup failure during a preview must return a config error without
# invoking the receipt-writing finish path.
(
  _dry_finish_called=0
  _mdm_finish() { _dry_finish_called=1; return 0; }
  _dry_log_rc=0
  _mdm_handle_log_setup_failure jane /Users/jane true || _dry_log_rc=$?
  if [[ "$_dry_log_rc" -eq "$MDM_EXIT_CONFIG" && "$_dry_finish_called" -eq 0 ]]; then
    pass "mdm-install: dry-run log 初期化失敗は receipt を変更しない"
  else
    fail "mdm-install: dry-run log 初期化失敗が receipt finish を呼び得る"
  fi
)

# Root history is independent of a user manifest/receipt, but grants deletion
# authority only to files that passed a successful root postcondition.  An
# absent candidate is never promoted merely by rendering or a failed attempt.
(
  _history_tmp="$(mktemp -d)"
  _history_support="$_history_tmp/support"
  _history_rendered="$_history_tmp/rendered"
  _history_home="$_history_tmp/home"
  mkdir -p "$_history_support" "$_history_rendered" "$_history_home/.claude"
  chmod 755 "$_history_support"
  jq -n '{files:["CLAUDE.md","settings.json"],absent_files:["commands/retired.md"]}' \
    > "$_history_rendered/manifest.json"
  export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_history_support"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _MDM_EXPECTED_OUTPUT="$_history_rendered"
  _history_rc=0
  _mdm_persist_managed_history jane "$_history_home" || _history_rc=$?
  _history_file="$_history_support/managed-history-jane.json"
  printf '{"files":["commands/forged.md"]}\n' \
    > "$_history_home/.claude/.starter-kit-manifest.json"
  printf '{"result":"failure"}\n' > "$_history_support/receipt-jane.json"
  _mdm_capture_prior_inventory jane "$_history_home" "$(/usr/bin/id -u)" \
    || _history_rc=$?
  if [[ "$_history_rc" -eq 0 ]] \
    && jq -e '.managed_inventory == ["CLAUDE.md","settings.json"]' \
      "$_history_file" >/dev/null \
    && grep -qx CLAUDE.md "$_MDM_PRIOR_INVENTORY" \
    && grep -qx settings.json "$_MDM_PRIOR_INVENTORY" \
    && ! grep -q retired "$_history_file"; then
    pass "mdm-install: root history は postcondition 済み present files のみ保持"
  else
    fail "mdm-install: root history が absent/target-user state を削除権限へ昇格"
  fi
  _mdm_cleanup_prior_inventory || true
  rm -rf "$_history_tmp"
)

# A fixed root-owned lock serializes the entire mutating run.  A contender
# fails without touching compliance, and the retained lock path is reusable.
if [[ -x /usr/bin/lockf ]]; then
  (
    _lock_tmp="$(mktemp -d)"; _lock_support="$_lock_tmp/support"
    mkdir -p "$_lock_support"; chmod 755 "$_lock_support"
    printf 'sentinel\n' > "$_lock_support/receipt-jane.json"
    export MDM_SYSTEM_RCPT_DIR_OVERRIDE="$_lock_support"
    export MDM_CONFIG_SKIP_OWNER_CHECK=1
    (
      _MDM_RUN_LOCK_FILE=""; _MDM_RUN_LOCK_BASE=""
      _mdm_acquire_run_lock jane "$_lock_tmp/home" || exit 1
      : > "$_lock_tmp/ready"
      _lock_wait=0
      while [[ ! -e "$_lock_tmp/release" && "$_lock_wait" -lt 500 ]]; do
        /bin/sleep 0.01; _lock_wait=$((_lock_wait + 1))
      done
      _mdm_release_run_lock
    ) &
    _lock_holder=$!
    _lock_wait=0
    while [[ ! -e "$_lock_tmp/ready" && "$_lock_wait" -lt 500 ]]; do
      /bin/sleep 0.01; _lock_wait=$((_lock_wait + 1))
    done
    _MDM_RUN_LOCK_FILE=""; _MDM_RUN_LOCK_BASE=""
    _lock_contender_rc=0
    _mdm_acquire_run_lock jane "$_lock_tmp/home" >/dev/null 2>&1 \
      || _lock_contender_rc=$?
    : > "$_lock_tmp/release"; wait "$_lock_holder"
    _lock_reuse_rc=0
    _mdm_acquire_run_lock jane "$_lock_tmp/home" || _lock_reuse_rc=$?
    _mdm_release_run_lock || _lock_reuse_rc=$?
    if [[ "$_lock_contender_rc" -ne 0 && "$_lock_reuse_rc" -eq 0 \
      && "$(cat "$_lock_support/receipt-jane.json")" == sentinel ]]; then
      pass "mdm-install: per-user lock は競合を拒否し receipt 不変で再利用可能"
    else
      fail "mdm-install: per-user remediation lock の排他/再利用契約が不正"
    fi
    rm -rf "$_lock_tmp"
  )
else
  skip "mdm-install: per-user remediation lock" "/usr/bin/lockf unavailable"
fi
