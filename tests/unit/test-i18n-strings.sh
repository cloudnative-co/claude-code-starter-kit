#!/bin/bash
# tests/unit/test-i18n-strings.sh - Keep translated string keys in sync

_i18n_tmp="$(mktemp -d)"
_SETUP_TMP_FILES+=("$_i18n_tmp")
_en_keys="$_i18n_tmp/en.keys"
_ja_keys="$_i18n_tmp/ja.keys"
_missing_ja="$_i18n_tmp/missing-ja.keys"
_missing_en="$_i18n_tmp/missing-en.keys"

grep -oE '^STR_[A-Z0-9_]+' "$PROJECT_DIR/i18n/en/strings.sh" | sort -u >"$_en_keys"
grep -oE '^STR_[A-Z0-9_]+' "$PROJECT_DIR/i18n/ja/strings.sh" | sort -u >"$_ja_keys"

comm -23 "$_en_keys" "$_ja_keys" >"$_missing_ja"
comm -13 "$_en_keys" "$_ja_keys" >"$_missing_en"

if [[ ! -s "$_missing_ja" && ! -s "$_missing_en" ]]; then
  pass "i18n-strings: en and ja expose the same STR_* keys"
else
  echo "  Missing in ja:" >&2
  sed 's/^/    /' "$_missing_ja" >&2
  echo "  Missing in en:" >&2
  sed 's/^/    /' "$_missing_en" >&2
  fail "i18n-strings: en and ja STR_* keys should stay in sync"
fi
