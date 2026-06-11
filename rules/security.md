# Security

- Never expose secrets, tokens, credentials, or private working directories in output.
- Validate URLs and block private/internal network access unless explicitly allowed.
- Avoid executing untrusted scripts or installing global tools without approval.
- Check auth, file, and command boundaries before making destructive changes.
- Prefer least privilege for permissions, hooks, and generated configs.
