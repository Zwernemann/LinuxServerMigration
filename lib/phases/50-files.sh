# shellcheck shell=bash
# Phase "files": Webverzeichnisse, Home-Verzeichnisse und Zertifikate kopieren.
# Kann beliebig oft wiederholt werden (rsync überträgt nur Änderungen).

# Alle zu synchronisierenden Web-Pfade (WEB_PATHS + DocumentRoots), ohne
# Pfade, die bereits in einem anderen enthalten sind.
web_paths() {
    local all=() p q k skip
    # shellcheck disable=SC2206
    all=($WEB_PATHS)
    if [[ -f "$(inv_file httpd-paths.tsv)" ]]; then
        while IFS=$'\t' read -r k p; do
            [[ "${k,,}" == documentroot && -n "$p" ]] && all+=("${p%/}")
        done <"$(inv_file httpd-paths.tsv)"
    fi
    mapfile -t all < <(printf '%s\n' "${all[@]}" | sed 's:/*$::' | { grep -v '^$' || true; } | sort -u)
    for p in "${all[@]}"; do
        skip=0
        for q in "${all[@]}"; do
            [[ "$p" != "$q" && "$p" == "$q"/* ]] && skip=1
        done
        [[ $skip == 0 ]] && printf '%s\n' "$p"
    done
    return 0
}

# Optionen für die Web-Synchronisation. Die .user.ini- und .pre-migration-
# Dateien, die auf dem Ziel entstehen, werden vor --delete geschützt.
web_rsync_opts() {
    local o=(--filter 'P .user.ini' --filter 'P *.pre-migration')
    is_yes "$FILES_DELETE" && o+=(--delete)
    printf '%s\0' "${o[@]}"
}

phase_files() {
    require_inventory
    local p excl=() wopts=() existing
    mapfile -d '' -t excl < <(rsync_excludes)
    mapfile -d '' -t wopts < <(web_rsync_opts)

    step "Webverzeichnisse"
    local paths=()
    mapfile -t paths < <(web_paths)
    for p in "${paths[@]}"; do
        if ! src_ssh "sudo -n test -d '$p'"; then warn "Pfad $p existiert auf der Quelle nicht – übersprungen"; continue; fi
        log "Synchronisiere $p ..."
        mkdir -p "$p"
        sync_dir "${wopts[@]}" "${excl[@]}" "$SRC:$p/" "$p/"
    done

    if is_yes "$MIGRATE_HOME_DIRS"; then
        step "Home-Verzeichnisse"
        # ec2-user/.ssh nicht überschreiben – sonst sperrt man sich aus.
        sync_dir "${excl[@]}" --exclude '/ec2-user/.ssh/' --exclude '/ec2-user/.bash_history' \
            "$SRC:/home/" /home/
    fi

    step "Zertifikate und weitere Pfade"
    local k f
    if [[ -f "$(inv_file httpd-paths.tsv)" ]]; then
        while IFS=$'\t' read -r k f; do
            [[ "${k,,}" == ssl* && -n "$f" ]] || continue
            mkdir -p "$(dirname "$f")"
            src_rsync -L "$SRC:$f" "$f" 2>/dev/null || warn "Zertifikatsdatei $f konnte nicht kopiert werden"
        done <"$(inv_file httpd-paths.tsv)"
    fi
    existing=$(src_ssh "sudo -n sh -c 'for p in /etc/letsencrypt /root/.acme.sh $EXTRA_PATHS; do [ -e \"\$p\" ] && echo \"\$p\"; done'" || true)
    for p in $existing; do
        log "Kopiere $p ..."
        if src_ssh "sudo -n test -d '$p'"; then
            mkdir -p "$p"
            src_rsync "${excl[@]}" "$SRC:$p/" "$p/"
        else
            mkdir -p "$(dirname "$p")"
            src_rsync "$SRC:$p" "$p"
        fi
    done

    step "Anpassungen im Webverzeichnis"
    webroot_adjust
    acmesh_adjust
    php_compat_scan
}

# rsync mit Statistik ins Log. Exit-Code 24 ("Dateien während der Übertragung
# verschwunden") ist auf einem laufenden System normal.
sync_dir() {
    local out rc=0
    out=$(mktemp)
    src_rsync --stats "$@" >"$out" 2>&1 || rc=$?
    grep -E '^(Number of (regular )?files transferred|Total transferred file size|rsync (error|warning))' "$out" |
        sed 's/^/    /' | tee -a "$LOG_FILE" >&2 || true
    if [[ $rc -ne 0 && $rc -ne 24 ]]; then
        tail -n 20 "$out" >>"$LOG_FILE"
        rm -f "$out"
        die "rsync fehlgeschlagen (Code $rc): ${*: -2:1}"
    fi
    rm -f "$out"
}

# acme.sh: Reload-Befehle mit "service"/Init-Skripten gibt es auf AL2023 nicht
# mehr – auf systemctl umstellen. Läuft nach jedem Sync, weil rsync die
# Einstellungen der Quelle zurückkopiert.
acmesh_adjust() {
    local f cmd new
    for f in /root/.acme.sh/*/*.conf; do
        [[ -f "$f" ]] || continue
        cmd=$(sed -n "s/^Le_ReloadCmd='\(.*\)'$/\1/p" "$f")
        if [[ "$cmd" == __ACME_BASE64__START_* ]]; then
            cmd=${cmd#__ACME_BASE64__START_}
            cmd=$(base64 -d <<<"${cmd%__ACME_BASE64__END_}" 2>/dev/null || true)
        fi
        [[ -n "$cmd" ]] || continue
        new=$(sed -E 's#(/sbin/|/usr/sbin/)?service[[:space:]]+httpd[[:space:]]+(restart|reload|force-reload|graceful)#systemctl reload httpd#g;
                      s#/etc/init\.d/httpd[[:space:]]+(restart|reload|force-reload|graceful)#systemctl reload httpd#g' <<<"$cmd")
        if [[ "$new" != "$cmd" ]]; then
            sed -i "s|^Le_ReloadCmd=.*|Le_ReloadCmd='$new'|" "$f"
            log "acme.sh ($(basename "$(dirname "$f")")): Reload-Befehl '$cmd' -> '$new'"
        elif [[ "$cmd" == *service* || "$cmd" == */etc/init.d/* ]]; then
            warn "acme.sh ($(basename "$(dirname "$f")")): Reload-Befehl '$cmd' bitte auf systemctl umstellen"
        fi
    done
}

# .htaccess an PHP-FPM und Apache 2.4 anpassen. Muss nach jedem Sync laufen,
# weil rsync die Originale der Quelle zurückkopiert.
webroot_adjust() {
    local p f paths=()
    mapfile -t paths < <(web_paths)
    for p in "${paths[@]}"; do
        [[ -d "$p" ]] || continue
        if is_yes "$PHP_DIRECTIVES_TO_USERINI"; then
            while IFS= read -r -d '' f; do
                "$TOOL_DIR/tools/php-to-userini.sh" htaccess "$f" 2>>"$WORK_DIR/htaccess.log" || true
            done < <(find "$p" -name .htaccess -type f -print0 2>/dev/null |
                xargs -0 -r grep -lZiE '^[[:space:]]*php_(admin_)?(value|flag)[[:space:]]' 2>/dev/null || true)
        fi
        if is_yes "$APACHE_CONVERT_ACCESS"; then
            while IFS= read -r -d '' f; do
                "$TOOL_DIR/tools/apache24-convert.sh" -i "$f" 2>>"$WORK_DIR/htaccess.log" || true
            done < <(find "$p" -name .htaccess -type f -print0 2>/dev/null |
                xargs -0 -r grep -lZiE '^[[:space:]]*(order|allow[[:space:]]+from|deny[[:space:]]+from)[[:space:]]' 2>/dev/null || true)
        fi
    done
    if [[ -s "$WORK_DIR/htaccess.log" ]]; then
        log "Angepasste .htaccess-Dateien: $(grep -c '^konvertiert' "$WORK_DIR/htaccess.log" || true) (Details: $WORK_DIR/htaccess.log)"
        { grep -v '^konvertiert' "$WORK_DIR/htaccess.log" || true; } | sort -u | while IFS= read -r f; do warn "$f"; done
        : >"$WORK_DIR/htaccess.log"
    fi
}

php_compat_scan() {
    local paths=()
    mapfile -t paths < <(web_paths)
    [[ ${#paths[@]} -gt 0 ]] || return 0
    log "Prüfe PHP-Code auf PHP-8-Inkompatibilitäten ..."
    if "$TOOL_DIR/tools/php8-compat-scan.sh" -o "$WORK_DIR/php8-compat.md" "${paths[@]}"; then
        log "PHP-8-Scan: keine kritischen Funde ($WORK_DIR/php8-compat.md)"
    else
        warn "PHP-8-Scan: kritische Funde im Code – siehe $WORK_DIR/php8-compat.md"
    fi
}
