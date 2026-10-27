# shellcheck shell=bash
# Phase "database": Datenbanken, Benutzer und Rechte übertragen.
# Wiederholbar: Dumps enthalten DROP DATABASE IF EXISTS.

phase_database() {
    require_inventory
    if ! is_yes "$MIGRATE_DATABASE"; then log "MIGRATE_DATABASE=no – übersprungen."; return 0; fi
    [[ "$(inv_get SRC_MYSQL_OK)" == 1 ]] ||
        die "MySQL auf der Quelle war bei der Inventarisierung nicht erreichbar – SRC_DB_* prüfen und 'inventory' wiederholen."
    systemctl is-active -q "$(db_service)" || run systemctl start "$(db_service)"
    tmysql -e 'SELECT 1' >/dev/null 2>&1 || die "Kein Zugriff auf die Ziel-Datenbank – zuerst 'install' ausführen."

    local dir="$WORK_DIR/dump" sv db f n
    mkdir -p "$dir"
    chmod 700 "$dir"
    mapfile -t sv < <(src_vars)
    local dbs=()
    mapfile -t dbs < <(db_list)

    step "Export auf der Quelle"
    src_run DUMP_MODE=accounts "DB_USER_EXCLUDE=$DB_USER_EXCLUDE" "TARGET_DB_ENGINE=$TARGET_DB_ENGINE" "${sv[@]}" -- "$TOOL_DIR/remote/dump.sh" \
        >"$dir/accounts.sql" || die "Export der MySQL-Benutzer fehlgeschlagen."
    awk -v u="$dir/users.sql" -v g="$dir/grants.sql" '/^-- @@GRANTS@@/ {gr=1} {print > (gr ? g : u)}' "$dir/accounts.sql"
    { grep '^-- WARN' "$dir/accounts.sql" || true; } | sed 's/^-- WARN: //' | while IFS= read -r n; do warn "MySQL-Benutzer: $n"; done

    for db in "${dbs[@]}"; do
        f="$dir/${db//\//_}.sql.gz"
        log "Dump $db ..."
        src_run DUMP_MODE=db "DUMP_DB=$db" "${sv[@]}" -- "$TOOL_DIR/remote/dump.sh" >"$f.part" ||
            die "Dump von $db fehlgeschlagen."
        gzip -t "$f.part" || die "Dump von $db ist beschädigt."
        zcat "$f.part" | tail -n 1 | grep -q 'Dump completed' || die "Dump von $db ist unvollständig."
        mv -f "$f.part" "$f"
        log "    $(du -h "$f" | cut -f1) komprimiert"
    done

    step "Import auf dem Ziel"
    tmysql <"$dir/users.sql" || die "Anlegen der MySQL-Benutzer fehlgeschlagen."
    for db in "${dbs[@]}"; do
        f="$dir/${db//\//_}.sql.gz"
        log "Importiere $db ..."
        if [[ "$TARGET_DB_ENGINE" == mysql84 ]]; then
            # NO_AUTO_CREATE_USER gibt es in MySQL 8 nicht mehr (steht in Routinen-Dumps)
            zcat "$f" | sed -E '/sql_mode/ { s/NO_AUTO_CREATE_USER,//g; s/,?NO_AUTO_CREATE_USER//g }' |
                tmysql --max-allowed-packet=1G
        else
            zcat "$f" | tmysql --max-allowed-packet=1G
        fi || die "Import von $db fehlgeschlagen."
    done

    log "Rechte setzen ..."
    tmysql --force <"$dir/grants.sql" 2>"$dir/grants.err" || true
    if [[ -s "$dir/grants.err" ]]; then
        warn "$(wc -l <"$dir/grants.err") GRANT-Anweisungen schlugen fehl – siehe $dir/grants.err"
    fi
    tmysql -e 'FLUSH PRIVILEGES'
    log "Datenbanken übertragen: ${dbs[*]:-keine}"
}
