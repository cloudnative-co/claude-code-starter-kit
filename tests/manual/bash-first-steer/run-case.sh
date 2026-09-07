#!/bin/bash
# tests/manual/bash-first-steer/run-case.sh
#
# Run ONE real Claude Code session against a fresh copy of the fixture and
# capture every observable: tool calls, hook responses, InstructionsLoaded
# events, marker files, git status and the persisted auto_mode attachment.
#
# Usage: run-case.sh <exp-root> <case-id> <mode> <flag> <variant> [model]
#   mode    : auto | acceptEdits | bypass
#   flag    : unset | 0 | 1   (env.CLAUDE_CODE_THRIFTY_SONIC via project settings)
#   variant : neutral | native | bash   (prompt wording; see below)
#   model   : default claude-fable-5-1
#
# Optional environment:
#   BFS_KIT_SETTINGS=<file>  use this kit-generated settings.json verbatim as
#                            the fixture's .claude/settings.json (hook commands
#                            must already resolve on this machine); observers
#                            are then layered on with --settings so the file
#                            under test stays byte-identical. `flag` must be
#                            "unset" in this mode.
#
# Isolation: the session runs with --setting-sources project and
# --strict-mcp-config, so ~/.claude/settings.json, ~/.claude/CLAUDE.md,
# ~/.claude/rules, plugins and MCP servers are not loaded. The session
# transcript is still persisted under ~/.claude/projects/ (synthetic content
# only); the run directory records its path.
set -euo pipefail

EXP_ROOT="${1:?usage: run-case.sh <exp-root> <case-id> <mode> <flag> <variant> [model]}"
CASE="${2:?case-id}"; MODE="${3:?mode}"; FLAG="${4:?flag}"; VARIANT="${5:?variant}"
MODEL="${6:-claude-fable-5-1}"
# Hook commands are absolute paths inside the settings file and run from the
# fixture's cwd, so a relative <exp-root> would silently disable the observers.
EXP_ROOT="$(cd "$EXP_ROOT" 2>/dev/null && pwd -P)" || { echo "exp-root not found: $1" >&2; exit 1; }
T="$EXP_ROOT/fixture-template"
HOOKS="$EXP_ROOT/hooks"
OUT="$EXP_ROOT/runs/$CASE"
REPO="$OUT/repo"

# Validate every argument before touching the filesystem (fail closed).
case "$MODE" in auto|acceptEdits|bypass) ;; *) echo "bad mode: $MODE (auto|acceptEdits|bypass)" >&2; exit 1 ;; esac
case "$FLAG" in unset|0|1) ;; *) echo "bad flag: $FLAG (unset|0|1)" >&2; exit 1 ;; esac
case "$VARIANT" in neutral|native|bash) ;; *) echo "bad variant: $VARIANT (neutral|native|bash)" >&2; exit 1 ;; esac
[[ "$CASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "bad case-id: $CASE" >&2; exit 1; }
if [[ -n "${BFS_KIT_SETTINGS:-}" ]]; then
  [[ "$FLAG" == "unset" ]] || { echo "flag must be 'unset' with BFS_KIT_SETTINGS" >&2; exit 1; }
  jq -e 'type == "object"' "$BFS_KIT_SETTINGS" >/dev/null 2>&1 || { echo "invalid settings file: $BFS_KIT_SETTINGS" >&2; exit 1; }
  # The kit's permissions fragment disables bypassPermissions; the CLI would
  # refuse the mode, so fail here instead of burning a session.
  if [[ "$MODE" == "bypass" ]] \
    && jq -e '.disableBypassPermissionsMode == "disable"' "$BFS_KIT_SETTINGS" >/dev/null 2>&1; then
    echo "mode=bypass is not usable with a kit settings.json (disableBypassPermissionsMode=disable)" >&2
    exit 1
  fi
  # The kit's hook commands are absolute paths under the real ~/.claude/hooks,
  # so a Standard/Full settings.json would run the real SessionStart/SessionEnd
  # hooks inside the fixture session: auto-update (git pull + setup.sh --update
  # on the real install), web-content-update (npm update of the real skill
  # deps) and the feature-recommendation reader. None of them is under test,
  # so refuse instead of mutating the user's install.
  if jq -e '((.hooks.SessionStart // []) | length) + ((.hooks.SessionEnd // []) | length) > 0' \
      "$BFS_KIT_SETTINGS" >/dev/null 2>&1; then
    echo "kit settings.json contains SessionStart/SessionEnd hooks (auto-update, web-content-update, feature-recommendation); they would run against the real ~/.claude. Generate it with a --hooks list that leaves them out, e.g. --hooks=doc-block,biome,doc-size,native-tools" >&2
    exit 1
  fi
fi
[[ -d "$T" ]] || { echo "fixture template missing; run make-fixture.sh first" >&2; exit 1; }
[[ -e "$OUT" ]] && { echo "run dir exists: $OUT" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "claude CLI not found" >&2; exit 1; }
# The formatter observable needs biome (or prettier) resolvable by the hook.
if ! command -v biome >/dev/null 2>&1 && ! command -v prettier >/dev/null 2>&1; then
  echo "warning: neither biome nor prettier is on PATH; the 'formatted' observable will always read 'no'" >&2
fi
mkdir -p "$OUT"
cp -R "$T" "$REPO"

OBS="$HOOKS/observer/observer-hook.sh"
observer_hooks="$(jq -cn --arg obs "$OBS" '{
  PreToolUse:         [ { matcher: "*", hooks: [ { type: "command", command: $obs } ] } ],
  PostToolUse:        [ { matcher: "*", hooks: [ { type: "command", command: $obs } ] } ],
  InstructionsLoaded: [ { hooks: [ { type: "command", command: $obs } ] } ]
}')"

extra_settings=()
if [[ -n "${BFS_KIT_SETTINGS:-}" ]]; then
  cp "$BFS_KIT_SETTINGS" "$REPO/.claude/settings.json"
  cp "$BFS_KIT_SETTINGS" "$OUT/kit-settings.json"
  extra_settings=( --settings "$(jq -cn --argjson h "$observer_hooks" '{hooks: $h}')" )
else
  env_json='{}'
  case "$FLAG" in
    unset) ;;
    0|1) env_json="$(jq -cn --arg v "$FLAG" '{CLAUDE_CODE_THRIFTY_SONIC: $v}')" ;;
  esac
  jq -n \
    --argjson obs "$observer_hooks" \
    --arg prettier "$HOOKS/prettier-hooks/format-file.sh" \
    --arg biome "$HOOKS/biome-hooks/format-file.sh" \
    --arg docblock "$HOOKS/doc-blocker/check-doc-write.sh" \
    --arg docsize "$HOOKS/doc-size-guard/check-doc-size.sh" \
    --argjson env "$env_json" '
  {
    env: $env,
    hooks: {
      PreToolUse: ($obs.PreToolUse + [
        { matcher: "Write", hooks: [ { type: "command", command: $docblock } ] }
      ]),
      PostToolUse: ($obs.PostToolUse + [
        { matcher: "Edit|Write", hooks: [ { type: "command", command: $prettier } ] },
        { matcher: "Edit|Write", hooks: [ { type: "command", command: $biome } ] },
        { matcher: "Write",      hooks: [ { type: "command", command: $docsize } ] }
      ]),
      InstructionsLoaded: $obs.InstructionsLoaded
    }
  }' > "$REPO/.claude/settings.json"
fi

git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.email=fixture@example.invalid -c user.name=fixture commit -q -m "fixture"

# --- prompt ------------------------------------------------------------------
base='Complete these four small tasks in this repository, then stop. Do not run tests and do not commit.
1. In src/app.ts, rename the function `f` to `getConfig` (including its call sites in that file).
2. Append the line `Updated by task.` to the end of docs/guide.md.
3. Create a new file AGENTS.md at the repository root that documents three agents (planner, reviewer, tester). For each agent write a `## <name>` heading followed by a numbered checklist of 55 concrete, distinct steps, written out in full (the file must end up at least 160 lines long).
4. Create a new file SUMMARY.md at the repository root with one line describing what you changed.'
case "$VARIANT" in
  neutral) prompt="$base" ;;
  native)  prompt="$base
Use the Read, Edit and Write tools for every file read and file change." ;;
  bash)    prompt="$base
Use Bash commands (cat, sed, printf, heredocs) for every file read and file change; do not use the Read, Edit or Write tools." ;;
esac
printf '%s\n' "$prompt" > "$OUT/prompt.txt"

# --- CLI flags ---------------------------------------------------------------
args=( -p "$prompt" --setting-sources project --strict-mcp-config
       --output-format stream-json --verbose --include-hook-events
       --model "$MODEL" --max-budget-usd 3 --permission-prompts none )
case "$MODE" in
  auto)        args+=( --permission-mode auto ) ;;
  acceptEdits) args+=( --permission-mode acceptEdits --allowedTools "Bash,Read,Edit,Write,Glob,Grep" ) ;;
  # bypass: no permission checks and no auto-mode classifier for this session
  # (a live model runs unguarded inside the fixture repo; see README).
  bypass)      args+=( --permission-mode bypassPermissions ) ;;
esac
args+=( "${extra_settings[@]+"${extra_settings[@]}"}" )
printf 'claude %s\n' "${args[*]}" > "$OUT/command.txt"
printf 'case=%s mode=%s flag=%s variant=%s model=%s kit_settings=%s\n' \
  "$CASE" "$MODE" "$FLAG" "$VARIANT" "$MODEL" "${BFS_KIT_SETTINGS:-}" > "$OUT/meta.txt"

# --- run ---------------------------------------------------------------------
start=$(date +%s)
rc=0
( cd "$REPO" && BFS_OBSERVER_LOG="$OUT/observer.jsonl" claude "${args[@]}" \
    > "$OUT/stdout.jsonl" 2> "$OUT/stderr.txt" ) || rc=$?
end=$(date +%s)
printf 'exit=%s duration_s=%s\n' "$rc" "$((end-start))" >> "$OUT/meta.txt"

# --- post-run captures -------------------------------------------------------
git -C "$REPO" status --porcelain -uall > "$OUT/git-status.txt" || true
git -C "$REPO" diff > "$OUT/git-diff.txt" || true
cp "$REPO/src/app.ts" "$OUT/app.ts.after" 2>/dev/null || true
# The Bash-first steer is persisted as a structured "auto_mode" attachment in
# the session transcript (rendered into a meta message at request time).
tp="$(jq -r 'select(.transcript_path != null) | .transcript_path' "$OUT/observer.jsonl" 2>/dev/null | head -1 || true)"
if [[ -n "$tp" && -f "$tp" ]]; then
  printf '%s\n' "$tp" > "$OUT/transcript-path.txt"
  jq -c 'select(.type=="attachment" and .attachment.type=="auto_mode") | .attachment' "$tp" \
    > "$OUT/auto-mode-attachment.jsonl" 2>/dev/null || true
fi
echo "done: $CASE rc=$rc"
