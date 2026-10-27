# shellcheck shell=bash
# Phase "verify": Ziel mit Quelle vergleichen und Bericht schreiben.

phase_verify() {
    require_inventory
    local res="$WORK_DIR/verify" ok=0 fail=0
    rm -rf "$res"
    mkdir -p "$res"
    : >"$res/results.tsv"

    check() { # check <OK|FEHLER|WARNUNG> <bereich> <text>
        printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$res/results.tsv"
        case "$1" in
        OK) ok=$((ok + 1)); log "[OK]     $2: $3" ;;
        WARNUNG) warn "$2: $3" ;;
        *) fail=$((fail + 1)); warn "[FEHLER] $2: $3" ;;
        esac
    }

    step "Dienste"
    local svc
    for svc in httpd php-fpm $(is_yes "$MIGRATE_DATABASE" && db_service); do
        if systemctl is-active -q "$svc"; then check OK Dienst "$svc läuft"; else check FEHLER Dienst "$svc läuft nicht"; fi
    done
    if cron_allowed; then
        if systemctl is-active -q crond; then check OK Dienst "crond läuft"; else check FEHLER Dienst "crond läuft nicht"; fi
    elif systemctl is-active -q crond; then
        check WARNUNG Dienst "crond läuft schon vor dem Cutover – Cronjobs laufen doppelt (systemctl stop crond)"
    else
        check OK Dienst "crond bis zum Cutover pausiert"
    fi
    if apachectl configtest >/dev/null 2>&1; then check OK Apache "Konfigurationstest"; else check FEHLER Apache "Konfigurationstest fehlgeschlagen"; fi

    step "Dateien"
    local p diff excl=()
    mapfile -d '' -t excl < <(rsync_excludes)
    while IFS= read -r p; do
        [[ -d "$p" ]] || continue
        # Dry-Run: welche Dateien würden noch übertragen werden?
        diff=$(src_rsync -n -i --delete --filter 'P .user.ini' --filter 'P *.pre-migration' "${excl[@]}" "$SRC:$p/" "$p/" 2>/dev/null |
            grep -vE '(^|[ /])\.htaccess$' | grep -cvE '^\.d' || true)
        if [[ "$diff" == 0 ]]; then
            check OK Dateien "$p identisch mit der Quelle"
        else
            check WARNUNG Dateien "$p: $diff Abweichungen zur Quelle (vor dem Cutover normal, wenn die Quelle weiterläuft)"
        fi
    done < <(web_paths)

    if is_yes "$MIGRATE_DATABASE" && [[ "$(inv_get SRC_MYSQL_OK)" == 1 ]] && is_yes "$VERIFY_ROW_COUNTS"; then
        step "Datenbank: Zeilenzahlen"
        local dbs sv
        dbs=$(db_list | tr '\n' ' ')
        mapfile -t sv < <(src_vars)
        src_run DUMP_MODE=counts "DUMP_DBS=$dbs" "${sv[@]}" -- "$TOOL_DIR/remote/dump.sh" >"$res/counts-source.tsv" ||
            check FEHLER Datenbank "Zählung auf der Quelle fehlgeschlagen"
        cat "$TOOL_DIR/remote/common.sh" "$TOOL_DIR/remote/dump.sh" >"$res/counts.sh"
        DB_CNF_FILE=$TARGET_MY_CNF DUMP_MODE=counts DUMP_DBS=$dbs bash "$res/counts.sh" >"$res/counts-target.tsv" ||
            check FEHLER Datenbank "Zählung auf dem Ziel fehlgeschlagen"
        if diff "$res/counts-source.tsv" "$res/counts-target.tsv" >"$res/counts.diff"; then
            check OK Datenbank "$(wc -l <"$res/counts-source.tsv") Tabellen/Objekte mit identischer Anzahl"
        else
            check WARNUNG Datenbank "$(grep -c '^[<>]' "$res/counts.diff") Abweichungen (Details: $res/counts.diff; vor dem Cutover normal, wenn die Quelle weiterläuft)"
        fi
    fi

    step "HTTP-Vergleich (Quelle vs. Ziel)"
    verify_http check

    if is_yes "$PHP_LINT"; then
        step "PHP-Syntaxprüfung (php -l)"
        local errors
        web_paths | tr '\n' '\0' | xargs -0 -r -I{} find {} -type f -name '*.php' -not -path '*/vendor/*' -print0 |
            xargs -0 -r -n 1 -P "$(nproc)" php -l -d display_errors=stdout -d log_errors=0 2>&1 |
            grep -E '^(PHP )?(Parse|Fatal) error' >"$res/php-lint.txt" || true
        errors=$(wc -l <"$res/php-lint.txt")
        if [[ $errors == 0 ]]; then check OK PHP "keine Syntaxfehler unter PHP $TARGET_PHP_VERSION"
        else check FEHLER PHP "$errors Dateien mit Syntaxfehlern unter PHP $TARGET_PHP_VERSION ($res/php-lint.txt)"; fi
    fi

    step "Fehlerprotokolle"
    local fatal
    fatal=$(cat /var/log/php-fpm/*error.log /var/log/httpd/*error_log 2>/dev/null | grep -c 'PHP Fatal' || true)
    if [[ "$fatal" == 0 ]]; then check OK Logs "keine 'PHP Fatal'-Meldungen"
    else check WARNUNG Logs "$fatal 'PHP Fatal'-Meldungen in /var/log/php-fpm bzw. /var/log/httpd"; fi

    write_report "$ok" "$fail"
    [[ $fail -eq 0 ]] || warn "$fail Prüfungen fehlgeschlagen – siehe $WORK_DIR/report.md"
}

# Alle Hostnamen (ServerName/ServerAlias) aus "httpd -S" mit Port
vhost_names() {
    httpd -S 2>/dev/null | awk '
        /port [0-9]+ namevhost/ { for (i = 1; i <= NF; i++) if ($i == "port") { port = $(i+1); print port "\t" $(i+3); break } }
        /^[ \t]+alias / { print port "\t" $2 }
        /^[^ \t]+:[0-9]+[ \t]/ && $0 !~ /NameVirtualHost/ { n = split($1, a, ":"); print a[n] "\t" $2 }' |
        { grep -v $'\tlocalhost$' || true; } | sort -u
}

verify_http() {
    local check_fn=$1 port name path scheme t s url res="$WORK_DIR/verify"
    local entries
    entries=$(vhost_names)
    [[ -n "$entries" ]] || entries=$'80\tlocalhost'
    : >"$res/http.tsv"
    while IFS=$'\t' read -r port name; do
        [[ "$name" == *'*'* ]] && continue
        scheme=http
        [[ "$port" == 443 ]] && scheme=https
        for path in $VERIFY_URL_PATHS; do
            url="$scheme://$name:$port$path"
            t=$(curl -sk --noproxy '*' -o "$res/body" -w '%{http_code} %{size_download}' --max-time 30 \
                --resolve "$name:$port:127.0.0.1" "$url" || echo "000 0")
            s=$(src_ssh "curl -sk --noproxy '*' -o /dev/null -w '%{http_code} %{size_download}' --max-time 30 --resolve '$name:$port:127.0.0.1' '$url'" 2>/dev/null </dev/null || echo "000 0")
            printf '%s\t%s\t%s\n' "$url" "$s" "$t" >>"$res/http.tsv"
            if head -c 2000 "$res/body" 2>/dev/null | grep -q '<?php'; then
                "$check_fn" FEHLER HTTP "$url liefert PHP-Quelltext aus – PHP-FPM-Handler fehlt!"
            elif [[ "${t%% *}" == "${s%% *}" ]]; then
                "$check_fn" OK HTTP "$url: Status ${t%% *} (Quelle ${s%% *}), Größe ${t##* } / ${s##* } Bytes"
            elif [[ "${t%% *}" =~ ^5 ]]; then
                "$check_fn" FEHLER HTTP "$url: Ziel ${t%% *}, Quelle ${s%% *} – siehe /var/log/httpd/ und /var/log/php-fpm/"
            else
                "$check_fn" WARNUNG HTTP "$url: Ziel ${t%% *}, Quelle ${s%% *}"
            fi
        done
    done <<<"$entries"
    rm -f "$res/body"
}

write_report() {
    local ok=$1 fail=$2 r="$WORK_DIR/report.md"
    {
        echo "# Migrationsbericht"
        echo
        echo "Erstellt: $(date '+%F %T') auf $(uname -n)"
        echo
        echo "| | Quelle | Ziel |"
        echo "|---|---|---|"
        echo "| System | $(inv_get SRC_OS) | $(. /etc/os-release; echo "$PRETTY_NAME") |"
        echo "| Apache | $(inv_get SRC_HTTPD_VERSION) | $(httpd -v 2>/dev/null | sed -n 's/^Server version: Apache\/\([0-9.]*\).*/\1/p') |"
        echo "| PHP | $(inv_get SRC_PHP_VERSION) | $(php -r 'echo PHP_VERSION;' 2>/dev/null) |"
        echo "| Datenbank | $(inv_get SRC_MYSQL_VERSION) | $(tmysql -N -B -e 'SELECT VERSION()' 2>/dev/null) |"
        echo
        echo "## Ergebnis: $ok OK, $fail Fehler"
        echo
        echo "| Status | Bereich | Prüfung |"
        echo "|---|---|---|"
        awk -F'\t' '{gsub(/\|/, "\\|"); print "| " $1 " | " $2 " | " $3 " |"}' "$WORK_DIR/verify/results.tsv"
        echo
        echo "## Warnungen aus allen Phasen"
        echo
        if [[ -s "$WORK_DIR/warnings.log" ]]; then
            awk -F'\t' '{print "- **" $2 "**: " $3}' "$WORK_DIR/warnings.log" | sort -u
        else
            echo "keine"
        fi
        echo
        echo "## Weitere Dateien"
        echo
        echo "- PHP-8-Kompatibilität: \`$WORK_DIR/php8-compat.md\`"
        echo "- HTTP-Vergleich: \`$WORK_DIR/verify/http.tsv\`"
        echo "- Zeilenzahlen: \`$WORK_DIR/verify/counts.diff\`"
        echo "- Inventar der Quelle: \`$WORK_DIR/inventory/\`"
        echo "- Log: \`$LOG_FILE\`"
    } >"$r"
    log "Bericht: $r"
}
