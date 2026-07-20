#!/bin/bash
# tests/unit/test-mdm-ref-validate.sh - ref 形式検証と SHA 解決

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

# ローカルにテスト用リポジトリを作る
_repo="$(mktemp -d)"
(
  cd "$_repo" || exit 1
  git init -q
  mkdir -p mdm
  printf 'a\n' > f.txt
  cp "$PROJECT_DIR/mdm/render-expected.py" mdm/render-expected.py
  git add f.txt mdm/render-expected.py
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
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
# NOTE: 裸のステートメント呼び出し + $? 参照は set -euo pipefail 下では
# 失敗時にテストランナー全体を即終了させない。
# `|| _rc=$?` で明示的に捕捉してから assert する。
_rc=0
mdm_resolve_ref_sha "$_repo" "--force" >/dev/null 2>&1 || _rc=$?
assert_exit_code "$MDM_EXIT_CONFIG" "$_rc" "不正 ref は exit CONFIG" \
  && pass "mdm-ref: 不正 ref 形式で exit 50" \
  || fail "mdm-ref: 不正 ref 形式で exit 50 を返すべき"

# 存在しない ref は exit SETUP(30)
_rc=0
mdm_resolve_ref_sha "$_repo" "nonexistent-branch" >/dev/null 2>&1 || _rc=$?
assert_exit_code "$MDM_EXIT_SETUP" "$_rc" "存在しない ref は exit SETUP" \
  && pass "mdm-ref: 存在しない ref で exit 30" \
  || fail "mdm-ref: 存在しない ref で exit 30 を返すべき"

# clean child は adjacent renderer を受け取った場合だけ bundle origin を
# publishし、mdm_main より前に checkout 束縛を有効化する。実 launcher は
# macOS root 専用なので、helper の挙動と clean-child call-site の両方を固定する。
(
  _MDM_EXPECTED_RENDERER=stale
  _MDM_EXPECTED_RENDERER_SNAPSHOT=0
  _MDM_EXPECTED_RENDERER_OWNER_UID=999
  _MDM_EXPECTED_RENDERER_BUNDLE_SNAPSHOT=0
  _mdm_publish_launcher_renderer_snapshot /private/tmp/trusted-renderer
  _renderer_publish_set=false
  if [[ "$_MDM_EXPECTED_RENDERER" == /private/tmp/trusted-renderer \
    && "$_MDM_EXPECTED_RENDERER_SNAPSHOT" == 1 \
    && -z "$_MDM_EXPECTED_RENDERER_OWNER_UID" \
    && "$_MDM_EXPECTED_RENDERER_BUNDLE_SNAPSHOT" == 1 ]]; then
    _renderer_publish_set=true
  fi
  _mdm_publish_launcher_renderer_snapshot ""
  if [[ "$_renderer_publish_set" == true \
    && -z "$_MDM_EXPECTED_RENDERER" \
    && "$_MDM_EXPECTED_RENDERER_SNAPSHOT" == 0 \
    && -z "$_MDM_EXPECTED_RENDERER_OWNER_UID" \
    && "$_MDM_EXPECTED_RENDERER_BUNDLE_SNAPSHOT" == 0 ]]; then
    pass "mdm-ref: launcher helperはbundle originを非空snapshotだけへ付与"
  else
    fail "mdm-ref: launcher helperのbundle renderer publish契約が不正"
  fi
)
if /usr/bin/awk '
  /^[[:space:]]*\. "\$_mdm_script"$/ && !source_line {
    source_line = NR
  }
  /^[[:space:]]*_mdm_publish_launcher_renderer_snapshot "\$_mdm_renderer"$/ \
      && source_line && !publish_line {
    publish_line = NR
  }
  /^[[:space:]]*mdm_main "\$@"$/ && publish_line && !main_line {
    main_line = NR
  }
  END {
    exit !(source_line < publish_line && publish_line < main_line)
  }
' "$PROJECT_DIR/mdm/install-mdm.sh"; then
  pass "mdm-ref: direct launcherはbundle originをclean childのmain前にpublish"
else
  fail "mdm-ref: direct launcherからbundle renderer origin伝播が欠落"
fi

# direct root launcher の trusted bundle renderer は、解決済み checkout の
# renderer と byte-exact な場合だけ実行可能になる。checkout 側は照合専用の
# snapshot とし、Python としては実行しない。
(
  _renderer_tmp="$(mktemp -d)"
  _renderer_snapshots="$_renderer_tmp/snapshots"
  _renderer_auth="$_renderer_tmp/auth"
  /bin/mkdir -p "$_renderer_snapshots" "$_renderer_auth"
  /bin/chmod 700 "$_renderer_snapshots" "$_renderer_auth"
  export MDM_TEST_TMP_ROOT="$_renderer_snapshots"
  export MDM_AUTH_TMPDIR_OVERRIDE="$_renderer_auth"
  MDM_AUTH_OWNER_UID_OVERRIDE="$(/usr/bin/id -u)"
  export MDM_AUTH_OWNER_UID_OVERRIDE
  KIT_MDM_EXPECTED_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export KIT_MDM_EXPECTED_POLICY_SHA256
  _renderer_uid="$(/usr/bin/id -u)"

  _renderer_snapshot_count() {
    /usr/bin/find "$_renderer_snapshots" -type f \
      -name 'claude-kit-mdm-launcher.*' -print \
      | /usr/bin/awk 'END { print NR + 0 }'
  }

  _renderer_auth_entry_count() {
    /usr/bin/find "$_renderer_auth" ! -path "$_renderer_auth" -print \
      | /usr/bin/awk 'END { print NR + 0 }'
  }

  _renderer_set_bundle() {
    _MDM_EXPECTED_RENDERER="$1"
    _MDM_EXPECTED_RENDERER_SNAPSHOT=1
    _MDM_EXPECTED_RENDERER_OWNER_UID="$_renderer_uid"
    _MDM_EXPECTED_RENDERER_BUNDLE_SNAPSHOT=1
    _MDM_CHECKOUT_RENDERER_SNAPSHOT=""
    _MDM_CHECKOUT_RENDERER_OWNER_UID=""
  }

  # 完全一致時は checkout snapshot を即時削除し、実行権威である bundle
  # snapshot だけを残す。
  _renderer_bundle=""
  _mdm_launcher_snapshot \
    "$_repo/mdm/render-expected.py" _renderer_bundle
  _renderer_set_bundle "$_renderer_bundle"
  _renderer_match_ok=false
  if _mdm_verify_expected_renderer_checkout_binding \
      "$_repo" "$_head_sha" "$_renderer_bundle" "$_renderer_uid" \
    && [[ -f "$_renderer_bundle" && ! -L "$_renderer_bundle" \
      && "$_MDM_EXPECTED_RENDERER" == "$_renderer_bundle" \
      && -z "$_MDM_CHECKOUT_RENDERER_SNAPSHOT" \
      && -z "$_MDM_CHECKOUT_RENDERER_OWNER_UID" \
      && "$(_renderer_snapshot_count)" -eq 1 ]]; then
    _renderer_match_ok=true
  fi
  if [[ "$_renderer_match_ok" == true ]]; then
    pass "mdm-ref: 同一bytesのbundle/checkout rendererを束縛しbundleだけ保持"
  else
    fail "mdm-ref: 同一rendererの束縛またはcheckout snapshot cleanupが不正"
  fi
  _renderer_cleanup_ok=false
  if _mdm_cleanup_renderer_snapshot \
    && [[ -z "$_MDM_EXPECTED_RENDERER" \
      && "$_MDM_EXPECTED_RENDERER_SNAPSHOT" == 0 \
      && -z "$_MDM_EXPECTED_RENDERER_OWNER_UID" \
      && "$_MDM_EXPECTED_RENDERER_BUNDLE_SNAPSHOT" == 0 \
      && "$(_renderer_snapshot_count)" -eq 0 ]]; then
    _renderer_cleanup_ok=true
  fi
  if [[ "$_renderer_cleanup_ok" == true ]]; then
    pass "mdm-ref: renderer一致後のbundle/global cleanupが完全"
  else
    fail "mdm-ref: renderer一致後にbundleまたはglobalが残留"
  fi

  # policy output が同じになり得る comment-only 差分も、renderer bytes の
  # 不一致として system Python / renderer 実行前に configuration error へする。
  _renderer_skew_source="$_renderer_tmp/render-expected-skew.py"
  /bin/cp "$_repo/mdm/render-expected.py" "$_renderer_skew_source"
  printf '\n# comment-only release skew fixture\n' >> "$_renderer_skew_source"
  _renderer_bundle=""
  _mdm_launcher_snapshot "$_renderer_skew_source" _renderer_bundle
  _renderer_set_bundle "$_renderer_bundle"
  _renderer_system_marker="$_renderer_tmp/system-python.called"
  _renderer_run_marker="$_renderer_tmp/renderer.called"
  _mdm_system_python() {
    : > "$_renderer_system_marker"
    printf '%s' /usr/bin/true
  }
  _mdm_run_with_timeout() {
    : > "$_renderer_run_marker"
    return 1
  }
  _renderer_mismatch_rc=0
  _mdm_prepare_expected_state /Users/fixture \
    "$_repo" "$_head_sha" >/dev/null 2>&1 \
    || _renderer_mismatch_rc=$?
  _renderer_head_after="$(/usr/bin/git -C "$_repo" rev-parse --verify HEAD)"
  _renderer_status_after="$(/usr/bin/git -C "$_repo" status --porcelain \
    --untracked-files=all)"
  if [[ "$_renderer_mismatch_rc" -eq "$MDM_EXIT_CONFIG" \
    && ! -e "$_renderer_system_marker" \
    && ! -e "$_renderer_run_marker" \
    && -z "$_MDM_CHECKOUT_RENDERER_SNAPSHOT" \
    && -z "$_MDM_CHECKOUT_RENDERER_OWNER_UID" \
    && "$_MDM_EXPECTED_RENDERER" == "$_renderer_bundle" \
    && -f "$_renderer_bundle" \
    && "$(_renderer_snapshot_count)" -eq 1 \
    && "$_renderer_head_after" == "$_head_sha" \
    && -z "$_renderer_status_after" ]]; then
    pass "mdm-ref: comment-only renderer差分を実行前にexit 50で拒否"
  else
    fail "mdm-ref: renderer差分が実行到達、誤exit、checkout変更、snapshot残留"
  fi
  _mdm_cleanup_renderer_snapshot || true
  if [[ -z "$_MDM_EXPECTED_RENDERER" \
    && "$_MDM_EXPECTED_RENDERER_SNAPSHOT" == 0 \
    && -z "$_MDM_EXPECTED_RENDERER_OWNER_UID" \
    && "$_MDM_EXPECTED_RENDERER_BUNDLE_SNAPSHOT" == 0 \
    && -z "$_MDM_CHECKOUT_RENDERER_SNAPSHOT" \
    && -z "$_MDM_CHECKOUT_RENDERER_OWNER_UID" \
    && -z "${_MDM_EXPECTED_DIR:-}" \
    && -z "${_MDM_EXPECTED_OUTPUT:-}" \
    && "$(_renderer_snapshot_count)" -eq 0 ]]; then
    pass "mdm-ref: renderer不一致後のtmp/global cleanupが完全"
  else
    fail "mdm-ref: renderer不一致後にtmpまたはglobalが残留"
  fi

  # Mutation probe: 比較 helper を no-op にすると同じ mismatch が system
  # Python と renderer 起動境界へ到達し、上の正式 assertion が赤になる。
  _renderer_mutant_cleanup_result="$_renderer_tmp/mutant-cleanup.result"
  (
    _renderer_bundle=""
    _mdm_launcher_snapshot "$_renderer_skew_source" _renderer_bundle
    _renderer_set_bundle "$_renderer_bundle"
    _renderer_mutant_system="$_renderer_tmp/mutant-system-python.called"
    _renderer_mutant_run="$_renderer_tmp/mutant-renderer.called"
    _mdm_verify_expected_renderer_checkout_binding() { return 0; }
    _mdm_system_python() {
      : > "$_renderer_mutant_system"
      printf '%s' /usr/bin/true
    }
    _mdm_run_with_timeout() {
      : > "$_renderer_mutant_run"
      return 1
    }
    _renderer_mutant_rc=0
    _mdm_prepare_expected_state /Users/fixture \
      "$_repo" "$_head_sha" >/dev/null 2>&1 \
      || _renderer_mutant_rc=$?
    if [[ "$_renderer_mutant_rc" -ne "$MDM_EXIT_CONFIG" \
      && -f "$_renderer_mutant_system" \
      && -f "$_renderer_mutant_run" ]]; then
      pass "mdm-ref: renderer束縛no-op mutationで不一致テストが反転"
    else
      fail "mdm-ref: renderer不一致テストが束縛no-op mutationを検出不能"
    fi
    _renderer_mutant_cleanup_rc=0
    _mdm_cleanup_expected_dir || _renderer_mutant_cleanup_rc=1
    _mdm_cleanup_checkout_renderer_snapshot || _renderer_mutant_cleanup_rc=1
    _mdm_cleanup_renderer_snapshot || _renderer_mutant_cleanup_rc=1
    if [[ "$_renderer_mutant_cleanup_rc" -eq 0 \
      && -z "${_MDM_EXPECTED_DIR:-}" \
      && -z "${_MDM_EXPECTED_OUTPUT:-}" \
      && -z "${_MDM_EXPECTED_OWNER_UID:-}" \
      && -z "${_MDM_EXPECTED_RENDERER:-}" \
      && "${_MDM_EXPECTED_RENDERER_SNAPSHOT:-0}" == 0 \
      && -z "${_MDM_EXPECTED_RENDERER_OWNER_UID:-}" \
      && "${_MDM_EXPECTED_RENDERER_BUNDLE_SNAPSHOT:-0}" == 0 \
      && -z "${_MDM_CHECKOUT_RENDERER_SNAPSHOT:-}" \
      && -z "${_MDM_CHECKOUT_RENDERER_OWNER_UID:-}" \
      && "$(_renderer_auth_entry_count)" -eq 0 \
      && "$(_renderer_snapshot_count)" -eq 0 ]]; then
      printf 'ok\n' > "$_renderer_mutant_cleanup_result"
      pass "mdm-ref: mutation probe内でもexpected/bundle tmpと全globalをcleanup"
    else
      fail "mdm-ref: mutation probe内でexpected/bundle tmpまたはglobalが残留"
    fi
    trap - EXIT HUP INT TERM
  )

  _renderer_mutant_cleanup_observed="$(/bin/cat \
    "$_renderer_mutant_cleanup_result" 2>/dev/null || true)"
  if [[ "$_renderer_mutant_cleanup_observed" == ok \
    && "$(_renderer_auth_entry_count)" -eq 0 \
    && "$(_renderer_snapshot_count)" -eq 0 \
    && -z "${_MDM_EXPECTED_RENDERER:-}" \
    && -z "${_MDM_CHECKOUT_RENDERER_SNAPSHOT:-}" ]]; then
    pass "mdm-ref: mutation probeのcleanup結果を親へ伝播し残留なし"
  else
    fail "mdm-ref: mutation probe cleanup未伝播またはtmp/globalが残留"
  fi
  trap - EXIT HUP INT TERM
  /bin/rm -rf "$_renderer_tmp"
)

/bin/rm -rf "$_repo"

mdm_test_reached_end
