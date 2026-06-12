---
description: Audit your personal Claude Code config for outdated, model-babysitting, or redundant instructions.
argument-hint: [global|project|all]
---

# /audit-config — Personal Config Audit

Audit user-owned configuration for instructions that no longer help (or
actively hurt) current-generation models. Kit-managed files are NOT in
scope — the kit audits its own content upstream.

## Scope

- `global` (default): the user section of `~/.claude/CLAUDE.md` (content
  outside the STARTER-KIT-MANAGED markers) and user-owned rule files
  (`~/.claude/rules/user-*.md` and any rules file not shipped by the kit)
- `project`: the current project's `CLAUDE.md` / `.claude/` config
- `all`: both

## Audit Lenses

Classify each instruction (line or section) into:

1. **babysitting** — countermeasures for old-model failure modes that no
   longer occur (e.g. tool-call format reminders, "fix errors immediately",
   forced step-by-step rituals)
2. **over-prescription** — rigid procedures that override the model's own
   judgment where it is now reliable (blanket TDD/coverage mandates,
   fixed command pipelines, arbitrary numeric gates)
3. **stale-premise** — references to old models, retired features, or
   superseded mechanics (thinking keywords, old model names, obsolete
   context-management lore)
4. **context-tax** — always-loaded lines duplicating what the harness or
   settings already enforce (language settings, parallel tool calls,
   risk reporting). Verify the duplication against the actual settings
   file or documented harness behavior before claiming it — cite what
   you checked.

## Preservation Rules (do not over-delete)

- **Genuine personal preferences stay.** Anything the model could not
  infer on its own — naming/secrecy rules, confirmation gates, response
  formats, workflow phrases — is the user's voice, not babysitting.
- When unsure whether something is preference or babysitting, keep it
  and say why you were unsure.
- Only mark `context-tax` removals when you actually verified the
  duplication (e.g. read `settings.json`, confirmed the harness ships
  the behavior). No speculation-based deletions.

## Output (proposal only — never edit without approval)

Produce a table: `target | verdict (keep/remove/rewrite/merge) | reason`,
followed by the full proposed replacement text for every rewrite/merge.
End with a summary of what gets shorter and what is preserved. Apply
changes only after the user approves them.
