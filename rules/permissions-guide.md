# Permissions Best Practice

## Principle: Wildcard Allow, Explicit Deny

Use wildcard syntax for common safe operations instead of dangerously-skip-permissions:
- `Bash(npm run *)` -- all npm scripts
- `Edit(/src/**)` -- all source files
- `Read(**)` -- read anything

## Deny Dangerous Operations

Always explicitly deny:
- `Bash(rm -rf /)` -- recursive root delete
- `Bash(git push --force *)` -- force push
- `Edit(/.env*)` -- environment files with secrets

## Sandbox Mode

For additional isolation, use `/sandbox` command to enable file and network sandboxing.
This reduces permission prompts while maintaining security boundaries.

## Never Use dangerously-skip-permissions

This flag disables ALL safety checks. Instead:
1. Start with restrictive permissions
2. Add wildcard allows for operations you trust
3. Use deny rules for operations that should never run
