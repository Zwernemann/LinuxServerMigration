# shellcheck shell=bash
# Wird jedem Skript vorangestellt, das auf dem QUELL-Server (Amazon Linux
# 2018.03, bash 4.2) als root läuft. Kann auch lokal auf dem Ziel laufen
# (DB_CNF_FILE gesetzt), z.B. für den Zeilenzahl-Vergleich.
set -o nounset -o pipefail
umask 077
export LC_ALL=C

: "${SRC_DB_HOST:=localhost}" "${SRC_DB_USER:=root}" "${SRC_DB_PASS:=}"
: "${DB_CNF_FILE:=}"

_cleanup_files=()
_cleanup() { [ ${#_cleanup_files[@]} -eq 0 ] || rm -rf "${_cleanup_files[@]}"; }
trap _cleanup EXIT

rlog() { echo "[quelle] $*" >&2; }

# Temporäre Client-Konfiguration mit den Zugangsdaten anlegen
mysql_setup() {
    if [ -n "$DB_CNF_FILE" ]; then
        MY_CNF=$DB_CNF_FILE
        return 0
    fi
    MY_CNF=$(mktemp /tmp/.migration-my.XXXXXX)
    _cleanup_files+=("$MY_CNF")
    if [ -n "$SRC_DB_PASS" ]; then
        local p=${SRC_DB_PASS//\\/\\\\}
        p=${p//\"/\\\"}
        printf '[client]\nuser=%s\npassword="%s"\nhost=%s\n' \
            "$SRC_DB_USER" "$p" "$SRC_DB_HOST" >"$MY_CNF"
    elif [ -r /root/.my.cnf ]; then
        cat /root/.my.cnf >"$MY_CNF"
        printf '\n[client]\nhost=%s\n' "$SRC_DB_HOST" >>"$MY_CNF"
    else
        printf '[client]\nuser=%s\nhost=%s\n' "$SRC_DB_USER" "$SRC_DB_HOST" >"$MY_CNF"
    fi
}

mysql_bin() { command -v mysql 2>/dev/null || command -v mariadb; }
mysqldump_bin() { command -v mysqldump 2>/dev/null || command -v mariadb-dump; }

# q "SQL" – Abfrage ohne Kopfzeile, tabulatorgetrennt
q() {
    "$(mysql_bin)" --defaults-extra-file="$MY_CNF" -N -B -e "$1" </dev/null
}

# SQL-Stringliteral
sqlq() {
    local s=${1//\\/\\\\}
    s=${s//\'/\\\'}
    printf "'%s'" "$s"
}
