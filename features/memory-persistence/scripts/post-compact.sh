#!/bin/bash
# PostCompact Hook - Notify after context compaction completes
#
# Runs after Claude compacts context. Keeps the message lightweight and
# points users back to the existing memory-persistence flow.

echo "[PostCompact] Compaction complete. Recent session notes and learned context will be available on the next SessionStart."
