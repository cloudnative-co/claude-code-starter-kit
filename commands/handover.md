# /handover - Structured Session Handover

Generate a structured handover document for seamless session continuation.

## Instructions

Create a handover document that captures the complete state of the current work session. This enables a fresh Claude Code session (or a different developer) to continue exactly where you left off.

### Generate HANDOVER.md

Create `HANDOVER.md` in the project root with the following structure:

```
# Session Handover
## Generated: [ISO 8601 timestamp]

## Current State
- **Branch**: [current git branch]
- **Last Commit**: [hash + message]
- **Uncommitted Changes**: [list of modified/added files]

## What Was Done
[Numbered list of completed actions in this session]

## What Remains
[Checklist of remaining tasks, in order of priority]
- [ ] Task 1
- [ ] Task 2

## Key Decisions Made
[Important decisions and their rationale]

## Known Issues / Blockers
[Any issues discovered but not resolved]

## Context Files
[List of files that the next session should read first]
- path/to/critical-file-1
- path/to/critical-file-2

## Recommended Next Steps
1. Start a fresh session: `claude`
2. Read this handover: "Read HANDOVER.md and continue from where the previous session left off"
3. [Specific first action]
```

### Rules

- Include actual git state (branch, last commit, uncommitted changes)
- Be specific about what was completed vs what remains
- List files in order of importance for context loading
- After generating, suggest running `/compact` or starting a new session
- The handover document should be self-contained - readable without any prior context

### Session Naming Convention

After creating the handover document, suggest renaming the session for easy retrieval:

```
/rename [feature-name: current-status]
```

Naming patterns:
- `[auth-refactor: plan-approved]` -- feature + status
- `[bug-123: investigating]` -- issue number + phase
- `[sprint-12: day-3-reviews]` -- sprint + day

This enables targeted `/resume` later:
```
claude --resume  # shows recent sessions with names
```
