#!/bin/bash
# Claude Code statusline script (ToS-safe version)
# Line 1: Model | Context% | +added/-removed | git branch
# Line 2: Context window progress bar (detailed)
# Line 3: Session cost | Version
#
# This version uses ONLY stdin data provided by Claude Code.
# No external API calls, no OAuth token extraction, no keychain access.
# Fully compliant with Anthropic Consumer Terms of Service.

set -euo pipefail

# ---------- Read stdin (Claude Code provides JSON) ----------
input=$(cat)

# ---------- ANSI Colors ----------
readonly GREEN=$'\e[38;2;151;201;195m'
readonly YELLOW=$'\e[38;2;229;192;123m'
readonly RED=$'\e[38;2;224;108;117m'
readonly GRAY=$'\e[38;2;74;88;92m'
readonly RESET=$'\e[0m'
readonly DIM=$'\e[2m'

# ---------- Color by percentage ----------
color_for_pct() {
  local pct="${1:-0}"
  if [[ -z "$pct" || "$pct" == "null" ]]; then
    printf '%s' "$GRAY"
    return
  fi
  local ipct
  ipct=$(printf "%.0f" "$pct" 2>/dev/null) || ipct=0
  if (( ipct >= 80 )); then
    printf '%s' "$RED"
  elif (( ipct >= 50 )); then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

# ---------- Progress bar (10 segments) ----------
progress_bar() {
  local pct="${1:-0}"
  local filled
  filled=$(awk "BEGIN{v=int($pct / 10 + 0.5); if(v>10)v=10; if(v<0)v=0; printf \"%d\", v}" 2>/dev/null) || filled=0
  local bar=""
  local i
  for (( i=1; i<=10; i++ )); do
    if (( i <= filled )); then
      bar+="▰"
    else
      bar+="▱"
    fi
  done
  printf '%s' "$bar"
}

# ---------- Safe JSON parsing (no eval) ----------
parse_json() {
  local json="$1"
  local query="$2"
  local default="${3:-}"
  local result
  result=$(printf '%s' "$json" | jq -r "$query" 2>/dev/null) || result=""
  if [[ -z "$result" || "$result" == "null" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$result"
  fi
}

# ---------- Parse stdin fields ----------
model_name=$(parse_json "$input" '.model.display_name // empty' 'Unknown')
used_pct=$(parse_json "$input" '.context_window.used_percentage // 0' '0')
remaining_pct=$(parse_json "$input" '.context_window.remaining_percentage // 100' '100')
ctx_size=$(parse_json "$input" '.context_window.context_window_size // 0' '0')
cwd=$(parse_json "$input" '.cwd // empty' '')
lines_added=$(parse_json "$input" '.cost.total_lines_added // 0' '0')
lines_removed=$(parse_json "$input" '.cost.total_lines_removed // 0' '0')
total_cost=$(parse_json "$input" '.cost.total_cost_usd // 0' '0')

# ---------- Git branch ----------
git_branch=""
if [[ -n "$cwd" && -d "$cwd" ]]; then
  git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null) || true
fi

# ---------- Line stats ----------
git_stats=""
if (( ${lines_added:-0} > 0 )) 2>/dev/null || (( ${lines_removed:-0} > 0 )) 2>/dev/null; then
  git_stats="+${lines_added}/-${lines_removed}"
fi

# ---------- Context window formatting ----------
ctx_pct_int=$(printf "%.0f" "${used_pct:-0}" 2>/dev/null) || ctx_pct_int=0

# Format context size (e.g., 200000 -> 200K)
format_tokens() {
  local tokens="${1:-0}"
  if (( tokens >= 1000000 )); then
    awk "BEGIN{printf \"%.0fM\", $tokens / 1000000}"
  elif (( tokens >= 1000 )); then
    awk "BEGIN{printf \"%.0fK\", $tokens / 1000}"
  else
    printf '%s' "$tokens"
  fi
}

ctx_size_display=$(format_tokens "$ctx_size")

# Used tokens (approximate)
used_tokens=0
if (( ctx_size > 0 )); then
  used_tokens=$(awk "BEGIN{printf \"%.0f\", $ctx_size * $used_pct / 100}" 2>/dev/null) || used_tokens=0
fi
used_tokens_display=$(format_tokens "$used_tokens")

# ---------- Cost formatting ----------
cost_display=""
if [[ -n "$total_cost" && "$total_cost" != "0" ]]; then
  cost_display=$(awk "BEGIN{printf \"\$%.2f\", $total_cost}" 2>/dev/null) || cost_display=""
fi

# ---------- Separator ----------
SEP="${GRAY} │ ${RESET}"

# ========== Line 1: Model | Context% | Changes | Branch ==========
ctx_color=$(color_for_pct "$ctx_pct_int")

line1="🤖 ${model_name}${SEP}${ctx_color}📊 ${ctx_pct_int}%${RESET}"

if [[ -n "$git_stats" ]]; then
  line1+="${SEP}✏️  ${GREEN}${git_stats}${RESET}"
fi

if [[ -n "$git_branch" ]]; then
  line1+="${SEP}🔀 ${git_branch}"
fi

# ========== Line 2: Context window progress bar ==========
ctx_bar_color=$(color_for_pct "$ctx_pct_int")
ctx_bar=$(progress_bar "$ctx_pct_int")

line2="${ctx_bar_color}📐 CTX  ${ctx_bar}  ${ctx_pct_int}%${RESET}"
if (( ctx_size > 0 )); then
  line2+="  ${DIM}${used_tokens_display} / ${ctx_size_display} tokens${RESET}"
fi

# ========== Line 3: Session cost ==========
line3=""
if [[ -n "$cost_display" ]]; then
  line3="${GREEN}💰 ${cost_display}${RESET}"
else
  line3="${DIM}💰 --${RESET}"
fi

# ---------- Output ----------
printf '%s\n' "$line1"
printf '%s\n' "$line2"
printf '%s' "$line3"
