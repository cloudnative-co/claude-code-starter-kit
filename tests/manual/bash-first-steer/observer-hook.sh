#!/bin/bash
# tests/manual/bash-first-steer/observer-hook.sh
#
# Observation-only hook used by the real-CLI harness. It appends a compact
# JSON line per hook event to $BFS_OBSERVER_LOG and never changes behaviour:
# no stdout, exit 0 always, input passed through untouched.
set -u
input="$(cat)"
log="${BFS_OBSERVER_LOG:-}"
[[ -n "$log" ]] || exit 0
printf '%s' "$input" | jq -c '{
  ts: (now | todate),
  event: .hook_event_name,
  tool: (.tool_name // null),
  permission_mode: (.permission_mode // null),
  file_path: (.tool_input.file_path // .file_path // null),
  command: ((.tool_input.command // null) | if . == null then null else .[0:300] end),
  load_reason: (.load_reason // null),
  memory_type: (.memory_type // null),
  trigger_file_path: (.trigger_file_path // null),
  transcript_path: (.transcript_path // null),
  session_id: (.session_id // null),
  cwd: (.cwd // null)
}' >> "$log" 2>/dev/null || true
exit 0
