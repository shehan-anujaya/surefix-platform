#!/bin/bash
# Runs once on the image-builder VM to prepare the base disk image:
# Debian 12 + Temurin JDK 25 + Node.js 22 + PM2 (with systemd startup so PM2 resurrects apps after a reboot).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wget curl gnupg apt-transport-https ca-certificates

# Temurin JDK 25 (Adoptium)
mkdir -p /etc/apt/keyrings
wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release; echo $VERSION_CODENAME) main" \
  > /etc/apt/sources.list.d/adoptium.list
apt-get update
apt-get install -y temurin-25-jdk
java -version

# Node.js 22 + PM2
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g pm2

# Runtime user + directories (apps in /opt/surefix, logs in /var/log/surefix, env in /etc/surefix)
id surefix >/dev/null 2>&1 || useradd -m -s /bin/bash surefix
mkdir -p /opt/surefix /var/log/surefix /etc/surefix
chown -R surefix:surefix /opt/surefix /var/log/surefix /etc/surefix

# PM2 daemon starts on boot for the surefix user and resurrects the saved process list
pm2 startup systemd -u surefix --hp /home/surefix
systemctl enable pm2-surefix

echo SUREFIX_IMAGE_READY
