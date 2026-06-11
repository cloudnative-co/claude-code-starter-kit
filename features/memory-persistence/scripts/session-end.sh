#!/bin/bash
# SessionEnd Hook - finalize existing session notes
#
# Runs when Claude session ends. Updates existing notes only; it does not
# create empty templates.
#
# Hook config (in ~/.claude/settings.json):
# {
#   "hooks": {
#     "SessionEnd": [{
#       "matcher": "*",
#       "hooks": [{
#         "type": "command",
#         "command": "~/.claude/hooks/memory-persistence/session-end.sh"
#       }]
#     }]
#   }
# }

SESSIONS_DIR="${HOME}/.claude/sessions"

if [ ! -d "$SESSIONS_DIR" ]; then
  exit 0
fi

latest="$(ls -t "$SESSIONS_DIR"/*.tmp 2>/dev/null | head -1 || true)"
if [ -n "$latest" ] && [ -f "$latest" ]; then
  tmp_file="$(mktemp)"
  awk -v updated="$(date '+%H:%M')" '
    /^\*\*Last Updated:\*\*/ { print "**Last Updated:** " updated; seen=1; next }
    { print }
    END { if (!seen) print "**Last Updated:** " updated }
  ' "$latest" > "$tmp_file" && mv "$tmp_file" "$latest"
  echo "[SessionEnd] Updated session file: $latest" >&2
fi

# Remove stale transient notes after 30 days.
find "$SESSIONS_DIR" -maxdepth 1 -name "*.tmp" -mtime +30 -delete 2>/dev/null || true
