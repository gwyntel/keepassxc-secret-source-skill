# Pitfalls and recovery

Each entry is a failure observed in practice, not a hypothetical.

## Silent failure modes

**Helper exits 1 with no output.** Hermes pipes stderr to /dev/null on purpose. There
is no diagnostic in the agent's log beyond "helper command failed". Always run the
helper by hand first; the three common causes are: Keychain item missing, database
file unreadable (sync client not finished / offline), master password wrong.

**`helper output was not a KEY=VALUE map`.** The helper ran and exited 0 but emitted
nothing usable: empty group, entries skipped as ambiguous, or values that span lines.
Assert with `KPXC_EXPECTED` so a check fails loudly instead of inheriting this warning.

**Values not applied though the helper prints them.** Precedence, not a bug: with
`override_existing: false` an existing `.env` value wins. Confirm with the deep check,
which reports `overrode .env=False` and the source that won.

## Timeouts

The 3 s default assumes an already-unlocked local file. Add a synced or streamed
database (`~/Library/CloudStorage/...`, a network mount) plus the KDF and 3 s is
routinely exceeded — the whole process group is killed and every var is lost. Raise
`helper_timeout_seconds` (15 is a sane floor) and measure:

```sh
time scripts/kpxc-secrets.sh >/dev/null
```

One `export` per run, never one CLI call per entry.

## Vault writes lost

`keepassxc-cli` writes the file directly. KeePassXC's GUI holds its own in-memory copy;
if it saves afterwards it overwrites your group or entries. After any CLI write:

- In the GUI, accept "reload from disk" rather than saving.
- Before a destructive CLI operation (`rm`, `--purge`), close the database in the GUI.
  The rollback script refuses to purge while KeePassXC is running unless `--force`,
  precisely because this failure looks like the cleanup silently didn't happen.

## Redaction hides the value from the agent

With secrets redaction enabled, an agent reading `.env` sees `***`, and if it then
"writes" a value it writes the mask. Never let an agent be the transport for a value
it can only see masked: pipe from file to vault in one shell pipeline, or have the
human type it. Verify with hashes.

## Ambiguous or dangling references

A reference resolves by root-relative path, then by unique trailing components. Two
entries with the same title in different groups make the trailing match ambiguous and
the var is skipped with a note. Qualify the path (`Work/github.com` vs `Personal/github.com`).
A dangling reference is skipped too — the failure is a missing env var at runtime, not
an error at startup.

## Group scoping

The CSV `Group` column includes the database's root group. Filtering by "name appears
somewhere in the path" makes an unrelated group injectable the moment someone creates
one with the same name. Drop the root segment and prefix-match. Verify with a decoy
group in a throwaway database rather than trusting the reasoning.

## `.env` emptied too early

Emptying `.env` before the vault path is proven means a vault outage leaves the agent
with no provider key at startup — and startup is not blocked, so the agent runs and
fails at the first API call. Order of operations: backup → move → verify deep → then
empty. Keep the backup until the profile has run green for a while.

## Recovery checklist

1. `KPXC_EXPECTED=... scripts/kpxc-secrets-check.sh` — is the helper healthy?
2. If yes and the profile still lacks keys: check `.env` precedence and `enabled`.
3. If no: `security find-generic-password -s <svc> -a "$USER" -w >/dev/null && echo ok`,
   then `keepassxc-cli ls -q "<vault.kdbx>"` by hand.
4. Nuclear: `KPXC_PROFILE_HOME=... scripts/kpxc-rollback.sh` restores `.env` from the
   pre-vault backup in seconds; the vault can be re-populated later.

## Unrelated noise in a `--deep` run

The deep check imports `agent.secret_sources.registry`, which tries to register the
bundled Bitwarden and 1Password sources. In a partially-installed environment those can
print `Failed to register bundled ... ModuleNotFoundError: No module named 'ruamel'` (or
similar) to stderr. That is the registry reporting an unavailable *other* source; it
does not affect `command`. Judge the run by the `RESULT:` line and the exit status.
