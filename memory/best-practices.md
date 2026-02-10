# Claude Code Best Practices (Detailed)

## Workflow Best Practices

### 1. Plan First, Always
- Use plan mode for any non-trivial task
- Break complex features into phases
- Validate feasibility before implementation

### 2. Context Window Management
- CLAUDE.md should be <150 lines (adherence drops beyond this)
- Manual `/compact` at ~50% context usage (don't rely on auto-compact)
- Each subtask should be completable within <50% of context window
- Avoid the last 20% of context for complex multi-file work
- Lower context sensitivity tasks (single-file edits, utils) are safe at higher usage

### 3. Progressive Disclosure
- Skill descriptions loaded automatically (lightweight)
- Full skill content loaded only on invocation (on-demand)
- Feature-specific subagents with skills for complex workflows
- Don't front-load all context; reveal as needed

### 4. Commit Strategy
- Commit immediately upon task completion
- Don't batch commits across multiple features
- Small, atomic commits with clear messages

### 5. Subagent Rules
- Subagents CANNOT invoke other subagents via bash
- Must use the Task tool with explicit parameters
- Keep subagent tasks focused and completable in <50% context
- Use haiku model for lightweight worker agents

### 6. /memory and /rules
- These offer NO guarantees of persistent adherence
- CLAUDE.md is the most reliable context mechanism
- Rules in `.claude/rules/*.md` support path-scoping

## Debugging Best Practices

### Tools
- `/doctor` command for diagnostics
- Background tasks for better log visibility
- MCP tools: Playwright + Chrome DevTools for browser automation
- Screenshots for visual bug reports

### Browser Automation Priority
1. **Playwright MCP** - Primary (best token efficiency ~13.7k, cross-browser)
2. **Chrome DevTools MCP** - Secondary (performance/network analysis)
3. **Claude in Chrome** - Manual testing with logged-in sessions

## Anti-Patterns to Avoid
- Complex agent orchestration when vanilla Claude Code suffices
- Exceeding CLAUDE.md 150-line limit
- Waiting for auto-compact instead of manual compact
- Front-loading too much context (use progressive disclosure)
- Running subtasks that exceed 50% context
- Using /memory or /rules as primary instruction mechanism
