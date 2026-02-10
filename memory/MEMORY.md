# Claude Code Best Practices Memory

## Source
Based on [shanraisshan/claude-code-best-practice](https://github.com/shanraisshan/claude-code-best-practice) repository.

## Core Principles
- See [best-practices.md](best-practices.md) for detailed patterns
- See [context-engineering.md](context-engineering.md) for context management
- See [architecture.md](architecture.md) for Command→Agent→Skills pattern
- See [settings-reference.md](settings-reference.md) for configuration

## Quick Reference

### Workflow Rules
1. **Always start with plan mode** for non-trivial tasks
2. **CLAUDE.md under 150 lines** - not guaranteed beyond that
3. **Manual `/compact` at ~50% context** - don't wait for auto-compact
4. **Keep subtasks completable in <50% context**
5. **Commit immediately upon task completion**
6. **Vanilla Claude Code > complex workflows** for smaller tasks

### Architecture Pattern: Command → Agent → Skills
- **Command**: Entry point (`/skill-name`)
- **Agent**: Orchestrates workflow with preloaded skills
- **Skills**: Domain knowledge injected at startup (progressive disclosure)

### Context Engineering
- Ancestor CLAUDE.md files always load (upward walk)
- Descendant CLAUDE.md files lazy-load on file access
- Sibling directories never cross-load
- Skill descriptions load automatically; full content only on invocation

### Model Selection
- **Haiku**: Lightweight agents, frequent invocations, worker agents (90% of Sonnet, 3x savings)
- **Sonnet**: Main dev work, orchestration, complex coding
- **Opus**: Deep reasoning, architecture, research

### Settings Priority (high→low)
1. CLI args → 2. `.claude/settings.local.json` → 3. `.claude/settings.json` → 4. `~/.claude/settings.json` → 5. managed-settings

### RPI Workflow
Research → Plan → Implement with validation checkpoints
- `/rpi:research` → feasibility analysis + GO/NO-GO
- `/rpi:plan` → user stories, UX, architecture
- `/rpi:implement` → phase-by-phase execution

### Debugging
- Use `/doctor` for diagnostics
- Run terminal commands as background tasks for log visibility
- Use Playwright MCP + Chrome DevTools MCP for browser automation
- Provide screenshots for visual issues
