---
name: keepassxc-secret-source
description: Use when agent secrets should come from a KeePassXC vault.
version: 1.0.0
author: gwyntel
license: MutuaL-1.2
compatibility: macOS or Linux with keepassxc-cli 2.7+, a Keychain/keyring CLI for non-interactive unlock, and Hermes Agent (secrets.command source).
metadata:
  hermes:
    tags: [secrets, keepassxc, hermes, profiles, keychain, vault]
    related_skills: [hermes-agent, skill-authoring]
---

# KeePassXC as a Hermes Secret Source

Wires an agent profile to pull its credentials from a KeePassXC database at
process startup, through Hermes' `secrets.command` helper source. Secrets live in
the vault; `.env` holds no credential values; the agent hydrates keys it is
explicitly allowed to see.

Delivered as three scripts (`scripts/kpxc-secrets.sh`, `scripts/kpxc-secrets-check.sh`,
`scripts/kpxc-rollback.sh`) plus a fixed procedure. Install the repo, not just
SKILL.md — see [Install](#install).

## When to use

- A profile's API keys, tokens or service credentials should rotate in a password
  manager instead of being pasted into `.env`.
- One shared human vault (multiple people, hundreds of entries) must expose only a
  chosen few entries to an automated agent.
- You need a rollback path for "the vault was unreachable at startup and the agent
  had no key".
- Not for: a single throwaway key that never changes. Write it to `.env` and stop.

## How the source behaves (read before designing anything)

Verified against `agent/secret_sources/{command,registry,base}.py`:

- The helper runs via `/bin/sh -c` at process startup with **stdin closed**
  (`DEVNULL`) and its **stderr captured and discarded**. Debug by running it
  yourself; Hermes will never show you the reason it failed.
- Output must be `KEY=VALUE` lines; values are unquoted one layer. Output over
  1 MiB, or a non-dotenv shape, means **no values applied** — a warning, not a crash.
- `helper_timeout_seconds` defaults to **3 s** and is deliberately tight. A vault on
  a synced or network filesystem needs more (see pitfalls).
- `override_existing: false` (default, and the right choice for a local vault) means
  **`.env` wins**; the vault only fills gaps. That makes a vault outage survivable
  only if `.env` still holds something — or if you keep a rollback backup.
- Precedence ladder and provenance come from `registry.apply_all()`; each applied var
  is labelled `command` in `report.provenance`. That label is your test assertion.

Depth: `references/hermes-command-source-contract.md`.

## Entry model — expose by reference, not by copy

Create a group (default name `hermes`) whose entries are the *only* thing the agent
can see. Each entry's **Title is the env var name**; its value comes from one of two
places:

| Mode | Entry shape | Use when |
|---|---|---|
| Literal | Password field holds the secret | the value exists nowhere else in the vault |
| Reference | Password empty, **URL** = `ref:<path>[#<Field>]` | the credential already lives in a real entry |

A reference resolves against the whole database, so the vault keeps one source of
truth and rotation needs no second edit:

```
Title: PLEXUS_API_KEY        Password: (blank)      URL: ref:Infrastructure/gateway
Title: GH_TOKEN              Password: (blank)      URL: ref:Work/github.com#Password
Title: SMTP_USER             Password: (blank)      URL: ref:Mail/smtp#Username
```

`<Field>` defaults to `Password`; any CSV column works (`Username`, `Notes`, `URL`),
case-insensitively. Relative paths are resolved from the database root group, so a
user never needs to know the root group's name.

**Group scoping rule (the one that bites).** `keepassxc-cli export -f csv` reports
`Group` as the *full* path including the database's root group (`Vault/hermes`).
Drop segment 0 and require the configured name to be a **prefix** of the rest:
`Vault/hermes` and `Vault/hermes/<sub>` match, `Unrelated/hermes` does not. Matching
the name "anywhere in the path" silently makes unrelated groups injectable.

Depth: `references/entry-model.md`.

## Setup

1. **Store the master password non-interactively.** `keepassxc-cli` 2.7.x has no
   `--pw-stdin`, but it *does* read the password from stdin when stdin is not a TTY.
   Put the master password in the OS keychain/keyring once, interactively:

   ```sh
   # macOS — prompts twice, nothing echoed
   security add-generic-password -s kpxc-agent-vault -a "$USER" -w
   ```

   The helper reads it back with `security find-generic-password`; on Linux swap in
   `secret-tool lookup service <name>`.

2. **Create the group** in the vault (GUI or CLI) and add the chosen entries as
   literal or reference entries.

3. **Copy `scripts/` somewhere stable for the profile** and give it a config file
   (`~/.config/kpxc-<profile>.conf`, mode 600):

   ```sh
   KPXC_DB="/path/to/vault.kdbx"
   KPXC_KEYCHAIN_SERVICE="kpxc-agent-vault"
   KPXC_GROUP="hermes"
   ```

4. **Point the profile at it** (CLI only — never hand-edit a live `config.yaml`):

   ```sh
   hermes -p <profile> config set secrets.command.enabled true
   hermes -p <profile> config set secrets.command.command \
     'KPXC_CONF=/Users/me/.config/kpxc-claude.conf /Users/me/.local/share/kpxc-secrets/kpxc-secrets.sh'
   hermes -p <profile> config set secrets.command.helper_timeout_seconds 15
   hermes -p <profile> config set secrets.command.override_existing false
   ```

   `secrets.command.command` is run by `/bin/sh -c`, so an inline env assignment is
   legal — but prefer the `KPXC_CONF` form: the check and rollback scripts invoke the
   helper themselves and would not inherit variables baked into Hermes' command
   string. One conf file keeps all three runnable the same way.

5. **Back up `.env` before deleting anything** from it:

   ```sh
   cp -p "$PROFILE_HOME/.env" "$PROFILE_HOME/backups/env-pre-vault-$(date +%Y%m%dT%H%M%S)"
   ```

6. **Move the values.** Never print a secret to move it — pipe it from `.env` into
   `keepassxc-cli add -p`, then prove the transfer by comparing hashes, not by
   eyeballing. Redaction filters may mask the value in an agent's own transcript, so
   the agent must not be the transport for a value it can only see masked.

   ```sh
   KC="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
   DBPW=$(security find-generic-password -s kpxc-agent-vault -a "$USER" -w)
   while IFS= read -r line; do
     case "$line" in ''|'#'*) continue ;; esac
     name=${line%%=*}; value=${line#*=}
     printf '%s\n%s\n' "$DBPW" "$value" | "$KC" add -q -p "$KPXC_DB" "hermes/$name"
   done < "$PROFILE_HOME/.env"
   # then compare fingerprints, never values:
   #   printf '%s' "$v" | shasum -a 256 | cut -c1-16
   ```

Full walkthrough with the guard checks: `references/setup-walkthrough.md`.

## Verify (three levels, cheapest first)

```sh
# 1. helper alone — names, lengths, hashes only
KPXC_EXPECTED="FOO_API_KEY BAR_TOKEN" scripts/kpxc-secrets-check.sh

# 2. helper + real fetch pipeline, with the expected vars stripped from the env
KPXC_EXPECTED="FOO_API_KEY BAR_TOKEN" HERMES_PROFILE_HOME="$PROFILE_HOME" \
  scripts/kpxc-secrets-check.sh --deep

# 3. the actual startup path — cheapest real proof
hermes -p <profile> config path        # expect: "Command helper: applied N secrets"
```

Level 2 must assert, not report: a check that prints `NOT SUPPLIED` and still exits 0
is not a test. The script exits non-zero unless every expected var arrives with
`provenance.source == "command"` and a non-empty value.

Then the canary: start a new session for the profile and make one model call. A
successful completion proves the provider key hydrated; nothing already running will
pick the change up.

## Roll back

```sh
# restore .env from the newest backup — safe, can only put values back
KPXC_PROFILE_HOME="$PROFILE_HOME" scripts/kpxc-rollback.sh

# ...and remove the vault entries + disable the source (refuses while the GUI is open)
KPXC_PROFILE_HOME="$PROFILE_HOME" KPXC_ENTRIES="FOO_API_KEY BAR_TOKEN" \
  KPXC_DB="$KPXC_DB" KPXC_KEYCHAIN_SERVICE=kpxc-agent-vault \
  scripts/kpxc-rollback.sh --purge
```

Restore is atomic (temp file → `mv`), re-`chmod 600`, and prints restored key names
only. `--purge` verifies each deletion by reading the entry back, verifies the config
write by parsing `config.yaml`, and exits non-zero with `rollback INCOMPLETE` rather
than claiming a rollback it did not finish.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Helper exits 1, no details | stderr is discarded by design | run the helper by hand |
| `helper output was not a KEY=VALUE map` | group empty, or only comments emitted | add entries; assert with `KPXC_EXPECTED` |
| Timeout on a synced vault | 3 s default + network/streamed read + KDF | raise `helper_timeout_seconds` to 10–20 |
| Vault edits vanish | KeePassXC GUI held stale in-memory state and saved | reload the DB in the GUI after CLI writes; `--purge` refuses without `--force` |
| Wrong entries injected | group matched "anywhere in the path" | prefix match after dropping the root segment |
| Ambiguous reference skipped | duplicate titles in different groups | qualify the path in `ref:` |
| Value written to `.env` is masked | redaction is on while the agent handles the value | pipe it, or have the human write it |

Depth: `references/pitfalls-and-recovery.md`.

## Install

This repo ships scripts and references, so installing SKILL.md alone is incomplete.

```sh
npx skills add gwyntel/keepassxc-secret-source-skill --skill keepassxc-secret-source
# or vendor the whole tree
git clone https://github.com/gwyntel/keepassxc-secret-source-skill
```

Hermes: clone or copy `scripts/` next to the skill and keep the paths in step 3
relative to the installed skill directory.

## License

Mutualist License v1.2 (`MutuaL-1.2`). See `LICENSE.md`. Sources and access dates:
`references/sources.md`.
