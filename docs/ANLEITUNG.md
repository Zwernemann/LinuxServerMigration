# Schritt-für-Schritt-Anleitung: Umzug von Amazon Linux 2018 auf 2023

Diese Anleitung setzt **keine Linux-Profikenntnisse** voraus. Alles, was du
brauchst, ist ein Browser und dein AWS-Login.

## Wer macht was?

| Wer | Was | Aufwand |
|---|---|---|
| **Du** | In der AWS-Konsole die CloudShell öffnen und einen Befehl ausführen | 5 Min. |
| `aws/provision-target.sh` | Legt den neuen Server an, installiert das Tool, richtet den Zugang zum alten Server ein | ca. 5 Min., automatisch |
| **Du** | Am neuen Server anmelden (im Browser) und das MySQL-Passwort eintragen | 5 Min. |
| `migrate.sh all` | Überträgt alles: Pakete, Dateien, Datenbanken, Konfiguration. Danach Prüfung und Bericht | 10 Min. bis einige Stunden, je nach Datenmenge |
| **Du** | Die Website auf dem neuen Server testen, ohne dass Besucher etwas merken | so lange du willst |
| `migrate.sh cutover` | Endgültig umschalten. Die Website ist nur wenige Minuten offline | einige Minuten |
| **Du** | Nach ein paar Tagen aufräumen und den alten Server abschalten | 5 Min. |

Der alte Server läuft die ganze Zeit normal weiter, bis du umschaltest. Bis
dahin kannst du jederzeit abbrechen; es wird nichts kaputt gemacht.

---

## Was du vorher wissen musst

1. **Deinen AWS-Login** mit Administratorrechten. Das Skript legt einen
   Server, eine Security Group und eine IAM-Rolle an.
2. **Die Instance-ID des alten Servers.** Du findest sie in der EC2-Konsole
   unter *Instanzen*; sie sieht so aus: `i-0abc123def4567890`.
3. **Das MySQL-root-Passwort des alten Servers.** Weißt du es nicht? Siehe
   [MySQL-Passwort](#mysql-passwort). Oft geht es auch ohne.
4. **Wo deine Domain verwaltet wird** (Route 53 oder ein externer Anbieter).
   Wichtig nur, wenn der alte Server keine Elastic IP hat (siehe
   [Umschalten](#schritt-5-umschalten-cutover)).

---

## Schritt 1: Neuen Server anlegen (AWS CloudShell)

1. In der [AWS-Konsole](https://console.aws.amazon.com/) anmelden.
2. Oben rechts die **Region des alten Servers** wählen, z.B. *Frankfurt*.
3. Oben in der Leiste auf das **CloudShell-Symbol** `>_` klicken. Es öffnet
   sich ein Terminal im Browser, in dem alle AWS-Werkzeuge schon installiert
   und angemeldet sind.
4. Dort eingeben (die Instance-ID durch deine ersetzen):

```bash
git clone https://github.com/Zwernemann/LinuxServerMigration.git
cd LinuxServerMigration
bash aws/provision-target.sh --old-instance i-0abc123def4567890
```

Das Skript zeigt zuerst an, was es vorhat, und fragt nach. Danach:

- Der neue Server bekommt **dasselbe Netzwerk, dieselben Firewall-Regeln
  (Security Groups) und dasselbe Schlüsselpaar** wie der alte. Der Instanztyp
  ist gleich groß, aus der aktuellen Generation (z.B. `t2.small` → `t3.small`).
- Der neue Server bekommt eine Rolle für den **Session Manager**. Damit
  meldest du dich später im Browser an, ganz ohne Schlüsseldatei.
- Über den Session Manager installiert das Skript auf dem neuen Server das
  Tool nach `/opt/linuxservermigration`, außerdem `tmux`. Die Ausgabe siehst
  du direkt in der CloudShell.
- Der alte Server erlaubt SSH-Zugriffe vom neuen Server, aber **nur** von
  diesem.
- Ist der alte Server noch nicht beim Session Manager angemeldet, fragt das
  Skript, ob ihm die Rolle zugewiesen werden soll. Das ist ungefährlich und
  braucht keinen Neustart. Klappt es, hinterlegt das Skript den Zugang zum
  alten Server selbst.
  Sonst zeigt es **einen Befehl**, den du einmal auf dem alten Server
  ausführst (siehe [Zugang zum alten Server](#zugang-zum-alten-server)).

Am Ende stehen die IP-Adressen des neuen Servers und ein Link zum Anmelden.

---

## Schritt 2: Am neuen Server anmelden und konfigurieren

Den Link aus Schritt 1 öffnen, **oder** in der EC2-Konsole den neuen Server
(Name `…-al2023`) anklicken und dann *Verbinden* → *Session Manager* →
*Verbinden* wählen. Es öffnet sich ein Terminal im Browser:

```bash
sudo -i
tmux new -s migration
cd /opt/linuxservermigration
nano migration.conf
```

> **Warum `tmux`?** Bricht die Browser-Verbindung ab, läuft die Migration
> trotzdem weiter. Zurück kommst du mit `sudo -i` und
> `tmux attach -t migration`.

In `migration.conf` ist schon fast alles eingetragen. Prüfen bzw. ergänzen:

```bash
SRC_DB_PASS="dein-mysql-root-passwort"    # leer lassen, wenn es ohne geht
TARGET_PHP_VERSION="8.3"                  # 8.2, 8.3 oder 8.4
```

Speichern mit `Strg+O`, `Enter`, beenden mit `Strg+X`. Dann testen:

```bash
./migrate.sh preflight
```

Hier wird geprüft, ob der neue Server den alten erreicht, ob `sudo` dort
funktioniert und ob das MySQL-Passwort stimmt. Bei einem Problem steht direkt
dabei, was zu tun ist.

---

## Schritt 3: Migration durchführen

```bash
./migrate.sh all
```

Das dauert je nach Datenmenge einige Minuten bis Stunden. Danach den Bericht
ansehen:

```bash
less /var/lib/server-migration/report.md        # Gesamtergebnis und Warnungen (beenden mit q)
less /var/lib/server-migration/php8-compat.md   # Stellen im PHP-Code, die unter PHP 8 Probleme machen
```

Die Migration kann **beliebig oft** wiederholt werden. Hast du z.B. etwas am
alten Server geändert, reicht `./migrate.sh files database`.

---

## Schritt 4: Testen, ohne dass es jemand merkt

Die Domain zeigt noch auf den alten Server. Um den neuen zu testen, leitest
du nur **deinen eigenen PC** per *hosts-Datei* auf den neuen Server um. Für
alle anderen Besucher ändert sich nichts.

**Windows:** Editor *als Administrator* starten und die Datei
`C:\Windows\System32\drivers\etc\hosts` öffnen.
**Mac/Linux:** `sudo nano /etc/hosts`

Diese Zeile hinzufügen (öffentliche IP des **neuen** Servers aus Schritt 1,
deine Domains):

```
3.120.45.67   www.example.com example.com
```

Browser neu starten und die Website gründlich durchklicken: Startseite,
Login, Formulare, Uploads, Mailversand, Adminbereich. Funktioniert alles,
bist du bereit zum Umschalten. **Danach die Zeile wieder entfernen!**

Wenn etwas nicht geht, steht im Fehlerlog des neuen Servers meist die
Ursache:

```bash
tail -50 /var/log/php-fpm/www-error.log
tail -50 /var/log/httpd/error_log
```

Typische Ursachen stehen in der README unter *Häufige Probleme*. Am
häufigsten ist alter PHP-Code (`mysql_connect` usw.), der unter PHP 8
angepasst werden muss.

---

## Schritt 5: Umschalten (Cutover)

Einen ruhigen Zeitpunkt wählen, z.B. abends. Dann auf dem neuen Server:

```bash
sudo -i
tmux attach -t migration      # oder: tmux new -s migration
cd /opt/linuxservermigration
./migrate.sh cutover
```

Das Skript stoppt Apache auf dem alten Server, damit dort niemand mehr Daten
schreibt. Dann überträgt es die letzten Änderungen, prüft den neuen Server und
hängt die **Elastic IP** um.

- **Hat der alte Server eine Elastic IP?** Dann ist die Website danach
  automatisch auf dem neuen Server. Fertig.
- **Keine Elastic IP?** Dann den DNS-Eintrag (A-Record) der Domain beim
  Domain-Anbieter auf die IP des neuen Servers ändern. Vorher am besten dem
  neuen Server eine eigene Elastic IP geben (EC2 → *Elastic IPs* →
  *Elastic IP-Adresse zuweisen* → *Zuordnen*), damit sich seine IP nie ändert.
  Tipp: Die TTL des DNS-Eintrags einen Tag vorher auf 300 Sekunden stellen;
  dann wirkt die Umstellung schneller.

**Etwas geht schief?**

```bash
./migrate.sh rollback
```

Das startet den alten Server wieder und hängt die Elastic IP zurück.

---

## Schritt 6: Aufräumen (nach einigen Tagen)

1. **Backup des alten Servers:** EC2 → alter Server → *Aktionen* → *Image und
   Vorlagen* → *Image erstellen*.
2. Den alten Server **stoppen**, nicht gleich terminieren. Nach ein bis zwei
   Wochen ohne Probleme kann er terminiert werden.
3. In der CloudShell die Migrations-Zugänge entfernen:
   ```bash
   cd LinuxServerMigration
   bash aws/provision-target.sh --old-instance i-0abc123def4567890 --cleanup
   ```
4. Auf dem neuen Server die Arbeitsdaten löschen (sie enthalten
   Datenbank-Dumps):
   ```bash
   sudo rm -rf /var/lib/server-migration
   ```

---

## Problem: `tmux` oder `/opt/linuxservermigration` fehlt

Dann ist die Einrichtung des neuen Servers nicht vollständig durchgelaufen.
Zwei Wege, es nachzuholen:

**a) In der CloudShell** das Skript einfach noch einmal ausführen. Es erkennt
den vorhandenen neuen Server und holt die Einrichtung nach:

```bash
cd LinuxServerMigration && git pull
bash aws/provision-target.sh --old-instance i-0abc123def4567890
```

Hast du den neuen Server selbst angelegt, gib ihn zusätzlich mit
`--new-instance i-…` an.

**b) Direkt auf dem neuen Server** (private IP des alten Servers einsetzen):

```bash
sudo -i
dnf -y install git
git clone https://github.com/Zwernemann/LinuxServerMigration.git /opt/linuxservermigration
/opt/linuxservermigration/aws/setup-target.sh --src-host 172.30.0.12
```

Am Ende wird der Befehl `echo 'ssh-ed25519 …' >> ~/.ssh/authorized_keys`
angezeigt. Ihn einmal auf dem **alten** Server ausführen (siehe nächster
Abschnitt).

Schlägt schon `dnf install` fehl, hat der neue Server keinen Internetzugang.
Dann in der EC2-Konsole prüfen, ob er eine öffentliche IP hat bzw. ob sein
Subnetz über ein Internet- oder NAT-Gateway verfügt.

## Zugang zum alten Server

Normalerweise musst du dich **gar nicht** selbst am alten Server anmelden;
das erledigt das Skript über den Session Manager. Klappt das nicht, zeigt
`provision-target.sh` einen Befehl wie

```bash
echo 'ssh-ed25519 AAAA... linuxservermigration' >> ~/.ssh/authorized_keys
```

Diesen einmal auf dem alten Server ausführen. So kommst du dorthin:

**a) Mit der Schlüsseldatei (`.pem`).** Welcher Schlüssel gemeint ist, steht
in der EC2-Konsole beim alten Server unter *Schlüsselpaarname*.

- Windows 10/11 (PowerShell):
  `ssh -i C:\Users\du\Downloads\meinkey.pem ec2-user@<öffentliche-IP-alt>`
- Mac/Linux: `chmod 400 meinkey.pem && ssh -i meinkey.pem ec2-user@<öffentliche-IP-alt>`
- Oder in der **CloudShell**: über *Aktionen* → *Datei hochladen* die
  `.pem`-Datei hochladen, dann wie bei Mac/Linux.

Kommt keine Verbindung zustande, erlaubt die Security Group des alten Servers
wahrscheinlich kein SSH von deiner IP. Dann in der EC2-Konsole unter
*Security Groups* eine Regel *SSH, Quelle: Meine IP* hinzufügen.

**b) Ohne Schlüsseldatei, mit Session Manager.** Das geht, wenn der SSM-Agent
auf dem alten Server läuft (bei AMIs ab 2017.09 vorinstalliert). Das
Provisionierungsskript richtet die nötige Rolle auf Wunsch ein. Danach: EC2 →
alter Server → *Verbinden* → *Session Manager*.

**c) Schlüssel verloren und kein Session Manager?** AWS bietet dafür die
Automatisierung *AWSSupport-ResetAccess* (Systems Manager → Automatisierung).
Sie setzt einen neuen Schlüssel, **stoppt dafür aber den Server kurz**.
Alternativ hilft der AWS-Support.

> EC2 Instance Connect funktioniert beim alten Amazon Linux 2018 nicht; erst
> ab Amazon Linux 2.

---

## MySQL-Passwort

Das Tool braucht auf dem alten Server einen MySQL-Benutzer mit vollen Rechten,
normalerweise `root`.

**Oft geht es ohne Passwort:** `SRC_DB_PASS` leer lassen und
`./migrate.sh preflight` ausführen. Auf vielen alten Servern liegt das
Passwort in `/root/.my.cnf`, oder root hat gar keins. Dann klappt es
automatisch.

**Wo es sonst stehen kann** (auf dem alten Server nachsehen):

```bash
sudo cat /root/.my.cnf
sudo grep -rIl "DB_PASSWORD\|db_pass\|mysql_connect\|new mysqli\|new PDO" /var/www | head
```

Wenn deine Anwendung selbst als `root` auf die Datenbank zugreift, steht das
Passwort in ihrer Konfigurationsdatei, z.B. `wp-config.php` oder
`config.php`.

**Passwort unbekannt?** Dann kann man es neu setzen. Die Datenbank ist dabei
etwa eine Minute nicht erreichbar. Auf dem alten Server:

```bash
sudo service mysqld stop
sudo mysqld_safe --skip-grant-tables --skip-networking &
sleep 5
mysql -uroot -e "FLUSH PRIVILEGES; SET PASSWORD FOR 'root'@'localhost' = PASSWORD('NeuesPasswort');"
sudo pkill mysqld; sleep 5
sudo service mysqld start
```

(Bei MySQL 5.7 statt `SET PASSWORD …` bitte
`ALTER USER 'root'@'localhost' IDENTIFIED BY 'NeuesPasswort';` verwenden.
Die Version zeigt `mysql --version`.)

**Datenbank liegt in RDS?** Dann ist nichts zu tun: in `migration.conf`
`MIGRATE_DATABASE="no"` setzen. Die Anwendung greift weiter auf RDS zu.

---

## Häufige Fragen

**Was kostet das?** Der neue Server läuft parallel zum alten, typischerweise
ein paar Tage. Die Kosten richten sich nach dem Instanztyp (z.B. `t3.small`
in Frankfurt etwa 0,02 € pro Stunde). Danach fällt der alte Server weg.
`t3`-Instanzen sind meist sogar günstiger als die alten `t2`.

**Wie lange ist die Website offline?** Nur während des Cutovers, und auch
nur so lange, wie die letzten Änderungen übertragen werden. Das sind meist
wenige Minuten, weil der große Teil schon in Schritt 3 übertragen wurde.

**Was passiert mit E-Mails?** Ein lokaler Mailserver für PHP-`mail()` wird
automatisch eingerichtet. Postfächer (dovecot o.ä.) werden **nicht**
migriert; das Tool meldet sie im Bericht.

**Kann ich den neuen Server vorher ausprobieren und dann neu anfangen?** Ja.
Einfach den neuen Server terminieren und `provision-target.sh` erneut
ausführen.

**Mein Problem steht hier nicht.** Bitte den Inhalt von
`/var/lib/server-migration/report.md` und die letzten Zeilen aus
`/var/log/server-migration/migrate-*.log` schicken.
