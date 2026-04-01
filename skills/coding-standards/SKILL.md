---
name: coding-standards
description: Universal coding standards, best practices, and patterns for TypeScript, JavaScript, React, and Node.js development.
when_to_use: Use when reviewing or writing TypeScript, JavaScript, React, or Node.js code and project-wide coding conventions matter.
---

# Coding Standards & Best Practices

Universal coding standards applicable across all projects. Detailed patterns and examples are in the `references/` directory.

## Quick Decision Guide

| What you need | Reference file |
|---|---|
| Naming, immutability, types, error handling, async | `references/typescript-patterns.md` |
| Components, hooks, state, memoization, lazy loading | `references/react-patterns.md` |
| REST API design, file structure, testing, code smells | `references/api-testing-patterns.md` |

## Categories

### TypeScript/JavaScript Patterns
Variable and function naming conventions, immutability (critical), comprehensive error handling, async/await best practices, type safety, comments/documentation style, and database query performance.

See: `references/typescript-patterns.md`

### React Patterns
Functional component structure with typed props, custom hooks (useDebounce pattern), proper state updates with functional setters, conditional rendering without ternary chains, useMemo/useCallback memoization, and lazy loading with Suspense.

See: `references/react-patterns.md`

### API Design, Testing & Code Smells
REST conventions, consistent ApiResponse format, Zod input validation, project file organization and naming, AAA test pattern, descriptive test naming, and anti-pattern detection (long functions, deep nesting, magic numbers).

See: `references/api-testing-patterns.md`

## Core Principles

1. **Readability First** -- self-documenting code over comments
2. **KISS** -- simplest solution that works
3. **DRY** -- extract and reuse common logic
4. **YAGNI** -- build only what is needed now
5. **Immutability** -- never mutate; always spread
