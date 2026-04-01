---
name: project-guidelines-example
description: Example project-specific skill template. Use as a starting point when creating guidelines for your own projects.
when_to_use: Use when creating a new project-specific skill or adapting this template into real architecture, workflow, and testing guidance.
---

# Project Guidelines Skill (Example)

This is an example of a project-specific skill. Use this as a template for your own projects.

Based on a real production application: [Zenith](https://zenith.chat) - AI-powered customer discovery platform.

## When to Use

Reference this skill when working on the specific project it's designed for. Project skills contain:
- Architecture overview
- File structure
- Code patterns
- Testing requirements
- Deployment workflow

## Reference Documents

- [Architecture & File Structure](references/architecture.md) - Tech stack, service diagram, directory layout
- [Code Patterns](references/code-patterns.md) - API response format, frontend API calls, Claude AI integration, custom hooks
- [Testing & Deployment](references/testing-deployment.md) - pytest, React Testing Library, deployment commands, environment variables

## Critical Rules

1. **No emojis** in code, comments, or documentation
2. **Immutability** - never mutate objects or arrays
3. **TDD** - write tests before implementation
4. **80% coverage** minimum
5. **Many small files** - 200-400 lines typical, 800 max
6. **No console.log** in production code
7. **Proper error handling** with try/catch
8. **Input validation** with Pydantic/Zod

## Related Skills

- `coding-standards` - General coding best practices
- `backend-patterns` - API and database patterns
- `frontend-patterns` - React and Next.js patterns
- `tdd-workflow` - Test-driven development methodology
