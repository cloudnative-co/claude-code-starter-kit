# Orchestrate Command

Plan, implement, and verify in the main thread; spawn independent review
agents after implementation. Prefer parallel reviews over sequential
agent relays.

## Usage

`/orchestrate [workflow-type] [task-description]`

## Default Execution Model

1. **Plan and implement in the main thread.** Keep full context; do not
   split planning/implementation across agents unless the task genuinely
   needs isolated exploration.
2. **After implementation, spawn independent reviewers in parallel:**
   - `code-reviewer` — always, before merge
   - `security-reviewer` — when the change touches auth, payments, PII,
     secrets, networking, or file/command boundaries
   - `architect` — when the change alters system boundaries or major design
3. **Reconcile findings yourself**, fix what is real, and report.

## Review Focus by Task Type

These are review-lens suggestions, not required agent chains:

- **feature** — correctness against requirements, tests for new behavior, security surface
- **bugfix** — root cause addressed (not symptom), regression test added
- **refactor** — behavior preserved, test coverage before/after, no scope creep
- **security** — input validation, authz/authn, secrets handling, injection surfaces

## Output Requirements

Report at the end (no fixed template — cover these points):

- Files changed
- Test results (commands run and outcomes)
- Review findings and how each was resolved
- Verdict: SHIP / NEEDS WORK / BLOCKED

## Custom Sequences

`/orchestrate custom "<agents>" "<description>"` runs an explicit agent
sequence when you really need one. Sub-agents do not share context: when
chaining, pass the next agent a one-paragraph summary of what was done,
key decisions, and open questions — no fixed handoff template.

## Tips

1. **Always include code-reviewer** before merge
2. **Use security-reviewer** for auth/payment/PII surfaces
3. Prefer parallel reviews over sequential chains — faster and no
   information loss between agents
