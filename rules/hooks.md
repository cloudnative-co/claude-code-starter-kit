# Hooks

- Treat hook stdout/stderr as user-visible control surfaces; keep output concise.
- Prefer external hook scripts over inline JSON shell when logic is nontrivial.
- Filter by matcher first, then validate real tool input schema inside the script.
- Use SessionStart only for startup/resume needs and SessionEnd for audits.
