---
name: orchestration-pattern
description: Guide for designing Command -> Agent -> Skill orchestration workflows. Use when creating new commands, agents, or skills, or when structuring multi-step workflows.
---

# Command -> Agent -> Skill Orchestration Pattern

## Architecture Overview

Three-tier separation of concerns for Claude Code workflows:

```
User -> Command (entry point, user interaction)
          -> Agent (execution, isolated context, preloaded skills)
             -> Skill (domain knowledge, progressive disclosure)
```

## When to Use Each Component

### Command (.claude/commands/*.md)
- User-facing entry points invoked with `/command-name`
- Handles parameter collection and user interaction
- Orchestrates the workflow by delegating to agents and skills
- Use for: repeatable workflows, multi-step processes

### Agent (.claude/agents/*.md)
- Autonomous workers in isolated context
- Preload skills via `skills:` frontmatter field
- Have constrained tools, permissions, and model selection
- Use for: specialized tasks requiring focused context

### Skill (.claude/skills/*/SKILL.md)
- Reusable knowledge modules
- Two patterns:
  - **Agent Skill** (preloaded): Full content injected into agent context at startup via `skills:` field
  - **On-demand Skill**: Only description loaded initially, full content loaded when invoked via Skill tool
- Use for: domain knowledge, procedures, templates

## Design Rules

1. **Commands orchestrate, agents execute, skills inform**
   - Commands should NOT contain implementation logic
   - Agents should NOT handle user interaction
   - Skills should NOT orchestrate other components

2. **Single responsibility per component**
   - One command per workflow
   - One agent per domain/task type
   - One skill per knowledge domain

3. **Agent skills vs on-demand skills**
   - Preload skills when the workflow is known upfront (agent always needs this knowledge)
   - Use on-demand invocation for exploratory or conditional knowledge loading

4. **Agents invoke via Task tool, never bash**
   - Agents CANNOT invoke other agents through bash/CLI commands
   - Always use the Task tool: `Task(subagent_type="agent-name", description="...", prompt="...")`
   - Be explicit: avoid vague terms like "launch" or "start" that could be misinterpreted as bash

## Example: Multi-Agent Review Pattern

```
/full-review (Command)
  -> Step 1: Task(security-reviewer) -- security audit
  -> Step 2: Task(code-reviewer) -- quality check
  -> Step 3: Synthesize results from both agents
```

### Command definition (.claude/commands/full-review.md):
```markdown
Run security-reviewer and code-reviewer agents on the current changes.
Synthesize findings into a unified review report.
```

### Agent definition (.claude/agents/security-reviewer.md):
```yaml
---
name: security-reviewer
skills:
  - security-review  # Preloaded at startup
tools: Read, Glob, Grep, Bash
---
```

## Anti-patterns

- **God agent**: One agent attempting all roles -> split into focused agents
- **Command as implementation**: Complex logic in command -> move to agent
- **Skill as orchestrator**: Skill calling agents -> invert the relationship
- **Bash-based agent invocation**: `claude task ...` in agent -> use Task tool
- **Over-orchestration**: Simple tasks with unnecessary layers -> vanilla Claude Code is better for small tasks

## Composability

Skills can be shared across multiple agents:
```
agent-A (skills: [shared-knowledge, domain-A-specific])
agent-B (skills: [shared-knowledge, domain-B-specific])
```

Commands can compose multiple agents:
```
/full-review (command)
  -> Task(security-reviewer)
  -> Task(code-reviewer)
  -> Task(performance-reviewer)
```
