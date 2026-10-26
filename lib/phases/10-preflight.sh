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
        die "SSH zu $SRC fehlgeschlagen. Security Group (Port $SRC_SSH_PORT vom neuen Server erlaubt?), Benutzer und Schlüssel prüfen."
    src_ssh 'sudo -n true' 2>/dev/null ||
        die "Auf der Quelle ist 'sudo' ohne Passwort/TTY nicht möglich. Auf der Quelle ausführen:
    echo 'Defaults:$SRC_SSH_USER !requiretty' | sudo tee /etc/sudoers.d/99-migration
    echo '$SRC_SSH_USER ALL=(ALL) NOPASSWD: ALL' | sudo tee -a /etc/sudoers.d/99-migration"

    local rel
    rel=$(src_ssh 'cat /etc/system-release' 2>/dev/null || true)
    log "Quelle: $rel"
    [[ "$rel" == *"Amazon Linux"* ]] || warn "Quelle meldet sich nicht als Amazon Linux: '$rel'"

    if ! src_ssh 'command -v rsync >/dev/null'; then
        log "Installiere rsync auf der Quelle ..."
        src_ssh 'sudo -n yum -y -q install rsync' || die "rsync konnte auf der Quelle nicht installiert werden."
    fi

    log "Freier Speicher auf dem Ziel:"
    df -hP / /var 2>/dev/null | tee -a "$LOG_FILE" >&2 || true
    log "Preflight OK."
}
