---
name: prompt-patterns
description: Practical prompt patterns and techniques for effective Claude Code usage. Reference when crafting prompts, planning workflows, or debugging interactions.
when_to_use: Use when the user wants help crafting prompts, planning an interaction strategy, or debugging prompt quality.
---

# Prompt Patterns for Claude Code

## Discovery Patterns

### Interview-Driven Spec
Instead of writing a spec yourself, let Claude interview you:
```
Start with a minimal description of what I want to build, then interview me
using AskUserQuestion tool. Ask one question at a time until you have enough
information to write a complete specification. Then create the spec document.
```
Creates better specs than writing them manually. Claude asks questions you wouldn't think of.

### Codebase Understanding
```
Read the entire codebase and explain the architecture to me as if I'm a new
team member. Focus on: data flow, key abstractions, and non-obvious design decisions.
```

## Quality Challenge Patterns

### Grill Mode
After implementation, challenge Claude to prove correctness:
```
Grill me on these changes and don't make a PR until I pass your test.
```
or
```
Prove to me this works. Diff between main and this branch, explain every change,
and identify any edge cases we missed.
```

### Elegant Redo
When a fix works but feels hacky:
```
Knowing everything you know now, scrap this and implement the elegant solution.
```
Claude's second attempt is almost always better because it has full context of the problem.

### Self-Critique
```
Review the code you just wrote as a senior engineer. Be harsh.
What would you change if this was going into a production system
serving 10 million users?
```

## Efficiency Patterns

### Subagent Offloading
When context is getting heavy:
```
Use subagents to investigate [topic]. Keep the main context clean.
```
Explicitly telling Claude to use subagents prevents context pollution.

### Batch Operations
```
Process these 5 files in parallel using subagents. Each subagent handles one file.
Collect all results and present a unified summary.
```

### Ultrathink
For complex reasoning tasks, include the keyword:
```
ultrathink about the best architecture for this system
```
Triggers extended thinking mode for higher effort reasoning.

## Debugging Patterns

### Bug -> Fix (No Micromanagement)
```
Here's the bug: [paste error/screenshot]. Fix it.
```
Claude fixes most bugs by itself. Don't prescribe the solution.

### Visual Debugging
Paste a screenshot of the issue, then:
```
Look at this screenshot. The layout is broken. Fix it.
```

## Session Management Patterns

### Phase-wise Gated Plan
```
Create a phase-wise plan for this feature. Each phase must have:
1. Clear deliverable
2. Test criteria (unit, integration, or manual verification)
3. Estimated context usage

Do not proceed to the next phase until the current phase passes all tests.
```

### Context-Aware Restart
Before starting a new task in the same session:
```
/clear
```
After heavy investigation:
```
/compact Preserve the key findings about [topic] and the implementation plan
```

### Rename and Resume
Name important sessions for easy retrieval:
```
/rename [feature-name implementation v2]
```
Later: `claude --resume` to pick up where you left off.
