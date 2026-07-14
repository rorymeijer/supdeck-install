#!/usr/bin/env bash
set -euo pipefail

APP_NAME="supdeck"
APP_DIR="/srv/docker/supdeck"
REPO="rorymeijer/Supdeck"
BRANCH="main"
PORT="8181"

echo "GitHub authenticatie voor private repo:"
read -r -p "GitHub username: " GITHUB_USER
read -r -s -p "GitHub token: " GITHUB_TOKEN
echo

# MySQL-gegevens worden tijdens de installatie in de PHP-installer
# (http://<server-ip>:PORT/install/) ingevoerd, dus hier niet meer vragen.

apt update
apt install -y git curl ca-certificates

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

mkdir -p "$APP_DIR"
cd "$APP_DIR"

rm -rf app

git clone -b "$BRANCH" "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${REPO}.git" app

cat > Dockerfile <<'EOF'
FROM php:8.3-apache

RUN apt-get update && apt-get install -y \
    unzip \
    curl \
    git \
    libzip-dev \
    libonig-dev \
    && docker-php-ext-install pdo pdo_mysql mysqli mbstring \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

COPY app/ /var/www/html/

RUN chown -R www-data:www-data /var/www/html/storage /var/www/html/config \
    && chmod -R 775 /var/www/html/storage /var/www/html/config
RUN chown -R www-data:www-data /var/www/html
RUN sed -i 's#/var/www/html#/var/www/html/public#g' /etc/apache2/sites-available/000-default.conf

WORKDIR /var/www/html
EOF

cat > compose.yml <<EOF
services:
  supdeck:
    build: .
    container_name: supdeck
    restart: unless-stopped
    ports:
      - "${PORT}:80"
    volumes:
      - ./storage:/var/www/html/storage
      - ./config:/var/www/html/config
EOF

mkdir -p storage config

cp -a app/config/* config/

chown -R 33:33 storage config
chmod -R 775 storage config

docker compose up -d --build

# --- Achtergrondtaak: cron op de host, uitgevoerd in de container --------
apt install -y cron
systemctl enable --now cron

cat > /etc/cron.d/supdeck <<'CRON'
# Supdeck achtergrondtaak. Draait in de supdeck-container als www-data.
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * root docker exec -u www-data supdeck php /var/www/html/scripts/process-outbox.php >> /var/log/supdeck-outbox.log 2>&1
CRON
chmod 0644 /etc/cron.d/supdeck

unset GITHUB_TOKEN

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-<server-ip>}"

echo
echo "=========================================================="
echo " Supdeck Docker-container draait!"
echo "=========================================================="
echo
echo " Wat moet je nu doen?"
echo
echo " Open in je browser de installer:"
echo
echo "      http://${SERVER_IP}:${PORT}/install/"
echo
echo "    Hier vul je de MySQL-gegevens (host, database,"
echo "    gebruiker, wachtwoord) in en rond je de installatie af."
echo
echo " Achtergrondtaak draait automatisch via cron op de host"
echo " (/etc/cron.d/supdeck)."
echo "=========================================================="
