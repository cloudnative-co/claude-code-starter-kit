---
name: agent-native-design
description: Guidelines for writing code that AI agents can efficiently navigate, understand, and modify
---

# Agent-Native Code Design

## Grep-able Naming

- Use named exports exclusively (no default exports)
- Consistent error type naming: `XxxError`, `XxxException`
- Descriptive function names that include the action: `createUser`, `validateEmail`, `fetchOrderById`
- Agents rely on `grep`, `glob`, `cat` - names must be searchable

## Collocated Tests

- Place tests adjacent to source: `ComponentName.test.tsx` next to `ComponentName.tsx`
- Use `__tests__/` directories within feature folders, not a top-level `tests/` tree
- One `ls` command should reveal if a file has tests
- Naming convention: `[filename].test.[ext]` or `[filename].spec.[ext]`

## Feature-based Module Structure

Prefer vertical (feature) slices over horizontal (layer) slices:

```
# GOOD: Feature-based (agent-friendly)
features/
  auth/
    auth.service.ts
    auth.controller.ts
    auth.test.ts
  orders/
    orders.service.ts
    orders.controller.ts
    orders.test.ts

# AVOID: Layer-based (agent-unfriendly)
controllers/
  auth.controller.ts
  orders.controller.ts
services/
  auth.service.ts
  orders.service.ts
```

## Tests as Reward Signal

- Every code path should have a test - untested code is unverifiable by agents
- Tests define "correct" behavior; agents use test pass/fail as their feedback loop
- Write tests before implementation when possible (TDD)

## Clear API Boundaries

- Define interfaces/types at module boundaries before implementation
- Shared types in a dedicated `types/` or `contracts/` location
- API contracts enable safe parallel development by multiple agents

## Small, Focused Files

- Target: <300 lines per file
- One responsibility per file
- Agents work better with many small files than few large ones
