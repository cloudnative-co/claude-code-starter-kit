#!/bin/bash
# tests/unit/test-mdm-wce-runtime.sh - root-owned WCE runtime acceptance tests

# Keep this suite process-isolated through tests/run-mdm-tests.sh.  Every
# mutation is confined to a canonical mktemp root and private Node/npm are
# replaced at their documented seams; no network process is started.
# shellcheck source=mdm/install-mdm.sh
MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

_mdm_wce_test_init() {
  _wce_tmp="$(builtin cd -P "$(mktemp -d)" && printf '%s' "$PWD")"
  _wce_auth="$_wce_tmp/authority"
  _wce_home="$_wce_tmp/home"
  _wce_node="$_wce_tmp/private-node"
  _wce_log="$_wce_tmp/npm.argv"
  _wce_uid="$(/usr/bin/id -u)"
  _wce_gid="$(/usr/bin/id -g)"
  _wce_user="$(/usr/bin/id -un)"
  /bin/mkdir -p "$_wce_auth/skills/web-content-extraction" \
    "$_wce_home/.claude/skills/web-content-extraction" \
    "$_wce_node/bin" "$_wce_node/lib/node_modules/npm/bin"
  /bin/chmod 0755 "$_wce_auth" "$_wce_auth/skills" \
    "$_wce_auth/skills/web-content-extraction" "$_wce_home" \
    "$_wce_home/.claude" "$_wce_home/.claude/skills" \
    "$_wce_home/.claude/skills/web-content-extraction" \
    "$_wce_node" "$_wce_node/bin" "$_wce_node/lib" \
    "$_wce_node/lib/node_modules" "$_wce_node/lib/node_modules/npm" \
    "$_wce_node/lib/node_modules/npm/bin"
  /bin/cp "$PROJECT_DIR/skills/web-content-extraction/package.json" \
    "$_wce_auth/skills/web-content-extraction/package.json"
  /bin/cp "$PROJECT_DIR/skills/web-content-extraction/package-lock.json" \
    "$_wce_auth/skills/web-content-extraction/package-lock.json"
  /bin/chmod 0644 "$_wce_auth/skills/web-content-extraction/package.json" \
    "$_wce_auth/skills/web-content-extraction/package-lock.json"
  printf '#!/bin/bash\nexit 0\n' > "$_wce_node/bin/node"
  printf '/* npm test seam */\n' \
    > "$_wce_node/lib/node_modules/npm/bin/npm-cli.js"
  /bin/chmod 0755 "$_wce_node/bin/node"
  /bin/chmod 0644 "$_wce_node/lib/node_modules/npm/bin/npm-cli.js"

  export _MDM_TEST_MODE=1
  export MDM_WCE_RUNTIME_ROOT_OVERRIDE="$_wce_tmp/runtime"
  export MDM_WCE_OWNER_UID_OVERRIDE="$_wce_uid"
  export MDM_WCE_OWNER_GID_OVERRIDE="$_wce_gid"
  export MDM_WCE_ARCH_OVERRIDE=arm64
  export MDM_EUID_OVERRIDE="$_wce_uid"
  export KIT_MDM_PREREQ_MODE=auto
  _MDM_AUTH_CHECKOUT="$_wce_auth"
  _MDM_WCE_VERIFIED_BUNDLE=""
  _MDM_EXPECTED_WCE_COMPONENT_SHA256=""
  _MDM_WCE_CARRIER_ACTIVE=false
  _MDM_GIT_SAFE_DIRECTORY=""

  _mdm_auth_expected_uid() { printf '%s' "$_wce_uid"; }
  _mdm_node_runtime_path() { printf '%s' "$_wce_node"; }
  _mdm_node_runtime_trusted() { [[ "$1" == "$_wce_node" ]]; }
  _mdm_exec_as_user() { shift 3; "$@"; }
}

_mdm_wce_test_fake_npm() {
  printf 'CALL\n' >> "$_wce_log"
  for _wce_arg in "$@"; do
    printf 'ARG:%s\n' "$_wce_arg" >> "$_wce_log"
  done
  /bin/mkdir -p node_modules
  while IFS= read -r _wce_dep; do
    /bin/mkdir -p "node_modules/$_wce_dep"
    printf '{"name":"%s"}\n' "$_wce_dep" \
      > "node_modules/$_wce_dep/package.json"
  done < <(/usr/bin/jq -r '.dependencies | keys[]' package.json)
}

_mdm_wce_test_quarantine_count() {
  local _target _candidate _count=0
  _target="$(_mdm_wce_runtime_path)" || return 1
  for _candidate in "${_target%/*}"/.wce-quarantine.*; do
    [[ -e "$_candidate" || -L "$_candidate" ]] || continue
    _count=$((_count + 1))
  done
  printf '%s' "$_count"
}

_mdm_wce_test_transient_count() {
  local _target _candidate _count=0
  _target="$(_mdm_wce_runtime_path)" || return 1
  for _candidate in "${_target%/*}"/.wce-stage.* \
    "${_target%/*}"/.wce-work.*; do
    [[ -e "$_candidate" || -L "$_candidate" ]] || continue
    _count=$((_count + 1))
  done
  printf '%s' "$_count"
}

_mdm_wce_test_stat_gid() {
  if [[ "$(/usr/bin/uname -s)" == Darwin ]]; then
    /usr/bin/stat -f '%g' "$1" 2>/dev/null
  else
    /usr/bin/stat -c '%g' "$1" 2>/dev/null
  fi
}

_mdm_wce_test_has_drop_arg() {
  local _expected="$1" _entry
  for _entry in "${MDM_DROP_ARGV[@]+"${MDM_DROP_ARGV[@]}"}"; do
    [[ "$_entry" == "$_expected" ]] && return 0
  done
  return 1
}

# Exact authenticated source bytes and package-lock contract.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  _package_sha=""; _lock_sha=""
  if _mdm_wce_runtime_source_hashes _package_sha _lock_sha \
    && [[ "$_package_sha" == "$_MDM_WCE_PACKAGE_SHA256" ]] \
    && [[ "$_lock_sha" == "$_MDM_WCE_LOCK_SHA256" ]] \
    && _mdm_wce_runtime_json_contract_valid \
      "$_wce_auth/skills/web-content-extraction/package.json" \
      "$_wce_auth/skills/web-content-extraction/package-lock.json" \
      "$_package_sha" "$_lock_sha"; then
    pass "mdm-wce: authenticated source hash と package-lock v3 contract を固定"
  else
    fail "mdm-wce: exact source hash/JSON contract の正常系を拒否"
  fi

  /usr/bin/jq \
    '.packages["node_modules/defuddle"].hasInstallScript = true' \
    "$_wce_auth/skills/web-content-extraction/package-lock.json" \
    > "$_wce_tmp/unsafe-lock.json"
  _unsafe_sha="$(_mdm_sha256_file "$_wce_tmp/unsafe-lock.json")"
  if ! _mdm_wce_runtime_json_contract_valid \
    "$_wce_auth/skills/web-content-extraction/package.json" \
    "$_wce_tmp/unsafe-lock.json" "$_package_sha" "$_unsafe_sha"; then
    pass "mdm-wce: matching hash でも install-script lock entry を拒否"
  else
    fail "mdm-wce: unsafe package-lock contract を許可"
  fi

  printf '\n' >> "$_wce_auth/skills/web-content-extraction/package.json"
  if ! _mdm_wce_runtime_source_hashes _package_sha _lock_sha; then
    pass "mdm-wce: authenticated source の 1 byte drift を拒否"
  else
    fail "mdm-wce: package source drift を exact hash として許可"
  fi
)

# Marker validation is byte-exact, including an otherwise JSON-ignorable NUL.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  _bundle="$_wce_tmp/marker-bundle"
  /bin/mkdir -m 0755 "$_bundle"
  _marker="$_bundle/$_MDM_WCE_MARKER_FILE"
  _expected="$(_mdm_wce_runtime_marker_json arm64 \
    "$_MDM_WCE_PACKAGE_SHA256" "$_MDM_WCE_LOCK_SHA256")"$'\n'
  _mdm_wce_runtime_marker_json arm64 "$_MDM_WCE_PACKAGE_SHA256" \
    "$_MDM_WCE_LOCK_SHA256" > "$_marker"
  if [[ "$(/bin/cat "$_marker")"$'\n' == "$_expected" ]] \
    && _mdm_wce_runtime_marker_valid "$_bundle" arm64 \
      "$_MDM_WCE_PACKAGE_SHA256" "$_MDM_WCE_LOCK_SHA256"; then
    pass "mdm-wce: marker の key/order/newline を exact bytes で検証"
  else
    fail "mdm-wce: canonical marker bytes を拒否"
  fi
  printf '\0' >> "$_marker"
  if ! _mdm_wce_runtime_marker_valid "$_bundle" arm64 \
    "$_MDM_WCE_PACKAGE_SHA256" "$_MDM_WCE_LOCK_SHA256"; then
    pass "mdm-wce: canonical JSON 後方の NUL suffix を拒否"
  else
    fail "mdm-wce: marker の NUL suffix を許可"
  fi
)

# Fresh managed directories are normalized to the explicit trust owner/group;
# they do not retain a differing parent group inherited from mkdir.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  _admin_gid=80
  if [[ "$(/usr/bin/uname -s)" == Darwin \
    && " $_wce_gid " != *" $_admin_gid "* \
    && " $(/usr/bin/id -G) " == *" $_admin_gid "* ]]; then
    export MDM_WCE_OWNER_GID_OVERRIDE="$_admin_gid"
    _prepare_rc=0
    _mdm_wce_runtime_prepare_base || _prepare_rc=$?
    _target="$(_mdm_wce_runtime_path)"; _version="${_target%/*}"
    if [[ "$_prepare_rc" -eq 0 \
      && "$(_mdm_wce_test_stat_gid "$MDM_WCE_RUNTIME_ROOT_OVERRIDE")" == "$_admin_gid" \
      && "$(_mdm_wce_test_stat_gid "$_version")" == "$_admin_gid" \
      && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$MDM_WCE_RUNTIME_ROOT_OVERRIDE")")" == 0755 \
      && "$(_mdm_mode_normalize "$(_mdm_stat_mode "$_version")")" == 0755 \
      && "$(_mdm_wce_test_stat_gid "$_wce_tmp")" == "$_wce_gid" ]]; then
      pass "mdm-wce: fresh base は inherited parent GID と異なる trust GID へ正規化"
    else
      fail "mdm-wce: fresh base の owner/group/mode 正規化に失敗"
    fi
  else
    skip "mdm-wce: inherited parent GID と異なる fresh base" \
      "Darwin admin group fixture unavailable"
  fi
)

# npm is invoked through env -i with only the pinned Node, fixed flags, and
# validated uppercase proxy allowlist.  The seam records argv and builds a
# minimal installed tree in the stage without executing Node or npm.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  _mdm_wce_runtime_npm_exec() { _mdm_wce_test_fake_npm "$@"; }
  _mdm_wce_runtime_prepare_base
  _target="$(_mdm_wce_runtime_path)"; _version="${_target%/*}"
  _stage="$(/usr/bin/mktemp -d "$_version/.wce-stage.XXXXXX")"
  _work="$(/usr/bin/mktemp -d "$_version/.wce-work.XXXXXX")"
  /bin/cp "$_wce_auth/skills/web-content-extraction/package.json" \
    "$_stage/package.json"
  /bin/cp "$_wce_auth/skills/web-content-extraction/package-lock.json" \
    "$_stage/package-lock.json"
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY
  export HTTP_PROXY=http://proxy.example:8080
  export HTTPS_PROXY=https://proxy.example:8443
  export NO_PROXY=localhost,.example.invalid
  export NODE_OPTIONS=--require=/tmp/attacker.js
  export npm_config_userconfig=/tmp/attacker.npmrc
  if _mdm_wce_runtime_npm_ci "$_stage" "$_work" \
    && [[ "$(/usr/bin/grep -c '^CALL$' "$_wce_log")" -eq 1 ]] \
    && /usr/bin/grep -Fxq 'ARG:/usr/bin/env' "$_wce_log" \
    && /usr/bin/grep -Fxq 'ARG:-i' "$_wce_log" \
    && /usr/bin/grep -Fxq "ARG:HOME=$_work/home" "$_wce_log" \
    && /usr/bin/grep -Fxq "ARG:PATH=$_wce_node/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$_wce_log" \
    && /usr/bin/grep -Fxq 'ARG:HTTP_PROXY=http://proxy.example:8080' "$_wce_log" \
    && /usr/bin/grep -Fxq 'ARG:HTTPS_PROXY=https://proxy.example:8443' "$_wce_log" \
    && /usr/bin/grep -Fxq 'ARG:NO_PROXY=localhost,.example.invalid' "$_wce_log" \
    && /usr/bin/grep -Fxq "ARG:$_wce_node/bin/node" "$_wce_log" \
    && /usr/bin/grep -Fxq "ARG:$_wce_node/lib/node_modules/npm/bin/npm-cli.js" "$_wce_log" \
    && /usr/bin/grep -Fxq 'ARG:ci' "$_wce_log" \
    && /usr/bin/grep -Fxq 'ARG:--omit=dev' "$_wce_log" \
    && /usr/bin/grep -Fxq 'ARG:--ignore-scripts' "$_wce_log" \
    && /usr/bin/grep -Fxq 'ARG:--no-bin-links' "$_wce_log" \
    && ! /usr/bin/grep -Fq 'attacker' "$_wce_log"; then
    pass "mdm-wce: npm argv/env を env -i と固定 flag/proxy allowlist へ分離"
  else
    fail "mdm-wce: npm argv/env isolation contract が不正"
  fi

  : > "$_wce_log"
  /bin/rm -rf "$_work"
  _work="$(/usr/bin/mktemp -d "$_version/.wce-work.XXXXXX")"
  export HTTP_PROXY=file:///tmp/socket
  unset HTTPS_PROXY NO_PROXY
  _proxy_rc=0
  _mdm_wce_runtime_npm_ci "$_stage" "$_work" >/dev/null 2>&1 \
    || _proxy_rc=$?
  if [[ "$_proxy_rc" -eq "$MDM_EXIT_CONFIG" && ! -s "$_wce_log" ]]; then
    pass "mdm-wce: 不正 proxy は npm seam 到達前に config error"
  else
    fail "mdm-wce: 不正 proxy を npm へ渡した (rc=$_proxy_rc)"
  fi
)

# Auto mode builds once, validates the complete tree, and reuses it without a
# second npm call.  Direct dependencies and xattr policy are part of trust.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY NODE_OPTIONS npm_config_userconfig
  _mdm_wce_runtime_npm_exec() { _mdm_wce_test_fake_npm "$@"; }
  _first_rc=0; _second_rc=0
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid" \
    || _first_rc=$?
  _target="$(_mdm_wce_runtime_path)"
  _first_digest="$_MDM_EXPECTED_WCE_COMPONENT_SHA256"
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid" \
    || _second_rc=$?
  if [[ "$_first_rc" -eq 0 && "$_second_rc" -eq 0 \
    && "$(/usr/bin/grep -c '^CALL$' "$_wce_log")" -eq 1 \
    && "$_MDM_WCE_VERIFIED_BUNDLE" == "$_target" \
    && "$_first_digest" =~ ^[0-9a-f]{64}$ \
    && "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" == "$_first_digest" ]] \
    && _mdm_wce_runtime_trusted "$_target"; then
    pass "mdm-wce: auto build 後は exact trusted bundle を npm 再実行なく再利用"
  else
    fail "mdm-wce: auto build/reuse が収束しない"
  fi

  /bin/mv "$_target/node_modules/defuddle" "$_wce_tmp/defuddle.saved"
  if ! _mdm_wce_runtime_metadata_valid "$_target" "$_wce_uid" "$_wce_gid"; then
    pass "mdm-wce: 全 direct dependency directory/package.json を必須化"
  else
    fail "mdm-wce: direct dependency 欠落を許可"
  fi
  /bin/mv "$_wce_tmp/defuddle.saved" "$_target/node_modules/defuddle"

  if [[ "$(/usr/bin/uname -s)" == Darwin ]] \
    && /usr/bin/xattr -w com.apple.provenance mdm-test \
      "$_target/node_modules/defuddle/package.json" 2>/dev/null; then
    if _mdm_wce_runtime_metadata_valid "$_target" "$_wce_uid" "$_wce_gid"; then
      pass "mdm-wce: bundle entry の com.apple.provenance xattr のみ許容"
    else
      fail "mdm-wce: provenance-only xattr を拒否"
    fi
    /usr/bin/xattr -d com.apple.provenance \
      "$_target/node_modules/defuddle/package.json" 2>/dev/null || true
  else
    skip "mdm-wce: provenance-only xattr" "writable Darwin provenance fixture unavailable"
  fi

  if [[ "$(/usr/bin/uname -s)" == Darwin ]] \
    && /usr/bin/xattr -w com.cloudnative.mdm-wce-test value \
      "$_target/node_modules/defuddle/package.json" 2>/dev/null; then
    if ! _mdm_wce_runtime_metadata_valid "$_target" "$_wce_uid" "$_wce_gid"; then
      pass "mdm-wce: provenance 以外の bundle xattr を拒否"
    else
      fail "mdm-wce: unapproved xattr を許可"
    fi
    /usr/bin/xattr -d com.cloudnative.mdm-wce-test \
      "$_target/node_modules/defuddle/package.json" 2>/dev/null || true
  else
    skip "mdm-wce: unapproved xattr rejection" "writable Darwin xattr fixture unavailable"
  fi
)

# An invalid fixed target is quarantined only after the replacement stage is
# trusted, while the exact fixed path receives the new tree.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY
  _mdm_wce_runtime_npm_exec() { _mdm_wce_test_fake_npm "$@"; }
  _mdm_wce_runtime_prepare_base
  _target="$(_mdm_wce_runtime_path)"
  /bin/mkdir -m 0755 "$_target"
  printf 'old-invalid\n' > "$_target/sentinel"
  _rc=0
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid" || _rc=$?
  _saved=""
  for _candidate in "${_target%/*}"/.wce-quarantine.*; do
    [[ -f "$_candidate/sentinel" ]] && _saved="$_candidate"
  done
  if [[ "$_rc" -eq 0 && -n "$_saved" \
    && "$(/bin/cat "$_saved/sentinel")" == old-invalid \
    && "$(_mdm_wce_test_transient_count)" -eq 0 ]] \
    && _mdm_wce_runtime_trusted "$_target"; then
    pass "mdm-wce: invalid fixed leaf を隔離して exact target へ publish"
  else
    fail "mdm-wce: invalid target quarantine/publish が不正"
  fi
)

# If publication fails after quarantine, the original inode is restored and
# no quarantine/work name remains from the failed attempt.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY
  _mdm_wce_runtime_npm_exec() { _mdm_wce_test_fake_npm "$@"; }
  _mdm_wce_runtime_prepare_base
  _target="$(_mdm_wce_runtime_path)"
  /bin/mkdir -m 0755 "$_target"
  printf 'restore-me\n' > "$_target/sentinel"
  _old_identity="$(_mdm_stat_identity "$_target")"
  _publish_failed=0
  _mdm_wce_runtime_promote() {
    if [[ "$_publish_failed" -eq 0 && "$2" == "$_target" \
      && "${1##*/}" == .wce-stage.* ]]; then
      _publish_failed=1
      return 1
    fi
    _mdm_node_runtime_atomic_rename_system "$1" "$2" create
  }
  _rc=0
  _mdm_wce_runtime_rebuild "$_target" >/dev/null 2>&1 || _rc=$?
  if [[ "$_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_target")" == "$_old_identity" \
    && "$(/bin/cat "$_target/sentinel")" == restore-me \
    && "$(_mdm_wce_test_quarantine_count)" -eq 0 \
    && "$(_mdm_wce_test_transient_count)" -eq 0 ]]; then
    pass "mdm-wce: quarantine 後 publish 失敗は旧 inode を rollback"
  else
    fail "mdm-wce: publish failure rollback が旧 target を保持しない"
  fi
)

# Fail mode is validation-only.  Both a valid activation and an invalid marker
# are checked without npm, quarantine, replacement, or marker rewriting.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY
  _mdm_wce_runtime_npm_exec() { _mdm_wce_test_fake_npm "$@"; }
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid"
  _target="$(_mdm_wce_runtime_path)"
  _preseed_digest="$(_mdm_artifact_digest tree \
    "$_target" "$_wce_uid" "$_wce_gid")"
  export KIT_MDM_PREREQ_MODE=fail
  _preseed_rc=0
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid" \
    || _preseed_rc=$?
  _preseed_after="$(_mdm_artifact_digest tree \
    "$_target" "$_wce_uid" "$_wce_gid")"
  if [[ "$_preseed_rc" -eq 0 \
    && "$_MDM_WCE_VERIFIED_BUNDLE" == "$_target" \
    && "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" == "$_preseed_digest" \
    && "$_preseed_after" == "$_preseed_digest" \
    && "$(/usr/bin/grep -c '^CALL$' "$_wce_log")" -eq 1 \
    && ! -e "$_wce_home/.claude/skills/web-content-extraction/node_modules" \
    && ! -L "$_wce_home/.claude/skills/web-content-extraction/node_modules" ]]; then
    pass "mdm-wce: fail mode 初回は activation 無し trusted preseed を read-only capture"
  else
    fail "mdm-wce: fail mode が bundle-only preseed を拒否/変更"
  fi

  _dry_missing_rc=0
  _mdm_wce_runtime_validate_dryrun \
    "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
    || _dry_missing_rc=$?
  /bin/ln -s "$_target/node_modules" \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  _dry_active_rc=0
  _mdm_wce_runtime_validate_dryrun \
    "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
    || _dry_active_rc=$?
  /bin/rm -f "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  /bin/ln -s "$_target/wrong-node-modules" \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  _dry_wrong_rc=0
  _mdm_wce_runtime_validate_dryrun \
    "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
    || _dry_wrong_rc=$?
  _dry_wrong_value=""
  _mdm_readlink_exact \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules" \
    _dry_wrong_value || true
  /bin/rm -f "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  printf 'replaceable\n' \
    > "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  /bin/chmod 0600 "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  _dry_regular_rc=0
  _mdm_wce_runtime_validate_dryrun \
    "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
    || _dry_regular_rc=$?
  _dry_regular_value="$(/bin/cat \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules")"
  /bin/rm -f "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  /bin/mkdir "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  printf 'preserve\n' \
    > "$_wce_home/.claude/skills/web-content-extraction/node_modules/local.txt"
  _dry_directory_before="$(_mdm_stat_identity \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules")"
  _dry_directory_rc=0
  _mdm_wce_runtime_validate_dryrun \
    "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
    || _dry_directory_rc=$?
  _dry_directory_after="$(_mdm_stat_identity \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules")"
  _dry_directory_value="$(/bin/cat \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules/local.txt")"
  /bin/chmod 0777 \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  _dry_unsafe_directory_before="$(_mdm_stat_identity \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules")"
  _dry_unsafe_directory_rc=0
  _mdm_wce_runtime_validate_dryrun \
    "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
    || _dry_unsafe_directory_rc=$?
  _dry_unsafe_directory_after="$(_mdm_stat_identity \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules")"
  /bin/chmod 0755 \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  _dry_acl_ready=false
  _dry_acl_rc=1
  _dry_acl_unchanged=true
  if [[ "$(/usr/bin/uname -s 2>/dev/null)" == Darwin ]] \
    && /bin/chmod +a 'everyone allow write' \
      "$_wce_home/.claude/skills/web-content-extraction/node_modules" \
      2>/dev/null; then
    _dry_acl_ready=true
  elif command -v setfacl >/dev/null 2>&1 \
    && setfacl -m "u:$(/usr/bin/id -u):rwx" \
      "$_wce_home/.claude/skills/web-content-extraction/node_modules" \
      2>/dev/null; then
    _dry_acl_ready=true
  fi
  if [[ "$_dry_acl_ready" == true ]]; then
    _dry_acl_before="$(_mdm_stat_identity \
      "$_wce_home/.claude/skills/web-content-extraction/node_modules")"
    _dry_acl_rc=0
    _mdm_wce_runtime_validate_dryrun \
      "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
      || _dry_acl_rc=$?
    _dry_acl_after="$(_mdm_stat_identity \
      "$_wce_home/.claude/skills/web-content-extraction/node_modules")"
    [[ "$_dry_acl_before" == "$_dry_acl_after" ]] \
      || _dry_acl_unchanged=false
  fi
  /bin/rm -rf "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  _dry_fifo_rc=0
  _dry_fifo_preserved=false
  _wce_mkfifo="$(command -v mkfifo || true)"
  if [[ -n "$_wce_mkfifo" ]] \
    && "$_wce_mkfifo" \
      "$_wce_home/.claude/skills/web-content-extraction/node_modules"; then
    _mdm_wce_runtime_validate_dryrun \
      "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
      || _dry_fifo_rc=$?
    [[ -p "$_wce_home/.claude/skills/web-content-extraction/node_modules" ]] \
      && _dry_fifo_preserved=true
    /bin/rm -f \
      "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  else
    _dry_fifo_rc=1
    _dry_fifo_preserved=true
  fi
  printf 'hardlink\n' > "$_wce_tmp/hardlink-source"
  /bin/ln "$_wce_tmp/hardlink-source" \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  _dry_hardlink_rc=0
  _mdm_wce_runtime_validate_dryrun \
    "$_wce_user" "$_wce_home" "$_wce_uid" >/dev/null 2>&1 \
    || _dry_hardlink_rc=$?
  /bin/rm -f "$_wce_home/.claude/skills/web-content-extraction/node_modules" \
    "$_wce_tmp/hardlink-source"
  if [[ "$_dry_missing_rc" -eq 0 && "$_dry_active_rc" -eq 0 \
    && "$_dry_wrong_rc" -eq 0 && "$_dry_regular_rc" -eq 0 \
    && "$_dry_directory_rc" -eq 0 && "$_dry_hardlink_rc" -ne 0 \
    && "$_dry_unsafe_directory_rc" -ne 0 \
    && "$_dry_unsafe_directory_before" == "$_dry_unsafe_directory_after" \
    && "$_dry_fifo_rc" -ne 0 && "$_dry_fifo_preserved" == true \
    && ( "$_dry_acl_ready" != true \
      || ( "$_dry_acl_rc" -ne 0 && "$_dry_acl_unchanged" == true ) ) \
    && "$(_mdm_wce_test_quarantine_count)" -eq 0 \
    && "$(/usr/bin/grep -c '^CALL$' "$_wce_log")" -eq 1 \
    && "$_dry_wrong_value" == "$_target/wrong-node-modules" \
    && "$_dry_regular_value" == replaceable \
    && "$_dry_directory_before" == "$_dry_directory_after" \
    && "$_dry_directory_value" == preserve ]]; then
    pass "mdm-wce: dry-run は安全なdirectoryを非破壊の予定移行として許可"
  else
    fail "mdm-wce: dry-run のactivation repair対称性が不正"
  fi
  /bin/ln -s "$_target/node_modules" \
    "$_wce_home/.claude/skills/web-content-extraction/node_modules"
  _before_digest="$(_mdm_artifact_digest tree "$_target" "$_wce_uid" "$_wce_gid")"
  _valid_rc=0
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid" \
    || _valid_rc=$?
  _after_digest="$(_mdm_artifact_digest tree "$_target" "$_wce_uid" "$_wce_gid")"
  if [[ "$_valid_rc" -eq 0 && "$_after_digest" == "$_before_digest" \
    && "$(/usr/bin/grep -c '^CALL$' "$_wce_log")" -eq 1 ]]; then
    pass "mdm-wce: fail mode の valid runtime 検証は read-only"
  else
    fail "mdm-wce: fail mode が valid runtime を変更/再構築"
  fi

  printf '\0' >> "$_target/$_MDM_WCE_MARKER_FILE"
  _bad_identity="$(_mdm_stat_identity "$_target/$_MDM_WCE_MARKER_FILE")"
  _bad_sha="$(_mdm_sha256_file "$_target/$_MDM_WCE_MARKER_FILE")"
  _quarantines="$(_mdm_wce_test_quarantine_count)"
  _invalid_rc=0
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid" \
    >/dev/null 2>&1 || _invalid_rc=$?
  if [[ "$_invalid_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_target/$_MDM_WCE_MARKER_FILE")" == "$_bad_identity" \
    && "$(_mdm_sha256_file "$_target/$_MDM_WCE_MARKER_FILE")" == "$_bad_sha" \
    && "$(_mdm_wce_test_quarantine_count)" == "$_quarantines" \
    && "$(/usr/bin/grep -c '^CALL$' "$_wce_log")" -eq 1 ]]; then
    pass "mdm-wce: fail mode は invalid target も隔離/修復せず拒否"
  else
    fail "mdm-wce: fail mode が invalid target を mutation"
  fi
)

# Activation validation binds the home owner/mode/effective-search boundary. A
# writable home is rejected without mutation, while macOS's standard harmless
# deny-delete ACL remains compatible.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY
  _mdm_wce_runtime_npm_exec() { _mdm_wce_test_fake_npm "$@"; }
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid"
  _target="$(_mdm_wce_runtime_path)"
  _skill="$_wce_home/.claude/skills/web-content-extraction"
  /bin/ln -s "$_target/node_modules" "$_skill/node_modules"

  /bin/chmod 0777 "$_wce_home"
  _home_identity="$(_mdm_stat_identity "$_wce_home")"
  _skill_identity="$(_mdm_stat_identity "$_skill")"
  _unsafe_rc=0
  _mdm_wce_runtime_activation_valid \
    "$_wce_user" "$_wce_home" "$_wce_uid" "$_target" \
    >/dev/null 2>&1 || _unsafe_rc=$?
  if [[ "$_unsafe_rc" -ne 0 \
    && "$(_mdm_stat_identity "$_wce_home")" == "$_home_identity" \
    && "$(_mdm_stat_identity "$_skill")" == "$_skill_identity" \
    && -L "$_skill/node_modules" \
    && "$(/usr/bin/readlink "$_skill/node_modules")" \
      == "$_target/node_modules" ]]; then
    pass "mdm-wce: mode 0777 home は activation validator が非変更で拒否"
  else
    fail "mdm-wce: unsafe home の activation を許可/変更"
  fi
  /bin/chmod 0755 "$_wce_home"

  if [[ "$(/usr/bin/uname -s)" == Darwin ]] \
    && /bin/chmod +a 'everyone deny delete' "$_wce_home" 2>/dev/null; then
    if _mdm_wce_runtime_activation_valid \
        "$_wce_user" "$_wce_home" "$_wce_uid" "$_target"; then
      pass "mdm-wce: 標準 home deny-delete ACL は effective search を妨げない"
    else
      fail "mdm-wce: benign home deny-delete ACL だけで activation を拒否"
    fi
    /bin/chmod -N "$_wce_home"
  else
    skip "mdm-wce: standard home deny-delete ACL" \
      "Darwin ACL fixture unavailable"
  fi
)

# The user-phase carrier is absent unless explicitly active, exact-path bound,
# and freshly trusted.  A failed gate clears argv rather than leaking a path.
(
  _mdm_wce_test_init
  trap '/bin/rm -rf "$_wce_tmp"' EXIT INT TERM
  unset HTTP_PROXY HTTPS_PROXY NO_PROXY
  _mdm_wce_runtime_npm_exec() { _mdm_wce_test_fake_npm "$@"; }
  _mdm_ensure_wce_runtime "$_wce_user" "$_wce_home" "$_wce_uid"
  _target="$(_mdm_wce_runtime_path)"
  _MDM_WCE_VERIFIED_BUNDLE="$_target"
  _MDM_WCE_CARRIER_ACTIVE=false
  if mdm_build_drop_argv "$_wce_uid" "$_wce_user" "$_wce_home" /bin/true \
    && ! _mdm_wce_test_has_drop_arg "KIT_MDM_WCE_RUNTIME_BUNDLE=$_target"; then
    pass "mdm-wce: inactive carrier は降格 env に含めない"
  else
    fail "mdm-wce: inactive carrier が user env へ漏出"
  fi

  _MDM_WCE_CARRIER_ACTIVE=true
  if mdm_build_drop_argv "$_wce_uid" "$_wce_user" "$_wce_home" /bin/true \
    && _mdm_wce_test_has_drop_arg "KIT_MDM_WCE_RUNTIME_BUNDLE=$_target"; then
    pass "mdm-wce: active/exact/trusted carrier だけを降格 env へ追加"
  else
    fail "mdm-wce: valid carrier を降格 env へ渡せない"
  fi

  _MDM_WCE_VERIFIED_BUNDLE="$_target-wrong"
  _wrong_rc=0
  mdm_build_drop_argv "$_wce_uid" "$_wce_user" "$_wce_home" /bin/true \
    >/dev/null 2>&1 || _wrong_rc=$?
  if [[ "$_wrong_rc" -ne 0 && "${#MDM_DROP_ARGV[@]}" -eq 0 ]]; then
    pass "mdm-wce: active carrier の non-exact path は fail-closed"
  else
    fail "mdm-wce: non-exact carrier path を許可"
  fi

  _MDM_WCE_VERIFIED_BUNDLE="$_target"
  printf '\n' >> "$_target/node_modules/defuddle/package.json"
  _drift_trusted=false
  _mdm_wce_runtime_trusted "$_target" && _drift_trusted=true
  _drift_digest="$_MDM_WCE_RUNTIME_DIGEST"
  _digest_rc=0
  mdm_build_drop_argv "$_wce_uid" "$_wce_user" "$_wce_home" /bin/true \
    >/dev/null 2>&1 || _digest_rc=$?
  if [[ "$_drift_trusted" == true \
    && "$_drift_digest" =~ ^[0-9a-f]{64}$ \
    && "$_drift_digest" != "$_MDM_EXPECTED_WCE_COMPONENT_SHA256" \
    && "$_digest_rc" -ne 0 && "${#MDM_DROP_ARGV[@]}" -eq 0 ]]; then
    pass "mdm-wce: structurally trusted でも expected digest drift carrier を拒否"
  else
    fail "mdm-wce: expected digest と異なる trusted carrier を許可"
  fi

  _MDM_EXPECTED_WCE_COMPONENT_SHA256="$_drift_digest"
  printf '\0' >> "$_target/$_MDM_WCE_MARKER_FILE"
  _untrusted_rc=0
  mdm_build_drop_argv "$_wce_uid" "$_wce_user" "$_wce_home" /bin/true \
    >/dev/null 2>&1 || _untrusted_rc=$?
  if [[ "$_untrusted_rc" -ne 0 && "${#MDM_DROP_ARGV[@]}" -eq 0 ]]; then
    pass "mdm-wce: exact path でも trust drift 後の carrier を拒否"
  else
    fail "mdm-wce: untrusted carrier を user env へ渡した"
  fi
)

# Static ordering keeps root construction before the only setup drop, limits
# the carrier lifetime to that drop, and revalidates trust + activation after.
_root_phase="$(/usr/bin/sed -n \
  '/^_mdm_run_root_user_phase()/,/^_mdm_run_user_phase()/p' \
  "$PROJECT_DIR/mdm/install-mdm.sh")"
_ensure_line="$(printf '%s\n' "$_root_phase" | /usr/bin/grep -n \
  '_mdm_ensure_wce_runtime ' | /usr/bin/sed -n '1s/:.*//p' || true)"
_active_line="$(printf '%s\n' "$_root_phase" | /usr/bin/grep -n \
  '_MDM_WCE_CARRIER_ACTIVE=true' | /usr/bin/sed -n '1s/:.*//p' || true)"
_exec_line="$(printf '%s\n' "$_root_phase" | /usr/bin/grep -n \
  '_mdm_exec_setup_as_user ' | /usr/bin/sed -n '1s/:.*//p' || true)"
_clear_line="$(printf '%s\n' "$_root_phase" | /usr/bin/grep -n \
  '_MDM_WCE_CARRIER_ACTIVE=false' | /usr/bin/tail -1 \
  | /usr/bin/cut -d: -f1 || true)"
_post_activation_line="$(printf '%s\n' "$_root_phase" | /usr/bin/grep -n \
  '_mdm_wce_runtime_activation_valid' | /usr/bin/tail -1 \
  | /usr/bin/cut -d: -f1 || true)"
if [[ "$_ensure_line" =~ ^[0-9]+$ && "$_active_line" =~ ^[0-9]+$ \
  && "$_exec_line" =~ ^[0-9]+$ && "$_clear_line" =~ ^[0-9]+$ \
  && "$_post_activation_line" =~ ^[0-9]+$ \
  && "$_ensure_line" -lt "$_active_line" \
  && "$_active_line" -lt "$_exec_line" \
  && "$_exec_line" -lt "$_clear_line" \
  && "$_clear_line" -lt "$_post_activation_line" \
  && "$(printf '%s\n' "$_root_phase" | /usr/bin/grep -c \
    '_mdm_wce_runtime_activation_valid')" -ge 1 \
  && "$(printf '%s\n' "$_root_phase" | /usr/bin/grep -c \
    '_mdm_wce_runtime_trusted')" -ge 2 ]]; then
  pass "mdm-wce: root phase は build→trust→carrier→setup→post-attest 順"
else
  fail "mdm-wce: root phase の WCE ordering/static wiring が不正"
fi

mdm_test_reached_end
