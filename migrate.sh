#!/usr/bin/env bash
# =============================================================================
#  LinuxServerMigration – Amazon Linux AMI 2018.03  ──►  Amazon Linux 2023
#  Apache + PHP + MySQL, vollautomatisch.
#
#  Läuft als root auf dem NEUEN Server und holt alles per SSH/rsync vom alten.
#  Der alte Server wird nur gelesen (Ausnahme: "cutover" stoppt dort Apache
#  und cron, "rollback" startet sie wieder).
#
#  Aufruf:  sudo ./migrate.sh [-c migration.conf] [-y] <phase>...
#
#  Phasen (in dieser Reihenfolge; "all" = preflight … verify):
#    preflight   Voraussetzungen prüfen (SSH, sudo, rsync)
#    inventory   Quelle analysieren, Konfiguration sichern
#    install     Apache, PHP-FPM, MariaDB/MySQL & Co. installieren
#    users       Linux-Benutzer/Gruppen übernehmen
#    files       Webverzeichnisse, /home, Zertifikate synchronisieren
#    database    Datenbanken, MySQL-Benutzer und Rechte übertragen
#    configure   php.ini, VirtualHosts, Cronjobs übernehmen, Dienste starten
#    verify      Ziel mit Quelle vergleichen, Bericht schreiben
#    cutover     Quelle stoppen, letzter Abgleich, Elastic IP umhängen
#    rollback    Quelle wieder starten (Elastic IP zurück)
# =============================================================================
set -Eeuo pipefail

TOOL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$TOOL_DIR/migration.conf"
export ASSUME_YES=no

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

phases=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    -c | --config) CONFIG=$2; shift 2 ;;
    -y | --yes) ASSUME_YES=yes; shift ;;
    -h | --help) usage ;;
    -*) echo "Unbekannte Option: $1" >&2; usage 2 ;;
    *) phases+=("$1"); shift ;;
    esac
done
[[ ${#phases[@]} -gt 0 ]] || usage 2

# Standardwerte, dann Konfiguration
# shellcheck source=migration.conf.example
source "$TOOL_DIR/migration.conf.example"
[[ -f "$CONFIG" ]] || { echo "Konfiguration $CONFIG fehlt (Vorlage: migration.conf.example)." >&2; exit 2; }
# shellcheck disable=SC1090
source "$CONFIG"

umask 022
mkdir -p "$WORK_DIR" "$LOG_DIR"
chmod 700 "$WORK_DIR"
LOG_FILE="$LOG_DIR/migrate-$(date +%Y%m%d).log"
touch "$WORK_DIR/warnings.log"

# shellcheck source=lib/common.sh
source "$TOOL_DIR/lib/common.sh"
for f in "$TOOL_DIR"/lib/phases/*.sh; do
    # shellcheck disable=SC1090
    source "$f"
done

# Nur in der Haupt-Shell abbrechen: In Prozess-/Befehlsersetzungen ist z.B.
# ein grep ohne Treffer kein Fehler – schlägt dort wirklich etwas fehl,
# bemerkt es die Haupt-Shell am Ergebnis.
trap '(( BASH_SUBSHELL )) || die "Abbruch in Zeile $LINENO (Phase ${CURRENT_PHASE:-?}): $BASH_COMMAND"' ERR

ALL_PHASES=(preflight inventory install users files database configure verify)
expanded=()
for p in "${phases[@]}"; do
    if [[ "$p" == all ]]; then expanded+=("${ALL_PHASES[@]}"); else expanded+=("$p"); fi
done

[[ $EUID -eq 0 ]] || die "Bitte als root ausführen: sudo $0 ${phases[*]}"
init_ssh

for p in "${expanded[@]}"; do
    declare -F "phase_$p" >/dev/null || die "Unbekannte Phase: $p"
done
for p in "${expanded[@]}"; do
    CURRENT_PHASE=$p
    # Alte Warnungen dieser Phase ersetzen
    awk -F'\t' -v p="$p" '$2 != p' "$WORK_DIR/warnings.log" >"$WORK_DIR/warnings.log.tmp" &&
        mv -f "$WORK_DIR/warnings.log.tmp" "$WORK_DIR/warnings.log"
    start=$SECONDS
    step "Phase: $p"
    "phase_$p"
    log "Phase $p abgeschlossen ($((SECONDS - start)) s)."
done
CURRENT_PHASE=

if [[ -s "$WORK_DIR/warnings.log" ]]; then
    log "$(wc -l <"$WORK_DIR/warnings.log") Warnungen insgesamt – siehe $WORK_DIR/warnings.log bzw. $WORK_DIR/report.md"
fi
