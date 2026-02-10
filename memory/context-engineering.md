# Context Engineering

## CLAUDE.md Loading in Monorepos

### Ancestor Loading (Upward)
- Claude walks UP the directory tree at startup
- All ancestor CLAUDE.md files are loaded immediately
- Root-level instructions are always available

### Descendant Loading (Downward)
- Subdirectory CLAUDE.md files use lazy loading
- Only loaded when you interact with files in those directories
- Sibling directories NEVER cross-load

### Recommended Structure
- **Root CLAUDE.md**: Repo-wide conventions, coding standards, commit formats
- **Component CLAUDE.md**: Framework-specific patterns, architecture, local testing
- **CLAUDE.local.md**: Personal preferences (gitignored)
- **~/.claude/CLAUDE.md**: Global instructions for all sessions

### Key Rules
- Keep each CLAUDE.md under 150 lines
- Denial permissions cannot be overridden by lower-priority settings
- Root instructions propagate to all subdirectories automatically

## Skills Discovery in Monorepos

### Loading Locations (Priority)
1. Enterprise (highest)
2. Personal (`~/.claude/skills/`)
3. Project (`.claude/skills/`)
4. Plugin (namespace-prefixed)

### Behavior
- Descriptions loaded into context automatically (lightweight)
- Full skill content only loads on invocation
- Nested package skills activate when editing files in those dirs
- Name conflicts resolved by priority hierarchy
- Plugin skills use `plugin-name:skill-name` to avoid collisions

## Settings Hierarchy (Priority)
1. Command-line arguments (highest)
2. `.claude/settings.local.json` (personal, gitignored)
3. `.claude/settings.json` (team-shared)
4. `~/.claude/settings.json` (global personal)
5. `managed-settings.json` (organizational, read-only, lowest)

## Hook Events (13 Total)
SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse,
PostToolUseFailure, PermissionRequest, Notification, Stop,
SubagentStart, SubagentStop, PreCompact, Setup

### Exit Codes
- 0: Success, continue
- 1: Error (logged, continues)
- 2: Block the operation
