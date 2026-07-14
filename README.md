# Supdeck Installer

Automatische installatie van **Supdeck** op zowel **Proxmox LXC** als **Docker**.

De installatiescripts downloaden automatisch de laatste versie van Supdeck vanuit GitHub, richten de database in (schema + voorbeelddata) en begeleiden je bij het configureren van een externe MySQL/MariaDB-database.

> **Let op:** De Supdeck-repository is momenteel privé. Tijdens de installatie wordt gevraagd om een GitHub-gebruikersnaam en een Personal Access Token (PAT) met leesrechten op de repository.

---

# Vereisten

## Algemeen

* Internetverbinding
* Een bestaande externe MySQL/MariaDB-server
* Een GitHub Personal Access Token met minimaal **Contents: Read** rechten

## Proxmox

* Proxmox VE 8 of hoger

## Docker

* Linux-server (Debian, Ubuntu of vergelijkbaar)
* Docker Engine
* Docker Compose

> Wanneer Docker nog niet is geïnstalleerd kan het Docker-installatiescript dit automatisch installeren.

---

# Installeren

## Proxmox LXC

Voer op de **Proxmox-host** uit:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rorymeijer/supdeck-install/main/proxmox-unattended-install.sh)"
```

---

## Docker

Voer op de Docker-host uit:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rorymeijer/supdeck-install/main/docker-unattended-install.sh)"
```

---

Tijdens beide installaties wordt gevraagd om:

* GitHub gebruikersnaam
* GitHub Personal Access Token
* MySQL-host
* MySQL-poort
* Databasenaam
* Databasegebruiker
* Databasewachtwoord

---

# Wat installeert het script?

## Proxmox

Het script:

* maakt automatisch een nieuwe Debian LXC-container aan;
* installeert Apache;
* installeert PHP en alle benodigde extensies;
* downloadt Supdeck vanuit GitHub;
* genereert `config/config.php` met de opgegeven databasegegevens;
* laadt het databaseschema en de voorbeelddata (incl. demo-accounts);
* configureert Apache;
* stelt de juiste bestandsrechten in;
* start Apache;
* stelt cron in voor de achtergrondtaak (e-mailnotificaties).

---

## Docker

Het script:

* installeert Docker (indien nodig);
* downloadt Supdeck vanuit GitHub;
* genereert `config/config.php` met de opgegeven databasegegevens;
* laadt het databaseschema en de voorbeelddata (incl. demo-accounts);
* bouwt automatisch de Docker-image;
* maakt een Docker Compose-configuratie aan;
* start de container;
* koppelt configuratie-, opslag- en uploadmappen als volumes;
* stelt cron op de host in voor de achtergrondtaak (e-mailnotificaties).

---

# Achtergrondtaken

Beide installers stellen automatisch cron in voor de Supdeck-achtergrondtaak:

* **process-outbox** – verwerkt de events-outbox en verstuurt e-mailmeldingen (elke minuut).

Op **Proxmox** draait cron in de container als `www-data`; op **Docker** draait cron op de host en voert de taak via `docker exec` in de container uit. De cron-configuratie staat in `/etc/cron.d/supdeck`.

> **Let op:** het e-mailtransport staat standaard op `log` (berichten worden als `.eml` in `storage/app/mail/` weggeschreven, er wordt niets verzonden). Zet in `config/config.php` het `mail.transport` op `smtp` met de juiste host/gebruiker/wachtwoord om echt te versturen.

---

# Database

Supdeck installeert **geen lokale database**.

Er wordt altijd gebruikgemaakt van een bestaande externe MySQL- of MariaDB-server. Het installatiescript laadt bij een lege database automatisch het schema (`database/sql/schema.sql`) en de voorbeelddata (`database/sql/seed.sql`). Bevat de database al tabellen, dan worden schema en voorbeelddata **niet** opnieuw geladen.

---

# Na de installatie

Open in de browser:

## Proxmox

```text
http://<container-ip>/
```

## Docker

```text
http://<server-ip>:8100/
```

Log in met een demo-account (wachtwoord `Welkom2026!`):

| E-mail | Rol |
| ------------------------- | ---------------------------- |
| `coordinator@demo.nl`     | Coördinator + Behandelaar    |
| `agent@demo.nl`           | Behandelaar                  |
| `melder@demo.nl`          | Melder (self-service portaal)|
| `beheer@demo.nl`          | Beheerder                    |

> **Tip:** verander na de eerste keer inloggen de wachtwoorden van de demo-accounts (of verwijder de accounts die je niet nodig hebt) voordat je Supdeck in productie gebruikt.

---

# Updaten

## Proxmox

Updates kunnen worden uitgevoerd met het meegeleverde commando:

```bash
pct exec <ctid> -- update-supdeck
```

Of handmatig via Git in de container:

```bash
cd /var/www/supdeck
git fetch origin
git reset --hard origin/main
systemctl reload apache2
```

## Docker

Wanneer de Supdeck-map als volume is gekoppeld, kunnen updates handmatig worden uitgevoerd:

```bash
cd /srv/docker/supdeck/app
git fetch origin
git reset --hard origin/main
```

Na een update hoeft de container normaal gesproken niet opnieuw gebouwd te worden zolang alleen de PHP-code is gewijzigd.

---

# GitHub Token

Maak een Personal Access Token aan via:

https://github.com/settings/personal-access-tokens

Minimale rechten:

* Repository access → **Only select repositories**
* Selecteer **Supdeck**
* Permissions:

  * **Contents → Read-only**

---

# Ondersteunde configuraties

| Onderdeel                 | Proxmox | Docker |
| ------------------------- | :-----: | :----: |
| Debian 12                 |    ✅    |    ✅   |
| Apache 2.4                |    ✅    |    ✅   |
| PHP 8.3+                  |    ✅    |    ✅   |
| Externe MySQL/MariaDB     |    ✅    |    ✅   |
| Automatisch schema + seed |    ✅    |    ✅   |
| GitHub Private Repository |    ✅    |    ✅   |

---

# Roadmap

Geplande uitbreidingen:

* In-app updater
* Automatische GitHub-updates
* Docker image via GitHub Container Registry (GHCR)
* SSL-configuratie via Nginx Proxy Manager
* Ondersteuning voor meerdere deployment-profielen
* Back-up- en restorefunctionaliteit
* Eén universeel installatiescript dat automatisch Proxmox of Docker detecteert

---

# Licentie

Zie de licentie in de hoofdrepository van Supdeck.

---

# Hoofdrepository

https://github.com/rorymeijer/Supdeck
