#!/usr/bin/env bash
# Ende-zu-Ende-Test der Phasen inventory, users, files, database, configure
# und verify über echtes SSH + sudo + rsync – mit zwei Containern.
#
# Da Amazon-Linux-Container ohne Internet keine Pakete installieren können,
# wird ein RHEL-kompatibles Basis-Image (Oracle Linux 9 aus dem mysql:8.4-
# Image, plus httpd/php/sshd/rsync) für Quelle UND Ziel verwendet. Getestet
# wird damit die gesamte Mechanik von migrate.sh; die paketabhängige Phase
# "install" und das AL2023-spezifische "preflight" sind ausgenommen.
#
# Voraussetzung: Image migtest-base (siehe tests/README.md)
#   tests/e2e-ssh.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
IMG=${IMG:-migtest-base:latest}
NET=migtest-e2e
SRC=migtest-e2e-src
TGT=migtest-e2e-tgt
K=$(mktemp -d)

cleanup() {
    docker rm -f "$SRC" "$TGT" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "${K:?}"
}
[[ -n "${KEEP:-}" ]] || trap cleanup EXIT
cleanup
mkdir -p "$K"
docker network create "$NET" >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$K/id" 2>/dev/null || docker run --rm -v "$K:/k" --entrypoint ssh-keygen "$IMG" -q -t ed25519 -N '' -f /k/id

wait_db() {
    local _
    for _ in $(seq 1 90); do
        docker exec "$1" mysql -uroot -p"$2" -e 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 2
    done
    docker logs "$1" | tail -20
    return 1
}

# systemctl-Ersatz für Container ohne systemd
SHIM='#!/bin/bash
case "$1" in
is-active|enable) exit 0 ;;
start|restart|reload)
  shift; for s in "$@"; do case "$s" in
    httpd) httpd -k restart 2>/dev/null || httpd -k start ;;
    php-fpm) pkill -x php-fpm; sleep 1; mkdir -p /run/php-fpm; php-fpm -D ;;
  esac; done ;;
esac
exit 0'

start_box() { # start_box <name> <rootpw>
    docker run -d --name "$1" --hostname "$1" --network "$NET" -e MYSQL_ROOT_PASSWORD="$2" \
        -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= \
        -v "$K/id.pub:/tmp/id.pub:ro" "$IMG" mysqld --mysql-native-password=ON >/dev/null
    wait_db "$1" "$2"
    docker exec -i "$1" bash -c "cat >/usr/local/bin/systemctl && chmod +x /usr/local/bin/systemctl" <<<"$SHIM"
    # Socket-Pfad des mysql-Images (Testumgebung, auf beiden Seiten gleich)
    docker exec "$1" bash -c 'printf "mysqli.default_socket=/var/run/mysqld/mysqld.sock\n" >/etc/php.d/99-test-socket.ini'
}

echo "== Quelle aufsetzen"
start_box "$SRC" 'srcR00t!'
docker exec -i "$SRC" bash -e <<'EOF'
ssh-keygen -A >/dev/null
useradd -m -u 500 ec2-user
useradd -m -u 501 webdev
groupadd -g 510 webteam
usermod -aG webteam webdev
usermod -aG webteam ec2-user
echo 'webdev:$6$salt$abcdefghijklmnopqrstuv' | chpasswd -e
echo 'ec2-user ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/90-ec2-user && chmod 440 /etc/sudoers.d/90-ec2-user
install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
install -m 600 -o ec2-user -g ec2-user /tmp/id.pub /home/ec2-user/.ssh/authorized_keys
echo 'nur auf der Quelle' >/home/webdev/notiz.txt
/usr/sbin/sshd
mkdir -p /var/www/example/uploads /var/www/html
echo '<?php echo "html ok";' >/var/www/html/index.php
cat >/var/www/example/index.php <<'PHP'
<?php
$db = new mysqli('localhost', 'shopuser', 'geheim1', 'shop');
$n = $db->query('SELECT COUNT(*) FROM kunden')->fetch_row()[0];
echo "kunden=$n upload=", ini_get('upload_max_filesize');
PHP
# Quelle läuft hier (anders als AL2018) schon mit PHP-FPM – daher IfModule
cat >/var/www/example/.htaccess <<'HT'
<IfModule mod_php5.c>
    php_value upload_max_filesize 48M
</IfModule>
<Files "secret.txt">
    Order allow,deny
    Deny from all
</Files>
HT
echo geheim >/var/www/example/secret.txt
# Alter Code: mysql_*-Funktionen, Endung .php3 und eine liegengebliebene Kopie
cat >/var/www/example/legacy.php3 <<'PHP'
<?php
$l = mysql_connect('localhost', 'shopuser', 'geheim1');
mysql_select_db('shop', $l);
echo 'legacy=', mysql_num_rows(mysql_query('SELECT * FROM kunden'));
PHP
cp /var/www/example/legacy.php3 /var/www/example/legacy.php3_notUsed
chown -R webdev:webteam /var/www/example
cat >/etc/httpd/conf.d/example.conf <<'CONF'
<VirtualHost *:80>
    ServerName example.test
    DocumentRoot /var/www/example
    <Directory /var/www/example>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
CONF
echo '*/5 * * * * php /var/www/example/index.php >/dev/null' >/var/spool/cron/webdev
mkdir -p /run/php-fpm && php-fpm -D && httpd -k start
mysql -uroot -p'srcR00t!' 2>/dev/null <<'SQL'
CREATE DATABASE shop;
CREATE TABLE shop.kunden (id INT PRIMARY KEY, name VARCHAR(50));
INSERT INTO shop.kunden VALUES (1, 'Müller'), (2, 'Schmidt'), (3, 'Weber');
CREATE USER 'shopuser'@'localhost' IDENTIFIED WITH mysql_native_password BY 'geheim1';
GRANT ALL ON shop.* TO 'shopuser'@'localhost';
SQL
EOF
docker exec "$SRC" curl -s -H 'Host: example.test' http://127.0.0.1/ && echo

echo "== Ziel aufsetzen"
start_box "$TGT" 'tgtR00t!'
docker cp "$ROOT" "$TGT:/opt/migration"
docker cp "$K/id" "$TGT:/root/migration_key"
docker exec -i "$TGT" bash -e <<'EOF'
printf '[client]\nuser=root\npassword="tgtR00t!"\n' >/root/.my.cnf
chmod 600 /root/.my.cnf /root/migration_key
mkdir -p /run/php-fpm && php-fpm -D && httpd -k start
cat >/opt/migration/migration.conf <<'CONF'
SRC_HOST="migtest-e2e-src"
SRC_SSH_KEY="/root/migration_key"
SRC_DB_PASS='srcR00t!'
DB_USER_EXCLUDE="root mysql.sys mysql.session mysql.infoschema"
TARGET_DB_ENGINE="mysql84"
TARGET_PHP_VERSION="8.0"
CERTBOT_SETUP="no"
PHP_LINT="yes"
CONF
EOF

echo "== migrate.sh inventory users files database configure verify"
docker exec "$TGT" /opt/migration/migrate.sh -y inventory users files database configure verify 2>&1 |
    grep -vE '^\s+(Number of|Total transferred)' | tail -n 60

echo "== Prüfungen"
fail=0
t() { if docker exec "$TGT" bash -c "$2" >/dev/null 2>&1; then echo "  ok   $1"; else echo "  FEHLER $1"; fail=1; fi; }
t "Benutzer webdev mit UID 501"            'id -u webdev | grep -qx 501'
t "Gruppe webteam (GID 510) mit Mitgliedern" 'getent group webteam | grep -q "^webteam:x:510:.*webdev"'
t "ec2-user nicht neu angelegt"             '! id ec2-user'
t "Passwort-Hash übernommen"                'grep -qF "webdev:\$6\$salt\$abc" /etc/shadow'
t "Home-Verzeichnis kopiert"                'grep -q "nur auf der Quelle" /home/webdev/notiz.txt'
t "Webdateien mit Eigentümer"               '[ "$(stat -c %U /var/www/example/index.php)" = webdev ]'
t ".htaccess: php_value -> .user.ini"       'grep -qx "upload_max_filesize = 48M" /var/www/example/.user.ini'
t ".htaccess: Order -> Require"             'grep -q "Require all denied" /var/www/example/.htaccess'
t "VirtualHost übernommen"                  'grep -q "ServerName example.test" /etc/httpd/conf.d/migrated-*-example.conf'
t "Crontab übernommen"                      'grep -q index.php /var/spool/cron/webdev'
t "Datenbank übertragen"                    'mysql -N -e "SELECT COUNT(*) FROM shop.kunden" | grep -qx 3'
t "MySQL-Benutzer mit altem Passwort"       'mysql -ushopuser -pgeheim1 -N -e "SELECT 1" shop'
t "Website liefert Daten aus der DB"        'curl -s -H "Host: example.test" http://127.0.0.1/ | grep -q "kunden=3 upload=48M"'
t ".php3 mit mysql_* läuft unter PHP 8"     'curl -s -H "Host: example.test" http://127.0.0.1/legacy.php3 | grep -qx "legacy=3"'
t "Restdatei .php3_notUsed gesperrt"        '[ "$(curl -s -o /dev/null -w %{http_code} -H "Host: example.test" http://127.0.0.1/legacy.php3_notUsed)" = 403 ]'
t "secret.txt gesperrt"                     '[ "$(curl -s -o /dev/null -w %{http_code} -H "Host: example.test" http://127.0.0.1/secret.txt)" = 403 ]'
t ".user.ini gesperrt"                      '[ "$(curl -s -o /dev/null -w %{http_code} -H "Host: example.test" http://127.0.0.1/.user.ini)" = 403 ]'
t "Bericht erstellt"                        'grep -q "## Ergebnis" /var/lib/server-migration/report.md'
t "Zweiter Lauf (idempotent)"               '/opt/migration/migrate.sh -y files database configure'
docker exec "$TGT" sed -n '/## Ergebnis/,/## Warnungen/p' /var/lib/server-migration/report.md
[[ $fail == 0 ]] && echo "== E2E OK"
exit $fail
