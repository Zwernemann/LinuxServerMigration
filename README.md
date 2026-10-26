# LinuxServerMigration

Vollautomatischer Umzug eines **Amazon Linux AMI 2018.03**- oder
**Amazon Linux 2**-Servers mit **Apache, PHP und MySQL/MariaDB** auf
**Amazon Linux 2023**.

Das Skript läuft auf dem **neuen** Server, holt sich per SSH und rsync alles
vom alten Server und baut die Umgebung dort neu auf. Der alte Server wird
dabei nur gelesen. Es wird also kein In-Place-Upgrade gemacht, und er bleibt
für einen Rückweg unverändert.

```
 alter Server (AL 2018.03 / AL2)          neuer Server (AL2023)
 ┌──────────────────────────┐   SSH/rsync  ┌──────────────────────────────┐
 │ Apache 2.2/2.4 + mod_php │ ───────────► │ Apache 2.4 + PHP-FPM 8.x     │
 │ PHP 5.x / 7.x            │              │ MariaDB 10.x / MySQL 8.4     │
 │ MySQL 5.5 / 5.6 / 5.7    │              │ systemd, dnf                 │
 └──────────────────────────┘              └──────────────────────────────┘
                                ./migrate.sh all  →  ./migrate.sh cutover
```

## Unterstützte Quellsysteme

| Quelle | Hinweise |
|---|---|
| **Amazon Linux AMI 2018.03** | SysV-Init, MySQL 5.5–5.7, PHP 5.x/7.x, Apache 2.2 oder 2.4. |
| **Amazon Linux 2** | systemd, MariaDB 5.5/10.x (`amazon-linux-extras`) oder MySQL 5.7/8.0. PHP aus `amazon-linux-extras` oder den Remi-Repos, auch als Software Collection unter `/opt/remi/phpXX`. Systembenutzer (UID < 1000) werden erkannt und nicht übernommen. Der SSM-Agent ist vorinstalliert, deshalb klappt die Einrichtung mit `provision-target.sh` meist vollautomatisch. |

Grenzen:
- **MySQL-8-Benutzer mit `caching_sha2_password`** (Standard bei MySQL 8.0)
  lassen sich nicht nach MariaDB übernehmen. Das Tool meldet sie, und ihr
  Passwort muss auf dem Ziel neu gesetzt werden. Alternativ als Ziel
  `TARGET_DB_ENGINE="mysql84"` wählen.
- **PHP-Version:** AL2023 bietet PHP 8.2, 8.3 und 8.4. PHP 8.2 bekommt nur
  noch bis Ende 2026 Sicherheitsupdates; für neue Umzüge ist **8.3 oder 8.4**
  die bessere Wahl (`TARGET_PHP_VERSION`).

## Was automatisch passiert

| Bereich | Was das Tool macht |
|---|---|
| **Analyse** | Versionen, PHP-Module, php.ini-Werte, VirtualHosts, Datenbanken, Benutzer und Cronjobs ermitteln. Mit `rpm -V` werden alle Konfigurationsdateien gefunden, die selbst angelegt oder geändert wurden. |
| **Pakete** | Apache, mod_ssl und PHP-FPM in der gewünschten Version werden installiert. Jedes PHP-Modul der Quelle wird dem passenden AL2023-Paket zugeordnet. Fehlende Module (redis, apcu, zip, imagick, …) werden per PECL gebaut. |
| **Datenbank** | Jede Datenbank wird mit `mysqldump` exportiert, inklusive Routinen, Triggern, Events und Views. MySQL-Benutzer kommen **mit ihren bisherigen Passwort-Hashes** mit, Anwendungen brauchen also keine neuen Zugangsdaten. Übernommen werden auch Rechte, `sql_mode`, Zeichensatz und `max_allowed_packet`. Am Ende werden die Zeilenzahlen aller Tabellen verglichen. |
| **Apache** | VirtualHosts, `<Directory>`-Blöcke, SSL-VHosts und zusätzliche Ports werden übernommen. **2.2→2.4:** `Order/Allow/Deny` wird zu `Require`, `NameVirtualHost`, `SSLMutex` und die SSLv2-Einstellungen fallen weg. Danach läuft ein Konfigurationstest. |
| **PHP-FPM** | `php_value`/`php_flag` aus VirtualHosts und `.htaccess` würden unter PHP-FPM einen *500-Fehler* verursachen. Sie werden deshalb in `.user.ini` verschoben, und `.user.ini` wird für den Webzugriff gesperrt. Werte aus der alten php.ini landen in `/etc/php.d/99-migrated.ini`. |
| **Alter Code** | Code, der noch `mysql_*` verwendet (in PHP 7 entfernt), läuft über eine mitgelieferte Kompatibilitätsschicht auf mysqli-Basis unverändert weiter (`tools/mysql-compat.php`). Dateien mit `.php3`/`.php4`/`.php5`/`.phtml` werden weiter von PHP ausgeführt. Liegengebliebene Kopien wie `x.php.bak`, `x.php3_notUsed`, `*.inc` oder `*.sql` würden als Text ausgeliefert, mitsamt Passwörtern; sie werden für den Webzugriff gesperrt. |
| **PHP 8** | Der Code wird nach Funktionen durchsucht, die es nicht mehr gibt (`mysql_*`, `ereg`, `each()`, `create_function`, `$str{0}` …). Zusätzlich prüft `php -l` alle Dateien auf Syntaxfehler. |
| **Dateien** | Webverzeichnisse und alle DocumentRoots, `/home`, SSL-Zertifikate und `/etc/letsencrypt` werden kopiert. Beim Cutover werden nur noch die Änderungen übertragen. |
| **System** | Linux-Benutzer und Gruppen werden mit UID/GID und Passwort übernommen, dazu Crontabs, eigene `/etc/cron.d`- und logrotate-Dateien sowie die Zeitzone. Läuft auf der Quelle ein Mailserver, wird postfix installiert. certbot wird eingerichtet. |
| **Prüfung** | Dienste, Konfigurationstest, Dateiabgleich, Zeilenzahlen, HTTP-Status jedes VirtualHosts (Quelle und Ziel im Vergleich) und PHP-Fehlerlogs werden geprüft. Ergebnis: Bericht `report.md`. |
| **Cutover** | Apache und cron auf der Quelle werden gestoppt, Dateien und Datenbanken ein letztes Mal synchronisiert, das Ziel geprüft und die Elastic IP umgehängt. `rollback` macht das rückgängig. |

## Schnellstart

> **Ausführliche Anleitung für Einsteiger:** [docs/ANLEITUNG.md](docs/ANLEITUNG.md).
> Sie erklärt Schritt für Schritt, wer was macht, wie du auf die Server
> kommst und wo das MySQL-Passwort steht.

### Empfohlen: alles aus der AWS CloudShell

```bash
# AWS-Konsole -> CloudShell-Symbol >_ (Region des alten Servers)
git clone https://github.com/Zwernemann/LinuxServerMigration.git
cd LinuxServerMigration
bash aws/provision-target.sh --old-instance i-0abc123def4567890
```

Das Skript legt den neuen AL2023-Server neben dem alten an (gleiches
Netzwerk, gleiche Security Groups, gleiches Schlüsselpaar) und installiert
das Tool. Außerdem richtet es den SSH-Zugang zum alten Server ein und
erstellt die `migration.conf` vor. Danach geht es mit
[Schritt 4](#4-migration-durchführen-der-alte-server-läuft-weiter) weiter;
am neuen Server meldest du dich im Browser über den Session Manager an.

### Manuell

#### 1. Neuen Server anlegen

Eine EC2-Instanz mit **Amazon Linux 2023** im selben VPC starten. In der
Security Group des **alten** Servers SSH (Port 22) vom neuen Server erlauben.

#### 2. SSH-Zugang vom neuen zum alten Server

Auf dem **neuen** Server:

```bash
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/migration_key
sudo cat /root/.ssh/migration_key.pub
```

Den ausgegebenen Schlüssel auf dem **alten** Server bei `ec2-user` eintragen:

```bash
echo 'ssh-ed25519 AAAA... root@neu' >> ~/.ssh/authorized_keys
```

`ec2-user` braucht auf der Quelle `sudo` ohne Passwort. Das ist bei Amazon
Linux Standard; `preflight` prüft es und sagt, was zu tun ist, falls nicht.

#### 3. Tool holen und konfigurieren

```bash
sudo dnf -y install git
git clone https://github.com/zwernemann/linuxservermigration.git
cd linuxservermigration
cp migration.conf.example migration.conf
vi migration.conf         # mindestens SRC_HOST und SRC_DB_PASS setzen
```

Die wichtigsten Einstellungen:

| Variable | Bedeutung |
|---|---|
| `SRC_HOST` | **Private** IP des alten Servers |
| `SRC_DB_PASS` | MySQL-root-Passwort der Quelle (leer = `/root/.my.cnf` dort) |
| `TARGET_PHP_VERSION` | `8.2`, `8.3` oder `8.4` |
| `TARGET_DB_ENGINE` | `mariadb` (empfohlen, aus den AL2023-Repos) oder `mysql84` |
| `ELASTIC_IP_ALLOCATION_ID` | optional: Elastic IP beim Cutover automatisch umhängen |

### 4. Migration durchführen (der alte Server läuft weiter)

```bash
sudo ./migrate.sh all
```

`all` führt nacheinander `preflight inventory install users files database
configure verify` aus. Jede Phase kann auch einzeln und **beliebig oft**
wiederholt werden, z.B. `sudo ./migrate.sh files database`.

Danach den Bericht lesen:

```bash
less /var/lib/server-migration/report.md          # Ergebnis + alle Warnungen
less /var/lib/server-migration/php8-compat.md     # PHP-8-Probleme im Code
```

### 5. Testen, bevor umgeschaltet wird

Auf dem **eigenen PC** die Domain per `hosts`-Datei auf die IP des neuen
Servers zeigen lassen, die Website durchklicken und Formulare, Logins sowie
Uploads testen:

```
# Linux/macOS: /etc/hosts   Windows: C:\Windows\System32\drivers\etc\hosts
203.0.113.50   www.example.com example.com
```

Probleme beheben (siehe unten) und `sudo ./migrate.sh files database verify`
so oft wiederholen wie nötig.

### 6. Umschalten

```bash
sudo ./migrate.sh cutover
```

Die Website ist dabei nur so lange nicht erreichbar, wie der letzte Abgleich
der Änderungen dauert, meist wenige Minuten. Ohne `ELASTIC_IP_ALLOCATION_ID`
danach den DNS-A-Record auf den neuen Server ändern. Tipp: die DNS-TTL einen
Tag vorher auf 300 Sekunden senken.

Falls etwas schiefgeht:

```bash
sudo ./migrate.sh rollback    # Quelle wieder starten, Elastic IP zurück
```

Den alten Server nach dem Umzug einige Tage **gestoppt** aufbewahren (vorher
ein AMI erstellen) und erst danach terminieren.

## Was manuell geprüft werden muss

Das Tool meldet all das als Warnung im Bericht:

- **PHP-Code, der unter PHP 8 nicht mehr läuft.** Der häufigste Fall bei
  alten Anwendungen sind `mysql_*`-Funktionen; dann muss der Code auf
  `mysqli`/PDO umgestellt werden. Liste: `php8-compat.md`.
- **Zusätzliche Dienste** wie memcached, redis, vsftpd oder fail2ban werden
  erkannt und gemeldet, aber nicht migriert.
- **Eigene sudo-Regeln** in `/etc/sudoers.d` werden bewusst nicht übernommen.
- **Komplexe Apache-Zugriffsregeln** mit `Satisfy` bleiben in der alten
  Syntax. Sie funktionieren dank `mod_access_compat` weiter.
- **Cronjobs mit `service …`** sollten auf `systemctl` umgestellt werden.
- **Apache-Module**, die auf AL2023 fehlen, werden aufgelistet.
- **Größe der Instanz:** `innodb_buffer_pool_size` wird nicht übernommen,
  weil der neue Server meist anders dimensioniert ist.

## Häufige Probleme

| Symptom | Ursache / Lösung |
|---|---|
| 500-Fehler, im Log `Invalid command 'php_value'` | Eine `.htaccess` außerhalb der Webpfade enthält noch `php_value`. Lösung: `tools/php-to-userini.sh htaccess <datei>` |
| Leere Seite, im Log `Call to undefined function mysql_connect()` | Der Code nutzt das entfernte ext/mysql und muss angepasst werden (siehe `php8-compat.md`) |
| `Access denied` für einen DB-Benutzer | Der Benutzer hatte auf der Quelle einen Hash von vor MySQL 4.1 oder kein Passwort (siehe Warnung). Lösung: `ALTER USER … IDENTIFIED BY '…'` |
| Konfigurationstest von Apache schlägt fehl | Die Meldung zeigt Datei und Zeile. `/etc/httpd/conf.d/migrated-*.conf` korrigieren, dann `./migrate.sh configure`. Von Hand geänderte Dateien werden nicht überschrieben. |
| SSH: `sudo: a password is required` / `requiretty` | Auf der Quelle: `echo 'Defaults:ec2-user !requiretty' \| sudo tee /etc/sudoers.d/99-migration` |

## Aufbau

```
migrate.sh                  Steuerung (Phasen, Logging, Fehlerbehandlung)
migration.conf.example      alle Einstellungen mit Erklärung
lib/common.sh               SSH/rsync, Logging, Paket- und DB-Helfer
lib/phases/*.sh             eine Datei je Phase
remote/*.sh                 laufen auf dem alten Server (bash 4.2-kompatibel)
tools/
  apache24-convert.sh       Order/Allow/Deny  ->  Require   (auch einzeln nutzbar)
  apache-migrate-config.sh  httpd.conf/ssl.conf/VHosts für 2.4 + PHP-FPM aufbereiten
  php-to-userini.sh         php_value/php_flag  ->  .user.ini
  php8-compat-scan.sh       PHP-5/7-Code auf PHP-8-Probleme prüfen
tests/                      Tests (siehe tests/README.md)
```

Arbeitsverzeichnis auf dem Ziel: `/var/lib/server-migration`, nur für root
lesbar. Es enthält Inventar, Konfigurations-Schnappschuss, Dumps und Bericht.
Log: `/var/log/server-migration/`.

Nach der Migration das Arbeitsverzeichnis löschen. Es enthält
Datenbank-Dumps und eine Kopie von `/etc/shadow`:
`sudo rm -rf /var/lib/server-migration`

## Sicherheit

- Auf dem alten Server wird nichts verändert. Ausnahme: `cutover` stoppt dort
  Apache und cron, `rollback` startet sie wieder.
- Passwörter werden nicht auf der Kommandozeile übergeben (nicht in `ps`
  sichtbar), sondern in temporären Dateien mit Modus 600, die danach
  gelöscht werden.
- `migration.conf` enthält Passwörter und ist per `.gitignore` vom
  Repository ausgeschlossen.
