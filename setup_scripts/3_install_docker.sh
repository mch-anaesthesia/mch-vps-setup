#!/usr/bin/env bash
set -euo pipefail

echo "[+] Removing old Docker versions"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do apt-get remove -y $pkg; done

echo "[+] Installing Docker Engine & Compose plugin"

# Add Docker's official GPG key:
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# 2) Capture variables
ARCH="$(dpkg --print-architecture)"         # e.g. amd64
CODENAME="$(lsb_release -cs)"               # e.g. jammy

# 3) Drop in the Docker repo with clean expansion
cat <<EOF | tee /etc/apt/sources.list.d/docker.list >/dev/null
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
${CODENAME} stable
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Ensure the 'docker' group exists (won't error if it already does)
if ! getent group docker >/dev/null; then
  groupadd docker
fi

# Add your user to it so they can run Docker without sudo
USER_TO_ADD="${SUDO_USER:-$(whoami)}"
usermod -aG docker "$USER_TO_ADD"