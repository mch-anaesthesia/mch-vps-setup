#!/usr/bin/env bash
set -eEuo pipefail

# Harden environment (works fine for interactive too)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

# ── Planka Restore Script (interactive) ──────────────────────────
# Flags:
#   --dry-run   : show what would be restored, do not modify anything
#   --yes       : skip final confirmation (ignored for --dry-run)

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
    *)         shift ;;
  esac
done

# Load credentials
[[ -r "$SYSTEM_ENV_FILE" ]] || { echo "✗ ERROR: Credentials file $SYSTEM_ENV_FILE not found or not readable." >&2; exit 1; }
set -o allexport; source "$SYSTEM_ENV_FILE"; set +o allexport

# Validate required variables
for var in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD; do
  [[ -n "${!var:-}" ]] || { echo "✗ ERROR: \$$var is not set in $SYSTEM_ENV_FILE" >&2; exit 1; }
done

# Ensure restic is installed
command -v restic >/dev/null || { echo "✗ ERROR: restic not installed." >&2; exit 1; }

# single-instance lock
exec 9>/var/lock/planka-restore.lock
flock -n 9 || { echo "Another restore is running; exiting."; exit 0; }

# Ensure containers exist/running
docker ps -a --format '{{.Names}}' | grep -qx "$PLANKA_CTN" \
  || { echo "✗ ERROR: Planka container '$PLANKA_CTN' does not exist." >&2; exit 1; }
if [[ "$DRY_RUN" -eq 0 ]]; then
  docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CTN" \
    || { echo "✗ ERROR: Postgres container '$POSTGRES_CTN' is not running." >&2; exit 1; }
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
  restic ls "$SNAP_ID" | head -n 200 || true
  echo "… (use 'restic ls $SNAP_ID' to see full list)"
  echo
  echo "[i] Would: stop Planka → restore to temp → import DB → copy assets → (re)start Planka"
  echo "[✓] Dry run complete — no changes made."
  exit 0
fi

echo "[+] Restoring snapshot: $SNAP_ID"
TMPDIR="$(mktemp -d "/tmp/planka-restore-${SNAP_ID}.XXXX")"
cleanup(){ rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Record whether Planka was running; stop it to prevent writes
WAS_RUNNING=0
if docker ps --format '{{.Names}}' | grep -qx "$PLANKA_CTN"; then
  WAS_RUNNING=1
  echo "[+] Stopping Planka container '$PLANKA_CTN'"
  docker stop "$PLANKA_CTN" >/dev/null
fi

# Early ERR trap: before safety dump exists, just restore service state if we fail
early_fail() {
  echo "[!] Restore failed before DB safety dump. Restoring service state…"
  if [[ $WAS_RUNNING -eq 1 ]]; then
    docker start "$PLANKA_CTN" >/dev/null || true
    echo "[i] Planka restarted."
  fi
}
trap early_fail ERR

# Restore files into TMPDIR
nice -n 10 ionice -c2 -n7 restic restore "$SNAP_ID" --target "$TMPDIR"

# Find where postgres.sql actually landed (handles deep restored paths)
psql_path="$(find "$TMPDIR" -type f -name postgres.sql -print -quit || true)"
if [[ -n "$psql_path" ]]; then
  RESTORE_ROOT="$(dirname "$psql_path")"
else
  echo "✗ ERROR: postgres.sql not found anywhere under $TMPDIR" >&2
  echo "Restored tree preview (depth 4):" >&2
  find "$TMPDIR" -maxdepth 4 -type d -print | sed 's/^/  /' >&2
  exit 1
fi

# Final confirmation (can be skipped with --yes)
if [[ "$ASSUME_YES" -ne 1 ]]; then
  echo
  read -rp "About to import DB and overwrite asset directories. Continue? [y/N] " yn
  case "${yn:-}" in
    y|Y|yes|YES) ;;
    *)
      echo "Aborted."
      if [[ $WAS_RUNNING -eq 1 ]]; then docker start "$PLANKA_CTN" >/dev/null; fi
      exit 1 ;;
  esac
fi

# Take safety dump (commit point)
SAFE_DUMP="$TMPDIR/pre-restore-current-db.sql"
echo "[+] Taking safety dump of current DB to $SAFE_DUMP"
docker exec -i "$POSTGRES_CTN" pg_dumpall -U postgres > "$SAFE_DUMP"

# Replace ERR trap with rollback that uses the safety dump
rollback() {
  echo "[!] Restore failed after safety dump. Rolling database back…"
  if [[ -s "$SAFE_DUMP" ]]; then
    if docker exec -i "$POSTGRES_CTN" psql -U postgres < "$SAFE_DUMP"; then
      echo "[✓] Database rolled back from safety dump."
    else
      echo "[!] Database rollback failed; manual intervention needed."
    fi
  else
    echo "[!] Safety dump missing/empty; cannot roll back DB."
  fi
  if [[ $WAS_RUNNING -eq 1 ]]; then
    docker start "$PLANKA_CTN" >/dev/null || true
  fi
  exit 1
}
trap rollback ERR

# Restore Postgres database
echo "[+] Importing database into container '$POSTGRES_CTN'"
docker exec -i "$POSTGRES_CTN" psql -U postgres < "$RESTORE_ROOT/postgres.sql"

# Restore Planka asset volumes (only after DB import succeeded)
echo "[+] Restoring Planka asset volumes into '$PLANKA_CTN'"
for vol in public/favicons public/user-avatars public/background-images private/attachments; do
  echo "    • $vol"
  if [[ -d "$RESTORE_ROOT/$vol" ]]; then
    docker run --rm \
      --volumes-from "$PLANKA_CTN" \
      -v "$RESTORE_ROOT":/backup ubuntu \
      bash -c "rm -rf /app/$vol/* && cp -a /backup/$vol/. /app/$vol/"
  else
    echo "      (skipped: not present in snapshot)"
  fi
done

# Success: clear ERR trap and restore original service state
trap - ERR
if [[ $WAS_RUNNING -eq 1 ]]; then
  echo "[+] Starting Planka container '$PLANKA_CTN'"
  docker start "$PLANKA_CTN" >/dev/null
fi

echo "[✓] Restore complete for snapshot $SNAP_ID"
