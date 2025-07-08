# mch-vps-setup

A collection of scripts and configuration to bootstrap and secure a VPS, install Docker & Docker Compose, deploy containers (including Caddy as a reverse proxy), and configure automated backups for a Planka instance.

## Repository Layout

```
.
├── scripts/
│   ├── 1-bootstrap.sh              # Create a sudo user and configure SSH keys
│   ├── 2-harden.sh                 # Disable root login, install Ansible & run hardening playbook
│   ├── 3-docker-install.sh         # Remove old Docker, install Docker Engine & Compose plugin
│   └── 4-planka-backup-setup.sh    # Set up Restic/Backblaze backups for Planka via cron
├── .env.example                    # Example environment file for backup credentials
├── compose.yml                     # Top‑level Docker Compose include for all services
└── containers/
    ├── caddy/compose.yml           # Caddy reverse proxy service definition
    └── planka/compose.yml          # Planka & Postgres service definitions
```

## Prerequisites

- Ubuntu (tested on 22.04 LTS)
- `sudo` privileges or root access
- Internet access to download packages and Docker images
- An SSH keypair (for script 1)

## Getting Started

1. **Clone this repository**

   ```bash
   git clone https://github.com/your-org/mch-vps-setup.git
   cd mch-vps-setup
   ```

2. **Bootstrap your VPS**

   Run the first script as root to create a non-root user with passwordless sudo and SSH key authentication:

   ```bash
   sudo scripts/1-bootstrap.sh
   ```

3. **Secure & harden the server**

   As the newly created user (or root), disable password login and run the Ansible hardening playbook:

   ```bash
   sudo scripts/2-harden.sh
   ```

4. **Install Docker & Compose plugin**

   Execute:

   ```bash
   sudo scripts/3-docker-install.sh
   ```

   This will remove any old Docker packages, add Docker’s official repository, install Docker Engine, CLI, containerd, and the Compose plugin, and add your user to the `docker` group.

5. **Configure automated Planka backups**

   - Copy `.env.example` to `.env` and fill in your Backblaze B2 & Restic variables:

     ```bash
     cp .env.example .env
     # Edit .env: set B2_ACCOUNT_ID, B2_ACCOUNT_KEY, RESTIC_REPOSITORY, RESTIC_PASSWORD
     ```

   - Run the backup setup script:

     ```bash
     sudo scripts/4-planka-backup-setup.sh
     ```

   This will:

   - Persist credentials to `/etc/planka-backup.env`
   - Install Restic (if missing)
   - Initialize the Restic repo (if needed)
   - Generate the backup script at `/usr/local/bin/planka-backup.sh`
   - Install an hourly cron job at `/etc/cron.d/planka-backup`

6. **Launch services with Docker Compose**

   Bring up Caddy, Planka, and any other containers:

   ```bash
   docker compose -f compose.yml up -d
   ```

   - Caddy will handle TLS and reverse proxy for your services.
   - Planka will be available on the configured domain.

## Customization

- **Caddy configuration**: edit `containers/caddy/compose.yml` and the accompanying `Caddyfile` in that directory.
- **Planka settings**: adjust environment variables and volumes in `containers/planka/compose.yml`.
- **Hardening playbook**: modify `ansible/hardening.yml` as desired.

## Cleanup & Maintenance

- To view backup logs:

  ```bash
  tail -f /var/log/planka-backup.log
  ```

- To manually run a backup:

  ```bash
  sudo /usr/local/bin/planka-backup.sh
  ```

- To update scripts, pull the latest changes and re-run the relevant scripts as needed.

## Troubleshooting

- **SSH issues**: ensure your SSH public key was correctly entered in step 1.
- **Ansible errors**: verify environment variables for MSMTP are set in `../.env` when running script 2.
- **Docker permission denied**: confirm your user is in the `docker` group (`newgrp docker`).
- **Restic failures**: check that your B2 credentials and repository path are correct in `.env`.

---

*Maintained by the MCH Ops Team*

