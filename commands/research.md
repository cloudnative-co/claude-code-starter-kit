# /research - Deep Codebase Investigation

Perform a thorough investigation of the codebase before making any changes.

## Instructions

You are entering **Research Phase**. Your goal is to deeply understand the relevant parts of the codebase before any planning or implementation begins.

### Steps

1. **Identify scope**: Based on the user's request, determine which parts of the codebase are relevant.

2. **Deep read**: Read all relevant files thoroughly. Use words like "deeply examine", "trace the flow", "understand the intricacies" in your analysis. Don't skim - understand the actual logic, edge cases, and design decisions.

3. **Map dependencies**: Trace imports, function calls, and data flow across files. Document the dependency graph.

4. **Identify patterns**: Note existing patterns, conventions, abstractions, and architectural decisions already in the codebase.

5. **Find constraints**: Identify tests, type contracts, API boundaries, and invariants that must be preserved.

6. **Generate research.md**: Save your findings as `research.md` in the project root (or a designated docs directory) with the following structure:

```
# Research: [Topic]
## Date: [YYYY-MM-DD]
## Scope
## Key Files
## Architecture & Patterns
## Dependencies & Data Flow
## Constraints & Invariants
## Risks & Considerations
## Recommendations for Planning Phase
```

### Rules

- **DO NOT write any code** during this phase.
- **DO NOT create a plan** during this phase. That is for `/plan`.
- Focus exclusively on understanding and documenting.
- If the codebase is large, use Subagents to investigate different areas in parallel.
- After generating research.md, suggest the user review it and then proceed to `/plan`.

### After Research

Recommend:
1. Review `research.md` and add inline annotations for anything unclear or needing correction.
2. When satisfied, run `/plan` to create an implementation plan based on the research.
3. Consider running `/compact` before `/plan` to start planning with fresh context (FIC).
