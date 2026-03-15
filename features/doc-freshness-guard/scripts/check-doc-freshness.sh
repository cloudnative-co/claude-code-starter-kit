#!/usr/bin/env bash
# Doc Freshness Guard - Checks documentation staleness and superseded ADR references
# Triggered as PostToolUse hook on git commit operations

set -euo pipefail

# Read hook input from stdin (required by Claude Code hook protocol)
input=$(cat)

WARN_DAYS="${DOC_FRESHNESS_WARN_DAYS:-3}"
ERROR_DAYS="${DOC_FRESHNESS_ERROR_DAYS:-5}"

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
exit_code=0
warnings=""
errors=""

# Check last-validated dates in docs
check_doc_freshness() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        # Look for last-validated, last_validated, or validated date patterns
        local validated_date
        validated_date=$(grep -iE '(last[_-]validated|validated)[[:space:]]*[:=][[:space:]]*' "$file" 2>/dev/null | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)

        if [[ -z "$validated_date" ]]; then
            continue
        fi

        local today_epoch validated_epoch diff_days

        # Cross-platform date handling (macOS vs Linux)
        if date --version >/dev/null 2>&1; then
            # GNU date (Linux/WSL)
            today_epoch=$(date +%s)
            validated_epoch=$(date -d "$validated_date" +%s 2>/dev/null || echo "0")
        else
            # BSD date (macOS)
            today_epoch=$(date +%s)
            validated_epoch=$(date -j -f "%Y-%m-%d" "$validated_date" +%s 2>/dev/null || echo "0")
        fi

        if [[ "$validated_epoch" == "0" ]]; then
            continue
        fi

        diff_days=$(( (today_epoch - validated_epoch) / 86400 ))

        local rel_path="${file#"$PROJECT_ROOT"/}"

        if (( diff_days >= ERROR_DAYS )); then
            errors="${errors}ERROR: ${rel_path} last validated ${diff_days} days ago (limit: ${ERROR_DAYS} days). Run validation and update the date.\n"
            exit_code=1
        elif (( diff_days >= WARN_DAYS )); then
            warnings="${warnings}WARNING: ${rel_path} last validated ${diff_days} days ago (recommend: <${WARN_DAYS} days).\n"
        fi
    done < <(find "$dir" -name "*.md" -type f 2>/dev/null)
}

# Check for references to superseded ADRs
check_superseded_adr_refs() {
    local adr_dir="${PROJECT_ROOT}/docs/adr"

    if [[ ! -d "$adr_dir" ]]; then
        return 0
    fi

    # Find superseded ADRs
    local superseded_adrs=()
    while IFS= read -r adr_file; do
        [[ -z "$adr_file" ]] && continue
        if grep -qiE 'status[[:space:]]*[:=][[:space:]]*superseded' "$adr_file" 2>/dev/null; then
            superseded_adrs+=("$(basename "$adr_file")")
        fi
    done < <(find "$adr_dir" -name "*.md" -type f 2>/dev/null)

    if [[ ${#superseded_adrs[@]} -eq 0 ]]; then
        return 0
    fi

    # Check if CLAUDE.md, AGENTS.md, or docs reference superseded ADRs
    local files_to_check=()
    for f in "${PROJECT_ROOT}/CLAUDE.md" "${PROJECT_ROOT}/AGENTS.md" "${PROJECT_ROOT}/.claude/CLAUDE.md" "${PROJECT_ROOT}/.claude/AGENTS.md"; do
        [[ -f "$f" ]] && files_to_check+=("$f")
    done
    while IFS= read -r doc_file; do
        [[ -z "$doc_file" ]] && continue
        files_to_check+=("$doc_file")
    done < <(find "${PROJECT_ROOT}/docs" -name "*.md" -not -path "*/adr/*" -type f 2>/dev/null)

    local check_file superseded
    for check_file in "${files_to_check[@]}"; do
        for superseded in "${superseded_adrs[@]}"; do
            if grep -q "$superseded" "$check_file" 2>/dev/null; then
                local rel_check="${check_file#"$PROJECT_ROOT"/}"
                warnings="${warnings}WARNING: ${rel_check} references superseded ADR: ${superseded}\n"
            fi
        done
    done
}

# Run checks
check_doc_freshness "${PROJECT_ROOT}/docs"
check_doc_freshness "${PROJECT_ROOT}/docs/adr"
check_superseded_adr_refs

# Output results
if [[ -n "$errors" ]]; then
    printf '%b' "$errors" >&2
fi
if [[ -n "$warnings" ]]; then
    printf '%b' "$warnings" >&2
fi

if [[ $exit_code -ne 0 ]]; then
    echo "" >&2
    echo "Tip: Update the 'last-validated' date in stale docs after reviewing them." >&2
    echo "Tip: Use a Subagent to fix documentation issues: spawn a doc-updater agent." >&2
fi

# Pass through the input
printf '%s\n' "$input"

exit $exit_code
