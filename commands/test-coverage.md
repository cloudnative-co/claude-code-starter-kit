# Test Coverage

Analyze test coverage and generate missing tests:

1. Identify the project's test tooling and run tests with coverage
   (e.g. npm test --coverage, pytest --cov, go test -cover)

2. Analyze the coverage report your test runner produces
   (e.g. coverage/coverage-summary.json for JS)

3. Identify files below 80% coverage threshold

4. For each under-covered file:
   - Analyze untested code paths
   - Generate unit tests for functions
   - Generate integration tests for APIs
   - Generate E2E tests for critical flows

5. Verify new tests pass

6. Show before/after coverage metrics

7. Ensure project reaches 80%+ overall coverage

Focus on:
- Happy path scenarios
- Error handling
- Edge cases (null / missing / empty values)
- Boundary conditions
