# shellcheck shell=bash
# Phase "preflight": Voraussetzungen auf Ziel und Quelle prüfen.

phase_preflight() {
    [[ $EUID -eq 0 ]] || die "Bitte als root ausführen (sudo ./migrate.sh ...)."

    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "amzn" || "${VERSION_ID:-}" != "2023" ]]; then
        is_yes "${FORCE_OS:-no}" ||
            die "Dieses Skript muss auf dem NEUEN Amazon Linux 2023 laufen (gefunden: ${PRETTY_NAME:-?}). Übersteuern mit FORCE_OS=yes."
        warn "Zielsystem ist nicht Amazon Linux 2023 (${PRETTY_NAME:-?}) – FORCE_OS=yes gesetzt."
    fi
    log "Ziel: ${PRETTY_NAME:-?}"

    pkg_install rsync openssh-clients tar gzip

    [[ -z "${SRC_SSH_KEY:-}" || -r "$SRC_SSH_KEY" ]] ||
        die "SSH-Schlüssel $SRC_SSH_KEY nicht lesbar."
    [[ -z "${SRC_SSH_KEY:-}" ]] || chmod 600 "$SRC_SSH_KEY"

    log "Teste SSH-Verbindung zu $SRC ..."
    src_ssh true ||
        die "SSH zu $SRC fehlgeschlagen. Läuft SSH auf der Quelle auf Port $SRC_SSH_PORT (sonst SRC_SSH_PORT in migration.conf setzen)? Erlaubt die Security Group diesen Port vom neuen Server? Benutzer und Schlüssel prüfen."
    src_ssh 'sudo -n true' 2>/dev/null ||
        die "Auf der Quelle ist 'sudo' ohne Passwort/TTY nicht möglich. Auf der Quelle ausführen:
    echo 'Defaults:$SRC_SSH_USER !requiretty' | sudo tee /etc/sudoers.d/99-migration
    echo '$SRC_SSH_USER ALL=(ALL) NOPASSWD: ALL' | sudo tee -a /etc/sudoers.d/99-migration"

    local rel
    rel=$(src_ssh 'cat /etc/system-release' 2>/dev/null || true)
    log "Quelle: $rel"
    [[ "$rel" == *"Amazon Linux"* ]] || warn "Quelle meldet sich nicht als Amazon Linux: '$rel'"

    if ! src_ssh 'command -v rsync >/dev/null && command -v tar >/dev/null && command -v gzip >/dev/null'; then
        log "Installiere rsync/tar/gzip auf der Quelle ..."
        src_ssh 'sudo -n yum -y -q install rsync tar gzip' || die "rsync/tar/gzip konnten auf der Quelle nicht installiert werden."
    fi

    if is_yes "$MIGRATE_DATABASE"; then
        log "Teste MySQL-Zugang auf der Quelle ..."
        local sv tmp
        mapfile -t sv < <(src_vars)
        tmp=$(mktemp)
        echo 'mysql_setup; q "SELECT CURRENT_USER()" >&2' >"$tmp"
        if ! src_run "${sv[@]}" -- "$tmp" 2>>"$LOG_FILE"; then
            rm -f "$tmp"
            die "Anmeldung an MySQL auf der Quelle als '$SRC_DB_USER' fehlgeschlagen.
    -> In migration.conf SRC_DB_PASS (MySQL-root-Passwort des alten Servers) eintragen.
    -> Liegt die Datenbank z.B. in RDS, MIGRATE_DATABASE=\"no\" setzen.
    Hilfe zum Finden des Passworts: docs/ANLEITUNG.md, Abschnitt 'MySQL-Passwort'."
        fi
        rm -f "$tmp"
        log "MySQL-Zugang OK."
    fi

    log "Freier Speicher auf dem Ziel:"
    df -hP / /var 2>/dev/null | tee -a "$LOG_FILE" >&2 || true
    log "Preflight OK."
}
