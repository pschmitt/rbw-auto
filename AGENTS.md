# Agent notes

`rbw-auto` provides container scripts and NixOS modules for backing up and
syncing Bitwarden-compatible vaults through `rbw`.

- Keep backup and sync behavior aligned with `README.md`, including retention,
  encryption, attachments, and destination purge semantics.
- Never use a real vault or real credentials for tests. Use isolated test
  accounts and keep credentials out of examples and logs.
- CI runs ShellCheck and Python linting; the Python lint action comes from
  [ci-workflows](https://github.com/pschmitt/ci-workflows).
- Before changing CI, check for a reusable workflow or action there and
  preserve the caller's existing behavior and check coverage.
- A push to `main` publishes the container image. Do not change image
  publication settings without an explicit request.
