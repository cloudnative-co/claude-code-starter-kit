---
name: context-management
description: Context Rot prevention and FIC (Frequent Intentional Compaction) guidance
---

# Context Management Skill

## When to Compact

- **Phase transitions**: After completing research, planning, or implementation phases
- **Before starting new tasks**: Fresh context improves output quality
- **When context exceeds ~40%**: Don't wait until 80-100%

## FIC (Frequent Intentional Compaction) Protocol

1. Complete current logical unit of work
2. Commit any pending changes
3. Save key findings to files (research.md, plan.md, progress.md)
4. Run `/compact`
5. Resume with file references instead of in-memory context

## Context Preservation via Files

Use the filesystem as external memory:
- `research.md` - Investigation findings
- `plan.md` - Implementation plan with file paths and code snippets
- `progress.md` - Current status and next steps
- `todo.md` - Remaining tasks as checklist

## Anti-patterns

- Loading "just in case" files into context
- Keeping full error traces after the issue is resolved
- Accumulating conversation history across unrelated tasks
