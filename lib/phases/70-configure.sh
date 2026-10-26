# shellcheck shell=bash
# Phase "configure": PHP-, Apache-, Cron-Konfiguration übertragen und Dienste starten.

# conf.d-Dateien, die zur Paketinstallation gehören (werden nie 1:1 kopiert)
STOCK_HTTPD_CONF="php.conf ssl.conf welcome.conf autoindex.conf userdir.conf notrace.conf manual.conf README perl.conf wsgi.conf"

phase_configure() {
    require_inventory
    mkdir -p "$WORK_DIR/gen"
    configure_php
    configure_apache
    is_yes "$MIGRATE_CRON" && configure_cron
    configure_logrotate
    is_yes "$CERTBOT_SETUP" && [[ -d /etc/letsencrypt/renewal ]] && configure_certbot

    step "Dienste neu starten"
    run systemctl restart php-fpm
    run systemctl restart httpd
    run systemctl restart crond
}

# ---------------------------------------------------------------------------
configure_php() {
    step "PHP-Konfiguration"
    local src_tsv tgt_tsv gen k v tv tz f base
    src_tsv=$(inv_file php-ini.tsv)
    tgt_tsv="$WORK_DIR/gen/php-ini-target.tsv"
    gen="$WORK_DIR/gen/99-migrated.ini"
    PHP_INI_KEYS=$PHP_INI_KEYS php -r '
        foreach (preg_split("/\s+/", getenv("PHP_INI_KEYS"), -1, PREG_SPLIT_NO_EMPTY) as $k) {
            $v = ini_get($k);
            if ($v !== false) { echo $k, "\t", $v, "\n"; }
        }' >"$tgt_tsv"
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

    # 5) Listen-Ports, Schutz der .user.ini
    {
        echo "# Automatisch erzeugt durch LinuxServerMigration"
        cat "$gen"/*.listen 2>/dev/null | sort -u
        echo
        echo "# .user.ini enthält PHP-Einstellungen und darf nicht ausgeliefert werden"
        echo '<Files ".user.ini">'
        echo '    Require all denied'
        echo '</Files>'
    } >"$gen/migrated-00-listen.conf"
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
            php5_module | php7_module | php_module | authz_default_module | authn_alias_module | \
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
