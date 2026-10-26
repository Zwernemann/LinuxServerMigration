# shellcheck shell=bash
# Phase "inventory": Quelle analysieren und Konfigurations-Schnappschuss holen.

SNAPSHOT_PATHS="/etc/httpd /etc/php.ini /etc/php.d /etc/my.cnf /etc/my.cnf.d
/var/spool/cron /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly
/etc/logrotate.d /etc/passwd /etc/group /etc/shadow /etc/gshadow /etc/sysconfig/clock
/etc/sudoers.d /etc/postfix/main.cf /etc/mail/sendmail.mc"

phase_inventory() {
    local inv tmpdir sv p existing
    inv="$WORK_DIR/$INV_DIR_REL"
    tmpdir=$(mktemp -d "$WORK_DIR/.inv.XXXXXX")
    mapfile -t sv < <(src_vars)

    log "Analysiere die Quelle ..."
    src_run "PHP_INI_KEYS=$PHP_INI_KEYS" "${sv[@]}" -- "$TOOL_DIR/remote/inventory.sh" |
        tar -xzf - -C "$tmpdir" || die "Inventarisierung der Quelle fehlgeschlagen."
    [[ -f "$tmpdir/summary.env" ]] || die "Inventar unvollständig (summary.env fehlt)."
    rm -rf "$inv"
    mv "$tmpdir" "$inv"

    log "Hole Konfigurations-Schnappschuss ..."
    mkdir -p "$(snap /)"
    # shellcheck disable=SC2086,SC2116  # echo: Zeilenumbrüche -> Leerzeichen
    existing=$(src_ssh "sudo -n sh -c 'for p in $(echo $SNAPSHOT_PATHS); do if [ -d \"\$p\" ]; then echo \"d:\$p\"; elif [ -e \"\$p\" ]; then echo \"f:\$p\"; fi; done'" || true)
    for p in $existing; do
        if [[ "$p" == d:* ]]; then
            p=${p#d:}
            mkdir -p "$(snap "$p")"
            src_rsync --delete "$SRC:$p/" "$(snap "$p")/"
        else
            p=${p#f:}
            mkdir -p "$(dirname "$(snap "$p")")"
            src_rsync "$SRC:$p" "$(snap "$p")"
        fi
    done
    chmod -R go-rwx "$(snap /)"

    inventory_summary
}

inventory_summary() {
    local f
    step "Zusammenfassung Quelle"
    {
        echo "Betriebssystem : $(inv_get SRC_OS)"
        echo "Hostname       : $(inv_get SRC_HOSTNAME)"
        echo "Zeitzone       : $(inv_get SRC_TIMEZONE)"
        echo "Apache         : $(inv_get SRC_HTTPD_VERSION)"
        echo "PHP            : $(inv_get SRC_PHP_VERSION)  ->  Ziel: PHP $TARGET_PHP_VERSION"
        echo "MySQL          : $(inv_get SRC_MYSQL_VERSION)  ->  Ziel: $TARGET_DB_ENGINE"
        echo "Mailserver     : $(inv_get SRC_MTA)"
        echo "Datenbanken    :"
        db_list | while read -r db; do
            awk -F'\t' -v d="$db" '$1==d {printf "    %-30s %8.1f MB\n", $1, $2/1048576}' "$(inv_file mysql-databases.tsv)"
        done
        echo "Eigene/geänderte Konfigurationsdateien:"
        sed 's/^/    /' "$(inv_file custom-files.tsv)" 2>/dev/null
        echo "Beim Start aktivierte Dienste:"
        tr '\n' ' ' <"$(inv_file services-enabled.txt)" 2>/dev/null | fold -s -w 90 | sed 's/^/    /'
        echo
    } | tee -a "$LOG_FILE" >&2

    f=$(inv_file mysql-engines.tsv)
    if [[ -f "$f" ]] && awk -F'\t' '$2=="MyISAM" && $1!="mysql"' "$f" | grep -q .; then
        warn "MyISAM-Tabellen gefunden ($(awk -F'\t' '$2=="MyISAM" && $1!="mysql" {printf "%s ", $1}' "$f")) – Dumps sind nur bei gestoppter Anwendung konsistent (passiert beim Cutover automatisch)."
    fi
    if [[ "$(inv_get SRC_MYSQL_OK)" != 1 ]] && is_yes "$MIGRATE_DATABASE"; then
        warn "MySQL auf der Quelle nicht erreichbar: $(head -c 300 "$(inv_file mysql-error.txt)" 2>/dev/null). SRC_DB_* in migration.conf prüfen."
    fi
    local svc
    for svc in memcached redis vsftpd proftpd pure-ftpd fail2ban monit nginx varnish squid named dovecot mongod tomcat jenkins supervisord; do
        if grep -qx "$svc" "$(inv_file services-enabled.txt)" 2>/dev/null; then
            warn "Dienst '$svc' ist auf der Quelle aktiv – wird NICHT automatisch migriert, bitte manuell prüfen."
        fi
    done
    if [[ -s "$(inv_file sudoers.d.txt)" ]]; then
        warn "Eigene sudo-Regeln in /etc/sudoers.d gefunden ($(tr '\n' ' ' <"$(inv_file sudoers.d.txt)")) – werden nicht übernommen (siehe $(snap /etc/sudoers.d))."
    fi
}
