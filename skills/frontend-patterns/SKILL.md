---
name: frontend-patterns
description: Frontend development patterns for React, Next.js, state management, performance optimization, and UI best practices.
when_to_use: Use when building or reviewing React or Next.js UI, custom hooks, state management, or frontend performance work.
---

# Frontend Development Patterns

Modern frontend patterns for React, Next.js, and performant user interfaces.

## Pattern Categories

### Component Patterns
Composition over inheritance, compound components, render props.
See [references/component-patterns.md](references/component-patterns.md) for implementations.

### Custom Hooks
Reusable hooks: useToggle, useDebounce; server state via TanStack Query / SWR.
See [references/hooks-patterns.md](references/hooks-patterns.md) for implementations.

### State Management & Performance
Context + Reducer pattern, memoization, code splitting, virtualization.
See [references/state-performance.md](references/state-performance.md) for implementations.

### Forms, Error Boundaries, Animation & Accessibility
Controlled forms with validation, ErrorBoundary, motion (formerly Framer Motion), keyboard navigation, focus management.
See [references/forms-errors-a11y.md](references/forms-errors-a11y.md) for implementations.

## Quick Decision Guide

| Need | Pattern |
|------|---------|
| Shared state across siblings | Context + Reducer |
| Expensive computation (no React Compiler) | `useMemo` |
| Stable callback reference (no React Compiler) | `useCallback` |
| Prevent unnecessary re-renders (no React Compiler) | `React.memo` |
| Large list rendering | Virtualization (`@tanstack/react-virtual`) |
| Heavy component | `lazy()` + `Suspense` |
| Form validation | Controlled form + error state |
| Graceful error handling | ErrorBoundary class component |
| Keyboard accessible UI | `role`, `aria-*`, `onKeyDown` handlers |

**Note**: On projects using React Compiler, manual memoization (`useMemo`/`useCallback`/`React.memo`) is generally unnecessary; add it only when profiling shows a real problem.

**Remember**: Choose patterns that fit your project complexity. Not every project needs every pattern.
