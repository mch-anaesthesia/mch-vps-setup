#!/usr/bin/env bash
set -euo pipefail

echo "[+] Disabling root login & password auth"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh

echo "[+] Installing Ansible & Git"
apt update
apt install -y software-properties-common
add-apt-repository --yes --update ppa:ansible/ansible
apt install -y ansible git
echo "[+] Installing devsec.hardening collection"
ansible-galaxy collection install devsec.hardening

echo "[+] Running Ansible hardening playbook"
set -o allexport
source ../.env # set $MSMTP_PASSWORD, $MSMTP_USER
set +o allexport
ANSIBLE_HOST_KEY_CHECKING=False
ansible-playbook -i localhost, ../ansible/hardening.yml -c local

echo "[✓] Hardening complete."
