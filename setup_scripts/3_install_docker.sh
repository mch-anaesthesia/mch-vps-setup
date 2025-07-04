#!/usr/bin/env bash
set -euo pipefail

echo "[+] Installing Docker Engine & Compose plugin"

# 1) Install prerequisites
apt-get update
apt-get install -y ca-certificates curl

# 2) Add Docker’s official GPG key (ASCII-armored)

install -m0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# 3) Add the Docker APT repository
echo \
  "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.asc] \
   https://download.docker.com/linux/ubuntu \
   $(. /etc/os-release && echo \$VERSION_CODENAME) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 4) Install Docker packages
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin

# Ensure the 'docker' group exists (won't error if it already does)
if ! getent group docker >/dev/null; then
  groupadd docker
fi

# Add your user to it so they can run Docker without sudo
USER_TO_ADD="${SUDO_USER:-$(whoami)}"
usermod -aG docker "$USER_TO_ADD"