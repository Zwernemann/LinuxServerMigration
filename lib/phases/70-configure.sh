# shellcheck shell=bash
# Phase "configure": PHP-, Apache-, Cron-Konfiguration übertragen und Dienste starten.

# conf.d-Dateien, die zur Paketinstallation gehören (werden nie 1:1 kopiert)
STOCK_HTTPD_CONF="php.conf ssl.conf welcome.conf autoindex.conf userdir.conf notrace.conf manual.conf README perl.conf wsgi.conf"

phase_configure() {
    require_inventory
    mkdir -p "$WORK_DIR/gen"
    configure_php
    configure_mysql_shim
    configure_apache
    is_yes "$MIGRATE_CRON" && configure_cron
    configure_logrotate
    configure_acme

    step "Dienste neu starten"
    run systemctl restart php-fpm
    run systemctl restart httpd
    cron_service
}

# ---------------------------------------------------------------------------
configure_php() {
    step "PHP-Konfiguration"
    local src_tsv tgt_tsv gen k v tv tz f base
    src_tsv=$(inv_file php-ini.tsv)
    tgt_tsv="$WORK_DIR/gen/php-ini-target.tsv"
    gen="$WORK_DIR/gen/99-migrated.ini"
    # Standardwerte des Ziels OHNE die vom Tool selbst geschriebenen ini-Dateien
    # (sonst hält ein zweiter Lauf die eigenen Einstellungen für Unterschiede)
    local scandir
    scandir=$(mktemp -d)
    for f in /etc/php.d/*.ini; do
        case "$(basename "$f")" in 95-mysql-compat.ini | 99-migrated.ini | 90-migrated-*) continue ;; esac
        ln -s "$f" "$scandir/"
    done
    PHP_INI_SCAN_DIR=$scandir PHP_INI_KEYS=$PHP_INI_KEYS php -r '
        foreach (preg_split("/\s+/", getenv("PHP_INI_KEYS"), -1, PREG_SPLIT_NO_EMPTY) as $k) {
            $v = ini_get($k);
            if ($v !== false) { echo $k, "\t", $v, "\n"; }
        }' >"$tgt_tsv"
    rm -rf "${scandir:?}"
    tz=$(inv_get SRC_TIMEZONE)
    {
        echo "; Automatisch erzeugt durch LinuxServerMigration"
        echo "; Werte aus der php.ini des alten Servers (PHP $(inv_get SRC_PHP_VERSION)),"
        echo "; soweit sie vom PHP-$TARGET_PHP_VERSION-Standard abweichen."
        [[ -f "$src_tsv" ]] && while IFS=$'\t' read -r k v; do
            case "$k" in error_log | session.save_path | session.save_handler) continue ;; esac
            if ! tv=$(awk -F'\t' -v k="$k" '$1==k {print $2; f=1} END {exit !f}' "$tgt_tsv"); then
                warn "php.ini: '$k' gibt es in PHP $TARGET_PHP_VERSION nicht mehr (Quelle: '$v')"
                continue
            fi
            if [[ "$k" == date.timezone && -z "$v" ]]; then v=${tz:-UTC}; fi
            [[ "$v" == "$tv" ]] && continue
            if [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]]; then
                echo "$k = $v"
            else
                echo "$k = \"${v//\"/\\\"}\""
            fi
        done <"$src_tsv"
    } >"$gen"
    install_generated "$gen" /etc/php.d/99-migrated.ini

    # Eigene ini-Dateien aus /etc/php.d der Quelle (ohne extension=-Zeilen)
    while IFS=$'\t' read -r k f; do
        [[ "$f" == /etc/php.d/*.ini && "$k" == custom ]] || continue
        base=$(basename "$f")
        sed -E 's/^[[:space:]]*((zend_)?extension[[:space:]]*=)/; [migration: prüfen] \1/' "$(snap "$f")" >"$WORK_DIR/gen/$base"
        install_generated "$WORK_DIR/gen/$base" "/etc/php.d/90-migrated-$base"
    done <"$(inv_file custom-files.tsv)"

    if php -v 2>&1 | grep -qiE 'warning|error'; then
        warn "PHP meldet Startwarnungen: $(php -v 2>&1 | grep -i -m3 -E 'warning|error' | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
configure_apache() {
    step "Apache-Konfiguration"
    local gen="$WORK_DIR/gen/httpd" f base k n conf inc pattern
    rm -rf "$gen"
    mkdir -p "$gen"
    local tool="$TOOL_DIR/tools/apache-migrate-config.sh"
    local generated=()

    # 1) Haupt-httpd.conf der Quelle
    conf=$(snap /etc/httpd/conf/httpd.conf)
    if [[ -f "$conf" ]]; then
        local who
        who=$(awk 'tolower($1) ~ /^(user|group)$/ && $2 != "apache" {printf "%s %s; ", $1, $2}' "$conf")
        [[ -z "$who" ]] || warn "Apache lief auf der Quelle mit '$who' – auf dem Ziel laufen httpd und PHP-FPM als 'apache' (ggf. /etc/php-fpm.d/www.conf und Dateirechte anpassen)"
        "$tool" main "$conf" "$gen/main" >"$gen/migrated-00-main.conf"
        generated+=(migrated-00-main.conf)
    fi
    # 2) ssl.conf der Quelle (nur VirtualHosts)
    conf=$(snap /etc/httpd/conf.d/ssl.conf)
    if [[ -f "$conf" ]]; then
        "$tool" ssl "$conf" "$gen/ssl" >"$gen/migrated-10-ssl.conf"
        generated+=(migrated-10-ssl.conf)
    fi
    # 3) eigene Dateien in conf.d
    n=20
    while IFS=$'\t' read -r k f; do
        [[ "$f" == /etc/httpd/conf.d/*.conf ]] || continue
        base=$(basename "$f")
        [[ " $STOCK_HTTPD_CONF " == *" $base "* ]] && continue
        "$tool" file "$(snap "$f")" "$gen/f$n" >"$gen/migrated-$n-$base"
        generated+=("migrated-$n-$base")
        n=$((n + 1))
    done <"$(inv_file custom-files.tsv)"
    # 4) weitere Include-Verzeichnisse aus der httpd.conf (z.B. sites-enabled/*.conf)
    if [[ -f "$(snap /etc/httpd/conf/httpd.conf)" ]]; then
        while read -r inc; do
            [[ "$inc" == /* ]] || inc="/etc/httpd/$inc"
            case "$inc" in /etc/httpd/conf.d/* | /etc/httpd/conf.modules.d/*) continue ;; esac
            if [[ "$inc" != /etc/httpd/* ]]; then
                warn "Apache-Include außerhalb von /etc/httpd ($inc) – bitte manuell übernehmen"
                continue
            fi
            pattern=$(snap "$inc")
            for f in $pattern; do
                [[ -f "$f" ]] || continue
                base=$(basename "$f")
                "$tool" file "$f" "$gen/f$n" >"$gen/migrated-$n-${base%.conf}.conf"
                generated+=("migrated-$n-${base%.conf}.conf")
                n=$((n + 1))
            done
        done < <(awk 'tolower($1) ~ /^include(optional)?$/ {gsub(/"/, "", $2); print $2}' "$(snap /etc/httpd/conf/httpd.conf)")
    fi

    # 5) Listen-Ports, Schutz der .user.ini, alte PHP-Endungen, Backup-Dateien
    local legacy
    legacy=$(legacy_php_extensions)
    {
        echo "# Automatisch erzeugt durch LinuxServerMigration"
        cat "$gen"/*.listen 2>/dev/null | sort -u
        echo
        echo "# .user.ini enthält PHP-Einstellungen und darf nicht ausgeliefert werden"
        echo '<Files ".user.ini">'
        echo '    Require all denied'
        echo '</Files>'
        if [[ -n "$legacy" ]]; then
            echo
            echo "# Alte PHP-Endungen der Quelle ebenfalls über PHP-FPM ausführen"
            echo "<FilesMatch \"\\.(${legacy// /|})\$\">"
            echo "    SetHandler \"proxy:$(fpm_listen)|fcgi://localhost\""
            echo '</FilesMatch>'
        fi
        if is_yes "$DENY_BACKUP_FILES"; then
            echo
            echo "# Backup-/Restdateien (z.B. x.php.bak, x.php3_notUsed, *.inc, *.sql) nicht als Text ausliefern"
            echo "<FilesMatch \"$BACKUP_FILES_RE\">"
            echo '    Require all denied'
            echo '</FilesMatch>'
        fi
    } >"$gen/migrated-00-listen.conf"
    [[ -z "$legacy" ]] || fpm_allow_extensions "$legacy"
    is_yes "$DENY_BACKUP_FILES" && report_backup_files
    generated=(migrated-00-listen.conf "${generated[@]}")

    # Hinweise der Konvertierung
    cat "$gen"/*.notes 2>/dev/null | sort -u | while IFS= read -r n; do log "Apache: $n"; done

    # Zugriffsregeln 2.2 -> 2.4
    if is_yes "$APACHE_CONVERT_ACCESS"; then
        for f in "${generated[@]}"; do
            "$TOOL_DIR/tools/apache24-convert.sh" -i "$gen/$f" 2>&1 | grep -v '^konvertiert' |
                while IFS= read -r n; do warn "Apache: $n"; done || true
            rm -f "$gen/$f.pre-migration"
        done
    fi

    for f in "${generated[@]}"; do
        install_generated "$gen/$f" "/etc/httpd/conf.d/$f"
    done

    # php_value & Co. aus VirtualHosts -> .user.ini
    if is_yes "$PHP_DIRECTIVES_TO_USERINI"; then
        local d name val
        cat "$gen"/*.php 2>/dev/null | while IFS=$'\t' read -r d name val; do
            if [[ -d "$d" ]]; then
                "$TOOL_DIR/tools/php-to-userini.sh" add "$d" "$name" "$val" 2>&1 | while IFS= read -r n; do warn "$n"; done
                log "PHP-Einstellung $name aus der Apache-Konfiguration nach $d/.user.ini verschoben"
            else
                warn "PHP-Einstellung $name=$val gehörte zu $d, das Verzeichnis existiert nicht"
            fi
        done
    fi

    # Module, die auf der Quelle geladen waren und auf dem Ziel fehlen
    if [[ -f "$(inv_file httpd-modules.txt)" ]]; then
        local m missing=()
        while read -r m; do
            case "$m" in
            mpm_*_module | php5_module | php7_module | php_module | authz_default_module | authn_alias_module | \
                disk_cache_module | mem_cache_module | ident_module | version_module | \
                authn_default_module | cern_meta_module | asis_module | dumpio_module | \
                substitute_module | suexec_module | cgi_module | cgid_module | usertrack_module) continue ;;
            esac
            httpd -M 2>/dev/null | grep -qw "$m" || missing+=("$m")
        done <"$(inv_file httpd-modules.txt)"
        [[ ${#missing[@]} -eq 0 ]] || warn "Apache-Module der Quelle fehlen auf dem Ziel: ${missing[*]}"
    fi

    if ! apachectl configtest >"$gen/configtest.out" 2>&1; then
        cat "$gen/configtest.out" >&2
        die "Apache-Konfigurationstest fehlgeschlagen (siehe oben). Dateien in /etc/httpd/conf.d/migrated-*.conf korrigieren und 'configure' erneut ausführen."
    fi
    grep -i 'warn' "$gen/configtest.out" | while IFS= read -r n; do warn "Apache: $n"; done || true
    log "Apache-Konfigurationstest OK."
}

# Dateinamen, die gesperrt werden: PHP-Endung + Anhang (x.php.bak,
# x.php3_notUsed, x.php~) sowie *.inc, *.bak, *.old, *.orig, *.swp, *.sql
BACKUP_FILES_RE='(\.(php[0-9]?|phtml)[^0-9A-Za-z/][^/]*|\.(inc|bak|old|orig|swp|sql))$'

# Welche alten PHP-Endungen kommen in den Webverzeichnissen vor?
legacy_php_extensions() {
    case "${PHP_LEGACY_EXTENSIONS,,}" in no | false | 0) return 0 ;; esac
    local ext found=()
    for ext in php3 php4 php5 phtml; do
        if [[ "${PHP_LEGACY_EXTENSIONS,,}" == yes ]] ||
            web_paths | tr '\n' '\0' | xargs -0 -r -I{} find {} -type f -name "*.$ext" -print -quit 2>/dev/null | grep -q .; then
            found+=("$ext")
        fi
    done
    echo "${found[*]}"
}

# Socket/Adresse des PHP-FPM-Pools www für SetHandler
fpm_listen() {
    local l
    l=$(awk -F= '/^[[:space:]]*listen[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /etc/php-fpm.d/www.conf 2>/dev/null)
    l=${l:-/run/php-fpm/www.sock}
    if [[ "$l" == /* ]]; then echo "unix:$l"; else echo "fcgi://$l"; fi
}

# PHP-FPM führt aus Sicherheitsgründen nur .php aus – alte Endungen erlauben
fpm_allow_extensions() {
    local conf=/etc/php-fpm.d/www.conf exts=".php .phar" e
    for e in $1; do exts="$exts .$e"; done
    [[ -f "$conf" ]] || return 0
    if grep -q '^security.limit_extensions' "$conf"; then
        sed -i "s/^security.limit_extensions.*/security.limit_extensions = $exts/" "$conf"
    else
        printf '\n; LinuxServerMigration: alte PHP-Endungen der Quelle\nsecurity.limit_extensions = %s\n' "$exts" >>"$conf"
    fi
    log "PHP-FPM führt jetzt aus: $exts"
}

report_backup_files() {
    local p f n=0
    while IFS= read -r p; do
        [[ -d "$p" ]] || continue
        while IFS= read -r f; do
            n=$((n + 1))
            [[ $n -le 20 ]] && log "Gesperrt für Webzugriff: $f"
        done < <(find "$p" -type f 2>/dev/null | grep -E "/[^/]*$BACKUP_FILES_RE" || true)
    done < <(web_paths)
    [[ $n -eq 0 ]] || warn "$n Backup-/Restdateien im Webverzeichnis werden nicht mehr ausgeliefert (auf dem alten Server waren sie ggf. lesbar) – am besten löschen."
}

# ---------------------------------------------------------------------------
# mysql_*-Kompatibilitätsschicht für alten Code
configure_mysql_shim() {
    local mode=${PHP_MYSQL_SHIM,,} dest=/usr/share/php/linuxservermigration/mysql-compat.php
    local ini=/etc/php.d/95-mysql-compat.ini tmp n=0 p
    case "$mode" in no | false | 0) return 0 ;; esac
    if [[ "$mode" == auto ]]; then
        while IFS= read -r p; do
            [[ -d "$p" ]] || continue
            n=$((n + $({ grep -rlE --include='*.php*' --include='*.phtml' --include='*.inc' \
                '\bmysql_[a-z_]+[[:space:]]*\(' "$p" 2>/dev/null || true; } | wc -l)))
        done < <(web_paths)
        [[ $n -gt 0 ]] || return 0
    fi
    step "mysql_*-Kompatibilität"
    install -D -m 0644 "$TOOL_DIR/tools/mysql-compat.php" "$dest"
    tmp=$(mktemp)
    {
        echo "; LinuxServerMigration: mysql_*-Funktionen (in PHP 7 entfernt) über mysqli nachbilden"
        echo "auto_prepend_file = $dest"
    } >"$tmp"
    install_generated "$tmp" "$ini"
    rm -f "$tmp"
    if grep -qs '^auto_prepend_file' /etc/php.d/99-migrated.ini; then
        warn "auto_prepend_file ist auch in /etc/php.d/99-migrated.ini gesetzt und überschreibt die mysql_*-Kompatibilität – bitte zusammenführen"
    fi
    warn "Code verwendet mysql_* ($n Dateien) – Kompatibilitätsschicht aktiv ($dest). Langfristig auf mysqli/PDO umstellen."
}

# ---------------------------------------------------------------------------
configure_cron() {
    step "Cronjobs"
    local f user k
    if [[ -d "$(snap /var/spool/cron)" ]]; then
        for f in "$(snap /var/spool/cron)"/*; do
            [[ -f "$f" ]] || continue
            user=$(basename "$f")
            if ! getent passwd "$user" >/dev/null; then
                warn "Crontab von '$user' nicht übernommen – Benutzer existiert nicht"
                continue
            fi
            install_generated "$f" "/var/spool/cron/$user" 0600 "$user:"
            cron_check "$f"
        done
    fi
    while IFS=$'\t' read -r k f; do
        [[ "$f" == /etc/cron.* && "$k" == custom ]] || continue
        if [[ "$f" == /etc/cron.d/* ]]; then
            install_generated "$(snap "$f")" "$f" 0644
        else
            install_generated "$(snap "$f")" "$f" 0755
        fi
        cron_check "$(snap "$f")"
    done <"$(inv_file custom-files.tsv)"
}

cron_check() {
    if grep -vE '^[[:space:]]*#' "$1" | grep -qE '(^|[[:space:];|&])(service[[:space:]]|/etc/init\.d/|chkconfig)'; then
        warn "Cron $1 verwendet 'service'/'/etc/init.d' – auf AL2023 'systemctl' verwenden"
    fi
}

configure_logrotate() {
    local k f
    while IFS=$'\t' read -r k f; do
        [[ "$f" == /etc/logrotate.d/* && "$k" == custom ]] || continue
        install_generated "$(snap "$f")" "$f" 0644
    done <"$(inv_file custom-files.tsv)"
}

# ---------------------------------------------------------------------------
# Zertifikatserneuerung: so wie auf der Quelle (acme.sh oder certbot)
configure_acme() {
    local crons acmesh=0 certbot=0
    crons=$(cat "$(snap /var/spool/cron)"/* "$(snap /etc/cron.d)"/* 2>/dev/null | grep -v '^[[:space:]]*#' || true)
    grep -q 'acme\.sh' <<<"$crons" && acmesh=1
    grep -q 'certbot\|letsencrypt-auto' <<<"$crons" && certbot=1
    if [[ $acmesh == 1 ]]; then
        configure_acmesh
    fi
    if is_yes "$CERTBOT_SETUP" && [[ -d /etc/letsencrypt/renewal ]] && { [[ $certbot == 1 ]] || [[ $acmesh == 0 ]]; }; then
        configure_certbot
    elif [[ $acmesh == 1 && -d /etc/letsencrypt/renewal ]]; then
        log "Zertifikate werden mit acme.sh erneuert – certbot wird nicht eingerichtet."
    fi
}

configure_acmesh() {
    step "acme.sh"
    local home=/root/.acme.sh
    if [[ ! -x "$home/acme.sh" ]]; then
        warn "acme.sh wird auf der Quelle per Cron verwendet, aber $home fehlt auf dem Ziel – Phase 'files' ausführen"
        return 0
    fi
    pkg_install socat openssl 2>/dev/null || true  # curl: curl-minimal ist vorhanden
    "$home/acme.sh" --list --home "$home" 2>&1 | sed 's/^/    /' | tee -a "$LOG_FILE" >&2 || true
    acmesh_adjust
}

configure_certbot() {
    step "Let's Encrypt / certbot"
    if ! command -v certbot >/dev/null 2>&1; then
        if pkg_available certbot; then
            pkg_install certbot python3-certbot-apache 2>/dev/null || pkg_install certbot
        else
            # AL2023 enthält certbot nicht – Installation in ein venv (offizielle Empfehlung)
            pkg_install python3 augeas-libs
            [[ -x /opt/certbot/bin/certbot ]] || {
                run python3 -m venv /opt/certbot
                run /opt/certbot/bin/pip install -q --upgrade pip
                run /opt/certbot/bin/pip install -q certbot certbot-apache
            }
            ln -sf /opt/certbot/bin/certbot /usr/bin/certbot
        fi
    fi
    # Alte certbot-auto-Pfade in den Renewal-Konfigurationen sind egal; der
    # Authenticator (webroot/apache) bleibt erhalten.
    local tmp
    tmp=$(mktemp)
    echo '17 3,15 * * * root /usr/bin/certbot renew -q --deploy-hook "systemctl reload httpd"' >"$tmp"
    install_generated "$tmp" /etc/cron.d/certbot-renew 0644
    rm -f "$tmp"
    certbot certificates >>"$LOG_FILE" 2>&1 || warn "certbot certificates meldet Fehler (siehe $LOG_FILE)"
}
