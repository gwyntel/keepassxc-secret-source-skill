# The `secrets.command` source contract

Read from Hermes Agent source (`agent/secret_sources/command.py`,
`registry.py`, `base.py`, `hermes_cli/env_loader.py`). Values here are what the code
does, not what the docs summarise.

## Execution

| Property | Value | Consequence |
|---|---|---|
| Runner | `/bin/sh -c "<command>"` | inline `VAR=value command` assignments are legal |
| stdin | `subprocess.DEVNULL` | a helper that prompts interactively hangs until the timeout |
| stderr | piped and thrown away | never surfaces the real error; run the helper by hand |
| stdout | captured, ≤ 1 MiB | a real vault dump of a few keys is far under this |
| timeout | `helper_timeout_seconds`, default 3.0 | whole process group is SIGKILLed on expiry |
| session | `start_new_session=True` | a helper can spawn children; they die with the group |
| env | caller's env minus Hermes' terminal blocklist | `HOME`, `PATH`, `USER` survive; a per-profile mux view may narrow it further |
| key | passed in `HERMES_SECRET_KEY` (empty for bulk sources) | a hostile key name can never be interpolated into the shell |

Environment note that has bitten twice: under a per-profile multiplex view, the child
gets *only* that view. Do not assume an exported variable you set in your own shell
reaches the helper during a routed-profile fetch — pass configuration through
`KPXC_CONF` or literal paths.

## Parsing

- Line shape: `^([A-Za-z_][A-Za-z0-9_]*)=(.*)$`. Anything else is skipped.
- One layer of matching surrounding quotes is stripped.
- Keys are not validated as "credential-shaped"; a name like `HOME` would be
  claimed if the helper emitted it. Emit only what you mean to expose.

## Precedence (`registry.apply_all`)

1. `secrets.preserve_existing` names always keep their previous value.
2. An existing `.env` / shell value wins unless the winning source has
   `override_existing: true`. `command` defaults to **false**.
3. Mapped sources, then bulk sources, in configured order; first claim wins and a
   later duplicate is reported as `skipped_claimed`, never silently overwritten.

Provenance is recorded per var (`source`, `shape`, `overrode_env`); that record is
what a real verification asserts on, not stdout text.

## Startup path

`hermes_cli/env_loader.py` stages a copy of the environment, calls `apply_all()`,
and publishes the staged env only after its own safety check. So a helper failure
degrades to "no values applied" — process startup is never blocked. That is why an
empty `.env` plus an unreachable vault means a running agent with no provider key
rather than a crash; keep the rollback backup.
