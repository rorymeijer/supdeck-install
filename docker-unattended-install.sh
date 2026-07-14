#!/usr/bin/env bash
set -euo pipefail

APP_NAME="supdeck"
APP_DIR="/srv/docker/supdeck"
REPO="rorymeijer/Supdeck"
BRANCH="main"
PORT="8100"

echo "GitHub authenticatie voor private repo:"
read -r -p "GitHub username: " GITHUB_USER
read -r -s -p "GitHub token: " GITHUB_TOKEN
echo

# Supdeck heeft geen web-installer: de database wordt hier ingericht.
# Er wordt gebruikgemaakt van een bestaande externe MySQL/MariaDB-server.
echo
echo "Gegevens van de externe MySQL/MariaDB-database:"
read -r -p "MySQL host [127.0.0.1]: " DB_HOST
DB_HOST="${DB_HOST:-127.0.0.1}"
read -r -p "MySQL poort [3306]: " DB_PORT
DB_PORT="${DB_PORT:-3306}"
read -r -p "Databasenaam [supdeck]: " DB_NAME
DB_NAME="${DB_NAME:-supdeck}"
read -r -p "Databasegebruiker [supdeck]: " DB_USER
DB_USER="${DB_USER:-supdeck}"
read -r -s -p "Databasewachtwoord: " DB_PASS
echo

apt update
apt install -y git curl ca-certificates openssl default-mysql-client

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

mkdir -p "$APP_DIR"
cd "$APP_DIR"

rm -rf app

git clone -b "$BRANCH" "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${REPO}.git" app

# --- Configuratie genereren -------------------------------------------------
# Supdeck laadt config/config.php (een array). We genereren die met de opgegeven
# databasegegevens, een verse APP_KEY en de juiste APP_URL.
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SERVER_IP="${SERVER_IP:-127.0.0.1}"
APP_URL="http://${SERVER_IP}:${PORT}"
APP_KEY="base64:$(openssl rand -base64 32)"

# Escapen voor PHP single-quoted strings (\ en ').
php_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }
DB_HOST_ESC="$(php_esc "$DB_HOST")"
DB_NAME_ESC="$(php_esc "$DB_NAME")"
DB_USER_ESC="$(php_esc "$DB_USER")"
DB_PASS_ESC="$(php_esc "$DB_PASS")"
APP_URL_ESC="$(php_esc "$APP_URL")"
APP_KEY_ESC="$(php_esc "$APP_KEY")"

cat > app/config/config.php <<EOF
<?php

declare(strict_types=1);

/**
 * Supdeck — applicatieconfiguratie (gegenereerd door supdeck-install).
 */

return [
    'app' => [
        'name'     => 'Supdeck',
        'env'      => 'production',
        'debug'    => false,
        'url'      => '${APP_URL_ESC}',
        'timezone' => 'Europe/Amsterdam',
        'locale'   => 'nl',
        'locales'  => ['nl', 'en'],
        'key'      => '${APP_KEY_ESC}',
    ],

    'sso' => [
        'entra'    => ['issuer' => '', 'client_id' => '', 'client_secret' => ''],
        'okta'     => ['issuer' => '', 'client_id' => '', 'client_secret' => ''],
        'keycloak' => ['issuer' => '', 'client_id' => '', 'client_secret' => ''],
    ],

    'tenant' => [
        'default_id' => 1,
    ],

    'db' => [
        'host'    => '${DB_HOST_ESC}',
        'port'    => ${DB_PORT},
        'socket'  => '',
        'name'    => '${DB_NAME_ESC}',
        'user'    => '${DB_USER_ESC}',
        'pass'    => '${DB_PASS_ESC}',
        'charset' => 'utf8mb4',
    ],

    'session' => [
        'lifetime' => 60,
    ],

    'mail' => [
        'transport'  => 'log',
        'from'       => 'no-reply@supdeck.local',
        'from_name'  => 'Supdeck',
        'host'       => '',
        'port'       => 587,
        'user'       => '',
        'pass'       => '',
        'encryption' => 'tls',
    ],
];
EOF

# --- Database inrichten -----------------------------------------------------
export MYSQL_PWD="$DB_PASS"
MYSQL=(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER")

# Database aanmaken indien nog niet aanwezig (vereist voldoende rechten).
"${MYSQL[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true

TBL="$("${MYSQL[@]}" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")" || {
  echo "FOUT: kan geen verbinding maken met de database (${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME})."
  exit 1
}

if [ "${TBL:-0}" -eq 0 ]; then
  echo "Schema laden..."
  "${MYSQL[@]}" "$DB_NAME" < app/database/sql/schema.sql
  echo "Voorbeelddata (incl. demo-accounts) laden..."
  "${MYSQL[@]}" "$DB_NAME" < app/database/sql/seed.sql
else
  echo "Database bevat al ${TBL} tabel(len); schema/seed niet opnieuw geladen."
fi
unset MYSQL_PWD

# --- Docker-image en compose ------------------------------------------------
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

RUN chown -R www-data:www-data /var/www/html/storage /var/www/html/config /var/www/html/public/uploads \
    && chmod -R 775 /var/www/html/storage /var/www/html/config /var/www/html/public/uploads
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
      - ./uploads:/var/www/html/public/uploads
EOF

mkdir -p storage config uploads
mkdir -p storage/app/mail storage/logs storage/cache storage/backups storage/scheduler

cp -a app/config/* config/
cp -a app/public/uploads/. uploads/ 2>/dev/null || true

chown -R 33:33 storage config uploads
chmod -R 775 storage config uploads

docker compose up -d --build

# --- Achtergrondtaak: cron op de host, uitgevoerd in de container -----------
apt install -y cron
systemctl enable --now cron

cat > /etc/cron.d/supdeck <<'CRON'
# Supdeck achtergrondtaak. Draait in de supdeck-container als www-data.
PATH=/usr/local/bin:/usr/bin:/bin
* * * * * root docker exec -u www-data supdeck php /var/www/html/scripts/process-outbox.php >> /var/log/supdeck-outbox.log 2>&1
CRON
chmod 0644 /etc/cron.d/supdeck

unset GITHUB_TOKEN

echo
echo "=========================================================="
echo " Supdeck Docker-container draait!"
echo "=========================================================="
echo
echo " Open in je browser:"
echo
echo "      ${APP_URL}/"
echo
echo " Log in met een demo-account (wachtwoord: Welkom2026!):"
echo "      coordinator@demo.nl   Coördinator + Behandelaar"
echo "      agent@demo.nl         Behandelaar"
echo "      melder@demo.nl        Melder (self-service portaal)"
echo "      beheer@demo.nl        Beheerder"
echo
echo " De achtergrondtaak (e-mailmeldingen) draait via cron op de"
echo " host (/etc/cron.d/supdeck)."
echo "=========================================================="
