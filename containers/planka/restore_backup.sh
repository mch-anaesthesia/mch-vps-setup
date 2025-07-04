#!/usr/bin/env bash
set -euo pipefail

# ── Planka Restore Script (interactive) ──────────────────────────
# Usage:
#   ./planka-restore.sh [snapshot-ID]
# If no ID given, lists available snapshots tagged "planka" and prompts user to pick.

# Configuration
SYSTEM_ENV_FILE="/etc/planka-backup.env"
POSTGRES_CTN="postgres-planka"
PLANKA_CTN="planka"
RESTIC_TAG="planka"

# Load credentials
if [[ ! -r "$SYSTEM_ENV_FILE" ]]; then
  echo "✗ ERROR: Credentials file $SYSTEM_ENV_FILE not found or not readable." >&2
  exit 1
fi
set -o allexport
source "$SYSTEM_ENV_FILE"
set +o allexport

# Validate required variables
for var in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    echo "✗ ERROR: \$$var is not set in $SYSTEM_ENV_FILE" >&2
    exit 1
  fi
done

# Ensure restic is installed
command -v restic >/dev/null || { echo "✗ ERROR: restic not installed." >&2; exit 1; }

# If no snapshot given, list and prompt
SNAP_ID="${1:-}"
if [[ -z "$SNAP_ID" ]]; then
  echo "Available snapshots tagged '$RESTIC_TAG':"
  echo
  restic snapshots --tag "$RESTIC_TAG" --no-lock \
    | tail -n +2 \
    | awk '{ printf "%s\t%s %s %s %s\n", $1, $2, $3, $4, $5 }'
  echo
  read -erp "Enter the snapshot ID to restore: " SNAP_ID
  if [[ -z "$SNAP_ID" ]]; then
    echo "✗ ERROR: No snapshot ID entered. Aborting." >&2
    exit 1
  fi
fi

echo "[+] Restoring snapshot: $SNAP_ID"
TMPDIR=$(mktemp -d /tmp/planka-restore-$SNAP_ID.XXXX)

# Restore the backup
restic restore "$SNAP_ID" --target "$TMPDIR"

# Restore Postgres database
echo "[+] Importing database into container '$POSTGRES_CTN'"
if ! docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CTN"; then
  echo "✗ ERROR: Postgres container '$POSTGRES_CTN' is not running." >&2
  exit 1
fi
cat "$TMPDIR/postgres.sql" | docker exec -i "$POSTGRES_CTN" psql -U postgres

# Restore Planka asset volumes
echo "[+] Restoring Planka asset volumes into '$PLANKA_CTN'"
for vol in public/favicons public/user-avatars public/background-images private/attachments; do
  echo "    • $vol"
  docker run --rm --volumes-from "$PLANKA_CTN" -v "$TMPDIR":/backup ubuntu bash -c \
    "rm -rf /app/$vol && mkdir -p /app/$vol && cp -a /backup/$vol/. /app/$vol/"
done

# Cleanup temporary files
echo "[+] Cleaning up"
rm -rf "$TMPDIR"

echo "[✓] Restore complete for snapshot $SNAP_ID"
