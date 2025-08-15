#!/usr/bin/env bash
set -euo pipefail

# ── CONFIGURATION ───────────────────────────────────────────────
# Directory where this installer lives (assumes .env is in parent)
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Paths
PROJECT_ENV_FILE="${SCRIPTDIR}/../.env"
SYSTEM_ENV_FILE="/etc/planka-backup.env"
BACKUP_SCRIPT="/usr/local/bin/planka-backup.sh"
CRON_FILE="/etc/cron.d/planka-backup"

# Docker container names
PLANKA_CTN="planka"
POSTGRES_CTN="postgres-planka"

# Cron schedule: minute hour dom mon dow (every hour)
CRON_SCHEDULE="0 * * * *"

# Restic/Backblaze retention policy
KEEP_HOURLY=24
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
# ────────────────────────────────────────────────────────────────

# 1) Load project .env
echo "[+] Loading project environment from ${PROJECT_ENV_FILE}"
if [[ ! -f "${PROJECT_ENV_FILE}" ]]; then
  echo "✗ ERROR: Project .env not found at ${PROJECT_ENV_FILE}" >&2
  exit 1
fi
set -o allexport
source "${PROJECT_ENV_FILE}"
set +o allexport

# 2) Validate required variables
for var in B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY RESTIC_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    echo "✗ ERROR: \$$var is not set in ${PROJECT_ENV_FILE}" >&2
    exit 1
  fi
done

# 3) Persist credentials to system env file
echo "[+] Writing credentials to ${SYSTEM_ENV_FILE}"
sudo tee "${SYSTEM_ENV_FILE}" >/dev/null <<EOF
B2_ACCOUNT_ID=${B2_ACCOUNT_ID}
B2_ACCOUNT_KEY=${B2_ACCOUNT_KEY}
RESTIC_REPOSITORY=${RESTIC_REPOSITORY}
RESTIC_PASSWORD=${RESTIC_PASSWORD}

# retention policy
KEEP_HOURLY=${KEEP_HOURLY}
KEEP_DAILY=${KEEP_DAILY}
KEEP_WEEKLY=${KEEP_WEEKLY}
KEEP_MONTHLY=${KEEP_MONTHLY}
EOF
sudo chmod 600 "${SYSTEM_ENV_FILE}"

echo "[+] Credentials saved"

# 4) Install restic if missing
if ! command -v restic >/dev/null; then
  echo "[+] Installing restic via apt"
  sudo apt-get update
  sudo apt-get install -y restic
fi

# 5) Initialize Restic repository if not already
echo "[+] Initializing Restic (if needed)"
B2_ACCOUNT_ID="${B2_ACCOUNT_ID}" \
B2_ACCOUNT_KEY="${B2_ACCOUNT_KEY}" \
RESTIC_REPOSITORY="${RESTIC_REPOSITORY}" \
RESTIC_PASSWORD="${RESTIC_PASSWORD}" \
restic snapshots >/dev/null 2>&1 || restic init

# 6) Generate backup script
echo "[+] Writing backup script to ${BACKUP_SCRIPT}"
sudo tee "${BACKUP_SCRIPT}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Harden environment for cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

# ── Planka Backup Script ─────────────────────────────────────────
# Dumps Postgres DB and Planka assets, stores them in B2 via Restic

SYSTEM_ENV_FILE="/etc/planka-backup.env"
# Load credentials
set -o allexport
source "${SYSTEM_ENV_FILE}"
set +o allexport

# single-instance lock
exec 9>/var/lock/planka-backup.lock
flock -n 9 || { echo "Another backup is running; exiting."; exit 0; }

# Containers
POSTGRES_CTN="postgres-planka"
PLANKA_CTN="planka"

# Quick container sanity checks
if ! docker ps --format '{{.Names}}' | grep -qx "${POSTGRES_CTN}"; then
  echo "✗ ERROR: container ${POSTGRES_CTN} not running"; exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -qx "${PLANKA_CTN}"; then
  echo "✗ ERROR: container ${PLANKA_CTN} not running"; exit 1
fi

# Timestamp & workspace
ts="$(date --utc +%FT%H-%M-%SZ)"
tmpdir="$(mktemp -d /tmp/planka-backup-${ts}.XXXX)"
cleanup(){ rm -rf "${tmpdir}"; }
trap cleanup EXIT

echo "[+] Dumping Postgres"
docker exec -t "${POSTGRES_CTN}" pg_dumpall -c -U postgres > "${tmpdir}/postgres.sql"

echo "[+] Copying assets"
for vol in public/favicons public/user-avatars public/background-images private/attachments; do
  mkdir -p "${tmpdir}/$(dirname "${vol}")"
  docker run --rm --volumes-from "${PLANKA_CTN}" -v "${tmpdir}":/backup ubuntu \
    cp -a "/app/${vol}" "/backup/${vol}"
done

echo "[+] Restic backup (contents only)"
(
  cd "${tmpdir}"
  nice -n 10 ionice -c2 -n7 restic backup . --tag planka
)

echo "[✓] Backup complete: ${ts}"
EOF
sudo chmod +x "${BACKUP_SCRIPT}"

echo "[+] Generated backup script"

# 6b) Generate maintenance script (prune + checks, on schedules)
MAINT_SCRIPT="/usr/local/bin/planka-backup-maint.sh"
echo "[+] Writing maintenance script to ${MAINT_SCRIPT}"
sudo tee "${MAINT_SCRIPT}" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Harden environment for cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

# ── Restic Maintenance Script ───────────────────────────────────
# Usage:
#   planka-backup-maint.sh prune       # forget+prune with policy
#   planka-backup-maint.sh check       # quick integrity check (10% read)
#   planka-backup-maint.sh check-full  # full read-data check (slow/costly)

SYSTEM_ENV_FILE="/etc/planka-backup.env"
set -o allexport; source "${SYSTEM_ENV_FILE}"; set +o allexport

# Retention is sourced from env file (no fallbacks)
KEEP_HOURLY="${KEEP_HOURLY}"
KEEP_DAILY="${KEEP_DAILY}"
KEEP_WEEKLY="${KEEP_WEEKLY}"
KEEP_MONTHLY="${KEEP_MONTHLY}"

# single-instance lock
exec 9>/var/lock/planka-backup-maint.lock
flock -n 9 || { echo "Maintenance already running; exiting."; exit 0; }

cmd="${1:-}"
case "$cmd" in
  prune)
    echo "[+] Forget + prune with policy"
    nice -n 10 ionice -c2 -n7 restic forget --prune --cleanup-cache \
      --tag planka \
      --group-by host \
      --keep-hourly "$KEEP_HOURLY" \
      --keep-daily  "$KEEP_DAILY" \
      --keep-weekly "$KEEP_WEEKLY" \
      --keep-monthly "$KEEP_MONTHLY"
    echo "[✓] Prune complete"
    ;;
  check)
    echo "[+] restic check (metadata + 10% read of pack data)"
    nice -n 10 ionice -c2 -n7 restic check --read-data-subset=10%
    echo "[✓] Check complete"
    ;;
  check-full)
    echo "[+] restic check (full read-data) — may be slow/expensive"
    nice -n 10 ionice -c2 -n7 restic check --read-data
    echo "[✓] Full check complete"
    ;;
  *)
    echo "Usage: $(basename "$0") {prune|check|check-full}" >&2
    exit 2
    ;;
esac
EOF
sudo chmod +x "${MAINT_SCRIPT}"
echo "[+] Generated maintenance script"

# 7) Install cron jobs
echo "[+] Installing cron job(s)"
sudo tee "${CRON_FILE}" >/dev/null <<EOC
# Hourly backup
${CRON_SCHEDULE} root ${BACKUP_SCRIPT} >> /var/log/planka-backup.log 2>&1
# Daily prune (03:17)
17 3 * * * root ${MAINT_SCRIPT} prune >> /var/log/planka-backup.log 2>&1
# Weekly integrity check (Sun 03:45, ~10% read)
45 3 * * 0 root ${MAINT_SCRIPT} check >> /var/log/planka-backup.log 2>&1
# Optional: Monthly full read check (1st 04:30) — uncomment if desired
#30 4 1 * * root ${MAINT_SCRIPT} check-full >> /var/log/planka-backup.log 2>&1
EOC

sudo chmod 644 "${CRON_FILE}"

echo "[✓] Setup complete"
echo "    Backup script:  ${BACKUP_SCRIPT}"
echo "    Maint script:   ${MAINT_SCRIPT}"
echo "    Cron (hourly):  ${CRON_SCHEDULE}"
echo "    Prune:          daily 03:17"
echo "    Check:          weekly Sun 03:45 (10% read)"
echo "    Retention:      hourly=${KEEP_HOURLY}, daily=${KEEP_DAILY}, weekly=${KEEP_WEEKLY}, monthly=${KEEP_MONTHLY}"
echo "    Env file:       ${SYSTEM_ENV_FILE}"
