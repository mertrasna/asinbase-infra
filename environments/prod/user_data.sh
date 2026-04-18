#!/bin/bash
set -euxo pipefail
exec > /var/log/user-data.log 2>&1

echo "=== User data started at $(date) ==="

# --- 1. System update ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

# --- 2. Base tools ---
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  git \
  unzip \
  ufw \
  fail2ban \
  unattended-upgrades

# --- 3. Docker (official repo) ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

# Let 'ubuntu' run docker without sudo
usermod -aG docker ubuntu

# Docker log rotation (keeps disk from filling up)
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
systemctl restart docker

# --- 4. AWS CLI v2 ---
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

# --- 5. nginx ---
apt-get install -y nginx
systemctl enable --now nginx
echo "<h1>Dev server ready - deploy your app</h1>" > /var/www/html/index.html

# --- 6. Firewall (defense in depth, SG is primary) ---
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# --- 7. fail2ban ---
systemctl enable --now fail2ban

# --- 8. Unattended security upgrades ---
dpkg-reconfigure -f noninteractive unattended-upgrades

# --- 9. App directory + fetch SSM params into .env ---
mkdir -p /opt/myapp
chown ubuntu:ubuntu /opt/myapp

REGION="eu-central-1"  # adjust to your region

aws ssm get-parameters-by-path \
  --path "/dev/backend/" \
  --with-decryption \
  --region "$REGION" \
  --query "Parameters[*].[Name,Value]" \
  --output text 2>/dev/null | \
while IFS=$'\t' read -r name value; do
  key=$(basename "$name" | tr '[:lower:]' '[:upper:]')
  echo "${key}=${value}"
done > /opt/myapp/.env || echo "# No SSM params yet" > /opt/myapp/.env

chmod 600 /opt/myapp/.env
chown ubuntu:ubuntu /opt/myapp/.env

echo "=== User data finished at $(date) ==="