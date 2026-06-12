# Update Documentation

Sync documentation from real sources of truth:

1. Detect the project's task definition source (package.json scripts,
   Makefile, pyproject.toml, etc.)
   - Generate a scripts/tasks reference table
   - Include descriptions from comments

2. Read .env.example (if present)
   - Extract all environment variables
   - Document purpose and format

3. Generate docs/CONTRIB.md with:
   - Development workflow
   - Available scripts
   - Environment setup
   - Testing procedures

4. Update docs/RUNBOOK.md **only when real operational sources exist**
   (CI workflow definitions, Dockerfile/compose, IaC, deploy scripts, or
   an existing docs/RUNBOOK.md). Derive content from those sources only.
   Omit any section (Deployment / Monitoring / Rollback / ...) that has
   no source — never invent procedures. List the missing sections in the
   report instead.

5. Identify obsolete documentation:
   - Find docs that look stale (e.g. not modified in ~90 days)
   - List for manual review

6. Show diff summary

Sources of truth: task definitions and .env.example for scripts/env;
CI / IaC / deploy configs for operational procedures.
