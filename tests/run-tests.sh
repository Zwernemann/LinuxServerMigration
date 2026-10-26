#!/usr/bin/env bash
# Schnelle Tests ohne Server. Optional mit Docker: Apache-2.4-Syntaxtest und
# Bash-4.2-Kompatibilität (Amazon Linux 2018) der Quell-Skripte.
#   tests/run-tests.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
pass=0 failed=0
ok() { echo "  ok   $*"; pass=$((pass + 1)); }
nok() { echo "  FEHLER $*"; failed=$((failed + 1)); }
expect() { # expect <beschreibung> <datei> <grep -E muster>
    if grep -qE -- "$3" "$2"; then ok "$1"; else nok "$1 (Muster '$3' fehlt in $2)"; fi
}
reject() {
    if grep -qE -- "$3" "$2"; then nok "$1 (Muster '$3' unerwartet in $2)"; else ok "$1"; fi
}

echo "== shellcheck"
if command -v shellcheck >/dev/null; then
    if shellcheck -x -s bash migrate.sh lib/common.sh lib/phases/*.sh remote/*.sh tools/*.sh tests/*.sh; then ok shellcheck; else nok shellcheck; fi
else echo "  (shellcheck nicht installiert – übersprungen)"; fi

echo "== Apache 2.2 -> 2.4 Zugriffsregeln"
tools/apache24-convert.sh tests/fixtures/access.conf >"$T/access.conf" 2>"$T/access.err"
expect "allow,deny + Allow all" "$T/access.conf" '^    Require all granted$'
expect "Deny all + Allow IP/Host" "$T/access.conf" '^    Require ip 10\.0\.0\.0/8 192\.168\.1\.5$'
expect "Host-Freigabe" "$T/access.conf" '^    Require host office\.example\.com$'
expect "Deny from all" "$T/access.conf" '^    Require all denied$'
expect "Allow all + Deny IP" "$T/access.conf" 'Require not ip 1\.2\.3\.4'
expect "Satisfy bleibt unverändert" "$T/access.conf" '^    Satisfy any$'
expect "Satisfy wird gemeldet" "$T/access.err" 'Satisfy'
if [[ $(grep -c '^    Order ' "$T/access.conf") == 1 ]]; then ok "nur der Satisfy-Kontext behält Order"; else nok "aktive Order-Zeilen"; fi

echo "== Apache-Konfiguration übernehmen"
S=tests/fixtures/source/etc/httpd
tools/apache-migrate-config.sh main "$S/conf/httpd.conf" "$T/main" >"$T/main.conf"
tools/apache-migrate-config.sh ssl "$S/conf.d/ssl.conf" "$T/ssl" >"$T/ssl.conf"
tools/apache-migrate-config.sh file "$S/conf.d/shop.conf" "$T/shop" >"$T/shop.conf"
expect "VirtualHost übernommen" "$T/main.conf" '<VirtualHost \*:8080>'
expect "AllowOverride der DocumentRoot übernommen" "$T/main.conf" 'AllowOverride All'
reject "NameVirtualHost entfernt" "$T/main.conf" '^NameVirtualHost'
reject "Listen nicht doppelt" "$T/main.conf" '^Listen'
reject "Stock-<Directory /> nicht übernommen" "$T/main.conf" '<Directory />'
reject "Stock-IfModule nicht übernommen" "$T/main.conf" 'StartServers'
expect "AddType php auskommentiert" "$T/main.conf" '^# \[migration: PHP läuft über PHP-FPM\] AddType'
expect "Listen 8080 erkannt" "$T/main.listen" '^Listen 8080$'
expect "php_value -> .user.ini der DocumentRoot" "$T/main.php" $'^/var/www/example\tupload_max_filesize\t64M$'
expect "php_admin_flag im Directory -> dessen .user.ini" "$T/main.php" $'^/var/www/example/uploads\tengine\toff$'
expect "SSL-VHost übernommen" "$T/ssl.conf" 'ServerName example.com'
reject "Standard-SSL-VHost übersprungen" "$T/ssl.conf" 'localhost\.crt'
reject "SSLMutex entfernt" "$T/ssl.conf" 'SSLMutex'
expect "SSLProtocol auskommentiert" "$T/ssl.conf" '^# \[migration: AL2023-Crypto-Policy'
expect "php_value in IfModule erkannt" "$T/shop.php" $'^/var/www/shop\tmemory_limit\t256M$'

echo "== .htaccess -> .user.ini"
cp -r tests/fixtures/www "$T/www"
tools/php-to-userini.sh htaccess "$T/www/app/.htaccess" 2>"$T/ui.err"
U="$T/www/app/.user.ini"
expect "upload_max_filesize" "$U" '^upload_max_filesize = 32M$'
expect "Anführungszeichen entfernt" "$U" '^post_max_size = 40M$'
expect "php_flag on -> On" "$U" '^short_open_tag = On$'
expect "Wert in IfModule" "$U" '^max_execution_time = 120$'
expect "Sonderzeichen gequotet" "$U" '^include_path = "\.:/var/www/app/lib"$'
reject "register_globals verworfen" "$U" 'register_globals'
expect "register_globals gemeldet" "$T/ui.err" 'register_globals'
reject "keine aktiven php_value mehr" "$T/www/app/.htaccess" '^[[:space:]]*php_(value|flag)'
expect "Sicherung angelegt" <(ls -a "$T/www/app") '\.htaccess\.pre-migration'
tools/php-to-userini.sh htaccess "$T/www/app/.htaccess" 2>/dev/null
if [[ $(grep -c upload_max_filesize "$U") == 1 ]]; then ok "idempotent"; else nok "idempotent"; fi
tools/apache24-convert.sh -i "$T/www/app/.htaccess" 2>/dev/null
expect ".htaccess Zugriffsregeln konvertiert" "$T/www/app/.htaccess" '^    Require all denied$'

echo "== PHP-8-Scan"
tools/php8-compat-scan.sh -o "$T/scan.md" tests/fixtures/php >/dev/null
rc=$?
if [[ $rc == 1 ]]; then ok "Exit-Code 1 bei kritischen Funden"; else nok "Exit-Code $rc"; fi
for w in 'mysql_\*' 'ereg' 'create_function' 'each\(\)' '\{\} wurde' 'case-insensitive' '=& new' 'utf8_encode' 'Interpolation'; do
    expect "erkennt $w" "$T/scan.md" "$w"
done
reject "Kommentarzeile ignoriert" "$T/scan.md" 'kommentar wird ignoriert'
reject "modern.php ohne kritische Funde" <(grep -A40 '^## KRITISCH' "$T/scan.md") 'modern\.php'

echo "== Bash-Syntax"
for f in migrate.sh lib/common.sh lib/phases/*.sh remote/*.sh tools/*.sh; do
    bash -n "$f" || nok "bash -n $f"
done
ok "bash -n (lokal)"

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    if docker image inspect amazonlinux:2018.03 >/dev/null 2>&1; then
        echo "== Quell-Skripte unter Amazon Linux 2018.03 (bash 4.2)"
        out=$( { echo 'PHP_INI_KEYS="memory_limit"'; cat remote/common.sh remote/inventory.sh; } |
            docker run --rm -i amazonlinux:2018.03 bash -s 2>"$T/al1.err" | tar -tzf - 2>&1)
        if grep -q summary.env <<<"$out"; then ok "inventory.sh läuft unter bash $(docker run --rm amazonlinux:2018.03 bash -c 'echo $BASH_VERSION')"
        else nok "inventory.sh unter AL2018: $(tail -3 "$T/al1.err")"; fi
        if docker run --rm -v "$ROOT:/m:ro" amazonlinux:2018.03 bash -c 'for f in /m/remote/*.sh; do bash -n "$f" || exit 1; done'; then
            ok "bash -n remote/*.sh unter bash 4.2"; else nok "bash -n unter bash 4.2"; fi
    fi
    if docker image inspect httpd:2.4 >/dev/null 2>&1; then
        echo "== Apache-2.4-Syntaxtest der konvertierten Konfiguration"
        mkdir -p "$T/conf"
        for f in main ssl shop; do cp "$T/$f.conf" "$T/conf/migrated-$f.conf"; done
        cp "$T/main.listen" "$T/conf/migrated-00-listen.conf"
        tools/apache24-convert.sh -i "$T"/conf/*.conf 2>/dev/null
        if docker run --rm -v "$T/conf:/test:ro" httpd:2.4 bash -c '
            C=/usr/local/apache2/conf/httpd.conf
            sed -i -E "s/^#(LoadModule (ssl_module|socache_shmcb_module|rewrite_module))/\1/" $C
            printf "Listen 443\nIncludeOptional /test/migrated-*.conf\n" >>$C
            d=/etc/letsencrypt/live/example.com; mkdir -p $d /var/www/example/uploads /var/www/admin /var/www/shop
            openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=t -keyout $d/privkey.pem -out $d/cert.pem -days 1 2>/dev/null
            cp $d/cert.pem $d/chain.pem
            httpd -t' >"$T/httpd.out" 2>&1; then ok "httpd -t: $(tail -1 "$T/httpd.out")"; else nok "httpd -t: $(cat "$T/httpd.out")"; fi
    fi
fi

echo
echo "Ergebnis: $pass ok, $failed Fehler"
[[ $failed == 0 ]]
