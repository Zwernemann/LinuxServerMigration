# shellcheck shell=bash
# Phase "install": Pakete auf dem Ziel installieren (Apache, PHP, Datenbank).

# Ordnet ein PHP-Modul der Quelle (php -m, kleingeschrieben) einem AL2023-Paket zu.
#   Ausgabe: pkg:<suffix> | pecl:<name> | removed:<hinweis> | builtin | unknown
php_module_map() {
    case "$1" in
    core | date | filter | hash | json | libxml | openssl | pcre | reflection | session | spl | standard | \
        zlib | ctype | curl | exif | fileinfo | ftp | gettext | iconv | phar | sockets | tokenizer | \
        calendar | bz2 | readline | mhash | random | cgi-fcgi | zend\ opcache | apache2handler)
        [[ "$1" == "zend opcache" ]] && echo pkg:opcache || echo builtin ;;
    mysqli | mysqlnd | pdo_mysql) echo pkg:mysqlnd ;;
    pdo | pdo_sqlite | sqlite3) echo pkg:pdo ;;
    dom | simplexml | xml | xmlreader | xmlwriter | xsl | wddx_xml) echo pkg:xml ;;
    posix | shmop | sysvmsg | sysvsem | sysvshm) echo pkg:process ;;
    pgsql | pdo_pgsql) echo pkg:pgsql ;;
    odbc | pdo_odbc) echo pkg:odbc ;;
    pdo_dblib | mssql) echo pkg:dblib ;;
    bcmath | dba | enchant | gd | gmp | intl | ldap | mbstring | opcache | pspell | snmp | soap | sodium | tidy | ffi)
        echo "pkg:$1" ;;
    zip) echo pkg-or-pecl:zip ;;
    imap) echo pkg-or-pecl:imap ;;
    apc | apcu) echo pecl:apcu ;;
    redis | igbinary | msgpack | mongodb | memcached | memcache | imagick | uuid | yaml | ssh2 | xdebug)
        echo "pecl:$1" ;;
    mongo) echo "removed:ext/mongo gibt es nicht mehr – Anwendung auf ext/mongodb umstellen" ;;
    mysql) echo "removed:ext/mysql (mysql_*) wurde in PHP 7.0 entfernt – Code muss auf mysqli/PDO umgestellt werden" ;;
    mcrypt) echo "removed:ext/mcrypt wurde in PHP 7.2 entfernt – auf openssl/sodium umstellen" ;;
    ereg) echo "removed:ext/ereg wurde in PHP 7.0 entfernt – auf preg_* umstellen" ;;
    xmlrpc) echo "removed:ext/xmlrpc wurde in PHP 8.0 entfernt" ;;
    wddx) echo "removed:ext/wddx wurde in PHP 7.4 entfernt" ;;
    recode | interbase | pdo_firebird) echo "removed:ext/$1 ist in PHP 8 nicht mehr verfügbar" ;;
    suhosin) echo "removed:suhosin gibt es für PHP 8 nicht" ;;
    "ioncube loader" | "the ioncube php loader" | "sourceguardian" | "zend guard loader")
        echo "removed:$1 muss manuell vom Hersteller für PHP $TARGET_PHP_VERSION installiert werden" ;;
    *) echo unknown ;;
    esac
}

# Entwicklungspakete, die PECL-Module zum Kompilieren brauchen
pecl_deps() {
    case "$1" in
    zip) echo libzip-devel ;;
    memcached) echo "libmemcached-awesome-devel zlib-devel cyrus-sasl-devel" ;;
    imagick) echo ImageMagick-devel ;;
    mongodb) echo "openssl-devel cyrus-sasl-devel" ;;
    imap) echo "libc-client-devel krb5-devel openssl-devel" ;;
    yaml) echo libyaml-devel ;;
    ssh2) echo libssh2-devel ;;
    uuid) echo libuuid-devel ;;
    esac
}

phase_install() {
    require_inventory
    local v=$TARGET_PHP_VERSION p m map pkgs=() pecl=() suffix

    step "Basis-Pakete"
    pkg_install httpd mod_ssl cronie rsync tar gzip logrotate openssl findutils which procps-ng

    step "PHP $v"
    if ! pkg_available "php$v"; then
        die "Paket php$v ist nicht verfügbar. Verfügbare Versionen: $(dnf -q list --available 'php8*' 2>/dev/null | awk '/^php8\.[0-9]+\./{sub(/\..*$/,"",$1); print $1}' | sort -u | tr '\n' ' ')"
    fi
    for suffix in "" -cli -fpm -common -mysqlnd -opcache -mbstring -xml -gd -pdo -process -intl -bcmath -soap -sodium; do
        pkg_available "php$v$suffix" && pkgs+=("php$v$suffix")
    done
    if [[ -f "$(inv_file php-modules.txt)" ]]; then
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            map=$(php_module_map "$m")
            case "$map" in
            builtin) ;;
            pkg:*)
                p="php$v-${map#pkg:}"
                if pkg_available "$p"; then pkgs+=("$p"); else warn "PHP-Modul '$m': Paket $p nicht verfügbar"; fi
                ;;
            pkg-or-pecl:*)
                p="php$v-${map#pkg-or-pecl:}"
                if pkg_available "$p"; then pkgs+=("$p"); else pecl+=("${map#pkg-or-pecl:}"); fi
                ;;
            pecl:*)
                [[ "${map#pecl:}" == xdebug ]] && { log "xdebug wird auf dem Produktivsystem nicht installiert."; continue; }
                p="php$v-${map#pecl:}"
                if pkg_available "$p"; then pkgs+=("$p"); else pecl+=("${map#pecl:}"); fi
                ;;
            removed:*) warn "PHP-Modul '$m': ${map#removed:}" ;;
            unknown)
                p="php$v-$m"
                if pkg_available "$p"; then pkgs+=("$p"); else warn "PHP-Modul '$m' der Quelle ist auf dem Ziel nicht bekannt – bitte manuell prüfen"; fi
                ;;
            esac
        done <"$(inv_file php-modules.txt)"
    fi
    mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
    pkg_install "${pkgs[@]}"

    if [[ ${#pecl[@]} -gt 0 ]]; then
        if is_yes "$PECL_AUTO"; then
            install_pecl "${pecl[@]}"
        else
            warn "Folgende PHP-Erweiterungen fehlen und müssen per PECL installiert werden: ${pecl[*]}"
        fi
    fi

    step "Datenbank ($TARGET_DB_ENGINE)"
    if is_yes "$MIGRATE_DATABASE"; then
        db_install
    else
        log "MIGRATE_DATABASE=no – keine lokale Datenbank."
        pkg_available "mariadb1011" && pkg_install mariadb1011 || pkg_install mariadb105 || true
    fi

    step "Mailserver"
    local mta
    mta=$(inv_get SRC_MTA)
    if [[ "$INSTALL_MTA" == yes || ("$INSTALL_MTA" == auto && "$mta" != none && -n "$mta") ]]; then
        pkg_install postfix
        configure_postfix
        run systemctl enable --now postfix
        run systemctl restart postfix
    else
        log "Kein Mailserver (Quelle: ${mta:-?}, INSTALL_MTA=$INSTALL_MTA)."
    fi

    step "Zeitzone"
    local tz
    tz=$(inv_get SRC_TIMEZONE)
    if [[ -n "$tz" && -e "/usr/share/zoneinfo/$tz" ]]; then
        run timedatectl set-timezone "$tz" || warn "Zeitzone $tz konnte nicht gesetzt werden"
    fi

    step "Dienste aktivieren"
    run systemctl enable --now php-fpm
    run systemctl enable --now crond
    run systemctl enable httpd   # Start erst nach der Konfiguration
}

# postfix wie den alten Mailserver auftreten lassen: gleicher Hostname im
# HELO/Absender, und nur IPv4 – EC2-IPv6-Adressen haben meist kein
# Reverse-DNS, große Anbieter (z.B. Microsoft 365) lehnen das ab.
configure_postfix() {
    local host
    host=$(inv_get SRC_HOSTNAME)
    run postconf -e "inet_protocols = ipv4"
    if [[ "$host" == *.* ]]; then
        run postconf -e "myhostname = $host"
    else
        warn "postfix: Hostname der Quelle unbekannt – myhostname bitte manuell setzen (postconf -e myhostname=...)"
    fi
    log "postfix: Ausgehende Mails gehen direkt über Port 25. Falls Mails nicht ankommen: AWS blockiert Port 25 standardmäßig (Freigabe beantragen oder Amazon SES als Relay nutzen)."
}

install_pecl() {
    local v=$TARGET_PHP_VERSION ext deps pear=php-pear ini
    pkg_available "php$v-pear" && pear="php$v-pear"
    pkg_install gcc make "php$v-devel" "$pear" || { warn "Build-Werkzeuge für PECL nicht installierbar – PECL übersprungen: $*"; return 0; }
    for ext in "$@"; do
        ini="/etc/php.d/40-$ext.ini"
        if php -m 2>/dev/null | grep -qix "$ext"; then continue; fi
        log "PECL: $ext"
        deps=$(pecl_deps "$ext")
        if [[ -n "$deps" ]]; then
            # shellcheck disable=SC2086
            pkg_install $deps || { warn "PECL $ext: Abhängigkeiten ($deps) nicht verfügbar – übersprungen"; continue; }
        fi
        if yes '' | pecl install -f "$ext" >>"$LOG_FILE" 2>&1; then
            [[ -f "$ini" ]] || echo "extension=$ext.so" >"$ini"
        else
            warn "PECL-Installation von '$ext' fehlgeschlagen (Details: $LOG_FILE)"
        fi
    done
    # igbinary/msgpack müssen vor redis/memcached geladen werden
    [[ -f /etc/php.d/40-igbinary.ini ]] && mv /etc/php.d/40-igbinary.ini /etc/php.d/30-igbinary.ini
    [[ -f /etc/php.d/40-msgpack.ini ]] && mv /etc/php.d/40-msgpack.ini /etc/php.d/30-msgpack.ini
    return 0
}

# ---------------------------------------------------------------------------
# Datenbank-Server
# ---------------------------------------------------------------------------
db_install() {
    local svc
    svc=$(db_service)
    case "$TARGET_DB_ENGINE" in
    mariadb)
        local p
        for p in mariadb1011-server mariadb105-server; do
            if pkg_available "$p"; then pkg_install "$p"; break; fi
        done
        rpm -q mariadb1011-server >/dev/null 2>&1 || rpm -q mariadb105-server >/dev/null 2>&1 ||
            die "Kein MariaDB-Server-Paket gefunden."
        ;;
    mysql84)
        if ! rpm -q mysql-community-server >/dev/null 2>&1; then
            rpm -q mysql84-community-release >/dev/null 2>&1 || run dnf -y install "$MYSQL84_REPO_RPM"
            pkg_install mysql-community-server
        fi
        ;;
    esac

    db_write_config
    run systemctl enable --now "$svc"
    db_root_setup
}

db_write_config() {
    local f tmp k v sqlmode pkt
    f=$(inv_file mysql-variables.tsv)
    tmp=$(mktemp)
    {
        echo "# Automatisch erzeugt durch LinuxServerMigration – Werte vom alten Server"
        echo "[mysqld]"
        if [[ -f "$f" ]]; then
            while IFS=$'\t' read -r k v; do
                case "$k" in
                sql_mode)
                    sqlmode=$v
                    if [[ "$TARGET_DB_ENGINE" == mysql84 ]]; then
                        # In MySQL 8 entfernte Modi
                        sqlmode=$(tr ',' '\n' <<<"$v" | { grep -vxE 'NO_AUTO_CREATE_USER|NO_FIELD_OPTIONS|NO_KEY_OPTIONS|NO_TABLE_OPTIONS|DB2|MAXDB|MSSQL|MYSQL323|MYSQL40|ORACLE|POSTGRESQL' || true; } | paste -sd, -)
                    fi
                    echo "sql_mode = \"$sqlmode\""
                    ;;
                max_allowed_packet)
                    pkt=$v
                    [[ "$pkt" =~ ^[0-9]+$ && $pkt -ge 67108864 ]] || pkt=67108864
                    echo "max_allowed_packet = $pkt"
                    ;;
                character_set_server | collation_server | lower_case_table_names | max_connections | \
                    wait_timeout | ft_min_word_len | group_concat_max_len)
                    echo "$k = $v"
                    ;;
                event_scheduler) [[ "$v" == ON ]] && echo "event_scheduler = ON" ;;
                esac
            done <"$f"
        fi
        if [[ "$TARGET_DB_ENGINE" == mysql84 ]]; then
            echo "# Passwort-Hashes vom alten Server verwenden mysql_native_password"
            echo "mysql_native_password = ON"
        fi
    } >"$tmp"
    install_generated "$tmp" /etc/my.cnf.d/99-migration.cnf
    grep -q '^!includedir /etc/my.cnf.d' /etc/my.cnf 2>/dev/null || echo '!includedir /etc/my.cnf.d' >>/etc/my.cnf
    rm -f "$tmp"
}

# root-Zugang einrichten und in /root/.my.cnf hinterlegen
db_root_setup() {
    local pw p tmp_pw
    if [[ -f "$TARGET_MY_CNF" ]] && tmysql -e 'SELECT 1' >/dev/null 2>&1; then
        log "Datenbank-root-Zugang über $TARGET_MY_CNF funktioniert."
        return 0
    fi
    pw=$TARGET_DB_ROOT_PASS
    if [[ -z "$pw" && "$SRC_DB_USER" == root && -n "$SRC_DB_PASS" ]]; then pw=$SRC_DB_PASS; fi
    [[ -n "$pw" ]] || pw="$(openssl rand -hex 12)Aa1-"

    case "$TARGET_DB_ENGINE" in
    mariadb)
        "$(mysql_client)" -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD($(sql_quote "$pw")); DROP USER IF EXISTS ''@'localhost'; DROP USER IF EXISTS ''@'$(hostname)'; FLUSH PRIVILEGES;" ||
            die "root-Passwort für MariaDB konnte nicht gesetzt werden."
        ;;
    mysql84)
        tmp_pw=$({ grep 'temporary password' /var/log/mysqld.log 2>/dev/null || true; } | tail -1 | awk '{print $NF}')
        [[ -n "$tmp_pw" ]] || die "Temporäres MySQL-root-Passwort nicht in /var/log/mysqld.log gefunden. Bitte TARGET_DB_ROOT_PASS korrekt setzen und /root/.my.cnf anlegen."
        MYSQL_PWD=$tmp_pw "$(mysql_client)" -uroot --connect-expired-password \
            -e "ALTER USER 'root'@'localhost' IDENTIFIED BY $(sql_quote "$pw");" ||
            die "root-Passwort für MySQL konnte nicht gesetzt werden (Passwortrichtlinie? Mind. 8 Zeichen, Groß/Klein, Ziffer, Sonderzeichen)."
        ;;
    esac
    p=${pw//\\/\\\\}
    p=${p//\"/\\\"}
    (umask 077; printf '[client]\nuser=root\npassword="%s"\n' "$p" >"$TARGET_MY_CNF")
    tmysql -e 'SELECT 1' >/dev/null || die "Anmeldung mit $TARGET_MY_CNF schlägt fehl."
    if [[ -z "$TARGET_DB_ROOT_PASS" && "$pw" != "$SRC_DB_PASS" ]]; then
        warn "Neues Datenbank-root-Passwort wurde erzeugt und in $TARGET_MY_CNF gespeichert."
    fi
    if [[ "$(awk -F'\t' '$1=="test"' "$(inv_file mysql-databases.tsv)" 2>/dev/null)" == "" ]]; then
        tmysql -e 'DROP DATABASE IF EXISTS test' || true
    fi
}
