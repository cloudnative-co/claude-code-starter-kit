#!/bin/bash
# tests/unit/test-mdm-bootstrap.sh - 自己ブートストラップ判定 + R4 レシート出力先ロジック

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

# ══ R2-Critical 回帰: root は信頼できない隣接 lib を source しない ══
# 単一ファイル配布で sticky/共有ディレクトリに配置された場合、攻撃者が隣に
# lib-mdm-config.sh を植えられる。root 実行時は「通常ファイル・非 symlink・
# root 所有・ファイル/親 dir とも group/other 書込不可」を満たさない隣接 lib
# を無視して自己ブートストラップ（pin 済み取得）に切り替える。
(
  # 親 dir が world-writable → 信頼しない（要ブートストラップ）
  _open="$_tmpd/open-dir"; mkdir -p "$_open"; chmod 777 "$_open"
  touch "$_open/lib-mdm-config.sh"; chmod 644 "$_open/lib-mdm-config.sh"
  export MDM_SELF_DIR="$_open" MDM_EUID_OVERRIDE=0 MDM_CONFIG_SKIP_OWNER_CHECK=1
  if mdm_needs_bootstrap; then
    pass "mdm-bootstrap: root は書込可能 dir の隣接 lib を信頼しない"
  else
    fail "mdm-bootstrap: root が書込可能 dir の隣接 lib を source してしまう（R2-Critical 回帰）"
  fi
)
(
  # 隣接 lib が symlink → 信頼しない
  _sldir="$_tmpd/symlink-dir"; mkdir -p "$_sldir"; chmod 755 "$_sldir"
  touch "$_tmpd/real-lib"
  ln -s "$_tmpd/real-lib" "$_sldir/lib-mdm-config.sh"
  export MDM_SELF_DIR="$_sldir" MDM_EUID_OVERRIDE=0 MDM_CONFIG_SKIP_OWNER_CHECK=1
  if mdm_needs_bootstrap; then
    pass "mdm-bootstrap: root は symlink の隣接 lib を信頼しない"
  else
    fail "mdm-bootstrap: root が symlink の隣接 lib を source してしまう"
  fi
)
(
  # 隣接 lib が group/other 書込可 → 信頼しない
  _wldir="$_tmpd/writable-lib-dir"; mkdir -p "$_wldir"; chmod 755 "$_wldir"
  touch "$_wldir/lib-mdm-config.sh"; chmod 666 "$_wldir/lib-mdm-config.sh"
  export MDM_SELF_DIR="$_wldir" MDM_EUID_OVERRIDE=0 MDM_CONFIG_SKIP_OWNER_CHECK=1
  if mdm_needs_bootstrap; then
    pass "mdm-bootstrap: root は group/other 書込可の隣接 lib を信頼しない"
  else
    fail "mdm-bootstrap: root が書込可の隣接 lib を source してしまう"
  fi
)
(
  # 安全な隣接 lib（755 dir・644 file・非 symlink）は root でも信頼する
  _okdir="$_tmpd/ok-dir"; mkdir -p "$_okdir"; chmod 755 "$_okdir"
  touch "$_okdir/lib-mdm-config.sh"; chmod 644 "$_okdir/lib-mdm-config.sh"
  export MDM_SELF_DIR="$_okdir" MDM_EUID_OVERRIDE=0 MDM_CONFIG_SKIP_OWNER_CHECK=1
  if mdm_needs_bootstrap; then
    fail "mdm-bootstrap: 安全な隣接 lib が root で信頼されない"
  else
    pass "mdm-bootstrap: 安全な隣接 lib は root でも信頼される"
  fi
)
rm -rf "$_tmpd"

# ── _mdm_receipt_dir_for（R4 のパス選択ロジック。実 id -u に依存しないよう
#    MDM_EUID_OVERRIDE でモック）────────────────────────────
(
  export MDM_EUID_OVERRIDE=0
  out="$(_mdm_receipt_dir_for "/Users/jane")"
  if [[ "$out" == "/Library/Application Support/ClaudeCodeStarterKit" ]]; then
    pass "mdm-bootstrap: root 時はシステム領域にレシート"
  else
    fail "mdm-bootstrap: root 時のレシート先が不正 (got '$out')"
  fi
)
(
  export MDM_EUID_OVERRIDE=501
  out="$(_mdm_receipt_dir_for "/Users/jane")"
  if [[ "$out" == "/Users/jane/Library/Application Support/ClaudeCodeStarterKit" ]]; then
    pass "mdm-bootstrap: 非root時はユーザー領域にレシート"
  else
    fail "mdm-bootstrap: 非root時のレシート先が不正 (got '$out')"
  fi
)

# ══ CRITICAL 回帰（最終レビュー #1）: 自己ブートストラップは ref 固定前に
#    clone した default branch のコードを一切 source/実行してはならない ══
#
# fixture: ローカル git repo を配布元に見立てる。
#   - pinned commit: 良性の lib + 「PINNED-STUB-EXECUTED」を出力して exit 42 する stub
#   - main tip:      lib にブービートラップ（source されたら MDM_TEST_TRAP_FILE を作成）
# KIT_MDM_GIT_REF=<pinned SHA> でブートストラップしたとき、
#   (1) トラップが発火しない（= pin 前の lib を source していない）
#   (2) pinned stub が実行される
#   (3) stub の exit code が伝搬する
# を検証する。旧実装（clone 直後の lib を source）ではトラップが発火して FAIL する。
_boot_tmpd="$(mktemp -d)"
_boot_tmpd="$(cd "$_boot_tmpd" && pwd -P)"
_boot_origin="$_boot_tmpd/origin"
mkdir -p "$_boot_origin/mdm"
git -C "$_boot_origin" init -q
git -C "$_boot_origin" symbolic-ref HEAD refs/heads/main
cat > "$_boot_origin/mdm/lib-mdm-config.sh" <<'EOF'
# benign fixture lib（pinned commit 用）
EOF
cat > "$_boot_origin/mdm/install-mdm.sh" <<'EOF'
#!/bin/bash
echo "PINNED-STUB-EXECUTED"
exit 42
EOF
git -C "$_boot_origin" add -A
git -C "$_boot_origin" -c user.name=t -c user.email=t@t commit -qm "pinned"
_boot_pinned_sha="$(git -C "$_boot_origin" rev-parse HEAD)"
cat > "$_boot_origin/mdm/lib-mdm-config.sh" <<'EOF'
# booby-trapped lib（main tip 用）: source されたらトラップファイルを作る
: > "${MDM_TEST_TRAP_FILE:-/dev/null}"
mdm_validate_gitref() { printf '%s' "$1"; }
mdm_resolve_ref_sha() { return 1; }
EOF
git -C "$_boot_origin" add -A
git -C "$_boot_origin" -c user.name=t -c user.email=t@t commit -qm "trapped main tip"

(
  export MDM_KIT_REPO_URL_OVERRIDE="$_boot_origin"
  export MDM_TEST_TRAP_FILE="$_boot_tmpd/trap-env"
  export KIT_MDM_GIT_REF="$_boot_pinned_sha"
  export TMPDIR="$_boot_tmpd/tmp"; mkdir -p "$TMPDIR"
  _rc=0
  _out="$(_mdm_bootstrap_and_reexec 2>/dev/null)" || _rc=$?
  if [[ ! -f "$MDM_TEST_TRAP_FILE" ]]; then
    pass "mdm-bootstrap: pin 前の default branch lib を source しない"
  else
    fail "mdm-bootstrap: pin 前の default branch lib が実行された（CRITICAL 回帰）"
  fi
  if printf '%s' "$_out" | grep -q 'PINNED-STUB-EXECUTED'; then
    pass "mdm-bootstrap: 固定 SHA の実体から再実行する"
  else
    fail "mdm-bootstrap: 固定 SHA の実体が実行されていない (out='$_out' rc=$_rc)"
  fi
  assert_exit_code 42 "$_rc" "再実行の exit code 伝搬" \
    && pass "mdm-bootstrap: 再実行の exit code を伝搬" \
    || fail "mdm-bootstrap: 再実行の exit code が伝搬しない (got $_rc)"
)

# 管理設定ファイルの KIT_MDM_GIT_REF も launcher に効く（env 未設定時）
(
  unset KIT_MDM_GIT_REF
  export MDM_KIT_REPO_URL_OVERRIDE="$_boot_origin"
  export MDM_TEST_TRAP_FILE="$_boot_tmpd/trap-conf"
  export TMPDIR="$_boot_tmpd/tmp2"; mkdir -p "$TMPDIR"
  _conf="$_boot_tmpd/mdm-config.conf"
  printf 'KIT_MDM_GIT_REF="%s"\n' "$_boot_pinned_sha" > "$_conf"
  chmod 644 "$_conf"
  export MDM_CONFIG_PATH_OVERRIDE="$_conf"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _rc=0
  _out="$(_mdm_bootstrap_and_reexec 2>/dev/null)" || _rc=$?
  if printf '%s' "$_out" | grep -q 'PINNED-STUB-EXECUTED' && [[ ! -f "$MDM_TEST_TRAP_FILE" ]]; then
    pass "mdm-bootstrap: 管理設定ファイルの KIT_MDM_GIT_REF が launcher に効く"
  else
    fail "mdm-bootstrap: 管理設定の ref が launcher に効かない (out='$_out' rc=$_rc)"
  fi
)

# CLI 引数（KEY=VALUE 形式）の KIT_MDM_GIT_REF は env/config より優先
(
  unset KIT_MDM_GIT_REF
  export MDM_KIT_REPO_URL_OVERRIDE="$_boot_origin"
  export MDM_TEST_TRAP_FILE="$_boot_tmpd/trap-cli"
  export TMPDIR="$_boot_tmpd/tmp3"; mkdir -p "$TMPDIR"
  _rc=0
  _out="$(_mdm_bootstrap_and_reexec "KIT_MDM_GIT_REF=$_boot_pinned_sha" 2>/dev/null)" || _rc=$?
  if printf '%s' "$_out" | grep -q 'PINNED-STUB-EXECUTED' && [[ ! -f "$MDM_TEST_TRAP_FILE" ]]; then
    pass "mdm-bootstrap: CLI 引数の KIT_MDM_GIT_REF が launcher に効く"
  else
    fail "mdm-bootstrap: CLI 引数の ref が launcher に効かない (out='$_out' rc=$_rc)"
  fi
)

# 不正な ref 形式は clone せず exit 50（MDM_EXIT_CONFIG）
(
  export MDM_KIT_REPO_URL_OVERRIDE="$_boot_origin"
  export MDM_TEST_TRAP_FILE="$_boot_tmpd/trap-badref"
  export KIT_MDM_GIT_REF='-evil-flag'
  export TMPDIR="$_boot_tmpd/tmp4"; mkdir -p "$TMPDIR"
  _rc=0
  _mdm_bootstrap_and_reexec >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "不正 ref は exit 50" \
    && pass "mdm-bootstrap: 不正 ref 形式を exit 50 で拒否" \
    || fail "mdm-bootstrap: 不正 ref 形式の拒否が不正 (got $_rc)"
)

# 不安全な管理設定ファイル（group/other 書込可）は exit 50
(
  unset KIT_MDM_GIT_REF
  export MDM_KIT_REPO_URL_OVERRIDE="$_boot_origin"
  export TMPDIR="$_boot_tmpd/tmp5"; mkdir -p "$TMPDIR"
  _conf="$_boot_tmpd/mdm-config-insecure.conf"
  printf 'KIT_MDM_GIT_REF="%s"\n' "$_boot_pinned_sha" > "$_conf"
  chmod 666 "$_conf"
  export MDM_CONFIG_PATH_OVERRIDE="$_conf"
  export MDM_CONFIG_SKIP_OWNER_CHECK=1
  _rc=0
  _mdm_bootstrap_and_reexec >/dev/null 2>&1 || _rc=$?
  assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "不安全 config は exit 50" \
    && pass "mdm-bootstrap: 不安全な管理設定ファイルを exit 50 で拒否" \
    || fail "mdm-bootstrap: 不安全 config の拒否が不正 (got $_rc)"
)

# launcher 自己完結ヘルパー: _mdm_boot_validate_gitref
(
  _rc=0; _mdm_boot_validate_gitref "main" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 ]] && pass "mdm-bootstrap: boot ref 検証が main を許容" \
    || fail "mdm-bootstrap: boot ref 検証が main を弾いた"
  _rc=0; _mdm_boot_validate_gitref "$_boot_pinned_sha" >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -eq 0 ]] && pass "mdm-bootstrap: boot ref 検証が 40桁 SHA を許容" \
    || fail "mdm-bootstrap: boot ref 検証が SHA を弾いた"
  _rc=0; _mdm_boot_validate_gitref '-evil' >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 ]] && pass "mdm-bootstrap: boot ref 検証が先頭ハイフンを拒否" \
    || fail "mdm-bootstrap: boot ref 検証が先頭ハイフンを許容してしまう"
  _rc=0; _mdm_boot_validate_gitref '' >/dev/null 2>&1 || _rc=$?
  [[ "$_rc" -ne 0 ]] && pass "mdm-bootstrap: boot ref 検証が空文字を拒否" \
    || fail "mdm-bootstrap: boot ref 検証が空文字を許容してしまう"
)

rm -rf "$_boot_tmpd"

# ── _mdm_finish（レシート書き出し + exit）: exit はサブシェル内で完結する
#    ため安全にテストできる。実 exit を裸で受けず、サブシェル終了後の $? を見る。
(
  _tmpd2="$(mktemp -d)"
  _tmpd2="$(cd "$_tmpd2" && pwd -P)"
  _rc=0
  ( export MDM_EUID_OVERRIDE=501
    # mdm_log 内部で参照されるグローバル（このサブシェル内では直接は読まない）。
    # shellcheck disable=SC2034
    MDM_LOG_FILE=""
    _mdm_finish "jane" "$_tmpd2" success "0" ) || _rc=$?
  assert_exit_code 0 "$_rc" "_mdm_finish は指定 exit code で終了" \
    && pass "mdm-bootstrap: _mdm_finish が exit 0 で終了" \
    || fail "mdm-bootstrap: _mdm_finish の exit code 不一致 (got $_rc)"

  _rcpt="$_tmpd2/Library/Application Support/ClaudeCodeStarterKit/receipt-jane.json"
  if [[ -f "$_rcpt" ]]; then
    pass "mdm-bootstrap: _mdm_finish が対象ユーザー領域にレシートを書く"
  else
    fail "mdm-bootstrap: _mdm_finish のレシートが生成されていない"
  fi
  if assert_json_field "$_rcpt" ".result" "success" "result=success"; then
    pass "mdm-bootstrap: _mdm_finish のレシート result フィールド"
  else
    fail "mdm-bootstrap: _mdm_finish のレシート result フィールド不正"
  fi
  rm -rf "$_tmpd2"
)
