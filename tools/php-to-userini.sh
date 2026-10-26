#!/usr/bin/env bash
# PHP-FPM (Standard bei AL2023) versteht keine php_value/php_flag-Direktiven in
# .htaccess – sie verursachen "500 Internal Server Error". Dieses Werkzeug
# verschiebt sie in eine .user.ini im selben Verzeichnis, die PHP-FPM liest.
#
#   php-to-userini.sh htaccess <.htaccess-datei>...
#   php-to-userini.sh add <verzeichnis> <name> <wert>
set -euo pipefail

# In PHP 7/8 entfernte Einstellungen – werden nicht übernommen
REMOVED_KEYS=" register_globals magic_quotes_gpc magic_quotes_runtime magic_quotes_sybase \
safe_mode safe_mode_gid safe_mode_include_dir safe_mode_exec_dir allow_call_time_pass_reference \
register_long_arrays y2k_compliance asp_tags always_populate_raw_post_data mbstring.func_overload \
track_errors sql.safe_mode session.bug_compat_42 session.bug_compat_warn define_syslog_variables \
zend.ze1_compatibility_mode session.hash_function session.hash_bits_per_character session.entropy_file \
session.entropy_length mcrypt.algorithms_dir mcrypt.modes_dir "

ini_value() {
    local v=$1
    # Umschließende Anführungszeichen entfernen
    if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    case "${v,,}" in
    on | true | yes) echo On; return ;;
    off | false | no | none) echo Off; return ;;
    esac
    if [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        printf '%s\n' "$v"
    else
        printf '"%s"\n' "${v//\"/\\\"}"
    fi
}

# add <dir> <name> <wert>  – Rückgabe 1, wenn die Einstellung entfernt wurde
add_setting() {
    local dir=$1 name=$2 value=$3 ini="$1/.user.ini" owner
    if [[ "$REMOVED_KEYS" == *" ${name,,} "* ]]; then
        echo "$dir: '$name' existiert in PHP 8 nicht mehr – nicht übernommen" >&2
        return 1
    fi
    if [[ -f "$ini" ]] && grep -qE "^[[:space:]]*${name//./\\.}[[:space:]]*=" "$ini"; then
        return 0
    fi
    if [[ ! -f "$ini" ]]; then
        printf '; Automatisch erzeugt bei der Migration (aus php_value/php_flag)\n' >"$ini"
        owner=$(stat -c '%U:%G' "$dir")
        chown "$owner" "$ini" 2>/dev/null || true
        chmod 0644 "$ini"
    fi
    printf '%s = %s\n' "$name" "$(ini_value "$value")" >>"$ini"
}

convert_htaccess() {
    local f=$1 dir tmp name value directive found=0
    dir=$(dirname "$f")
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([[:space:]]*)(php_value|php_flag|php_admin_value|php_admin_flag)[[:space:]]+([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
            directive=${BASH_REMATCH[2]}
            name=${BASH_REMATCH[3]}
            value=${BASH_REMATCH[4]%$'\r'}
            value=${value%"${value##*[![:space:]]}"}
            found=1
            add_setting "$dir" "$name" "$value" || true
            printf '%s# [migration -> .user.ini] %s %s %s\n' "${BASH_REMATCH[1]}" "$directive" "$name" "$value" >>"$tmp"
        else
            printf '%s\n' "$line" >>"$tmp"
        fi
    done <"$f"
    if [[ $found == 1 ]]; then
        cp -p "$f" "$f.pre-migration"
        cat "$tmp" >"$f"
        echo "konvertiert: $f -> $dir/.user.ini" >&2
    fi
    rm -f "$tmp"
}

case "${1:-}" in
htaccess)
    shift
    for f in "$@"; do convert_htaccess "$f"; done
    ;;
add)
    [[ $# -eq 4 ]] || { echo "Aufruf: $0 add <dir> <name> <wert>" >&2; exit 2; }
    add_setting "$2" "$3" "$4" || true
    ;;
*)
    echo "Aufruf: $0 htaccess <datei>... | add <dir> <name> <wert>" >&2
    exit 2
    ;;
esac
