---
name: tdd-workflow
description: Use this skill when the user explicitly asks for TDD or a tests-first workflow, or when developing a new feature with a test coverage requirement. Provides a structured red-green-refactor workflow with unit, integration, and E2E test guidance.
when_to_use: Use when the user explicitly requests TDD/tests-first development, or when building a new feature where test coverage is a stated requirement.
---

# Test-Driven Development Workflow

This skill provides a structured TDD workflow for projects that adopt tests-first development.

## When to Activate

- The user explicitly asks for TDD or tests-first development
- New feature work where test coverage is a stated requirement
- Adding API endpoints or components under a coverage policy

For routine bug fixes or refactors, add focused tests for the changed behavior instead of invoking this full workflow (the /tdd command and tdd-guide agent remain available when you want it explicitly).

## Core Principles

### 1. Tests BEFORE Code
Within this workflow, the default is to write tests first, then implement code to make tests pass.

### 2. Coverage Guidance
- Coverage target follows the project's own standard (e.g., 80% as a common baseline); scale effort with the size of the change
- Cover relevant edge cases
- Test error scenarios
- Verify boundary conditions

### 3. Test Types

**Unit Tests** - Individual functions, utilities, component logic, pure functions, helpers.

**Integration Tests** - API endpoints, database operations, service interactions, external API calls.

**E2E Tests (Playwright)** - Critical user flows, complete workflows, browser automation, UI interactions. Applies to web UI projects only.

## TDD Workflow Steps

### Step 1: Write User Journeys
```
As a [role], I want to [action], so that [benefit]

Example:
As a user, I want to search for markets semantically,
so that I can find relevant markets even without exact keywords.
```

### Step 2: Generate Test Cases
For each user journey, create comprehensive test cases covering happy paths, edge cases, fallback behavior, and sorting/filtering logic.

### Step 3: Run Tests (They Should Fail)
Use the project's test runner. Examples:
```bash
npm test                      # Node.js
pytest                        # Python
bash tests/run-unit-tests.sh  # shell projects
# Tests should fail - we haven't implemented yet
```

### Step 4: Implement Code
Write minimal code to make tests pass.

### Step 5: Run Tests Again
Re-run the same test command (e.g., `npm test`, `pytest`):
```bash
npm test
# Tests should now pass
```

### Step 6: Refactor
Improve code quality while keeping tests green:
- Remove duplication
- Improve naming
- Optimize performance
- Enhance readability

### Step 7: Verify Coverage
Use the project's coverage tooling. Examples:
```bash
npm run test:coverage   # Node.js
pytest --cov            # Python
# Verify coverage meets the project's target
```

## Best Practices

1. **Write Tests First** - Always TDD
2. **One Assert Per Test** - Focus on single behavior
3. **Descriptive Test Names** - Explain what's tested
4. **Arrange-Act-Assert** - Clear test structure
5. **Mock External Dependencies** - Isolate unit tests
6. **Test Edge Cases** - Null, undefined, empty, large
7. **Test Error Paths** - Not just happy paths
8. **Keep Tests Fast** - Unit tests < 50ms each
9. **Clean Up After Tests** - No side effects
10. **Review Coverage Reports** - Identify gaps

## Success Metrics

- Coverage target met (per project standard, e.g., 80%)
- All tests passing (green)
- No skipped or disabled tests
- Fast test execution (< 30s for unit tests)
- E2E tests cover critical user flows
- Tests catch bugs before production

## References

These templates target JavaScript/TypeScript stacks; adapt the structure for other languages.

- `references/test-templates.md` - Unit, integration, E2E, and mocking code templates (JS/TS)
- `references/testing-mistakes.md` - Common pitfalls, file organization, coverage config, CI setup (JS/TS)

---

**Remember**: Give changed behavior a focused test. Tests are the safety net that enables confident refactoring, rapid development, and production reliability.
