#!/bin/bash
# tests/unit/test-mdm-ref-validate.sh - ref 形式検証と SHA 解決

MDM_SOURCE_ONLY=1 source "$PROJECT_DIR/mdm/install-mdm.sh"

# ローカルにテスト用リポジトリを作る
_repo="$(mktemp -d)"
(
  cd "$_repo" || exit 1
  git init -q
  printf 'a\n' > f.txt
  git add f.txt
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

rm -rf "$_repo"

mdm_test_reached_end
