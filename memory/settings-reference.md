# Settings Quick Reference

## Model Selection
| Alias | Use Case |
|-------|----------|
| `haiku` | Lightweight agents, worker agents (3x savings) |
| `sonnet` | Main dev, orchestration, complex coding |
| `opus` | Deep reasoning, architecture, research |
| `opusplan` | Opus for planning, Sonnet for execution |
| `sonnet[1m]` | Sonnet with 1M token context |

## Opus 4.6 Effort Levels
- **High** (default): Full reasoning depth
- **Medium**: Balanced
- **Low**: Minimal reasoning, fastest

## Key Environment Variables
| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_MODEL` | Override default model |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Subagent model |
| `MAX_THINKING_TOKENS` | Extended thinking limit |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | Auto-compact threshold |
| `BASH_MAX_TIMEOUT_MS` | Bash command timeout |
| `MCP_TIMEOUT` | MCP startup timeout (default: 10000ms) |

## Permission Patterns
| Tool | Pattern | Example |
|------|---------|---------|
| Bash | `Bash(pattern)` | `Bash(npm run *)` |
| Read | `Read(path)` | `Read(.env)` |
| Edit | `Edit(path)` | `Edit(src/**)` |
| Write | `Write(path)` | `Write(*.md)` |
| MCP | `mcp__server__tool` | `mcp__github__*` |
| Task | `Task(agent)` | `Task(Explore)` |

## Browser Automation MCP
| Tool | Tokens | Best For |
|------|--------|----------|
| Playwright MCP | ~13.7k | Primary testing, cross-browser |
| Claude in Chrome | ~15.4k | Manual testing with auth |
| Chrome DevTools MCP | ~19.0k | Performance, network debug |

## Community Terminology
- **Context Bloat**: Too much context loaded
- **Context Rot**: Stale/outdated context
- **Dumb Zone**: Last 20% of context window
- **Progressive Disclosure**: Load context on-demand
- **The Holy Trinity**: Skills + Agents + Hooks
- **Token Burn**: Wasted tokens on irrelevant context
- **Slot Machine Method**: Retry hoping for different result
