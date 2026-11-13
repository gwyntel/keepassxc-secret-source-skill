#!/bin/sh
# Verify what a KeePassXC secret-source helper hands Hermes.
# Prints env var NAMES, value lengths and sha256 prefixes only — never values.
#
#   kpxc-secrets-check.sh           helper status + emitted vars
#   kpxc-secrets-check.sh --deep    also run Hermes' real fetch pipeline with the
#                                   expected vars removed from the environment, and
#                                   assert each one arrives from the 'command'
#                                   source with a non-empty value
#
# Exit status: 0 only when the helper runs and emits every expected var; with
# --deep, only when the pipeline actually hydrates all of them.
#
# Configuration:
#   KPXC_HELPER        helper to test (default: kpxc-secrets.sh beside this script)
#   KPXC_EXPECTED      space-separated var names that must be emitted (required)
#   HERMES_PROFILE_HOME  profile directory holding config.yaml (required for --deep)
#   HERMES_SRC         Hermes source checkout (default: /usr/share/hermes-agent)
#   HERMES_PY          python that can import agent.secret_sources (default:
#                      $HERMES_SRC/.venv/bin/python, else python3)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
HELPER="${KPXC_HELPER:-$HERE/kpxc-secrets.sh}"
EXPECTED="${KPXC_EXPECTED:?set KPXC_EXPECTED to the env vars the helper must emit}"
HERMES_SRC="${HERMES_SRC:-/usr/share/hermes-agent}"
SHASUM="${SHASUM:-shasum}"

if [ -z "${HERMES_PY:-}" ]; then
    if [ -x "$HERMES_SRC/.venv/bin/python" ]; then
        HERMES_PY="$HERMES_SRC/.venv/bin/python"
    else
        HERMES_PY="python3"
    fi
fi

echo "helper:   $HELPER"
echo "expected: $EXPECTED"
[ "${1:-}" = "--deep" ] && echo "profile:  ${HERMES_PROFILE_HOME:-<unset>}"
echo

[ -x "$HELPER" ] || { echo "STATUS: FAILED — helper missing or not executable"; exit 1; }

OUT=$("$HELPER") || {
    echo "STATUS: FAILED — helper exited non-zero (Hermes discards its stderr;"
    echo "        run '$HELPER' by hand to see the real error)"
    exit 1
}

RC=0
if [ -z "$OUT" ]; then
    echo "STATUS: FAILED — helper ran but emitted nothing, so Hermes hydrates nothing"
    RC=1
else
    printf '%s\n' "$OUT" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        k=${line%%=*}
        v=${line#*=}
        printf '  %-26s len=%-4d sha256=%s\n' "$k" "${#v}" \
            "$(printf '%s' "$v" | "$SHASUM" -a 256 | cut -c1-16)"
    done
    for name in $EXPECTED; do
        if ! printf '%s\n' "$OUT" | grep -q "^$name="; then
            echo "STATUS: FAILED — helper did not emit $name"
            RC=1
        fi
    done
    [ "$RC" -eq 0 ] && echo "STATUS: OK — $(printf '%s\n' "$OUT" | grep -c '=') var(s) available"
fi

if [ "${1:-}" = "--deep" ]; then
    echo
    if [ -z "${HERMES_PROFILE_HOME:-}" ]; then
        echo "deep check: SKIPPED — set HERMES_PROFILE_HOME to the profile directory"
    elif [ ! -f "$HERMES_PROFILE_HOME/config.yaml" ]; then
        echo "deep check: SKIPPED — no config.yaml at $HERMES_PROFILE_HOME"
    elif [ ! -d "$HERMES_SRC/agent/secret_sources" ]; then
        echo "deep check: SKIPPED — no Hermes source at $HERMES_SRC (set HERMES_SRC)"
    else
        echo "deep check: Hermes' secret-source pipeline, expected vars removed first"
        ( cd "$HERMES_SRC" && "$HERMES_PY" - "$HERMES_PROFILE_HOME" "$EXPECTED" <<'PY'
import hashlib
import os
import sys

import yaml
from pathlib import Path

home = Path(sys.argv[1])
names = sys.argv[2].split()
cfg = yaml.safe_load(open(home / "config.yaml"))["secrets"]
for name in names:
    os.environ.pop(name, None)

from agent.secret_sources.registry import apply_all

env = dict(os.environ)
report = apply_all(cfg, home, environ=env)
print("  sources run :", [getattr(s, "name", s) for s in report.sources] or "none")

ok = True
for name in names:
    prov = report.provenance.get(name)
    value = env.get(name, "")
    good = bool(value) and prov is not None and prov.source == "command"
    ok = ok and good
    where = f"{prov.source} (overrode .env={prov.overrode_env})" if prov else "NOT SUPPLIED"
    digest = hashlib.sha256(value.encode()).hexdigest()[:16] if value else "-"
    print(f"  {name:<22} -> {where:<34} len={len(value)} sha256={digest} "
          f"{'ok' if good else 'FAIL'}")

print("  RESULT:", "PASS" if ok else "FAIL — Hermes would not receive every expected var")
sys.exit(0 if ok else 1)
PY
        ) || RC=1
    fi
fi

exit "$RC"
