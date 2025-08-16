#!/usr/bin/env bash
set -euo pipefail

# Harden environment (works fine for interactive too)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

# ── Planka Restore Script (interactive) ──────────────────────────
# Always lists available snapshots tagged "planka" and prompts to pick one.
# Flags:
#   --dry-run   : show what would be restored, do not modify anything
#   --yes       : skip final confirmation (ignored for --dry-run)

# Configuration
SYSTEM_ENV_FILE="/etc/planka-backup.env"
POSTGRES_CTN="postgres-planka"
PLANKA_CTN="planka"
RESTIC_TAG="planka"

# ---------- args ----------
DRY_RUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    *)         # ignore stray args (we always prompt for snapshot interactively)
               shift ;;
  esac
done

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

# single-instance lock (still useful for dry-run to avoid overlapping prompts)
exec 9>/var/lock/planka-restore.lock
flock -n 9 || { echo "Another restore is running; exiting."; exit 0; }

# Ensure containers exist (Planka may be stopped; Postgres must be running for *real* restore)
if ! docker ps -a --format '{{.Names}}' | grep -qx "$PLANKA_CTN"; then
  echo "✗ ERROR: Planka container '$PLANKA_CTN' does not exist." >&2
  exit 1
fi
if [[ "$DRY_RUN" -eq 0 ]]; then
  if ! docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CTN"; then
    echo "✗ ERROR: Postgres container '$POSTGRES_CTN' is not running." >&2
    exit 1
  fi
fi

# Always list and prompt
SNAP_ID=""
if command -v jq >/dev/null; then
  echo -e "IDX\tID\t\t\tTIME (UTC)\t\tHOST\tTAGS"
  json="$(restic snapshots --tag "$RESTIC_TAG" --no-lock --json)"
  mapfile -t lines < <(echo "$json" \
    | jq -r 'sort_by(.time) | reverse
             | to_entries[]
             | "\(.key)\t\(.value.short_id)\t\(.value.time)\t\(.value.hostname)\t\((.value.tags // [])|join(","))"')
  printf '%s\n' "${lines[@]}"
  echo
  read -erp "Enter IDX or snapshot ID to restore: " pick
  [[ -n "$pick" ]] || { echo "✗ ERROR: No selection entered. Aborting." >&2; exit 1; }
  if [[ "$pick" =~ ^[0-9]+$ ]]; then
    SNAP_ID="$(echo "$json" | jq -r 'sort_by(.time) | reverse | .['"$pick"'].short_id')"
  else
    SNAP_ID="$pick"
  fi
else
  echo "Available snapshots tagged '$RESTIC_TAG':"
  echo
  restic snapshots --tag "$RESTIC_TAG" --no-lock
  echo
  read -erp "Enter the snapshot ID to restore: " SNAP_ID
fi

[[ -n "$SNAP_ID" ]] || { echo "✗ ERROR: No snapshot ID entered. Aborting." >&2; exit 1; }

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "──────── DRY RUN ────────"
  echo "[i] Snapshot to inspect: $SNAP_ID"
  # Show metadata for the chosen snapshot (host, time, tags)
  if command -v jq >/dev/null; then
    restic snapshots --no-lock --json \
      | jq -r --arg id "$SNAP_ID" '
          map(select(.short_id==$id or .id==$id))[]
          | "ID: \(.short_id)\nTime: \(.time)\nHost: \(.hostname)\nTags: \((.tags // [])|join(","))"'
  else
    restic snapshots | awk -v id="$SNAP_ID" '$1==id{print;exit}'
  fi

  echo
  echo "[i] Files in the snapshot (top 200 paths):"
  # List without restoring data
  restic ls "$SNAP_ID" | head -n 200 || true
  echo "… (use 'restic ls $SNAP_ID' to see full list)"

  echo
  echo "[i] What WOULD happen:"
  echo "  • Stop container: ${PLANKA_CTN} (if running)"
  echo "  • Restore files from snapshot into a temp dir"
  echo "  • Import Postgres via: docker exec -i ${POSTGRES_CTN} psql --set=ON_ERROR_STOP=on -U postgres < postgres.sql"
  echo "  • Replace Planka asset dirs inside ${PLANKA_CTN}:"
  echo "      public/favicons, public/user-avatars, public/background-images, private/attachments"
  echo "  • Start container: ${PLANKA_CTN}"
  echo
  echo "[✓] Dry run complete — no changes made."
  exit 0
fi

echo "[+] Restoring snapshot: $SNAP_ID"
TMPDIR="$(mktemp -d "/tmp/planka-restore-${SNAP_ID}.XXXX")"
cleanup(){ rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Stop Planka to avoid writes during restore (safe even if already stopped)
if docker ps --format '{{.Names}}' | grep -qx "$PLANKA_CTN"; then
  echo "[+] Stopping Planka container '$PLANKA_CTN'"
  docker stop "$PLANKA_CTN" >/dev/null
fi

# Restore files into TMPDIR
nice -n 10 ionice -c2 -n7 restic restore "$SNAP_ID" --target "$TMPDIR"

# Determine actual restore root (restic nests files under TMPDIR/<original-tempdir>)
if [[ -f "$TMPDIR/postgres.sql" ]]; then
  RESTORE_ROOT="$TMPDIR"
else
  RESTORE_ROOT="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$RESTORE_ROOT" ]] || { echo "✗ ERROR: Restored data directory not found under $TMPDIR" >&2; exit 1; }
fi

# Sanity check
[[ -f "$RESTORE_ROOT/postgres.sql" ]] || { echo "✗ ERROR: postgres.sql not found in restored set." >&2; exit 1; }

# Final confirmation (can be skipped with --yes)
if [[ "$ASSUME_YES" -ne 1 ]]; then
  echo
  read -rp "About to import DB and overwrite asset directories. Continue? [y/N] " yn
  case "${yn:-}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Restore Postgres database (stop on first SQL error)
echo "[+] Importing database into container '$POSTGRES_CTN'"
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

# Start Planka back up
echo "[+] Starting Planka container '$PLANKA_CTN'"
docker start "$PLANKA_CTN" >/dev/null

echo "[✓] Restore complete for snapshot $SNAP_ID"
