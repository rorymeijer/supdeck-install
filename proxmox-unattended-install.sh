#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="supdeck"
CPU="2"
RAM="2048"
DISK="20"
BRIDGE="vmbr0"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"

REPO="rorymeijer/Supdeck"
BRANCH="main"

echo "GitHub authenticatie voor private repo:"
read -r -p "GitHub username: " GITHUB_USER
read -r -s -p "GitHub token: " GITHUB_TOKEN
echo

# Supdeck heeft geen web-installer: de database wordt tijdens de installatie
# ingericht op een bestaande externe MySQL/MariaDB-server.
echo
echo "Gegevens van de externe MySQL/MariaDB-database:"
read -r -p "MySQL host: " DB_HOST
read -r -p "MySQL poort [3306]: " DB_PORT
DB_PORT="${DB_PORT:-3306}"
read -r -p "Databasenaam [supdeck]: " DB_NAME
DB_NAME="${DB_NAME:-supdeck}"
read -r -p "Databasegebruiker [supdeck]: " DB_USER
DB_USER="${DB_USER:-supdeck}"
read -r -s -p "Databasewachtwoord: " DB_PASS
echo

CONFIG_HOST="/root/supdeck-config.php"
DBPASS_HOST="/root/supdeck-dbpass"
POST_INSTALL_HOST="/root/supdeck-post-install.sh"
CONFIG_CT="/root/supdeck-config.php"
DBPASS_CT="/root/supdeck-dbpass"
POST_INSTALL_CT="/root/supdeck-post-install.sh"

# --- config.php genereren op de host (APP_URL als placeholder) ---------------
# Escapen voor PHP single-quoted strings (\ en '). Shell her-expandeert
# ingevulde waarden niet, dus willekeurige wachtwoorden zijn veilig.
php_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }
DB_HOST_ESC="$(php_esc "$DB_HOST")"
DB_NAME_ESC="$(php_esc "$DB_NAME")"
DB_USER_ESC="$(php_esc "$DB_USER")"
DB_PASS_ESC="$(php_esc "$DB_PASS")"
APP_KEY="base64:$(openssl rand -base64 32)"
APP_KEY_ESC="$(php_esc "$APP_KEY")"

cat > "$CONFIG_HOST" <<EOF
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
        'url'      => '__APP_URL__',
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

# Wachtwoord als los bestand (geen shell-parsing) voor het laden van het schema.
printf '%s' "$DB_PASS" > "$DBPASS_HOST"
chmod 600 "$DBPASS_HOST" "$CONFIG_HOST"

# --- Post-install script -----------------------------------------------------
cat > "$POST_INSTALL_HOST" <<POSTEOF
#!/usr/bin/env bash
set -euo pipefail

rm -f /etc/apt/sources.list.d/pve-enterprise.sources
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph.sources
rm -f /etc/apt/sources.list.d/ceph.list

apt update

apt install -y apache2 git unzip curl sudo cron mariadb-client \\
php php-cli php-mysql php-mbstring php-curl php-xml libapache2-mod-php

a2enmod rewrite

echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
a2enconf servername

rm -rf /var/www/supdeck

git clone -b "$BRANCH" "https://$GITHUB_USER:$GITHUB_TOKEN@github.com/$REPO.git" /var/www/supdeck

# Configuratie plaatsen: APP_URL invullen met het container-IP.
IP="\$(hostname -I 2>/dev/null | awk '{print \$1}')"
IP="\${IP:-localhost}"
sed -i "s#__APP_URL__#http://\${IP}#" /root/supdeck-config.php
cp /root/supdeck-config.php /var/www/supdeck/config/config.php

mkdir -p /var/www/supdeck/storage/app/mail \\
         /var/www/supdeck/storage/logs \\
         /var/www/supdeck/storage/cache \\
         /var/www/supdeck/storage/backups \\
         /var/www/supdeck/storage/scheduler \\
         /var/www/supdeck/public/uploads

# Hele map eigendom van www-data zodat de app (en in-app updater) overal kan
# schrijven; storage/config/uploads schrijfbaar.
chown -R www-data:www-data /var/www/supdeck
chmod -R 775 /var/www/supdeck/storage /var/www/supdeck/config /var/www/supdeck/public/uploads

git config --global --add safe.directory /var/www/supdeck || true
sudo -u www-data git config --global --add safe.directory /var/www/supdeck || true

# --- Database inrichten (externe MySQL/MariaDB) ------------------------------
export MYSQL_PWD="\$(cat /root/supdeck-dbpass)"
mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -e "CREATE DATABASE IF NOT EXISTS \\\`$DB_NAME\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || true
TBL="\$(mysql -h $DB_HOST -P $DB_PORT -u $DB_USER -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';")" || {
  echo "FOUT: kan geen verbinding maken met de database ($DB_USER@$DB_HOST:$DB_PORT/$DB_NAME)."
  exit 1
}
if [ "\${TBL:-0}" -eq 0 ]; then
  echo "Schema laden..."
  mysql -h $DB_HOST -P $DB_PORT -u $DB_USER "$DB_NAME" < /var/www/supdeck/database/sql/schema.sql
  echo "Voorbeelddata (incl. demo-accounts) laden..."
  mysql -h $DB_HOST -P $DB_PORT -u $DB_USER "$DB_NAME" < /var/www/supdeck/database/sql/seed.sql
else
  echo "Database bevat al \${TBL} tabel(len); schema/seed niet opnieuw geladen."
fi
unset MYSQL_PWD

cat > /etc/apache2/sites-available/supdeck.conf <<'EOF'
<VirtualHost *:80>
    ServerName supdeck.local
    DocumentRoot /var/www/supdeck/public

    <Directory /var/www/supdeck/public>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/supdeck_error.log
    CustomLog \${APACHE_LOG_DIR}/supdeck_access.log combined
</VirtualHost>
EOF

a2dissite 000-default.conf || true
a2ensite supdeck.conf
systemctl enable apache2
systemctl restart apache2

cat > /usr/local/bin/update-supdeck <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd /var/www/supdeck

sudo -u www-data git fetch origin
sudo -u www-data git reset --hard origin/main

chown -R www-data:www-data /var/www/supdeck/storage /var/www/supdeck/config /var/www/supdeck/.git
chmod -R 775 /var/www/supdeck/storage /var/www/supdeck/config
chown -R www-data:www-data /var/www/supdeck

systemctl reload apache2

echo "Supdeck is bijgewerkt."
EOF

chmod +x /usr/local/bin/update-supdeck

systemctl enable --now cron

cat > /etc/cron.d/supdeck <<'CRON'
# Supdeck achtergrondtaak (als www-data): verwerkt de events-outbox (e-mail).
PATH=/usr/bin:/bin
* * * * * www-data php /var/www/supdeck/scripts/process-outbox.php >> /var/www/supdeck/storage/logs/outbox.log 2>&1
CRON
chmod 0644 /etc/cron.d/supdeck

cat > /root/supdeck-info.txt <<EOF
Supdeck draait op:
http://\${IP}/

Demo-accounts (wachtwoord: Welkom2026!):
  coordinator@demo.nl   Coördinator + Behandelaar
  agent@demo.nl         Behandelaar
  melder@demo.nl        Melder (self-service portaal)
  beheer@demo.nl        Beheerder

Handmatig updaten:
update-supdeck
EOF

rm -f /root/supdeck-post-install.sh /root/supdeck-config.php /root/supdeck-dbpass
history -c || true
POSTEOF

chmod +x "$POST_INSTALL_HOST"

echo "Container aanmaken..."

BEFORE_IDS="$(pct list | awk 'NR>1 {print $1}')"

var_unprivileged=1 \
var_cpu="$CPU" \
var_ram="$RAM" \
var_disk="$DISK" \
var_hostname="$HOSTNAME" \
var_os=debian \
var_version=12 \
var_brg="$BRIDGE" \
var_net=dhcp \
var_ipv6_method=none \
var_ssh=yes \
var_nesting=0 \
var_keyctl=1 \
var_tags=supdeck,web,automated \
var_container_storage="$STORAGE" \
var_template_storage="$TEMPLATE_STORAGE" \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh)"

AFTER_IDS="$(pct list | awk 'NR>1 {print $1}')"
CTID="$(comm -13 <(echo "$BEFORE_IDS" | sort) <(echo "$AFTER_IDS" | sort) | tail -n 1)"

if [[ -z "$CTID" ]]; then
  echo "Kon CTID niet automatisch bepalen."
  echo "Gebruik: pct list"
  exit 1
fi

echo "Nieuwe container gevonden: CTID $CTID"

echo "Bestanden naar container kopiëren..."
pct push "$CTID" "$CONFIG_HOST" "$CONFIG_CT" --perms 600
pct push "$CTID" "$DBPASS_HOST" "$DBPASS_CT" --perms 600
pct push "$CTID" "$POST_INSTALL_HOST" "$POST_INSTALL_CT" --perms 700

echo "Post-install uitvoeren in container..."
pct exec "$CTID" -- bash "$POST_INSTALL_CT"

rm -f "$POST_INSTALL_HOST" "$CONFIG_HOST" "$DBPASS_HOST"

CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
CT_IP="${CT_IP:-<container-ip>}"

echo
echo "=========================================================="
echo " Supdeck is geïnstalleerd in container $CTID!"
echo "=========================================================="
echo
echo " Open in je browser:"
echo
echo "      http://${CT_IP}/"
echo
echo " Log in met een demo-account (wachtwoord: Welkom2026!):"
echo "      coordinator@demo.nl   Coördinator + Behandelaar"
echo "      agent@demo.nl         Behandelaar"
echo "      melder@demo.nl        Melder (self-service portaal)"
echo "      beheer@demo.nl        Beheerder"
echo
echo " Handmatig updaten kan later met:"
echo
echo "      pct exec $CTID -- update-supdeck"
echo "=========================================================="
