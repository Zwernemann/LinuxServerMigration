# shellcheck shell=bash
# Gemeinsame Hilfsfunktionen für migrate.sh (laufen auf dem ZIEL-Server).

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_ts() { date '+%F %T'; }

log() {
    printf '%s [INFO]  %s\n' "$(_ts)" "$*" | tee -a "$LOG_FILE" >&2
}

step() {
    printf '\n%s ==== %s ====\n' "$(_ts)" "$*" | tee -a "$LOG_FILE" >&2
}

# Warnungen landen zusätzlich in warnings.log und damit im Abschlussbericht.
warn() {
    printf '%s [WARN]  %s\n' "$(_ts)" "$*" | tee -a "$LOG_FILE" >&2
    printf '%s\t%s\t%s\n' "$(_ts)" "${CURRENT_PHASE:-?}" "$*" >>"$WORK_DIR/warnings.log"
}

die() {
    printf '%s [FEHLER] %s\n' "$(_ts)" "$*" | tee -a "$LOG_FILE" >&2
    exit 1
}

# Befehl protokollieren und ausführen
run() {
    log "+ $*"
    "$@"
}

is_yes() {
    case "${1,,}" in yes | y | ja | j | true | 1 | on) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# SSH / rsync zur Quelle
# ---------------------------------------------------------------------------
init_ssh() {
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30
        -o ServerAliveCountMax=6 -o StrictHostKeyChecking=accept-new
        -o UserKnownHostsFile="$WORK_DIR/known_hosts" -p "$SRC_SSH_PORT")
    if [[ -n "${SRC_SSH_KEY:-}" ]]; then
        SSH_OPTS+=(-i "$SRC_SSH_KEY")
    fi
    # Für rsync -e muss die Kommandozeile als ein String übergeben werden.
    RSYNC_RSH="ssh$(printf ' %q' "${SSH_OPTS[@]}")"
    SRC="$SRC_SSH_USER@$SRC_HOST"
}

src_ssh() {
    ssh "${SSH_OPTS[@]}" "$SRC" "$@"
}

# Führt ein oder mehrere lokale Skriptdateien als root auf der Quelle aus.
#   src_run VAR=wert ... -- datei1 [datei2 ...]
# Die Variablen werden dem Skript vorangestellt (nicht über die
# Kommandozeile – so tauchen Passwörter nicht in "ps" auf). Das Skript wird
# auf der Quelle in eine temporäre Datei geschrieben, damit Befehle im Skript
# nicht versehentlich den Skripttext von stdin lesen.
src_run() {
    local vars=() files=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do vars+=("$1"); shift; done
    shift
    files=("$@")
    {
        local kv
        for kv in "${vars[@]}"; do
            printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"
        done
        cat "$TOOL_DIR/remote/common.sh" "${files[@]}"
    } | src_ssh 'f=$(mktemp /tmp/.migration.XXXXXX) && cat >"$f" && sudo -n bash "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc'
}

# Variablen, die jedes Quellskript braucht
src_vars() {
    printf '%s\n' "SRC_DB_HOST=$SRC_DB_HOST" "SRC_DB_USER=$SRC_DB_USER" \
        "SRC_DB_PASS=$SRC_DB_PASS"
}

# rsync von der Quelle (liest dort als root via sudo)
src_rsync() {
    rsync -aH --rsync-path="sudo -n rsync" -e "$RSYNC_RSH" "$@"
}

rsync_excludes() {
    local p out=()
    for p in $RSYNC_EXCLUDES; do out+=(--exclude "$p"); done
    printf '%s\0' "${out[@]}"
}

# ---------------------------------------------------------------------------
# Inventar-Zugriff (Daten der Quelle, ermittelt in Phase "inventory")
# ---------------------------------------------------------------------------
INV_DIR_REL="inventory"

inv_file() { printf '%s/%s/%s' "$WORK_DIR" "$INV_DIR_REL" "$1"; }

# inv_get KEY  – Wert aus summary.env (Datei wird nicht "gesourct")
inv_get() {
    local key=$1 k v
    [[ -f "$(inv_file summary.env)" ]] || return 0
    while IFS='=' read -r k v; do
        if [[ "$k" == "$key" ]]; then printf '%s' "$v"; return 0; fi
    done <"$(inv_file summary.env)"
}

require_inventory() {
    [[ -f "$(inv_file summary.env)" ]] ||
        die "Kein Inventar vorhanden – zuerst './migrate.sh inventory' ausführen."
}

# Pfad im Konfigurations-Schnappschuss der Quelle
snap() { printf '%s/source-snapshot%s' "$WORK_DIR" "$1"; }

# ---------------------------------------------------------------------------
# Paketverwaltung (Ziel, dnf)
# ---------------------------------------------------------------------------
pkg_available() {
    rpm -q "$1" >/dev/null 2>&1 && return 0
    dnf -q list --available "$1" >/dev/null 2>&1
}

pkg_install() {
    [[ $# -gt 0 ]] || return 0
    local missing=() p
    for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
    [[ ${#missing[@]} -gt 0 ]] || return 0
    run dnf -y install "${missing[@]}"
}

# ---------------------------------------------------------------------------
# Generierte Dateien: überschreiben, solange niemand sie von Hand geändert hat
# ---------------------------------------------------------------------------
#   install_generated <neue-datei> <ziel> [modus] [owner]
install_generated() {
    local new=$1 dest=$2 mode=${3:-0644} owner=${4:-root:root}
    local ref="$WORK_DIR/generated$dest"
    mkdir -p "$(dirname "$ref")" "$(dirname "$dest")"
    if [[ -e "$dest" ]] && ! { [[ -f "$ref" ]] && cmp -s "$dest" "$ref"; }; then
        if cmp -s "$dest" "$new"; then
            cp -f "$new" "$ref"
            return 0
        fi
        warn "$dest wurde manuell geändert oder existierte schon – nicht überschrieben. Neue Version: $dest.migration-new"
        install -m "$mode" "$new" "$dest.migration-new"
        return 0
    fi
    install -m "$mode" "$new" "$dest"
    chown "$owner" "$dest"
    cp -f "$new" "$ref"
    log "Geschrieben: $dest"
}

# ---------------------------------------------------------------------------
# cron auf dem Ziel erst nach dem Cutover (sonst laufen Jobs doppelt)
cron_allowed() {
    is_yes "${CRON_BEFORE_CUTOVER:-no}" || [[ -f "$WORK_DIR/cutover.done" ]]
}

cron_service() {
    if cron_allowed; then
        run systemctl enable crond
        run systemctl restart crond
    else
        run systemctl enable crond
        run systemctl stop crond
        log "cron ist bis zum Cutover pausiert (Jobs liefen sonst doppelt auf altem und neuem Server)."
    fi
}

# ---------------------------------------------------------------------------
# Datenbank auf dem Ziel
# ---------------------------------------------------------------------------
TARGET_MY_CNF=/root/.my.cnf

mysql_client() { command -v mysql 2>/dev/null || command -v mariadb 2>/dev/null || echo mysql; }

tmysql() {
    "$(mysql_client)" --defaults-extra-file="$TARGET_MY_CNF" "$@"
}

# TARGET_DB_ENGINE=auto: MySQL 8.x -> MySQL 8.4 (gleiche Kollationen wie
# utf8mb4_0900_ai_ci, caching_sha2_password, JSON), sonst MariaDB
resolve_db_engine() {
    [[ "$TARGET_DB_ENGINE" == auto ]] || return 0
    local v
    v=$(inv_get SRC_MYSQL_VERSION)
    [[ -n "$v" ]] || return 0
    if [[ "$v" != *MariaDB* && "${v%%.*}" =~ ^[0-9]+$ && ${v%%.*} -ge 8 ]]; then
        TARGET_DB_ENGINE=mysql84
    else
        TARGET_DB_ENGINE=mariadb
    fi
    log "Datenbank-Ziel automatisch gewählt: $TARGET_DB_ENGINE (Quelle: $v)"
}

db_service() {
    resolve_db_engine
    case "$TARGET_DB_ENGINE" in
    mariadb) echo mariadb ;;
    mysql84) echo mysqld ;;
    auto) die "TARGET_DB_ENGINE=auto: zuerst 'inventory' ausführen" ;;
    *) die "Unbekannte TARGET_DB_ENGINE: $TARGET_DB_ENGINE" ;;
    esac
}

# SQL-String-Literal (für Passwörter)
sql_quote() {
    local s=${1//\\/\\\\}
    s=${s//\'/\'\'}
    printf "'%s'" "$s"
}

# Liste der zu migrierenden Datenbanken (aus dem Inventar)
db_list() {
    local name db inc ok
    while IFS=$'\t' read -r name _; do
        [[ -n "$name" ]] || continue
        ok=1
        for db in $DB_EXCLUDE; do [[ "$name" == "$db" ]] && ok=0; done
        if [[ -n "${DB_INCLUDE// /}" ]]; then
            inc=0
            for db in $DB_INCLUDE; do [[ "$name" == "$db" ]] && inc=1; done
            [[ $inc == 1 ]] || ok=0
        fi
        [[ $ok == 1 ]] && printf '%s\n' "$name"
    done <"$(inv_file mysql-databases.tsv)"
    return 0
}
