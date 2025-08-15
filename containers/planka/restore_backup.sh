#!/usr/bin/env bash
set -euo pipefail

# ── Planka Restore Script (interactive) ──────────────────────────
# Always lists available snapshots tagged "planka" and prompts to pick one.

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
if ! command -v restic >/dev/null; then
  echo "✗ ERROR: restic not installed." >&2
  exit 1
fi

# Always list and prompt
SNAP_ID=""
if command -v jq >/dev/null; then
  echo -e "IDX\tID\t\t\tTIME (UTC)\t\tHOST"
  restic snapshots --tag "$RESTIC_TAG" --no-lock --json \
    | jq -r 'to_entries[] | "\(.key)\t\(.value.short_id)\t\(.value.time)\t\(.value.hostname)"'
  echo
  read -erp "Enter IDX or snapshot ID to restore: " pick
  if [[ -z "$pick" ]]; then
    echo "✗ ERROR: No selection entered. Aborting." >&2
    exit 1
  fi
  if [[ "$pick" =~ ^[0-9]+$ ]]; then
    SNAP_ID="$(restic snapshots --tag "$RESTIC_TAG" --no-lock --json | jq -r ".[$pick].short_id")"
  else
    SNAP_ID="$pick"
  fi
else
  echo "Available snapshots tagged '$RESTIC_TAG':"
  echo
  # Fallback to human table (format may vary between versions)
  restic snapshots --tag "$RESTIC_TAG" --no-lock
  echo
  read -erp "Enter the snapshot ID to restore: " SNAP_ID
fi

if [[ -z "$SNAP_ID" ]]; then
  echo "✗ ERROR: No snapshot ID entered. Aborting." >&2
  exit 1
fi

echo "[+] Restoring snapshot: $SNAP_ID"
TMPDIR="$(mktemp -d "/tmp/planka-restore-${SNAP_ID}.XXXX")"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Restore the backup
restic restore "$SNAP_ID" --target "$TMPDIR"

# Determine actual restore root (restic nests files under TMPDIR/<original-tempdir>)
if [[ -f "$TMPDIR/postgres.sql" ]]; then
  RESTORE_ROOT="$TMPDIR"
else
  RESTORE_ROOT="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [[ -z "$RESTORE_ROOT" ]]; then
    echo "✗ ERROR: Restored data directory not found under $TMPDIR" >&2
    exit 1
  fi
fi

# Sanity check
if [[ ! -f "$RESTORE_ROOT/postgres.sql" ]]; then
  echo "✗ ERROR: postgres.sql not found in restored set." >&2
  exit 1
fi

# Restore Postgres database
echo "[+] Importing database into container '$POSTGRES_CTN'"
if ! docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CTN"; then
  echo "✗ ERROR: Postgres container '$POSTGRES_CTN' is not running." >&2
  exit 1
fi
docker exec -i "$POSTGRES_CTN" psql -U postgres < "$RESTORE_ROOT/postgres.sql"

# Restore Planka asset volumes
echo "[+] Restoring Planka asset volumes into '$PLANKA_CTN'"
for vol in public/favicons public/user-avatars public/background-images private/attachments; do
  echo "    • $vol"
  docker run --rm \
    --volumes-from "$PLANKA_CTN" \
    -v "$RESTORE_ROOT":/backup ubuntu \
    bash -c "rm -rf /app/$vol/* && cp -a /backup/$vol/. /app/$vol/"
done

echo "[✓] Restore complete for snapshot $SNAP_ID"
