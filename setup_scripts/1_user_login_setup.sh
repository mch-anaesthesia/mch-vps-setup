#!/usr/bin/env bash
set -euo pipefail

read -rp "Enter the new sudo username: " NEW_USER
read -rp "Paste your SSH public key (openssh format): " SSH_PUB_KEY

echo "[+] Creating user: $NEW_USER"
adduser --disabled-password --gecos "" "$NEW_USER"
usermod -aG sudo "$NEW_USER"

echo "[+] Granting $NEW_USER passwordless sudo"
# create a sudoers snippet
cat > /etc/sudoers.d/010_${NEW_USER}_nopasswd <<EOF
${NEW_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/010_${NEW_USER}_nopasswd

echo "[+] Setting up SSH key for $NEW_USER"
USER_HOME="/home/$NEW_USER"
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
echo "$SSH_PUB_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"

cat <<EOF

[✓] Bootstrap complete.

→ Test SSH & Docker before proceeding:

    ssh $NEW_USER@<your-server-ip>
    docker run hello-world

EOF
