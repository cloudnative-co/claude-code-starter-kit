# Daily Practices

## Commit Discipline
- Commit as soon as each task is completed. Do not batch multiple tasks into one commit.
- Use descriptive commit messages that explain WHY, not just WHAT.

## Context Hygiene
- Start each new task with `/clear` or a fresh session.
- Run `/compact` proactively at ~50% context usage. Do not wait for auto-compact.
- After switching to a completely different task, always start a new session.

## Debugging Approach
- Always ask Claude to run the terminal (you want to see logs of) as a background task.
- Provide screenshots of visual issues -- Claude can analyze them directly.
- For browser issues, use MCP integrations (Playwright, Chrome DevTools) so Claude can see console logs.

## Plan Before Execute
- Always start complex tasks with plan mode (Shift+Tab or /plan).
- Use phase-wise gated plans: each phase has tests before proceeding to next.

## Ultrathink for Hard Problems
- Include the keyword `ultrathink` in prompts for complex architecture decisions.
- This activates extended thinking mode for higher effort reasoning.

## Model and Context Awareness
- Use `/model` to select the appropriate model for the task.
- Use Haiku for lightweight tasks (doc updates, simple fixes).
- Use Opus for complex reasoning and architecture decisions.
