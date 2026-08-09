# rbw-auto

Backup and sync helpers for Bitwarden/Vaultwarden, built on top of
[rbw](https://github.com/pschmitt/rbw) (specifically
[pschmitt/rbw](https://github.com/pschmitt/rbw), a fork with multi-account
support, native vault-to-vault mirroring, and non-interactive
login/unlock/export/import/purge). `rbw` does the heavy lifting (auth,
export/import, attachments, org/collection management); these scripts are
thin wrappers adding backup rotation, healthchecks, and idempotent org/
collection creation on top.

The backup archive format changed from the old `bw`-CLI-based version of
this repo: it's now whatever `rbw export` produces (its own JSON, optionally
gpg-encrypted), not the old `bw export` + `bw list items` + attachments
tarball. There's no compatibility shim -- old archives from before this
rewrite must be restored with the old `bw`-CLI-based tooling.

Every account used here (for backup, or as sync source/destination) must
already be configured in `rbw`'s `config.json` (name/email/baseUrl) --
these scripts only ever supply the master password (and, once, a personal
API key for `rbw register`) at runtime. The NixOS module (see below)
renders `config.json` for you; for plain Docker usage, `entrypoint.sh`
renders it from env vars on every start.

For interactive Android/Termux use, install the
[pschmitt/rbw fork](https://github.com/pschmitt/rbw) rather than upstream
`rbw`. It includes native `termux-keystore` unlock
support; configure `accounts.<name>.unlock.termux` in rbw's
`config.json` after running the one-step `rbw termux enroll` flow. The
enrollment alias defaults to `rbw-<account>`; set `termux_key_alias` in
`config.json` or `RBW_TERMUX_KEY_ALIAS` to reuse a different Keystore key.
The container jobs documented here continue
to receive their password through their existing environment-file mechanism.

*Note on bitwarden.com*: the official server requires a one-time `rbw
register` (personal API key) per account before scripted login works (bot
detection). Both scripts run this automatically before login, but it's a
no-op unless you supply that account's `*_REGISTER_CLIENT_ID`/
`*_REGISTER_CLIENT_SECRET` env vars (see below) -- get the key from
[bitwarden.com](https://bitwarden.com/help/article/personal-api-key/).

## Backup

```shell
podman run -it --rm \
  -v /tmp/data:/data \
  -e ACCOUNT_EMAIL=me@example.com \
  -e BW_PASSWORD=xxxx \
  -e ENCRYPTION_PASSPHRASE=mySecret1234 \
  -e BW_BACKUP_RETENTION=30 \
  -e CRON="0 23 * * *" \
  ghcr.io/pschmitt/rbw-auto:latest
```

- `ACCOUNT` (optional, default: `backup`): the rbw account name.
- `ACCOUNT_EMAIL`: the account's email address (used to render `config.json`).
- `ACCOUNT_BASE_URL` (optional): the account's server URL, omit for the
  official bitwarden.com.
- `BW_PASSWORD`: the account's master password.
- `BW_TOTP_SECRET` (optional): the account's TOTP secret (base32, the same
  one an authenticator app would use), if it has TOTP-based 2FA enabled.
  A fresh code is generated per login/unlock via `oathtool`.
- `BW_BACKUP_REGISTER_CLIENT_ID`/`BW_BACKUP_REGISTER_CLIENT_SECRET`
  (optional): personal API key, used once to run `rbw register`
  non-interactively against bitwarden.com.
- `BW_BACKUP_ATTACHMENTS` (optional, default: `1`): set to `0` to skip
  downloading/embedding attachment contents (faster, smaller, but
  attachments won't be restorable from that backup).
- `ENCRYPTION_PASSPHRASE` (optional): if set, backups are gpg-encrypted
  (`rbw export --encrypt`) with this passphrase.
- `BW_BACKUP_RETENTION` (optional, default: `30`): how many backups to
  keep. Set to `0` to disable rotation. `KEEP` is deprecated; use this
  instead.
- `CRON` (optional): if set, runs the backup periodically on this schedule
  instead of once.
- `HEALTHCHECK_URL` (optional): pings Healthchecks.io (or a compatible
  endpoint) when the backup starts, completes successfully, or fails.
- `BW_BACKUP_DIR` (optional, default: `/data`): where backups are written.
  Mount your volume accordingly.

## Sync between two vaults

Run the container with the `sync` command to mirror one Bitwarden/
Vaultwarden account's vault into another (via `rbw mirror` -- entries and
attachments, no temp files):

```shell
podman run -it --rm \
  -e SRC_ACCOUNT_EMAIL=you@example.com \
  -e SRC_BW_PASSWORD=xxxx \
  -e DEST_ACCOUNT_EMAIL=you@vaultwarden.example \
  -e DEST_ACCOUNT_BASE_URL=https://vault.example.com \
  -e DEST_BW_PASSWORD=xxxx \
  ghcr.io/pschmitt/rbw-auto:latest sync
```

- `SRC_ACCOUNT`/`DEST_ACCOUNT` (optional, default: `source`/`destination`):
  the rbw account names.
- `SRC_ACCOUNT_EMAIL`/`DEST_ACCOUNT_EMAIL`, `SRC_ACCOUNT_BASE_URL`/
  `DEST_ACCOUNT_BASE_URL`: connection metadata for `config.json`.
- `SRC_BW_PASSWORD`/`DEST_BW_PASSWORD`: the two accounts' master passwords.
- `SRC_BW_TOTP_SECRET`/`DEST_BW_TOTP_SECRET` (optional): TOTP secrets for
  whichever account(s) have TOTP-based 2FA enabled, same as `BW_TOTP_SECRET`
  above.
- `SRC_REGISTER_CLIENT_ID`/`SRC_REGISTER_CLIENT_SECRET`,
  `DEST_REGISTER_CLIENT_ID`/`DEST_REGISTER_CLIENT_SECRET` (optional):
  personal API keys for `rbw register`, same as above.
- `BW_SYNC_MODE` (optional, default: `personal`):
  - `personal`: mirror the entire source vault into the destination
    account's personal vault, 1:1.
  - `collections`: mirror into one or more destination organization
    collections (see below). Each configured name is handled based on
    whether the source account has a same-named collection: if so, that
    destination collection gets a scoped 1:1 mirror of just that source
    collection; if not, it gets a full mirror of the entire source vault
    instead (e.g. useful for a "whole vault" collection with no
    source-side counterpart).
- `DEST_BW_PURGE_VAULT` (optional, `personal` mode only): if set to `1`,
  wipes the destination's personal vault before importing (server-side
  purge, same as `rbw purge-vault`). Entries in an org collection are
  never touched by this.
- `DEST_BW_ORG`/`DEST_BW_COLLECTIONS` (required in `collections` mode):
  the destination organization name and a comma-separated list of
  collection names to mirror into, e.g.
  `DEST_BW_COLLECTIONS="default,Some Other Collection"`. The org and any
  missing collections are created automatically. The source account is
  only ever read, never modified.
- `BW_SYNC_ATTACHMENTS` (optional, default: `1`): set to `0` to skip
  attachments.
- `BW_SYNC_OVERWRITE` (optional, default: `1`): set to `0` to leave
  existing destination entries untouched instead of overwriting them.
- `HEALTHCHECK_URL` works here too; sync pings start/fail/success.

## NixOS module

`flake.nix` exports `nixosModules.default`, providing
`services.rbw-auto-backup` and `services.rbw-auto-sync`. Both are
collections of independent, named jobs -- `services.rbw-auto-backup.backups.<name>`
and `services.rbw-auto-sync.syncs.<name>` -- the same way
`services.restic.backups.<name>` works: each named job gets its own systemd
service+timer (`rbw-auto-backup-<name>`/`rbw-auto-sync-<name>`), own
schedule, own accounts, own Monit check, and can be enabled/disabled
independently. Jobs of the same kind (all backups, or all syncs) share one
system user/group and one declaratively-rendered `rbw` `config.json`
listing every account any of that kind's jobs use (rbw's own multi-account
support already keys everything off `--account`, so there's no need for
separate Unix users per job). The same `rbw register` automation described
above runs per-job from that job's own `environmentFiles`-supplied env
vars. Every job's systemd unit also force-terminates `rbw-agent` for its
account(s) on exit (`ExecStopPost`, regardless of success/failure) -- a
oneshot job has no business leaving a background agent running, and a
lingering one causes `systemd` to log a "left-over process in control
group" warning on the job's next run.

```nix
services.rbw-auto-backup.backups.personal = {
  account = {
    name = "personal";
    email = "me@example.com";
  };
  environmentFiles = [ config.sops.secrets."rbw-auto-backup-personal".path ];
};

services.rbw-auto-sync.syncs.personal = {
  sourceAccount = {
    name = "personal";
    email = "me@example.com";
  };
  destAccount = {
    name = "vaultwarden";
    email = "me@example.com";
    baseUrl = "https://vault.example.com";
  };
  purgeDestination = true;
  environmentFiles = [ config.sops.secrets."rbw-auto-sync-personal".path ];
};

services.rbw-auto-sync.syncs.org-collections = {
  sourceAccount = {
    name = "personal";
    email = "me@example.com";
  };
  destAccount = {
    name = "vaultwarden";
    email = "me@example.com";
    baseUrl = "https://vault.example.com";
  };
  mode = "collections";
  collections = {
    org = "Example-Org";
    names = [ "Shared" ];
  };
  environmentFiles = [ config.sops.secrets."rbw-auto-sync-org-collections".path ];
};
```

See `nix/module.nix` for the full option list.

## How do I decrypt my backup?

Use the `rbw` fork from [pschmitt/rbw](https://github.com/pschmitt/rbw) for
inspection and conversion. It understands the archive format produced by
`rbw-auto` directly, so there is normally no need to manually invoke `gpg`
or unpack the tarball. Set the same passphrase used by `ENCRYPTION_PASSPHRASE`
in `RBW_EXPORT_PASSPHRASE`:

```shell
export RBW_EXPORT_PASSPHRASE='mySecret1234'

rbw list --from-file data/bw-export-xxx.tar.gz.gpg
rbw get --from-file data/bw-export-xxx.tar.gz.gpg github
rbw show --from-file data/bw-export-xxx.tar.gz.gpg github
```

For an interactive browser, use the TUI. Add `--write` to edit the exported
file; write operations create a `.bak` next to it before changing anything:

```shell
rbw tui --from-file data/bw-export-xxx.tar.gz.gpg
rbw tui --from-file data/bw-export-xxx.tar.gz.gpg --write
```

The other file-backed commands include `list`, `search`, `code`, `history`,
`add`, `edit`, `set`, `remove`/`delete`, `archive`, `unarchive`, `restore`,
and `attachment list/get/create/rm`. For example:

```shell
rbw attachment list --from-file data/bw-export-xxx.tar.gz.gpg github
rbw export --from-file data/bw-export-xxx.tar.gz.gpg \
  --format bitwarden-json --output vault.json
rbw export --from-file data/bw-export-xxx.tar.gz.gpg \
  --format bitwarden-csv --output vault.csv
```

If putting the passphrase in the environment is not suitable, every
`--from-file` command accepts `--passphrase PASSPHRASE`; this may be exposed
through `ps` and shell history. The older
`--from-file-passphrase PASSPHRASE` spelling remains an alias. `--attachments`
must have been used when the backup was created if attachment contents should
be available to the TUI, attachment commands, or zip conversion. The legacy
[decrypt.sh](decrypt.sh) wrapper remains available, but the native `rbw`
commands preserve the export format and support direct querying/conversion.
