#!/bin/sh
# Roll a profile's secrets back OUT of the KeePassXC vault and into .env.
#
#   kpxc-rollback.sh                 restore the newest env-pre-vault-* backup
#   kpxc-rollback.sh --purge         ...then delete the vault entries and disable
#                                    the secret source for that profile
#   kpxc-rollback.sh --purge --force ...even while KeePassXC is running
#   kpxc-rollback.sh --file PATH     restore a specific backup (relative paths
#                                    resolve against the profile's backups/)
#   kpxc-rollback.sh --list          list backups, change nothing
#
# Step 1 (restore .env) is always attempted first and can only put values back.
# Step 2 refuses to run while KeePassXC has the database open unless --force,
# because a GUI save from stale in-memory state resurrects what it just deleted.
# Any failure in step 2 exits non-zero and suppresses the "complete" message.
#
# Configuration:
#   KPXC_PROFILE_HOME   required — profile directory (its .env and backups/ are used)
#   KPXC_PROFILE_NAME   default: basename of KPXC_PROFILE_HOME
#   KPXC_ENTRIES        required for --purge — space-separated env var names
#   KPXC_DB, KPXC_GROUP, KPXC_KEYCHAIN_SERVICE, KPXC_KEYCHAIN_ACCOUNT, KPXC_CLI,
#                       KPXC_CONF — as for kpxc-secrets.sh
#   HERMES_BIN          default: hermes
#   HERMES_PY           python with pyyaml, for verifying the config write
set -u

[ -n "${KPXC_CONF:-}" ] && [ -f "$KPXC_CONF" ] && . "$KPXC_CONF"

: "${KPXC_PROFILE_HOME:?set KPXC_PROFILE_HOME to the profile directory}"

ENV_FILE="$KPXC_PROFILE_HOME/.env"
BK_DIR="$KPXC_PROFILE_HOME/backups"
PROFILE_NAME="${KPXC_PROFILE_NAME:-$(basename "$KPXC_PROFILE_HOME")}"
ENTRIES="${KPXC_ENTRIES:-}"
GROUP="${KPXC_GROUP:-hermes}"
HERMES_BIN="${HERMES_BIN:-hermes}"
HERMES_PY="${HERMES_PY:-python3}"
SECURITY_BIN="${SECURITY_BIN:-/usr/bin/security}"
KEYCHAIN_ACCOUNT="${KPXC_KEYCHAIN_ACCOUNT:-$(id -un)}"

if [ -z "${KPXC_CLI:-}" ]; then
    if [ -x "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" ]; then
        KPXC_CLI="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
    else
        KPXC_CLI="keepassxc-cli"
    fi
fi

PURGE=0
FORCE=0
WANT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --purge) PURGE=1 ;;
        --force) FORCE=1 ;;
        --file) shift; WANT="${1:-}" ;;
        --list) ls -1t "$BK_DIR"/env-pre-vault-* 2>/dev/null || echo "no backups in $BK_DIR"; exit 0 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -n "$WANT" ]; then
    case "$WANT" in
        /*) BACKUP="$WANT" ;;
        *)
            if [ -f "$BK_DIR/$WANT" ]; then
                BACKUP="$BK_DIR/$WANT"
            elif [ -f "$BK_DIR/${WANT#backups/}" ]; then
                BACKUP="$BK_DIR/${WANT#backups/}"
            elif [ -f "$WANT" ]; then
                BACKUP="$WANT"
            else
                BACKUP="$BK_DIR/$WANT"
            fi
            ;;
    esac
else
    BACKUP=$(ls -1t "$BK_DIR"/env-pre-vault-* 2>/dev/null | head -1)
fi

if [ -z "${BACKUP:-}" ] || [ ! -s "$BACKUP" ]; then
    echo "ABORT: no usable backup found (looked for env-pre-vault-* in $BK_DIR)" >&2
    exit 1
fi

echo "== step 1: restore .env from backup =="
echo "backup: $BACKUP"
TMP=$(mktemp "$KPXC_PROFILE_HOME/.env.restore.XXXXXX") || exit 1
cp "$BACKUP" "$TMP" && chmod 600 "$TMP" && mv "$TMP" "$ENV_FILE" || {
    rm -f "$TMP"
    echo "ABORT: could not write $ENV_FILE" >&2
    exit 1
}
printf 'restored keys (names only): '
grep -c '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | tr -d '\n'
printf ' var(s): '
grep -o '^[A-Za-z_][A-Za-z0-9_]*' "$ENV_FILE" | tr '\n' ' '
echo
echo "  $ENV_FILE now holds the pre-vault values again (mode 600)."
echo

if [ "$PURGE" -eq 0 ]; then
    cat <<EOF
== done (vault entries kept) ==
The vault still holds $GROUP/{$ENTRIES}. Harmless while
secrets.command.override_existing is false (.env wins). Re-run with --purge to
remove them too.
Next: start a new session for this profile so it reads the restored .env.
EOF
    exit 0
fi

echo "== step 2: delete vault entries + disable the secret source =="
FAILS=0

if pgrep -f "KeePassXC.app/Contents/MacOS/KeePassXC" >/dev/null 2>&1; then
    if [ "$FORCE" -eq 0 ]; then
        echo "ABORT: KeePassXC is running and may hold the database open; a GUI save" >&2
        echo "       from stale state would resurrect these entries. Close the database" >&2
        echo "       (Database -> Close) and re-run, or pass --force." >&2
        echo "       .env is restored, so Hermes works; only cleanup is pending." >&2
        exit 1
    fi
    echo "  --force: proceeding with KeePassXC running (reload the DB in the GUI after)"
fi

if [ -z "$ENTRIES" ]; then
    echo "  FAILED: KPXC_ENTRIES is empty — nothing named to delete" >&2
    FAILS=$((FAILS + 1))
elif [ -z "${KPXC_DB:-}" ] || [ -z "${KPXC_KEYCHAIN_SERVICE:-}" ]; then
    echo "  FAILED: KPXC_DB / KPXC_KEYCHAIN_SERVICE unset — cannot reach the vault" >&2
    FAILS=$((FAILS + 1))
else
    DBPW=$("$SECURITY_BIN" find-generic-password -s "$KPXC_KEYCHAIN_SERVICE" \
                -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null) || {
        echo "ABORT: could not read the master password from the Keychain." >&2
        echo "       .env is restored, so Hermes works — only cleanup is left." >&2
        exit 1
    }
    for name in $ENTRIES; do
        entry="$GROUP/$name"
        if ! printf '%s\n' "$DBPW" | "$KPXC_CLI" show -q -s -a Password "$KPXC_DB" "$entry" >/dev/null 2>&1; then
            echo "  absent, nothing to delete: $entry"
            continue
        fi
        printf '%s\ny\n' "$DBPW" | "$KPXC_CLI" rm -q "$KPXC_DB" "$entry" >/dev/null 2>&1
        if printf '%s\n' "$DBPW" | "$KPXC_CLI" show -q -s -a Password "$KPXC_DB" "$entry" >/dev/null 2>&1; then
            echo "  FAILED: $entry still present after rm" >&2
            FAILS=$((FAILS + 1))
        else
            echo "  removed $entry (verified gone)"
        fi
    done
fi

if "$HERMES_BIN" -p "$PROFILE_NAME" config set secrets.command.enabled false >/dev/null 2>&1; then
    if "$HERMES_PY" - "$KPXC_PROFILE_HOME/config.yaml" <<'PY'
import sys

import yaml

cfg = yaml.safe_load(open(sys.argv[1])) or {}
enabled = (cfg.get("secrets") or {}).get("command", {}).get("enabled")
sys.exit(0 if enabled is False else 1)
PY
    then
        echo "  secrets.command.enabled -> false (verified in config.yaml)"
    else
        echo "  FAILED: config write did not verify (still enabled?)" >&2
        FAILS=$((FAILS + 1))
    fi
else
    echo "  FAILED: could not disable secrets.command.enabled" >&2
    FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -gt 0 ]; then
    cat <<EOF

== rollback INCOMPLETE — $FAILS failure(s) ==
.env IS restored, so Hermes still works. Vault cleanup did not fully verify:
fix the failures above (usually: database open in KeePassXC, or the vault path
unreachable) and re-run with --purge.
EOF
    exit 1
fi

cat <<EOF

== rollback complete (verified) ==
.env restored · vault entries deleted and confirmed gone · secret source disabled.
Nothing points at the password manager for profile '$PROFILE_NAME' any more.
Start a new session for the profile so it reads the restored .env.
EOF
