#!/bin/bash
# tests/unit/test-skill-frontmatter.sh - Unit tests for shipped skill frontmatter

_sf_fail=0
for _sf_skill in "$PROJECT_DIR"/skills/*/SKILL.md; do
  [[ -f "$_sf_skill" ]] || continue
  _sf_name="$(basename "$(dirname "$_sf_skill")")"
  _sf_fm="$(sed -n '/^---$/,/^---$/p' "$_sf_skill")"

  if [[ "$_sf_fm" != *$'\n''name:'* ]]; then
    echo "  missing name frontmatter in $_sf_skill" >&2
    _sf_fail=1
  fi
  if [[ "$_sf_fm" != *$'\n''description:'* ]]; then
    echo "  missing description frontmatter in $_sf_skill" >&2
    _sf_fail=1
  fi
  if [[ "$_sf_fm" != *$'\n''when_to_use:'* ]]; then
    echo "  missing when_to_use frontmatter in $_sf_skill" >&2
    _sf_fail=1
  fi
  if [[ "$_sf_name" == "continuous-learning" ]] && [[ "$_sf_fm" != *$'\n''user-invocable: false'* ]]; then
    echo "  continuous-learning should opt out of slash menu" >&2
    _sf_fail=1
  fi
done

if [[ "$_sf_fail" -eq 0 ]]; then
  pass "skill frontmatter: shipped skills include required discovery fields"
else
  fail "skill frontmatter: shipped skills should include required discovery fields"
fi
