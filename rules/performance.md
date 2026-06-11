# Performance

- Avoid repeated heavy work in hooks and startup paths.
- Cache or gate network/process-heavy checks when correctness allows.
- Measure or bound long-running commands with timeouts.
- Prefer lazy, on-demand context over always-loaded reference material.
