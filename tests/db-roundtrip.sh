#!/usr/bin/env bash
# Integrationstest für den Datenbank-Teil (benötigt Docker):
#   MySQL 5.6 (wie auf Amazon Linux AMI 2018)  ->  MariaDB 10.11 / MySQL 8.4
# Prüft Export von Daten, Routinen, Views, Triggern, Benutzern und Rechten,
# den Import und den Zeilenzahl-Vergleich.
#
#   tests/db-roundtrip.sh [mariadb|mysql84|all]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WHICH=${1:-all}
NET=migtest-net
PW='Src-Pa55"wort\x'   # absichtlich mit Sonderzeichen

cleanup() { docker rm -f migtest-src migtest-mariadb migtest-mysql84 >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null

wait_db() { # wait_db <container> <client>
    local _
    for _ in $(seq 1 90); do
        docker exec "$1" sh -c "$2 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e 'SELECT 1'" >/dev/null 2>&1 && return 0
        sleep 2
    done
    docker logs "$1" | tail -20
    return 1
}

echo "== Quelle: MySQL 5.6"
docker run -d --name migtest-src --network "$NET" -e MYSQL_ROOT_PASSWORD=init mysql:5.6 >/dev/null
wait_db migtest-src mysql
docker exec -i migtest-src sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' 2>&1 <<'SQL' | grep -v 'Using a password' || true
SET GLOBAL sql_mode = 'NO_ENGINE_SUBSTITUTION';
-- Passwort mit " und \ testet das Escaping der Zugangsdaten
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('Src-Pa55"wort\\x');
SET PASSWORD FOR 'root'@'%' = PASSWORD('Src-Pa55"wort\\x');
CREATE DATABASE shop CHARACTER SET utf8;
USE shop;
CREATE TABLE kunden (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100), erstellt DATETIME DEFAULT '0000-00-00 00:00:00') ENGINE=InnoDB;
CREATE TABLE log (id INT AUTO_INCREMENT PRIMARY KEY, msg TEXT, bild BLOB) ENGINE=MyISAM;
INSERT INTO kunden (name) VALUES ('Müller'), ('Schäfer'), ('O''Brien'), ('😀 utf8mb4?');
INSERT INTO log (msg, bild) VALUES ('a', UNHEX('00FF10')), ('b', NULL);
CREATE VIEW v_kunden AS SELECT id, name FROM kunden;
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
CREATE PROCEDURE p_anzahl() SELECT COUNT(*) FROM kunden;
CREATE TRIGGER t_log AFTER INSERT ON kunden FOR EACH ROW INSERT INTO log (msg) VALUES (NEW.name);
CREATE DATABASE `blog-2`;
CREATE TABLE `blog-2`.posts (id INT PRIMARY KEY, title VARCHAR(50));
INSERT INTO `blog-2`.posts VALUES (1, 'Hallo');
GRANT ALL PRIVILEGES ON shop.* TO 'shopuser'@'localhost' IDENTIFIED BY 'geheim1';
GRANT SELECT ON shop.* TO 'shopuser'@'%' IDENTIFIED BY 'geheim1';
GRANT SELECT, INSERT ON `blog-2`.posts TO 'blog'@'10.0.%' IDENTIFIED BY 'bl0g';
CREATE USER 'nopass'@'localhost';
GRANT USAGE ON *.* TO 'nopass'@'localhost';
FLUSH PRIVILEGES;
SQL

payload() { # payload VAR=wert ... -> Skript wie src_run es erzeugt
    local kv
    for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
    cat "$ROOT/remote/common.sh" "$ROOT/remote/dump.sh"
}
OUT=$(mktemp -d)
src() { payload SRC_DB_HOST=localhost SRC_DB_USER=root "SRC_DB_PASS=$PW" "$@" | docker exec -i migtest-src bash -s; }

echo "== Export"
src DUMP_MODE=accounts "DB_USER_EXCLUDE=root mysql.sys" >"$OUT/accounts.sql"
awk -v u="$OUT/users.sql" -v g="$OUT/grants.sql" '/^-- @@GRANTS@@/ {gr=1} {print > (gr ? g : u)}' "$OUT/accounts.sql"
for db in shop blog-2; do src DUMP_MODE=db "DUMP_DB=$db" >"$OUT/$db.sql.gz"; gzip -t "$OUT/$db.sql.gz"; done
zcat "$OUT/shop.sql.gz" | tail -n1 | grep -q 'Dump completed'
src DUMP_MODE=counts "DUMP_DBS=shop blog-2" >"$OUT/counts-src.tsv"
grep -q "WARN: 'nopass'@'localhost' hat KEIN Passwort" "$OUT/accounts.sql"
cat "$OUT/accounts.sql"
cat "$OUT/counts-src.tsv"

import_into() { # import_into <name> <image> <client> [mysqld-args]
    local name=$1 image=$2 client=$3
    shift 3
    echo "== Ziel: $image"
    docker run -d --name "$name" --network "$NET" -e MYSQL_ROOT_PASSWORD=ziel -e MARIADB_ROOT_PASSWORD=ziel "$image" "$@" >/dev/null
    wait_db "$name" "$client"
    tgt() { docker exec -i "$name" sh -c "$client -uroot -pziel $*" 2>&1 | grep -v 'Using a password' || true; }
    tgt <"$OUT/users.sql"
    for db in shop blog-2; do
        if [[ "$name" == *mysql84 ]]; then
            zcat "$OUT/$db.sql.gz" | sed -E '/sql_mode/ { s/NO_AUTO_CREATE_USER,//g; s/,?NO_AUTO_CREATE_USER//g }' | tgt --max-allowed-packet=1G
        else
            zcat "$OUT/$db.sql.gz" | tgt --max-allowed-packet=1G
        fi
    done
    tgt --force <"$OUT/grants.sql"
    # Zeilenzahlen mit demselben Skript auf dem Ziel
    { payload SRC_DB_HOST=localhost SRC_DB_USER=root SRC_DB_PASS=ziel DUMP_MODE=counts "DUMP_DBS=shop blog-2"; } |
        docker exec -i "$name" bash -s >"$OUT/counts-$name.tsv"
    diff "$OUT/counts-src.tsv" "$OUT/counts-$name.tsv" && echo "Zeilenzahlen identisch"
    # Anmeldung mit dem übernommenen Passwort-Hash
    local q="SELECT MD5(GROUP_CONCAT(HEX(name) ORDER BY id)) FROM shop.kunden"
    [[ "$(docker exec "$name" sh -c "$client -uroot -pziel -N -e '$q'" 2>/dev/null)" == \
        "$(docker exec migtest-src sh -c "mysql -uroot -p'$PW' -N -e '$q'" 2>/dev/null)" ]] && echo "Textdaten bytegenau identisch"
    docker exec "$name" sh -c "$client -ushopuser -pgeheim1 shop -N -e 'CALL p_anzahl();'" 2>/dev/null | grep -qx 4 &&
        echo "Anmeldung mit altem Passwort + Prozedur OK"
    docker exec "$name" sh -c "$client -ushopuser -pgeheim1 -e 'SHOW GRANTS'" 2>/dev/null | grep -q 'ALL PRIVILEGES ON `shop`' &&
        echo "Rechte übernommen"
    docker exec "$name" sh -c "$client -uroot -pziel -N -e \"SELECT COUNT(*) FROM mysql.user WHERE user IN ('shopuser','blog','nopass')\"" 2>/dev/null
    docker exec "$name" sh -c "$client -uroot -pziel -N -e \"SELECT HEX(bild) FROM shop.log WHERE msg='a'\"" 2>/dev/null | grep -qx 00FF10 &&
        echo "BLOB-Daten korrekt"
}

[[ "$WHICH" == all || "$WHICH" == mariadb ]] && import_into migtest-mariadb mariadb:10.11 mariadb
[[ "$WHICH" == all || "$WHICH" == mysql84 ]] && import_into migtest-mysql84 mysql:8.4 mysql --mysql-native-password=ON
echo "== OK"
