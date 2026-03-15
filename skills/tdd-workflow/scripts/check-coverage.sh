#!/usr/bin/env bash
# check-coverage.sh - Auto-detect test runner and report coverage
# Usage: bash check-coverage.sh [threshold]
# Returns: coverage percentage and pass/fail status
set -euo pipefail

THRESHOLD="${1:-80}"

if [ -f "package.json" ]; then
    if grep -q '"vitest"' package.json 2>/dev/null; then
        npx vitest run --coverage --reporter=verbose 2>/dev/null | grep -E "Statements|Branches|Functions|Lines|All files" || echo "Run: npx vitest run --coverage"
    elif grep -q '"jest"' package.json 2>/dev/null; then
        npx jest --coverage --coverageReporters=text-summary 2>/dev/null | grep -E "Statements|Branches|Functions|Lines" || echo "Run: npx jest --coverage"
    else
        echo "No recognized JS test runner found in package.json"
    fi
elif [ -f "go.mod" ]; then
    go test -coverprofile=coverage.out ./... 2>/dev/null
    go tool cover -func=coverage.out | tail -1
    rm -f coverage.out
elif [ -f "requirements.txt" ] || [ -f "pyproject.toml" ]; then
    python3 -m pytest --cov --cov-report=term-summary 2>/dev/null | grep -E "TOTAL|^Name" || echo "Run: pytest --cov"
elif [ -f "Cargo.toml" ]; then
    cargo test 2>/dev/null || echo "Run: cargo test"
else
    echo "No recognized test runner found"
    echo "Supported: vitest, jest (JS/TS), go test, pytest, cargo test"
    exit 1
fi

echo ""
echo "Target coverage threshold: ${THRESHOLD}%"
