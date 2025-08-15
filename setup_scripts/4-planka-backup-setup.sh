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

# ── Planka Backup Script ─────────────────────────────────────────
# Dumps Postgres DB and Planka assets, stores them in B2 via Restic

SYSTEM_ENV_FILE="/etc/planka-backup.env"
# Load credentials
set -o allexport
source "${SYSTEM_ENV_FILE}"
set +o allexport

# Containers
POSTGRES_CTN="postgres-planka"
PLANKA_CTN="planka"

# Retention
KEEP_HOURLY=24
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# Timestamp & workspace
ts="$(date --utc +%FT%H-%M-%SZ)"
tmpdir="$(mktemp -d /tmp/planka-backup-${ts}.XXXX)"

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
  restic backup . --tag planka
)

echo "[+] Pruning snapshots"
restic forget --prune \
  --tag planka \
  --keep-hourly "${KEEP_HOURLY}" \
  --keep-daily "${KEEP_DAILY}" \
  --keep-weekly "${KEEP_WEEKLY}" \
  --keep-monthly "${KEEP_MONTHLY}"

echo "[+] Cleaning up"
rm -rf "${tmpdir}"
echo "[✓] Backup complete: ${ts}"
EOF
sudo chmod +x "${BACKUP_SCRIPT}"

echo "[+] Generated backup script"

# 7) Install cron job
echo "[+] Installing cron job to ${CRON_FILE}"
sudo tee "${CRON_FILE}" >/dev/null <<EOC
${CRON_SCHEDULE} root ${BACKUP_SCRIPT} >> /var/log/planka-backup.log 2>&1
EOC

sudo chmod 644 "${CRON_FILE}"

echo "[✓] Setup complete"
echo "    Backup script: ${BACKUP_SCRIPT}"
echo "    Cron: ${CRON_SCHEDULE}"
echo "    Retention: hourly=${KEEP_HOURLY}, daily=${KEEP_DAILY}, weekly=${KEEP_WEEKLY}, monthly=${KEEP_MONTHLY}"
echo "    Env file: ${SYSTEM_ENV_FILE}"
