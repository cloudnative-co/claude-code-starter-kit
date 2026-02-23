#!/bin/bash
# Claude Code statusline script
# Displays: token count | context remaining | version info

input=$(cat)

# Token usage
total_input=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
total_output=$(echo "$input" | jq -r '.context_window.current_usage.output_tokens // 0')
tokens=$(( total_input + total_output ))

# Context remaining percentage (pre-calculated)
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Version
version=$(echo "$input" | jq -r '.version // empty')

# Build parts
parts=()

if [ "$tokens" -gt 0 ] 2>/dev/null; then
  parts+=("${tokens} tokens")
fi

if [ -n "$remaining" ]; then
  remaining_int=$(printf "%.0f" "$remaining" 2>/dev/null || echo "$remaining")
  parts+=("Context: ${remaining_int}%")
fi

if [ -n "$version" ]; then
  parts+=("v${version}")
fi

# Join with separator
printf "%s" "$(IFS=' | '; echo "${parts[*]}")"
