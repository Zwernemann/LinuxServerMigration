# shellcheck shell=bash
# Phasen "cutover" (endgültig umschalten) und "rollback".

imds() {
    local token
    token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' --max-time 5) || return 1
    curl -sf -H "X-aws-ec2-metadata-token: $token" --max-time 5 "http://169.254.169.254/latest/meta-data/$1"
}

aws_cli() {
    command -v aws >/dev/null 2>&1 || pkg_install awscli-2 || die "aws-cli nicht verfügbar."
    if [[ -n "$AWS_REGION" ]]; then aws --region "$AWS_REGION" "$@"; else aws "$@"; fi
}

move_eip() { # move_eip <instance-id>
    log "Hänge Elastic IP $ELASTIC_IP_ALLOCATION_ID an $1 ..."
    aws_cli ec2 associate-address --allocation-id "$ELASTIC_IP_ALLOCATION_ID" \
        --instance-id "$1" --allow-reassociation >>"$LOG_FILE" ||
        die "Elastic IP konnte nicht umgehängt werden (IAM-Rechte ec2:AssociateAddress?)."
}

confirm() {
    is_yes "${ASSUME_YES:-no}" && return 0
    local a
    read -r -p "$1 [ja/NEIN] " a
    is_yes "$a"
}

phase_cutover() {
    require_inventory
    cat >&2 <<EOF

  CUTOVER – endgültige Umschaltung
  ---------------------------------
  1. Apache und cron auf der Quelle werden gestoppt (CUTOVER_STOP_SOURCE=$CUTOVER_STOP_SOURCE)
  2. Dateien und Datenbanken werden ein letztes Mal synchronisiert
  3. cron startet auf dem neuen Server, das Ziel wird geprüft
  4. Elastic IP wird umgehängt (${ELASTIC_IP_ALLOCATION_ID:-nicht konfiguriert – danach SOFORT von Hand umhängen})

  Die Website ist während dieser Zeit nicht erreichbar.
  Die Quelle wird NICHT gelöscht – Rückweg: ./migrate.sh rollback

EOF
    confirm "Cutover jetzt durchführen?" || die "Abgebrochen."

    if is_yes "$CUTOVER_STOP_SOURCE"; then
        step "Quelle stoppen"
        src_ssh 'sudo -n service httpd stop; sudo -n service crond stop' || warn "Dienste auf der Quelle ließen sich nicht stoppen"
    fi

    CURRENT_PHASE=files phase_files
    CURRENT_PHASE=database phase_database
    run systemctl restart php-fpm httpd
    touch "$WORK_DIR/cutover.done"
    cron_service
    CURRENT_PHASE=verify phase_verify

    if [[ -n "$ELASTIC_IP_ALLOCATION_ID" ]]; then
        step "Elastic IP"
        local me
        me=$(imds instance-id) || die "Instance-ID des Ziels nicht ermittelbar (IMDS)."
        move_eip "$me"
    fi

    cat >&2 <<EOF

  Cutover abgeschlossen. Nächste Schritte:
   - Website im Browser prüfen; Bericht: $WORK_DIR/report.md
   - Ohne Elastic IP: DNS-Einträge (A-Record) auf die IP des neuen Servers ändern
   - Let's Encrypt: 'certbot renew --dry-run' testen
   - Den alten Server einige Tage gestoppt aufbewahren (AMI/Snapshot anlegen),
     erst dann terminieren.
   - Zurück zur Quelle: ./migrate.sh rollback

EOF
}

phase_rollback() {
    confirm "Quelle wieder in Betrieb nehmen (Apache/cron starten, Elastic IP zurück)?" || die "Abgebrochen."
    # Auf dem neuen Server cron wieder anhalten, damit Jobs nicht doppelt laufen
    rm -f "$WORK_DIR/cutover.done"
    cron_service
    src_ssh 'sudo -n service crond start; sudo -n service httpd start' || die "Dienste auf der Quelle ließen sich nicht starten."
    if [[ -n "$ELASTIC_IP_ALLOCATION_ID" ]]; then
        [[ -n "$SRC_INSTANCE_ID" ]] || die "SRC_INSTANCE_ID ist nicht gesetzt – Elastic IP bitte manuell zurückhängen."
        move_eip "$SRC_INSTANCE_ID"
    fi
    log "Quelle läuft wieder. Achtung: Daten, die inzwischen auf dem Ziel geschrieben wurden, sind dort nicht vorhanden."
}
