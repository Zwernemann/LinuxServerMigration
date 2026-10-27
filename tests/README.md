# Tests

| Test | Benötigt | Prüft |
|---|---|---|
| `tests/run-tests.sh` | bash, optional shellcheck und Docker | Apache-Konvertierung, `.user.ini`, PHP-8-Scan, Bash-4.2-Kompatibilität (Image `amazonlinux:2018.03`), `httpd -t` mit Apache 2.4 (Image `httpd:2.4`) |
| `tests/db-roundtrip.sh` | Docker | Export von MySQL 5.6 und Import in MariaDB 10.11 und MySQL 8.4: Daten (bytegenau), Routinen, Trigger, Views, Benutzer mit Passwort-Hash, Rechte, Zeilenzahl-Vergleich |
| `tests/db-mysql8.sh` | Docker | MySQL 8.0 (mit GTIDs) → MySQL 8.4: `utf8mb4_0900_ai_ci`, JSON samt funktionalem Index, `caching_sha2_password`-Benutzer mit altem Passwort, zweiter Import wie beim Cutover |
| `tests/e2e-ssh.sh` | Docker, Image `migtest-base` | `migrate.sh inventory users files database configure verify` über echtes SSH, sudo und rsync zwischen zwei Containern, danach ein zweiter Lauf (Wiederholbarkeit) |

Amazon-Linux-Container können ohne Internetzugang keine Pakete installieren.
Für den E2E-Test wird daher ein RHEL-kompatibles Image (Oracle Linux 9 aus
`mysql:8.4`) als Quelle und Ziel verwendet. Nicht abgedeckt sind die Phasen
`preflight` (prüft auf AL2023) und `install` (AL2023-Paketnamen); diese lassen
sich nur auf einer echten AL2023-Instanz testen.

Basis-Image bauen:

```bash
docker run --name migbase --entrypoint bash mysql:8.4 -c \
  'microdnf -y --disablerepo="mysql*" install openssh-server openssh-clients sudo rsync httpd php php-mysqlnd php-cli tar gzip procps-ng findutils which cronie shadow-utils diffutils && microdnf clean all'
docker commit --change 'ENTRYPOINT ["docker-entrypoint.sh"]' --change 'CMD ["mysqld"]' migbase migtest-base:latest
docker rm migbase
```
