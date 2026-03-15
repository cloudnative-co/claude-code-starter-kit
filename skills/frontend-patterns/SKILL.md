---
name: frontend-patterns
description: Frontend development patterns for React, Next.js, state management, performance optimization, and UI best practices.
---

# Frontend Development Patterns

Modern frontend patterns for React, Next.js, and performant user interfaces.

## Pattern Categories

### Component Patterns
Composition over inheritance, compound components, render props.
See [references/component-patterns.md](references/component-patterns.md) for implementations.

### Custom Hooks
Reusable hooks: useToggle, useQuery, useDebounce.
See [references/hooks-patterns.md](references/hooks-patterns.md) for implementations.

### State Management & Performance
Context + Reducer pattern, memoization, code splitting, virtualization.
See [references/state-performance.md](references/state-performance.md) for implementations.

### Forms, Error Boundaries, Animation & Accessibility
Controlled forms with validation, ErrorBoundary, Framer Motion, keyboard navigation, focus management.
See [references/forms-errors-a11y.md](references/forms-errors-a11y.md) for implementations.

## Quick Decision Guide

| Need | Pattern |
|------|---------|
| Shared state across siblings | Context + Reducer |
| Expensive computation | `useMemo` |
| Stable callback reference | `useCallback` |
| Prevent unnecessary re-renders | `React.memo` |
| Large list rendering | Virtualization (`@tanstack/react-virtual`) |
| Heavy component | `lazy()` + `Suspense` |
| Form validation | Controlled form + error state |
| Graceful error handling | ErrorBoundary class component |
| Keyboard accessible UI | `role`, `aria-*`, `onKeyDown` handlers |

**Remember**: Choose patterns that fit your project complexity. Not every project needs every pattern.
