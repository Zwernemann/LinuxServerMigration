#!/usr/bin/env bash
# Integrationstest MySQL 8.0 (z.B. Amazon Linux 2) -> MySQL 8.4 LTS (benötigt Docker):
# utf8mb4_0900_ai_ci, JSON, caching_sha2_password-Benutzer, GTIDs und ein
# zweiter Import (wie beim Cutover).
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
NET=migtest8-net
cleanup() { docker rm -f m8-src m8-tgt >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null

wait_db() {
    local _
    for _ in $(seq 1 90); do
        docker exec "$1" mysql -uroot -p"$2" -h127.0.0.1 -e 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 2
    done
    docker logs "$1" | tail -20
    return 1
}
docker run -d --name m8-src --network "$NET" -e MYSQL_ROOT_PASSWORD=src mysql:8.0 \
    --gtid-mode=ON --enforce-gtid-consistency=ON >/dev/null
docker run -d --name m8-tgt --network "$NET" -e MYSQL_ROOT_PASSWORD=tgt mysql:8.4 --mysql-native-password=ON >/dev/null
wait_db m8-src src
wait_db m8-tgt tgt

docker exec -i m8-src mysql -uroot -psrc --default-character-set=utf8mb4 2>/dev/null <<'SQL'
CREATE DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE TABLE shop.produkte (id INT PRIMARY KEY, name VARCHAR(50), daten JSON, INDEX ((CAST(daten->>'$.sku' AS CHAR(20)) COLLATE utf8mb4_bin)));
INSERT INTO shop.produkte VALUES (1, 'Größe XL 😀', '{"sku": "A-1", "preis": 9.5}'), (2, 'Ärmel', '{"sku": "B-2"}');
CREATE VIEW shop.v AS SELECT id, daten->>'$.sku' AS sku FROM shop.produkte;
CREATE USER 'magento'@'localhost' IDENTIFIED BY 'M8-geheim!';
CREATE USER 'magento'@'%' IDENTIFIED BY 'M8-geheim!';
CREATE USER 'alt'@'localhost' IDENTIFIED WITH mysql_native_password BY 'alt123';
GRANT ALL ON shop.* TO 'magento'@'localhost', 'magento'@'%';
GRANT SELECT ON shop.produkte TO 'alt'@'localhost';
-- phpMyAdmin-Stil: Unterstrich maskiert; Admin mit ALL ON *.* (enthält SET_USER_ID)
CREATE DATABASE CCS_EDI; CREATE TABLE CCS_EDI.t (id INT);
CREATE USER 'edi'@'%' IDENTIFIED BY 'edi-pw'; GRANT ALL ON `CCS\_EDI`.* TO 'edi'@'%';
CREATE USER 'admin'@'%' IDENTIFIED BY 'adm-pw'; GRANT ALL ON *.* TO 'admin'@'%' WITH GRANT OPTION;
SQL

payload() {
    local kv
    for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
    cat "$ROOT/remote/common.sh" "$ROOT/remote/dump.sh"
}
OUT=$(mktemp -d)
src() { payload SRC_DB_HOST=localhost SRC_DB_USER=root SRC_DB_PASS=src "$@" | docker exec -i m8-src bash -s; }
tgt() { docker exec -i m8-tgt mysql -uroot -ptgt "$@" 2>&1 | grep -v 'Using a password' || true; }

for run in 1 2; do
    echo "== Durchlauf $run"
    src DUMP_MODE=accounts TARGET_DB_ENGINE=mysql84 "DB_USER_EXCLUDE=root mysql.sys mysql.session mysql.infoschema" >"$OUT/accounts.sql"
    awk -v u="$OUT/users.sql" -v g="$OUT/grants.sql" '/^-- @@GRANTS@@/ {gr=1} {print > (gr ? g : u)}' "$OUT/accounts.sql"
    src DUMP_MODE=db DUMP_DB=shop >"$OUT/shop.sql.gz"
    src DUMP_MODE=db DUMP_DB=CCS_EDI >"$OUT/edi.sql.gz"
    if zcat "$OUT/shop.sql.gz" | grep -q 'GTID_PURGED'; then echo 'FEHLER: GTID_PURGED im Dump'; exit 1; fi
    tgt <"$OUT/users.sql"
    zcat "$OUT/shop.sql.gz" | tgt --max-allowed-packet=1G
    zcat "$OUT/edi.sql.gz" | tgt --max-allowed-packet=1G
    sed -i -E '/^GRANT /s/(^GRANT |,)SET_USER_ID(,| ON )/\1SET_ANY_DEFINER,ALLOW_NONEXISTENT_DEFINER\2/' "$OUT/grants.sql"
    tgt --force <"$OUT/grants.sql" >"$OUT/grants.err"
    if grep -q ERROR "$OUT/grants.err"; then cat "$OUT/grants.err"; echo "FEHLER: GRANT-Import"; exit 1; fi
done
grep -q "caching_sha2_password' AS 0x" "$OUT/accounts.sql" && echo "ok   caching_sha2-Hash hexadezimal exportiert"
grep -q WARN "$OUT/accounts.sql" || echo "ok   keine übersprungenen Benutzer"
docker exec m8-tgt mysql -umagento -p'M8-geheim!' -h127.0.0.1 -N -e "SELECT name FROM shop.produkte WHERE id=1" 2>/dev/null | grep -q 'XL' &&
    echo "ok   Anmeldung magento (caching_sha2) mit altem Passwort"
docker exec m8-tgt mysql -ualt -palt123 -N -e "SELECT COUNT(*) FROM shop.produkte" 2>/dev/null | grep -qx 2 &&
    echo "ok   Anmeldung alt (mysql_native_password)"
[[ "$(docker exec m8-tgt mysql -uroot -ptgt -N -e "SELECT TABLE_COLLATION FROM information_schema.tables WHERE table_schema='shop' AND table_name='produkte'" 2>/dev/null)" == utf8mb4_0900_ai_ci ]] &&
    echo "ok   Kollation utf8mb4_0900_ai_ci erhalten"
q="SELECT MD5(GROUP_CONCAT(id, HEX(name), daten ORDER BY id)) FROM shop.produkte"
[[ "$(docker exec m8-tgt mysql -uroot -ptgt -N -e "$q" 2>/dev/null)" == "$(docker exec m8-src mysql -uroot -psrc -N -e "$q" 2>/dev/null)" ]] &&
    echo "ok   Daten inkl. JSON und Emoji identisch"
docker exec m8-tgt mysql -uroot -ptgt -N -e "SELECT sku FROM shop.v WHERE id=1" 2>/dev/null | grep -qx 'A-1' && echo "ok   View mit JSON-Ausdruck funktioniert"
docker exec m8-tgt mysql -uedi -pedi-pw -N -e "SELECT COUNT(*) FROM CCS_EDI.t" 2>/dev/null | grep -qx 0 &&
    echo "ok   maskierter Unterstrich (CCS\\_EDI) korrekt übernommen"
docker exec m8-tgt mysql -uroot -ptgt -N -e "SHOW GRANTS FOR 'admin'@'%'" 2>/dev/null | grep -q SET_ANY_DEFINER &&
    echo "ok   SET_USER_ID -> SET_ANY_DEFINER (Admin-Rechte vollständig)"
echo "== OK"
