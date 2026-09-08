#!/bin/bash
# Hardening + Coolify bootstrap, rendered by Terraform's templatefile().
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# --- 1. System Update & Dependencies ---------------------------------------
apt-get update
apt-get upgrade -y
apt-get install -y curl git ufw jq ca-certificates

# --- 2. Swapfile Setup (4GB swap for build stability) ----------------------
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl vm.swappiness=10
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
fi

# --- 3. Kernel Hardening & TCP Tuning --------------------------------------
cat <<'SYSCTL' >> /etc/sysctl.conf

# --- DDoS / SYN flood protection (added by cloud-init) ---
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_rfc1337 = 1
SYSCTL
sysctl -p

# --- 4. Host Firewall (UFW) Configuration -----------------------------------
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8000/tcp
ufw --force enable

# --- 5. Coolify Automated Installation --------------------------------------
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
