# Setup walkthrough

End-to-end for one profile. Placeholders: `<profile>`, `$PROFILE_HOME`
(`~/.hermes/profiles/<profile>`), `<vault.kdbx>`, `kpxc-agent-vault` (Keychain item
name). Nothing here needs the secret values to pass through the agent's context.

## 0. Preflight

```sh
keepassxc-cli --version                 # 2.7.x assumed; 2.7.6 verified
ls <vault.kdbx>                         # readable by this user
pgrep -l KeePassXC                      # if running, plan to reload the DB later
```

## 1. Keychain item (human, interactive)

```sh
security add-generic-password -s kpxc-agent-vault -a "$USER" -w
security find-generic-password -s kpxc-agent-vault -a "$USER" -w >/dev/null && echo OK
```

Never pass the master password on the command line; `-w` with no value prompts.

## 2. Group and entries

```sh
KC="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
DBPW=$(security find-generic-password -s kpxc-agent-vault -a "$USER" -w)

printf '%s\n' "$DBPW" | "$KC" mkdir -q "<vault.kdbx>" hermes        # group at the root

# reference entry: no secret stored here
printf '%s\n' "$DBPW" | "$KC" add -q --url "ref:Infrastructure/gateway" \
  "<vault.kdbx>" hermes/FOO_API_KEY

# literal entry: value typed by the human, or piped from an existing .env
printf '%s\n%s\n' "$DBPW" "<the secret>" | "$KC" add -q -p "<vault.kdbx>" hermes/BAR_TOKEN
```

Verify structure without revealing values:

```sh
printf '%s\n' "$DBPW" | "$KC" ls -q -R "<vault.kdbx>" | grep -A5 '^hermes/'
```

## 3. Scripts and config

```sh
mkdir -p ~/.local/share/kpxc-secrets ~/.config
cp scripts/*.sh ~/.local/share/kpxc-secrets/ && chmod 700 ~/.local/share/kpxc-secrets/*.sh
printf '%s\n' \
  'KPXC_DB="<vault.kdbx>"' \
  'KPXC_KEYCHAIN_SERVICE="kpxc-agent-vault"' \
  'KPXC_GROUP="hermes"' > ~/.config/kpxc-<profile>.conf
chmod 600 ~/.config/kpxc-<profile>.conf
```

## 4. Profile config (CLI only)

```sh
hermes -p <profile> config set secrets.command.enabled true
hermes -p <profile> config set secrets.command.command \
  'KPXC_CONF=/Users/me/.config/kpxc-<profile>.conf /Users/me/.local/share/kpxc-secrets/kpxc-secrets.sh'
hermes -p <profile> config set secrets.command.helper_timeout_seconds 15
hermes -p <profile> config set secrets.command.override_existing false
```

Expect a "helper command failed" line after the first `config set` if the helper is
not yet runnable. That is the orchestrator reporting honestly, not a broken write.

## 5. Back up, then move values out of `.env`

```sh
TS=$(date +%Y%m%dT%H%M%S)
mkdir -p "$PROFILE_HOME/backups"
cp -p "$PROFILE_HOME/.env" "$PROFILE_HOME/backups/env-pre-vault-$TS"
chmod 600 "$PROFILE_HOME/backups/env-pre-vault-$TS"

# fingerprint BEFORE (safe to print)
for k in FOO_API_KEY BAR_TOKEN; do
  v=$(grep -m1 "^$k=" "$PROFILE_HOME/.env" | cut -d= -f2-)
  printf '%-20s len=%d sha=%s\n' "$k" "${#v}" "$(printf '%s' "$v" | shasum -a 256 | cut -c1-16)"
done
```

Add the values to the vault (loop in the main SKILL.md, step 6), then re-run the same
fingerprint loop against the helper's output and compare. Equal length **and** equal
sha256 prefix is the proof; "looks right" is not.

Only then replace `.env` with a comment header pointing at the vault.

## 6. Verify and canary

```sh
KPXC_EXPECTED="FOO_API_KEY BAR_TOKEN" scripts/kpxc-secrets-check.sh --deep
hermes -p <profile> config path        # "Command helper: applied 2 secrets"
hermes -p <profile>                    # new session; one model call
```

## 7. Housekeeping

- Reload the database in KeePassXC after any CLI write; a GUI save from stale state
  reverts it.
- Keep `backups/env-pre-vault-*` until the profile has run successfully for a while.
- If the vault file lives on a synced drive, `helper_timeout_seconds` of 15 is a
  reasonable floor; measure the helper (`time scripts/kpxc-secrets.sh`).
