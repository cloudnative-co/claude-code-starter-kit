# Bash-first steer — real Claude Code verification harness

Manual, model-calling harness. It is **not** wired into CI: every case starts
a real `claude -p` session (Fable 5.1, a few tens of cents each) and needs a
logged-in Claude Code CLI on the machine.

Prerequisites: `claude` (logged in), `jq`, `git`, and `biome` or `prettier`
on `PATH` (the formatter observable reads "no" otherwise; run-case.sh warns).
The recorded results below were produced with `biome` on `PATH` and no
`prettier`, so the "formatted" column reflects biome-hooks; prettier-hooks
uses the same `tool_input.file_path` contract and was not exercised.

## What it verifies

Claude Code 2.1.261 injects a "Bash-first" steer into **auto** and
**bypassPermissions** sessions (feature flag `CLAUDE_CODE_THRIFTY_SONIC`,
forced on for Fable 5.1 models, GrowthBook cohort for Opus 5). The steer reads:

> Do your work through the Bash tool wherever it can accomplish the job: read
> files with cat, head, or sed -n, search with grep and find, and make file
> changes with sed, heredocs, or short scripts, rather than using the dedicated
> Read, Edit, or Write tools.

Under that steer the model never calls Read/Edit/Write, so:

- `PostToolUse` `Edit|Write` hooks (prettier-hooks, biome-hooks) never format
- `PreToolUse` `Write` (doc-blocker) never asks, `PostToolUse` `Write`
  (doc-size-guard) never warns
- `.claude/rules/*.md` with `paths:` and nested `CLAUDE.md` are never loaded
  (they load on Read, not on cat)
- native checkpoint/rewind does not track the change (official limitation for
  Bash edits)

The kit's `native-file-tools` feature ships `env.CLAUDE_CODE_THRIFTY_SONIC="0"`
(Standard / Full) to opt out. This harness reproduces both the failure and the
fix with observable events only — no reliance on the model's self-report.

## Isolation

Each case runs `claude -p` with `--setting-sources project --strict-mcp-config`
in a fresh copy of a synthetic git repository, so `~/.claude/settings.json`,
`~/.claude/CLAUDE.md`, `~/.claude/rules/`, plugins and MCP servers are not
loaded (verified via the `InstructionsLoaded` observer: only the fixture's own
files appear). In the default mode every hook the session runs lives inside the
experiment directory, so the user's real configuration is never modified. In
`BFS_KIT_SETTINGS` mode the hook commands are the real `~/.claude/hooks/*`
scripts (see below). Session transcripts are still written under
`~/.claude/projects/` (synthetic content only); each run directory records the
path.

Observables per run (`runs/<case>/`):

| File | Content |
|---|---|
| `stdout.jsonl` | `--output-format stream-json --include-hook-events`: tool calls, hook responses (exit code, stdout, stderr), result and cost |
| `observer.jsonl` | `PreToolUse` / `PostToolUse` / `InstructionsLoaded` events from an observation-only hook |
| `auto-mode-attachment.jsonl` | the persisted `auto_mode` attachment from the transcript; `bashFirst:true` means the steer was injected |
| `git-status.txt`, `git-diff.txt`, `app.ts.after` | resulting repository state |

Rules and nested CLAUDE.md carry random marker tokens (`tokens.env`) that never
appear in the prompt; each instructs the model to `touch` a marker file. The
authoritative signal is the `InstructionsLoaded` event
(`path_glob_match` / `nested_traversal`); the marker files are a secondary
behavioural check.

## Running

```bash
EXP=$(mktemp -d)
bash tests/manual/bash-first-steer/make-fixture.sh "$EXP"          # once
bash tests/manual/bash-first-steer/run-case.sh "$EXP" A1 auto unset neutral   # failure
bash tests/manual/bash-first-steer/run-case.sh "$EXP" B1 auto 0 neutral       # fix (env in project settings)
bash tests/manual/bash-first-steer/run-case.sh "$EXP" C1 acceptEdits unset neutral  # control: no steer outside auto/bypass
bash tests/manual/bash-first-steer/summarize-run.sh "$EXP" A1
```

Arguments: `<mode> ∈ auto|acceptEdits|bypass`, `<flag> ∈ unset|0|1`
(`env.CLAUDE_CODE_THRIFTY_SONIC` in the fixture's project settings),
`<variant> ∈ neutral|native|bash` (prompt wording: neutral, "use Read/Edit/
Write", "use Bash only"). Repeat a case a few times — the model is stochastic.

`bypass` runs the session with `--permission-mode bypassPermissions`: no
permission prompts and no auto-mode classifier, so a live model works
unguarded inside the throwaway fixture repository. The fixture contains only
synthetic files, but run that mode only on a machine where that is acceptable.

To verify a kit-generated `settings.json` verbatim (for example the output of
`setup.sh --profile=full --hooks=doc-block,biome,doc-size,native-tools` in a
throwaway `HOME`), pass it with `BFS_KIT_SETTINGS=<file>` and `flag=unset`;
observers are then layered on with `--settings` so the file under test is
byte-identical to the kit output. The hook commands in that file are absolute
paths under the real `~/.claude/hooks/`, so they must already resolve on this
machine, and `run-case.sh` refuses a file that contains `SessionStart` /
`SessionEnd` hooks: a stock Standard/Full `settings.json` would otherwise run
the real auto-update hook (`git pull` + `setup.sh --update` on the real
install), the web-content-update hook and the feature-recommendation reader
inside the fixture session. Generate the file with a `--hooks` list that
leaves those out, as in the example above.

## Expected outcomes (Claude Code 2.1.261, claude-fable-5-1, 2026-09-06)

| Case | Steer attachment | Tools used | biome | doc-blocker ask | doc-size-guard warn | paths rule / nested CLAUDE.md loaded |
|---|---|---|---|---|---|---|
| auto, unset (×3) | `bashFirst:true` | Bash only | no | no | no | no / no |
| auto, `"0"` (×3) | none | Read/Write (+Bash for touch/git) | yes | yes | yes | yes / yes |
| acceptEdits, unset | none | Read/Write | yes | yes | yes | yes / yes |
| auto, unset, prompt "use Read/Edit/Write" | `bashFirst:true` | Read/Edit/Write | yes | yes | yes | yes / yes |
| auto, `"0"`, prompt "use Bash only" | none | Bash only | no | no | no | no / no |
| bypassPermissions, unset | `bashFirst:true, bypass:true` | Bash only | no | no | no | no / no |
| acceptEdits, `"1"` | none | Read/Write | yes | yes | yes | yes / yes |

Reading the table: the flag removes the steer and restores normal tool
selection; it does not forbid Bash, and any deliberate Bash edit still bypasses
the Edit|Write hooks and lazy instruction loading. Outside auto/bypass the
steer is never injected, whatever the flag says.
