When reviewing changes in this repository, explicitly check upgrade-path coverage in addition to fresh-install behavior.

If a pull request adds or changes a feature flag, setup prompt, generated file, profile default, hook, command, settings key, or any other user-visible setup behavior, review whether existing installs are upgraded correctly through `setup.sh --update` and `/update-kit`.

Look for cases where a new key is added for fresh installs but older saved config, manifests, or deployed files would silently miss the new behavior. Missing keys on older installs should receive the intended default for that profile, but explicit user choices that already exist must not be overwritten.

Also review whether user-facing documentation was updated in the same pull request when needed. Check for missing updates to:

- `CHANGELOG.md` for user-visible behavior changes, new defaults, upgrade behavior changes, or new commands
- `README.md` and `README.en.md` for setup flow, defaults, CLI flags, or prerequisites
- files under `docs/` when configuration mapping, feature behavior, or upgrade behavior changed

If these update-path or documentation concerns are missing, call them out as review findings instead of assuming they can be handled later.
