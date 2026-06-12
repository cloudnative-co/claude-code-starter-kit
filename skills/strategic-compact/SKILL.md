---
name: strategic-compact
description: Guidance for compacting context manually at phase boundaries instead of waiting for auto-compaction mid-task.
when_to_use: Use when a session is getting long and the user is between phases, such as after exploration, before implementation, or before a handoff.
---

# Strategic Compact Skill

Compact at logical boundaries of your workflow when context has gone stale.
Check the statusline for actual context usage before deciding — do not guess
from tool-call counts or elapsed time.

## When Compacting Pays Off

- **After exploration, before execution** — Compact research context, keep the implementation plan
- **After completing a milestone** — Fresh start for the next phase
- **Before major context shifts** — Clear exploration context before a different task

## Best Practices

1. **Compact after planning** - Once plan is finalized, compact to start fresh
2. **Compact after debugging** - Clear error-resolution context before continuing
3. **Don't compact mid-implementation** - Preserve context for related changes
4. **Trust the harness** - Auto-compaction and the statusline context meter are
   reliable; manual /compact is an optimization at phase boundaries, not a
   requirement
