# Sources

Accessed 2026-11-12.

## Hermes Agent documentation

- Secrets overview — https://hermes-agent.nousresearch.com/docs/user-guide/secrets
- Command helper secret source — https://hermes-agent.nousresearch.com/docs/user-guide/secrets/command

## Hermes Agent source (behaviour verified here, not inferred from docs)

- `agent/secret_sources/command.py` — helper execution, timeout, output cap, parsing
- `agent/secret_sources/registry.py` — precedence ladder, provenance, mux env scoping
- `agent/secret_sources/base.py` — `source_child_env()`, error taxonomy
- `hermes_cli/env_loader.py` — staged-env startup path and the `local_env` narrowing that can hide an exported variable from the helper

## KeePassXC

- CLI reference (`keepassxc-cli 2.7.6` on macOS): `keepassxc-cli help`, `export --help`,
  `add --help`, `show --help`, `rm --help`
- Project — https://keepassxc.org/

## License

- Mutualist License v1.2 — https://codeberg.org/Mutualism/Mutualist-License
  (`LICENSE.md` in that repository; the bare `LICENSE` path 404s)

No conflicts found between the docs and the code at the revision consulted; where they
differ in emphasis the code was treated as authoritative and the difference is called
out in `hermes-command-source-contract.md`.
