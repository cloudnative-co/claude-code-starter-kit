# Command → Agent → Skills Architecture

## Pattern Overview

| Component | Role | Invocation |
|-----------|------|------------|
| **Command/Skill** | Entry point, user interaction | `/skill-name` |
| **Agent** | Orchestrates workflow with preloaded skills | Task tool |
| **Skills** | Domain knowledge injected at startup | Progressive disclosure |

## When to Use
- Multi-step workflows requiring coordination
- Domain-specific knowledge injection
- Sequential tasks with validation checkpoints
- Reusable components across projects

## Why It Works
- **Progressive disclosure**: Context loaded only when needed
- **Single execution context**: Agent maintains state across phases
- **Clean separation**: Each component has clear responsibility
- **Reusability**: Skills shared across agents and projects

## Agent Definition Format
```yaml
---
name: agent-name
description: When to use this agent proactively
tools: WebFetch, Read, Write  # restricted tool set
model: haiku  # cost-appropriate model
color: green
skills:
  - skill-one
  - skill-two
---
```

## Skill Definition Format
File: `.claude/skills/<name>/SKILL.md`
```yaml
---
name: skill-name
description: What this skill provides
model: haiku
tools: WebFetch, Read
context: fork  # isolated execution
---
```

## RPI Workflow (Research → Plan → Implement)

### Directory Structure
```
rpi/{feature-slug}/
  REQUEST.md          # Initial spec
  research/           # Feasibility + GO/NO-GO
  plan/               # Product, UX, Engineering specs
  implement/          # Execution records
```

### Phases
1. `/rpi:research` - Feasibility analysis, produces GO/NO-GO verdict
2. `/rpi:plan` - User stories, UX flows, technical architecture
3. `/rpi:implement` - Phase-by-phase development with validation

## Agent SDK vs CLI
- CLI: 110+ system prompt strings, auto-loads CLAUDE.md
- SDK: Minimal by default, must explicitly configure
- SDK `claude_code` preset matches CLI but still needs `settingSources: ["project"]` for CLAUDE.md
- Deterministic output between platforms NOT guaranteed (no seed parameter)
