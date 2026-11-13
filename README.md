# keepassxc-secret-source

A Hermes Agent skill that makes a KeePassXC database the source of truth for a
profile's credentials — plus the scripts, the verification, and the rollback path.

Secrets stay in the vault. The profile's `.env` ends up holding no values. At process
startup Hermes runs a helper that unlocks the database from the OS keychain, exports
one group as `KEY=VALUE`, and hydrates only the entries you deliberately exposed.

## What you get

- `SKILL.md` — the procedure, the entry model, and the pitfalls that cost real time
- `scripts/kpxc-secrets.sh` — the helper Hermes calls (`secrets.command`)
- `scripts/kpxc-secrets-check.sh` — verification that asserts, and exits non-zero when the pipeline does not actually hydrate a key
- `scripts/kpxc-rollback.sh` — restore `.env` from the pre-vault backup; optional verified purge
- `references/` — the source contract, entry/reference semantics, a full walkthrough, pitfalls, and sources

## Prerequisites

- `keepassxc-cli` 2.7+ (2.7.6 verified) and a `.kdbx` file readable by the user
- A keychain/keyring CLI for non-interactive unlock: macOS `security`, or Linux `secret-tool`
- Python 3 (stdlib only for the helper; `pyyaml` for the deep check and the config verification)
- Hermes Agent with the `secrets.command` source (any recent release)

## Install

```sh
# Agent Skills CLI
npx skills add gwyntel/keepassxc-secret-source-skill --skill keepassxc-secret-source

# or vendor the tree (scripts and references included)
git clone https://github.com/gwyntel/keepassxc-secret-source-skill
```

SKILL.md alone is not enough — the scripts and references are part of the skill.

## Quick start

```sh
# 1. human, interactive: master password into the keychain
security add-generic-password -s kpxc-agent-vault -a "$USER" -w

# 2. copy the scripts somewhere stable and write a config file (mode 600)
install -m 700 -d ~/.local/share/kpxc-secrets
install -m 700 scripts/*.sh ~/.local/share/kpxc-secrets/
printf '%s\n' 'KPXC_DB="/path/to/vault.kdbx"' \
  'KPXC_KEYCHAIN_SERVICE="kpxc-agent-vault"' 'KPXC_GROUP="hermes"' \
  > ~/.config/kpxc-myprofile.conf && chmod 600 ~/.config/kpxc-myprofile.conf

# 3. wire the profile
hermes -p myprofile config set secrets.command.enabled true
hermes -p myprofile config set secrets.command.command \
  'KPXC_CONF=/Users/me/.config/kpxc-myprofile.conf /Users/me/.local/share/kpxc-secrets/kpxc-secrets.sh'
hermes -p myprofile config set secrets.command.helper_timeout_seconds 15
hermes -p myprofile config set secrets.command.override_existing false
```

Then add entries to the vault's `hermes` group (Title = env var name; value literal or
a `ref:` to an existing entry) and verify:

```sh
KPXC_EXPECTED="FOO_API_KEY BAR_TOKEN" scripts/kpxc-secrets-check.sh --deep \
  HERMES_PROFILE_HOME=~/.hermes/profiles/myprofile
hermes -p myprofile config path        # expect: "Command helper: applied 2 secrets"
```

## Update

```sh
npx skills update keepassxc-secret-source
# vendored clone:
git -C keepassxc-secret-source-skill pull
```

Re-copy `scripts/` after updating if you vendored them into `~/.local/share/`.

## Layout

```
keepassxc-secret-source-skill/
├── SKILL.md
├── README.md
├── LICENSE.md
├── scripts/
│   ├── kpxc-secrets.sh
│   ├── kpxc-secrets-check.sh
│   └── kpxc-rollback.sh
└── references/
    ├── entry-model.md
    ├── hermes-command-source-contract.md
    ├── pitfalls-and-recovery.md
    ├── setup-walkthrough.md
    └── sources.md
```

## Troubleshooting

- **`helper command failed`, no detail** — Hermes discards helper stderr by design. Run
  `scripts/kpxc-secrets.sh` by hand; usual causes are a missing keychain item, an
  unreadable vault, or a wrong master password.
- **`helper output was not a KEY=VALUE map`** — the group is empty or every entry was
  skipped (ambiguous reference, multi-line value). Set `KPXC_EXPECTED` so a check fails
  instead of warning.
- **Timeout on a synced vault** — raise `helper_timeout_seconds`; 3 s is the default and
  assumes an unlocked local file.
- **Vault edits disappear** — the KeePassXC GUI saved from stale state. Reload the
  database, then re-apply.
- **Installer picked the wrong target, or nothing installed** — confirm `name:` in
  `SKILL.md` (`keepassxc-secret-source`) matches the skill directory, and pass
  `--skill` explicitly when installing from this repo (repo name carries a `-skill`
  suffix, the skill name does not).
- **`npx skills` dies with `does not provide an export named 'glob'`** — the CLI needs
  Node 22+; an older `node` on PATH (20.x) fails at import time. Use a newer Node or
  `npx -y skills@latest` under one.
- **Valid agent ids** — `-a claude` is rejected; the ids are `claude-code`, `codex`,
  `hermes-agent`, … (`npx skills add --help` lists them).

## License

Mutualist License v1.2 (`MutuaL-1.2`) — see [LICENSE.md](LICENSE.md).
Not legal advice; read the license before redistributing.
