#!/bin/bash
# PreCompact Hook - Save state before context compaction
#
# Runs before Claude compacts context, giving you a chance to
# preserve important state that might get lost in summarization.
#
# Hook config (in ~/.claude/settings.json):
# {
#   "hooks": {
#     "PreCompact": [{
#       "matcher": "*",
#       "hooks": [{
#         "type": "command",
#         "command": "~/.claude/hooks/memory-persistence/pre-compact.sh"
#       }]
#     }]
#   }
# }

SESSIONS_DIR="${HOME}/.claude/sessions"
COMPACTION_LOG="${SESSIONS_DIR}/compaction-log.txt"

mkdir -p "$SESSIONS_DIR"

# Log compaction event with timestamp
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Context compaction triggered" >> "$COMPACTION_LOG"

ACTIVE_SESSION=$(ls -t "$SESSIONS_DIR"/*.tmp 2>/dev/null | head -1)
if [ -z "$ACTIVE_SESSION" ]; then
  ACTIVE_SESSION="$SESSIONS_DIR/$(date '+%Y-%m-%d')-session.tmp"
  {
    echo "# Session continuity notes"
    echo "**Date:** $(date '+%Y-%m-%d')"
    echo "**Last Updated:** $(date '+%H:%M')"
  } > "$ACTIVE_SESSION"
fi

echo "" >> "$ACTIVE_SESSION"
echo "---" >> "$ACTIVE_SESSION"
echo "**[Compaction occurred at $(date '+%H:%M')]** - Context was summarized" >> "$ACTIVE_SESSION"

echo "[PreCompact] State saved before compaction" >&2
