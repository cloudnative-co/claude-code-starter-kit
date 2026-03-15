#!/usr/bin/env bash
# check-structure.sh - Check if codebase follows agent-native design principles
# Usage: bash check-structure.sh [directory]
set -euo pipefail

DIR="${1:-.}"

echo "=== Agent-Native Design Check ==="
echo ""

# Check for default exports (JS/TS)
echo "--- Default Exports (should be 0) ---"
default_count=$(grep -rn "export default" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" "$DIR" 2>/dev/null | grep -v node_modules | grep -v ".next" | grep -v dist | wc -l | tr -d ' ')
echo "Found: ${default_count} default exports"
if [ "$default_count" -gt 0 ]; then
    echo "  Tip: Use named exports for grep-ability"
    grep -rn "export default" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" "$DIR" 2>/dev/null | grep -v node_modules | grep -v ".next" | grep -v dist | head -5
fi
echo ""

# Check for collocated tests
echo "--- Collocated Tests ---"
src_files=$(find "$DIR" -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" | grep -v node_modules | grep -v ".next" | grep -v dist | grep -v test | grep -v spec | wc -l | tr -d ' ')
test_files=$(find "$DIR" -name "*.test.*" -o -name "*.spec.*" | grep -v node_modules | wc -l | tr -d ' ')
echo "Source files: ${src_files}, Test files: ${test_files}"
if [ "$src_files" -gt 0 ]; then
    ratio=$((test_files * 100 / src_files))
    echo "Test coverage ratio: ${ratio}%"
fi
echo ""

# Check for horizontal vs vertical slicing
echo "--- Directory Structure ---"
if [ -d "${DIR}/src/controllers" ] || [ -d "${DIR}/src/services" ] || [ -d "${DIR}/src/models" ]; then
    echo "WARNING: Horizontal slicing detected (controllers/, services/, models/)"
    echo "Consider: Feature-based structure (features/auth/, features/orders/)"
elif [ -d "${DIR}/src/features" ] || [ -d "${DIR}/features" ]; then
    echo "OK: Feature-based structure detected"
else
    echo "INFO: No standard structure detected"
fi
echo ""

# Check file sizes
echo "--- File Size Check (target: <300 lines) ---"
large_files=$(find "$DIR" -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" | grep -v node_modules | grep -v ".next" | grep -v dist | while read -r f; do
    lines=$(wc -l < "$f" | tr -d ' ')
    if [ "$lines" -gt 300 ]; then
        echo "  ${f}: ${lines} lines"
    fi
done)
if [ -n "$large_files" ]; then
    echo "WARNING: Files exceeding 300 lines:"
    echo "$large_files"
else
    echo "OK: All files under 300 lines"
fi
