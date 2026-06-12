# /learn - Extract Reusable Patterns

Analyze the current session and extract any patterns worth saving as skills.

## Trigger

Run `/learn` at any point during a session when you've solved a non-trivial problem.

## What to Extract

Look for:

1. **Error Resolution Patterns**
   - What error occurred?
   - What was the root cause?
   - What fixed it?
   - Is this reusable for similar errors?

2. **Debugging Techniques**
   - Non-obvious debugging steps
   - Tool combinations that worked
   - Diagnostic patterns

3. **Workarounds**
   - Library quirks
   - API limitations
   - Version-specific fixes

4. **Project-Specific Patterns**
   - Codebase conventions discovered
   - Architecture decisions made
   - Integration patterns

## Output Format

Create a skill at `~/.claude/skills/learned/<pattern-name>/SKILL.md` so the
current skill discovery mechanism (directory + SKILL.md with YAML
frontmatter) can load it:

```markdown
---
name: <pattern-name>
description: <one-line description of the problem this solves>
when_to_use: Use when <trigger condition for this pattern>
---

# [Descriptive Pattern Name]

## Problem
[What problem this solves - be specific]

## Solution
[The pattern/technique/workaround]

## Example
[Code example if applicable]
```

## Process

1. Review the session for extractable patterns
2. Identify the most valuable/reusable insight
3. Draft the SKILL.md
4. Ask user to confirm before saving
5. Save to `~/.claude/skills/learned/<pattern-name>/SKILL.md`

## Notes

- Don't extract trivial fixes (typos, simple syntax errors)
- Don't extract one-time issues (specific API outages, etc.)
- Focus on patterns that will save time in future sessions
- Keep skills focused - one pattern per skill
- Routine learnings are captured automatically by auto-memory; use /learn
  only to promote a pattern into an activatable skill
