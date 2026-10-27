# shellcheck shell=bash
# Datenbank-Export. Läuft auf der QUELLE (oder mit DB_CNF_FILE lokal).
#   DUMP_MODE=db       DUMP_DB=<name>     -> gzip-SQL-Dump auf stdout
#   DUMP_MODE=accounts DB_USER_EXCLUDE=…  -> SQL für Benutzer + Rechte
#   DUMP_MODE=counts   DUMP_DBS="a b c"   -> db<TAB>objekt<TAB>anzahl
exec 3>&1 1>&2
mysql_setup

case "${DUMP_MODE:-}" in
# ---------------------------------------------------------------------------
db)
    rlog "Exportiere Datenbank ${DUMP_DB} ..."
    extra=()
    # MySQL 5.6+ mit GTIDs: ohne diese Option scheitert ein zweiter Import
    # (Cutover) an "GTID_PURGED can only be set when GTID_EXECUTED is empty"
    if "$(mysqldump_bin)" --help 2>/dev/null | grep -q -- '--set-gtid-purged'; then
        extra+=(--set-gtid-purged=OFF)
    fi
    "$(mysqldump_bin)" --defaults-extra-file="$MY_CNF" \
        --single-transaction --quick --routines --triggers --events \
        --hex-blob --add-drop-database --default-character-set=utf8mb4 \
        --max-allowed-packet=1G ${extra[@]+"${extra[@]}"} --databases "$DUMP_DB" </dev/null | gzip -c >&3
    ;;
# ---------------------------------------------------------------------------
accounts)
    rlog "Exportiere MySQL-Benutzer und Rechte ..."
    has_col() {
        q "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='mysql'
            AND table_name='user' AND column_name='$1'"
    }
    # MySQL 5.5/5.6: Spalte "Password", 5.7: "authentication_string"
    if [ "$(has_col Password)" != 0 ] && [ "$(has_col authentication_string)" != 0 ]; then
        pw="IF(COALESCE(authentication_string,'')<>'', authentication_string, Password)"
    elif [ "$(has_col Password)" != 0 ]; then
        pw="Password"
    else
        pw="authentication_string"
    fi
    if [ "$(has_col plugin)" != 0 ]; then plugin="COALESCE(plugin,'')"; else plugin="''"; fi

    excl="''"
    for u in ${DB_USER_EXCLUDE:-root}; do excl="$excl,$(sqlq "$u")"; done

    # Präfixe "h:"/"p:", weil read leere Felder zwischen Tabs zusammenfasst
    users=$(q "SELECT User, Host, CONCAT('h:', COALESCE($pw, '')), CONCAT('p:', $plugin)
                 FROM mysql.user WHERE User NOT IN ($excl)")
    # MySQL -> MySQL 8.4: Konten 1:1 per SHOW CREATE USER übernehmen, auch mit
    # caching_sha2_password (Standard ab MySQL 8.0). Der Hash ist binär und
    # wird deshalb hexadezimal ausgegeben (MySQL >= 8.0.17).
    scu=0
    case "$(q 'SELECT VERSION()')" in
    *MariaDB* | 5.5.* | 5.6.*) ;;
    *) [ "${TARGET_DB_ENGINE:-}" = mysql84 ] && scu=1 ;;
    esac
    {
        echo "-- @@USERS@@"
        printf '%s\n' "$users" | while IFS=$'\t' read -r user host hash plug; do
            [ -n "$user" ] || continue
            acct="$(sqlq "$user")@$(sqlq "$host")"
            hash=${hash#h:}
            plug=${plug#p:}
            if [ $scu = 1 ]; then
                case "$plug" in
                mysql_native_password | caching_sha2_password | sha256_password | '') ;;
                *)
                    echo "-- WARN: $acct verwendet Plugin '$plug' – übersprungen"
                    continue
                    ;;
                esac
                cu=$(q "SET SESSION print_identified_with_as_hex = ON; SHOW CREATE USER $acct" 2>/dev/null)
                if [ -z "$cu" ] && [ "$plug" != caching_sha2_password ] && [ "$plug" != sha256_password ]; then
                    cu=$(q "SHOW CREATE USER $acct" 2>/dev/null)
                fi
                if [ -n "$cu" ]; then
                    [ -n "$hash" ] || echo "-- WARN: $acct hat KEIN Passwort"
                    echo "DROP USER IF EXISTS $acct;"
                    echo "$cu;"
                    continue
                fi
                echo "-- WARN: $acct konnte nicht 1:1 exportiert werden (MySQL < 8.0.17?) – Passwort auf dem Ziel neu setzen"
            fi
            case "$plug" in
            '' | mysql_native_password) ;;
            *)
                echo "-- WARN: $acct verwendet Plugin '$plug' – übersprungen"
                continue
                ;;
            esac
            if [ ${#hash} -eq 41 ] && [ "${hash:0:1}" = '*' ]; then
                echo "CREATE USER IF NOT EXISTS $acct IDENTIFIED WITH mysql_native_password AS '$hash';"
                echo "ALTER USER $acct IDENTIFIED WITH mysql_native_password AS '$hash';"
            elif [ -z "$hash" ]; then
                echo "-- WARN: $acct hat KEIN Passwort"
                echo "CREATE USER IF NOT EXISTS $acct;"
            else
                echo "-- WARN: $acct hat einen alten Passwort-Hash (vor MySQL 4.1) – Konto gesperrt angelegt, Passwort neu setzen!"
                echo "CREATE USER IF NOT EXISTS $acct ACCOUNT LOCK;"
            fi
        done
        echo "-- @@GRANTS@@"
        printf '%s\n' "$users" | while IFS=$'\t' read -r user host hash plug; do
            [ -n "$user" ] || continue
            acct="$(sqlq "$user")@$(sqlq "$host")"
            q "SHOW GRANTS FOR $acct" | sed -E \
                -e "s/ IDENTIFIED BY PASSWORD ('[^']*'|<secret>)//" \
                -e 's/$/;/'
        done
    } >&3
    ;;
# ---------------------------------------------------------------------------
counts)
    list="''"
    for d in ${DUMP_DBS:-}; do list="$list,$(sqlq "$d")"; done
    {
        q "SELECT CONCAT('SELECT ', QUOTE(table_schema), ', ', QUOTE(table_name), ', COUNT(*) FROM \`',
                  REPLACE(table_schema, '\`', '\`\`'), '\`.\`', REPLACE(table_name, '\`', '\`\`'), '\`;')
             FROM information_schema.tables
            WHERE table_type = 'BASE TABLE' AND table_schema IN ($list)
            ORDER BY table_schema, table_name"
        echo "SELECT routine_schema, CONCAT('@', LOWER(routine_type)), COUNT(*) FROM information_schema.routines WHERE routine_schema IN ($list) GROUP BY 1, 2;"
        echo "SELECT table_schema, '@views', COUNT(*) FROM information_schema.views WHERE table_schema IN ($list) GROUP BY 1;"
        echo "SELECT trigger_schema, '@triggers', COUNT(*) FROM information_schema.triggers WHERE trigger_schema IN ($list) GROUP BY 1;"
        echo "SELECT event_schema, '@events', COUNT(*) FROM information_schema.events WHERE event_schema IN ($list) GROUP BY 1;"
    } | "$(mysql_bin)" --defaults-extra-file="$MY_CNF" -N -B | LC_ALL=C sort >&3
    ;;
*)
    rlog "Unbekannter DUMP_MODE"
    exit 2
    ;;
esac
