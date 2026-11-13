#!/bin/sh
# Hermes "command" secret-source helper backed by a KeePassXC database.
#
# Contract with Hermes: print KEY=VALUE lines on stdout and exit 0. Hermes runs
# this through /bin/sh -c with stdin closed and DISCARDS stderr, so run it by
# hand when you need to see why it failed.
#
# Configuration (environment variables, or a file sourced from $KPXC_CONF):
#   KPXC_DB                 required — path to the .kdbx file
#   KPXC_KEYCHAIN_SERVICE   required — login-Keychain item holding the master password
#   KPXC_KEYCHAIN_ACCOUNT   default: current user
#   KPXC_GROUP              default: hermes — group whose entries are exposed
#   KPXC_CLI                default: macOS KeePassXC app path, else keepassxc-cli on PATH
#   KPXC_CONF               optional — file of KEY=VALUE lines sourced first
#   PYTHON3                 default: python3
#   SECURITY_BIN            default: /usr/bin/security
set -u

[ -n "${KPXC_CONF:-}" ] && [ -f "$KPXC_CONF" ] && . "$KPXC_CONF"

: "${KPXC_DB:?set KPXC_DB to the path of the .kdbx database}"
: "${KPXC_KEYCHAIN_SERVICE:?set KPXC_KEYCHAIN_SERVICE to the Keychain item holding the master password}"

KPXC_GROUP="${KPXC_GROUP:-hermes}"
KPXC_KEYCHAIN_ACCOUNT="${KPXC_KEYCHAIN_ACCOUNT:-$(id -un)}"
PYTHON3="${PYTHON3:-python3}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"

if [ -z "${KPXC_CLI:-}" ]; then
    if [ -x "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" ]; then
        KPXC_CLI="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
    else
        KPXC_CLI="keepassxc-cli"
    fi
fi

[ -r "$KPXC_DB" ] || exit 1

# Master password from the login Keychain. keepassxc-cli 2.7.x has no
# --pw-stdin flag, but it does read the password from stdin when stdin is not a
# TTY — which is exactly what the printf pipe below produces.
PW=$("$SECURITY_BIN" find-generic-password -s "$KPXC_KEYCHAIN_SERVICE" \
        -a "$KPXC_KEYCHAIN_ACCOUNT" -w 2>/dev/null) || exit 1
[ -n "$PW" ] || exit 1

TMP=$(mktemp "${TMPDIR:-/tmp}/kpxc-secrets.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT HUP INT TERM

# One database open for the whole run (the KDF dominates: never reopen per entry),
# then filter and resolve references locally.
printf '%s\n' "$PW" | "$KPXC_CLI" export -q -f csv "$KPXC_DB" > "$TMP" 2>/dev/null || exit 1

"$PYTHON3" - "$TMP" "$KPXC_GROUP" <<'PY'
import csv
import re
import sys

path, group = sys.argv[1], sys.argv[2].strip("/")
env_name = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def note(msg):
    print(f"# {msg}", file=sys.stderr)


rows = []
with open(path, newline="", encoding="utf-8", errors="replace") as fh:
    for row in csv.DictReader(fh):
        grp = [seg for seg in (row.get("Group") or "").strip("/").split("/") if seg]
        rows.append((grp, row))

# keepassxc-cli's CSV "Group" column is the FULL path including the database's
# own root group (e.g. "Vault/hermes"). Drop that root segment and require the
# configured group to be a PREFIX of what remains, so "hermes" matches
# Vault/hermes and Vault/hermes/<sub> but never Unrelated/hermes.
want = group.split("/")


def in_group(grp):
    rel = grp[1:]
    return rel[:len(want)] == want


# Index every entry by its root-group-relative path, so a reference written as
# "Servers/db admin" resolves without the caller knowing the root group's name.
index = {}
for grp, row in rows:
    rel = tuple(grp[1:] + [(row.get("Title") or "").strip()])
    index.setdefault(rel, row)


def field(row, attr):
    """Attribute lookup by CSV column name, case-insensitive."""
    low = attr.lower()
    for key, value in row.items():
        if key and key.lower() == low:
            return value
    return None


def resolve(ref):
    attr = "Password"
    if "#" in ref:
        ref, attr = ref.rsplit("#", 1)
        attr = attr.strip() or "Password"
    segs = tuple(s.strip() for s in ref.strip().strip("/").split("/") if s.strip())
    if not segs:
        return None, "empty reference"
    hit = index.get(segs)
    if hit is None:
        folded = tuple(s.lower() for s in segs)
        hits = [row for p, row in index.items()
                if tuple(s.lower() for s in p[-len(segs):]) == folded]
        if len(hits) == 1:
            hit = hits[0]
        elif len(hits) > 1:
            return None, f"{'/'.join(segs)!r} is ambiguous ({len(hits)} matches) — qualify the path"
        else:
            return None, f"{'/'.join(segs)!r} not found"
    value = field(hit, attr)
    if value is None:
        return None, f"entry {'/'.join(segs)!r} has no attribute {attr!r}"
    return value, None


out = {}
for grp, row in rows:
    if not in_group(grp):
        continue
    title = (row.get("Title") or "").strip()
    value = row.get("Password") or ""
    ref = (row.get("URL") or "").strip()

    if ref.lower().startswith("ref:"):
        value, err = resolve(ref[4:])
        if err:
            note(f"skipped {title!r}: {err}")
            continue
    if not title or not value:
        continue
    if not env_name.match(title) or "\n" in value or "\r" in value:
        note(f"skipped {title!r}: not env-var shaped, or the value spans lines")
        continue
    out[title] = value

for key in sorted(out):
    sys.stdout.write(f"{key}={out[key]}\n")
PY
