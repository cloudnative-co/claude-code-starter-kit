# /spec-kit-init - Bootstrap GitHub Spec Kit in the current project

Initialize GitHub Spec Kit (Spec-Driven Development workflow) inside the
current project so that the `/speckit-constitution`, `/speckit-specify`,
`/speckit-clarify`, `/speckit-plan`, `/speckit-tasks`, and `/speckit-implement`
skills become available alongside the StarterKit's own commands.

This command is a thin guide layer — it does NOT install `specify-cli`
itself. You install `specify-cli` once per machine via `uv` (or `pipx`),
and this command shows you the canonical invocation for the current
project. The StarterKit deliberately stays decoupled from Spec Kit's release
cycle; `uv tool upgrade specify-cli` is how you keep Spec Kit current.

## Instructions

You are entering **Spec Kit Initialization**. Walk the user through the
5 steps below in order. Do not execute heavy operations without
confirmation; the user is in control.

### Step 1 — Verify prerequisites

Run these checks and report their results to the user as a small table:

- `uv --version` (required; install hint if missing: `curl -LsSf https://astral.sh/uv/install.sh | sh`)
- `python3 --version` (≥ 3.10 required by `specify-cli`)
- `git --version` (required)
- `claude --version` (Claude Code itself; should already be installed if you're reading this)

If any of the first three are missing, STOP and ask the user how they want
to proceed (install via Homebrew? via official installer? skip?). Do not
run installers without explicit consent.

### Step 2 — Install or update specify-cli (user-scope)

If `specify --version` does not return a version, run:

```bash
LATEST_TAG=$(gh api repos/github/spec-kit/releases/latest --jq .tag_name)
uv tool install specify-cli --from "git+https://github.com/github/spec-kit.git@${LATEST_TAG}"
```

If `specify` is already installed, offer to upgrade:

```bash
uv tool upgrade specify-cli
```

Confirm with `specify --version` and `specify check | grep -i claude`
(the latter must show `Claude Code (available)`).

### Step 3 — Initialize Spec Kit in the current project

From the project root (NOT inside `~/.claude/`):

```bash
specify init . --integration claude --script sh
# or, if the directory is non-empty:
specify init --here --integration claude --script sh --force
```

If the user wants Spec Kit's feature-branch automation, run
`specify extension add git` after init (the git extension is opt-in
since v0.10.0).

After init, the project will have:

- `.claude/skills/speckit-*` — 14 SKILL.md files (project-local, namespaced)
- `.specify/` — spec-kit metadata (templates, scripts, memory/constitution.md)
- `CLAUDE.md` — a minimal `<!-- SPECKIT START --> ... <!-- SPECKIT END -->` block pointing to the active plan

If the project already has a StarterKit-managed `CLAUDE.md`, Spec Kit's
`<!-- SPECKIT START -->` block coexists with StarterKit's
`<!-- BEGIN STARTER-KIT-MANAGED -->` block — the marker names are
different and do not interfere with each other.

### Step 4 — Set the SDD ground rules for the project

Brief the user on the StarterKit ↔ Spec Kit responsibility split before
they start writing a constitution:

1. **User-level global rules (`~/.claude/CLAUDE.md` and `~/.claude/rules/`)**
   hold organization-wide and personal context (e.g., "ゼロトラスト前提",
   "TS strict default", "Okta SSO 標準"). They apply to every project.
2. **`<project>/.specify/memory/constitution.md`** holds project-specific
   principles, SLAs, and compliance requirements (e.g., "this Lambda's
   audit log retention ≥ 397 days", "this project's test branch coverage ≥ 80%").
   It applies only inside that project, and **overrides** the user-level
   global rules when the two conflict.
3. Each PR description MUST contain a line:
   `Constitution Check: Compliant` (or `Deviations: ...` with justification).
4. Constitution amendments require an explicit Sync Impact Report at the
   top of the file and approval from the project owner.

### Step 5 — Hand off to the Spec Kit workflow

Recommend the user start with `/speckit-constitution`, then `/speckit-specify`,
then `/speckit-clarify` (optional but recommended), then `/speckit-plan`,
then `/speckit-tasks`. Do NOT run `/speckit-implement` without the user's
explicit go-ahead — it executes the entire task list and can be expensive.

## Notes & gotchas

- Spec Kit's command separator is **hyphen, not dot**: `/speckit-plan`, NOT `/speckit.plan`. The dot form was retired before v0.8.0.
- Since Spec Kit v0.10.0 (2026-06), the git extension is opt-in and the `--no-git` flag has been removed; `specify init` does not create a git branch by default. Run `specify extension add git` after init if you want Spec Kit's branch automation.
- `specify init` writes only into `<project>/`. It does NOT touch `~/.claude/` (verified during the StarterKit evaluation in `docs/spec-kit-evaluation.md`).
- Spec Kit's bash scripts (`.specify/scripts/bash/*.sh`) do NOT use `rm -rf`, `curl`, `wget`, `sudo`, or `git push --force`. They are compatible with the StarterKit's deny rules.
- Long-term maintenance of `specify-cli` is delegated to `uv tool upgrade`; the StarterKit does not bundle or pin a Spec Kit version.

## When NOT to use this command

- The project already has its own SDD or RFC process and you don't want
  parallel artifacts. Spec Kit imposes a non-trivial directory structure
  (`.specify/`, `specs/<NNN>-feature/`).
- The work is a one-off script or sandbox — Spec Kit's overhead exceeds
  the project's size.
- You only need a single design doc, not a five-stage pipeline. In that
  case, `/plan` (from the StarterKit) is lighter.
