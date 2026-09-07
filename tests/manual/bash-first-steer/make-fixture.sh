#!/bin/bash
# tests/manual/bash-first-steer/make-fixture.sh
#
# Build the synthetic fixture template shared by every case of the real-CLI
# harness. Nothing here touches ~/.claude; everything lives under <exp-root>.
#
# Usage: make-fixture.sh <exp-root> [kit-repo]
#   exp-root : empty or new directory that will hold fixture-template/, hooks/,
#              tokens.env and runs/
#   kit-repo : starter-kit checkout whose feature scripts are copied verbatim
#              (default: the checkout this script lives in)
set -euo pipefail

EXP_ROOT="${1:?usage: make-fixture.sh <exp-root> [kit-repo]}"
KIT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
T="$EXP_ROOT/fixture-template"
HOOKS="$EXP_ROOT/hooks"

if [[ -e "$T" ]]; then
  echo "fixture-template already exists: $T" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "$EXP_ROOT"

# --- marker tokens (never written into any prompt) ---------------------------
tok() { od -An -tx1 -N 3 /dev/urandom | tr -d ' \n'; }
UNCOND_TOKEN="UNCOND-$(tok)"
PATHRULE_TOKEN="PATHRULE-$(tok)"
NESTED_TOKEN="NESTED-$(tok)"
printf 'UNCOND_TOKEN=%s\nPATHRULE_TOKEN=%s\nNESTED_TOKEN=%s\n' \
  "$UNCOND_TOKEN" "$PATHRULE_TOKEN" "$NESTED_TOKEN" > "$EXP_ROOT/tokens.env"

# --- kit hook scripts (verbatim copies of the distributed scripts) -----------
for f in prettier-hooks biome-hooks doc-blocker doc-size-guard; do
  mkdir -p "$HOOKS/$f"
  cp "$KIT/features/$f/scripts/"*.sh "$HOOKS/$f/"
  chmod +x "$HOOKS/$f/"*.sh
done
mkdir -p "$HOOKS/observer"
cp "$(dirname "${BASH_SOURCE[0]}")/observer-hook.sh" "$HOOKS/observer/observer-hook.sh"
chmod +x "$HOOKS/observer/observer-hook.sh"

# --- repository skeleton -----------------------------------------------------
mkdir -p "$T/.claude/rules" "$T/src" "$T/docs"

# Deliberately unformatted TypeScript: a formatter run is visible in the diff.
cat > "$T/src/app.ts" <<'EOF'
const  config={a:1,b:2,   c:3}
function f( ){return config}
export function main(){const c=f();console.log(c.a+c.b+c.c);return f()}
EOF

printf '# Guide\n\nThis guide has one paragraph.\n' > "$T/docs/guide.md"

# Nested CLAUDE.md: loaded only when Claude *reads* a file under docs/.
cat > "$T/docs/CLAUDE.md" <<EOF
# docs/ instructions

Whenever you change any file under docs/, you MUST first create an empty file
named \`${NESTED_TOKEN}.flag\` at the repository root (use \`touch\`). This is a
mandatory bookkeeping step for this directory.
EOF

# Unconditional rule (no paths:): loaded at session start regardless of tools.
cat > "$T/.claude/rules/bookkeeping.md" <<EOF
# Bookkeeping

Before you finish any task in this repository, you MUST create an empty file
named \`${UNCOND_TOKEN}.flag\` at the repository root (use \`touch\`).
EOF

# Path-scoped rule: loaded only when a matching file is read with Read.
cat > "$T/.claude/rules/typescript.md" <<EOF
---
paths:
  - "src/**/*.ts"
---
# TypeScript rule

Before you modify any TypeScript file, you MUST create an empty file named
\`${PATHRULE_TOKEN}.flag\` at the repository root (use \`touch\`).
EOF

# Root CLAUDE.md above doc-size-guard's 250-line warning threshold.
{
  printf '# Fixture project\n\n'
  printf 'This is a synthetic fixture repository for a hook experiment.\n\n'
  for i in $(seq 1 254); do printf -- '- filler line %d\n' "$i"; done
} > "$T/CLAUDE.md"

printf 'node_modules/\n' > "$T/.gitignore"
printf '# fixture\n' > "$T/README.md"

echo "fixture template written to $T"
