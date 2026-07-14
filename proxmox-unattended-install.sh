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

# MySQL-gegevens worden tijdens de installatie in de PHP-installer
# (http://<container-ip>/install/) ingevoerd, dus hier niet meer vragen.

POST_INSTALL_HOST="/root/supdeck-post-install.sh"
POST_INSTALL_CT="/root/supdeck-post-install.sh"

cat > "$POST_INSTALL_HOST" <<POSTEOF
#!/usr/bin/env bash
set -euo pipefail

rm -f /etc/apt/sources.list.d/pve-enterprise.sources
rm -f /etc/apt/sources.list.d/pve-enterprise.list
rm -f /etc/apt/sources.list.d/ceph.sources
rm -f /etc/apt/sources.list.d/ceph.list

apt update

apt install -y apache2 git unzip curl sudo cron \\
php php-cli php-mysql php-mbstring php-curl php-xml libapache2-mod-php

a2enmod rewrite

echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
a2enconf servername

rm -rf /var/www/supdeck

git clone -b "$BRANCH" "https://$GITHUB_USER:$GITHUB_TOKEN@github.com/$REPO.git" /var/www/supdeck

mkdir -p /var/www/supdeck/storage/logs /var/www/supdeck/config

# Rechten voor installer, storage én in-app updater
# Hele map eigendom van www-data zodat de installer en in-app updater
# overal kunnen schrijven (git-operaties, updates, config).
chown -R www-data:www-data /var/www/supdeck
chmod -R 775 /var/www/supdeck/storage /var/www/supdeck/config

# Git safe-directory voor root én www-data
git config --global --add safe.directory /var/www/supdeck || true
sudo -u www-data git config --global --add safe.directory /var/www/supdeck || true

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
# Supdeck achtergrondtaak (als www-data).
PATH=/usr/bin:/bin
* * * * * www-data php /var/www/supdeck/scripts/process-outbox.php >> /var/www/supdeck/storage/logs/outbox.log 2>&1
CRON
chmod 0644 /etc/cron.d/supdeck

cat > /root/supdeck-db-info.txt <<EOF
Open (hier voer je de MySQL-gegevens in):
http://<container-ip>/install/

Na installatie uitvoeren:
rm -rf /var/www/supdeck/public/install

Handmatig updaten:
update-supdeck
EOF

rm -f /root/supdeck-post-install.sh
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

echo "Post-install script naar container kopiëren..."
pct push "$CTID" "$POST_INSTALL_HOST" "$POST_INSTALL_CT" --perms 700

echo "Post-install uitvoeren in container..."
pct exec "$CTID" -- bash "$POST_INSTALL_CT"

rm -f "$POST_INSTALL_HOST"

CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
CT_IP="${CT_IP:-<container-ip>}"

echo
echo "=========================================================="
echo " Supdeck is geïnstalleerd in container $CTID!"
echo "=========================================================="
echo
echo " Wat moet je nu doen?"
echo
echo " Open in je browser de installer:"
echo
echo "      http://${CT_IP}/install/"
echo
echo "    Hier vul je de MySQL-gegevens (host, database,"
echo "    gebruiker, wachtwoord) in en rond je de installatie af."
echo
echo " Handmatig updaten kan later met:"
echo
echo "      pct exec $CTID -- update-supdeck"
echo "=========================================================="
