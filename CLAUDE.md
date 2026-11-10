# Hinweise für Claude (verbindlich für jede Migration mit diesem Repository)

## Arbeitsweise (Wunsch des Nutzers)

- **Jede neue Migration beginnt direkt in der AWS CloudShell mit
  `aws/provision-target.sh`.** Keine Anleitung zum Anlegen von Instanzen,
  Platten, Security Groups oder IAM-Rollen über die EC2-Konsole („Klickorgie“),
  keine manuellen Einzelschritte, wenn das Skript es kann.
- Vorher **alle nötigen Angaben einsammeln** und daraus **einen einzigen
  Befehl** bauen:
  - Instance-ID des alten Servers (oder `--old-ip`), Region
  - SSH-Port des alten Servers (`--src-ssh-port`, der neue bekommt denselben)
  - gewünschter Instanztyp (`--instance-type`, z.B. `t3.micro` beibehalten)
  - Datenplatten und ihr Mountpunkt (`--data-volume 30:/daten`)
  - Zusatzpakete und -verzeichnisse (`--conf 'EXTRA_PACKAGES=…'`,
    `--conf 'EXTRA_PATHS=…'`, z.B. Verzeichnisse aus Cronjobs)
  - Dafür zuerst das Bestandsaufnahme-Skript auf dem alten Server laufen lassen
    (siehe unten) und `df`, `crontab -l`, `grep datadir /etc/my.cnf` abfragen.
- Fehlt dem Skript eine Fähigkeit, **das Skript erweitern** (mit Test), statt
  den Nutzer manuelle Befehle ausführen zu lassen.
- Bei jedem Befehl angeben, **wo** er läuft: **CloudShell**, **ALTER Server**
  oder **NEUER Server** (Prompt/Hostname nennen).
- Ein Befehl pro Codeblock; kein `sudo -i` zusammen mit weiteren Zeilen in
  einem Block (die Folgezeilen werden sonst verschluckt).
- Passwörter nie über `--conf` oder die Kommandozeile der CloudShell, sondern
  direkt auf dem neuen Server in `migration.conf`.

## Standard-Ablauf

```
CloudShell:   git clone -b <branch> https://github.com/Zwernemann/LinuxServerMigration.git
              cd LinuxServerMigration
              bash aws/provision-target.sh --old-instance i-… --src-ssh-port … \
                   --instance-type … --data-volume GB:/pfad --conf '…'
NEUER Server: sudo -i ; tmux new -s migration ; cd /opt/linuxservermigration
              (DB-Passwort in migration.conf, falls nötig)
              ./migrate.sh preflight ; ./migrate.sh inventory ; ./migrate.sh all
              Browser-Test über hosts-Datei, Mail-Test
              ./migrate.sh cutover
CloudShell:   bash aws/provision-target.sh --old-instance i-… --src-ssh-port … --cleanup   (nach einigen Tagen)
```

Bestandsaufnahme eines Servers (auf dem **alten** Server, liefert System,
Apache-VHosts, PHP-Module, MySQL, Dienste, Ports, Cron, Zertifikate, Mail):

```
curl -fsSL https://raw.githubusercontent.com/Zwernemann/LinuxServerMigration/main/tools/bestandsaufnahme.sh | sudo bash | tee ~/bestand.txt
```

## Erfahrungen aus echten Umzügen (bereits im Tool umgesetzt)

- SSH auf Nicht-Standard-Port: `--src-ssh-port`, neuer Server übernimmt ihn.
  Konkrete Ports, IPs, Instance-IDs, Domains, Benutzernamen oder Passwörter
  von Kundenservern **nie** in Dateien dieses (öffentlichen) Repositorys
  oder in Commit-Nachrichten schreiben – nur Platzhalter wie `<PORT>`.
- PuTTY-Schlüssel stehen oft nur in `~ec2-user/.ssh/authorized_keys` → werden übernommen.
- MySQL 8.0 → **MySQL 8.4** (nicht MariaDB): `TARGET_DB_ENGINE=auto`;
  `SET_USER_ID` → `SET_ANY_DEFINER`; GRANTs roh exportieren (`db\_name` mit maskiertem Unterstrich).
- Datenbank auf Datenplatte wie zuvor: `TARGET_DB_DATADIR=auto`.
- cron startet erst beim Cutover (sonst doppelte Erinnerungsmails).
- acme.sh in `/root/.acme.sh` wird übernommen; nicht mehr genutzte Domains
  **auf dem alten und dem neuen Server** entfernen (Cutover kopiert erneut).
  Neue Zertifikate nach `/daten/certs/<domain>/`, Prüfdateien unter
  `/daten/acme/challenge` (nicht unter `/var/www` oder `/daten/www` – die
  werden mit `--delete` synchronisiert).
- Toter Code (`mysql_*`, `.php3`) auf Quellen mit PHP ≥ 7 nicht wieder
  lauffähig machen; nicht ausgeführte `.php3` werden gesperrt.
- s-nail: `set expandargv` für `mail … -- -r absender`.
- postfix: interner AWS-Hostname als HELO → nach Cutover `myhostname` und
  Reverse-DNS der Elastic IP setzen.
- Bei 1 GB RAM (t3.micro) automatisch 2 GB Swap.

## Entwicklung

- Tests: `tests/run-tests.sh` (immer), `tests/db-roundtrip.sh`,
  `tests/db-mysql8.sh`, `tests/e2e-ssh.sh` (Docker; siehe `tests/README.md`).
- Quellskripte (`remote/*.sh`) müssen unter bash 4.2 laufen.
- Mit `set -o pipefail`: `grep` ohne Treffer in Pipelines immer mit `|| true`.
