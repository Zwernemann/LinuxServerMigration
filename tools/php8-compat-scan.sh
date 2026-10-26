#!/usr/bin/env bash
# Sucht in PHP-Code nach Konstrukten, die unter PHP 8 nicht mehr funktionieren
# (PHP 5.x/7.x -> 8.x). Schnelle, grep-basierte Heuristik – kein Ersatz für
# Tests, findet aber die typischen Stolpersteine alter Anwendungen.
#
#   php8-compat-scan.sh [-o bericht.md] verzeichnis...
#
# Exit-Code: 0 = nichts Kritisches, 1 = kritische Funde
set -uo pipefail

out=/dev/stdout
if [[ "${1:-}" == "-o" ]]; then out=$2; shift 2; fi
[[ $# -gt 0 ]] || { echo "Aufruf: $0 [-o bericht.md] verzeichnis..." >&2; exit 2; }

# schwere|regex (grep -E)|Beschreibung
RULES=(
    'KRITISCH|\bmysql_[a-z_]+[[:space:]]*\(|ext/mysql (mysql_*) wurde in PHP 7.0 entfernt -> mysqli/PDO verwenden'
    'KRITISCH|\b(ereg|eregi|ereg_replace|eregi_replace|split|spliti|sql_regcase)[[:space:]]*\(|POSIX-Regex (ereg*/split) wurde in PHP 7.0 entfernt -> preg_* verwenden'
    'KRITISCH|\bmcrypt_[a-z_]+[[:space:]]*\(|ext/mcrypt wurde in PHP 7.2 entfernt -> openssl_* oder sodium_* verwenden'
    'KRITISCH|\bcreate_function[[:space:]]*\(|create_function() wurde in PHP 8.0 entfernt -> anonyme Funktionen'
    'KRITISCH|\beach[[:space:]]*\([[:space:]]*\$|each() wurde in PHP 8.0 entfernt -> foreach'
    'KRITISCH|\$[A-Za-z_][A-Za-z0-9_]*\{[^}]*\}|Zugriff auf String/Array mit {} wurde in PHP 8.0 entfernt -> [] verwenden'
    'KRITISCH|\b(get_magic_quotes_gpc|get_magic_quotes_runtime|set_magic_quotes_runtime|magic_quotes_runtime)[[:space:]]*\(|magic_quotes-Funktionen wurden in PHP 8.0 entfernt'
    'KRITISCH|function[[:space:]]+__autoload[[:space:]]*\(|__autoload() wurde in PHP 8.0 entfernt -> spl_autoload_register()'
    'KRITISCH|\b(session_register|session_unregister|session_is_registered|call_user_method|call_user_method_array|set_socket_blocking)[[:space:]]*\(|in PHP 5.4–8.0 entfernte Funktion'
    'KRITISCH|\bmoney_format[[:space:]]*\(|money_format() wurde in PHP 8.0 entfernt -> NumberFormatter'
    'KRITISCH|\b(is_real|hebrevc|convert_cyr_string|restore_include_path|ezmlm_hash|fgetss|image2wbmp|jpeg2wbmp|png2wbmp|ldap_sort)[[:space:]]*\(|in PHP 8.0 entfernte Funktion'
    'KRITISCH|\(real\)|(real)-Cast wurde in PHP 8.0 entfernt -> (float)'
    'KRITISCH|\$HTTP_(GET|POST|COOKIE|SERVER|ENV|POST_FILES|SESSION)_VARS|$HTTP_*_VARS wurden in PHP 5.4 entfernt -> $_GET, $_POST, ...'
    'KRITISCH|\$HTTP_RAW_POST_DATA|$HTTP_RAW_POST_DATA wurde in PHP 7.0 entfernt -> file_get_contents("php://input")'
    'KRITISCH|\bdefine[[:space:]]*\([^,]+,[^,]+,[[:space:]]*true[[:space:]]*\)|define() mit case-insensitive=true ist seit PHP 8.0 ein Fehler'
    'KRITISCH|=[[:space:]]*&[[:space:]]*new[[:space:]]|"=& new" ist seit PHP 7.0 ein Syntaxfehler'
    'WARNUNG|<%|ASP-Tags (<% %>) wurden in PHP 7.0 entfernt'
    'KRITISCH|<script[[:space:]]+language[[:space:]]*=[[:space:]]*"?php|<script language="php"> wurde in PHP 7.0 entfernt'
    'WARNUNG|\b(utf8_encode|utf8_decode)[[:space:]]*\(|utf8_encode/utf8_decode sind seit PHP 8.2 veraltet'
    'WARNUNG|"[^"]*\$\{[A-Za-z_]|"${var}"-Interpolation ist seit PHP 8.2 veraltet -> "{$var}"'
    'WARNUNG|FILTER_SANITIZE_STRING|FILTER_SANITIZE_STRING ist seit PHP 8.1 veraltet'
    'WARNUNG|\b(strftime|gmstrftime)[[:space:]]*\(|strftime() ist seit PHP 8.1 veraltet'
    'WARNUNG|\bimap_[a-z_]+[[:space:]]*\(|ext/imap ist ab PHP 8.4 nicht mehr Teil von PHP (PECL)'
    'WARNUNG|\b(xmlrpc_[a-z_]+)[[:space:]]*\(|ext/xmlrpc wurde in PHP 8.0 entfernt (PECL)'
    'WARNUNG|\b(wddx_[a-z_]+)[[:space:]]*\(|ext/wddx wurde in PHP 7.4 entfernt'
    'WARNUNG|\bassert[[:space:]]*\([[:space:]]*["'\'']|assert() mit String-Argument funktioniert seit PHP 8.0 nicht mehr'
    'WARNUNG|\$php_errormsg|$php_errormsg wurde in PHP 8.0 entfernt -> error_get_last()'
    'WARNUNG|\b(ini_set|ini_get)[[:space:]]*\([[:space:]]*["'\''](magic_quotes|register_globals|safe_mode)|Zugriff auf entfernte ini-Einstellung'
    'INFO|<\?[[:space:]]|Short-Open-Tag "<?" – funktioniert nur mit short_open_tag=On'
    'INFO|\bmail[[:space:]]*\(|mail() benötigt einen lokalen Mailserver (postfix) oder SMTP-Konfiguration'
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

find "$@" -type f \( -name '*.php' -o -name '*.php3' -o -name '*.php4' -o -name '*.php5' \
    -o -name '*.phtml' -o -name '*.inc' \) -not -path '*/vendor/*' -not -path '*/.git/*' \
    -print0 >"$tmp/files"
nfiles=$(tr -cd '\0' <"$tmp/files" | wc -c)

critical=0
{
    echo "# PHP-8-Kompatibilitätsprüfung"
    echo
    echo "Geprüfte Verzeichnisse: $*  "
    echo "Geprüfte Dateien: $nfiles (ohne vendor/)"
    echo
    echo "| Schwere | Treffer | Dateien | Problem |"
    echo "|---|---:|---:|---|"
} >"$tmp/head"
: >"$tmp/body"

i=0
for rule in "${RULES[@]}"; do
    i=$((i + 1))
    sev=${rule%%|*}
    rest=${rule#*|}
    rx=${rest%|*}
    desc=${rest##*|}
    # Kommentarzeilen grob ausblenden
    xargs -0 -r grep -nHE -- "$rx" <"$tmp/files" 2>/dev/null |
        grep -vE ':[0-9]+:[[:space:]]*(//|#|\*|/\*)' >"$tmp/hits.$i" || true
    hits=$(wc -l <"$tmp/hits.$i")
    [[ $hits -gt 0 ]] || continue
    files=$(cut -d: -f1 "$tmp/hits.$i" | sort -u | wc -l)
    [[ $sev == KRITISCH ]] && critical=$((critical + hits))
    echo "| $sev | $hits | $files | $desc |" >>"$tmp/head"
    {
        echo
        echo "## $sev: $desc"
        echo
        echo '```'
        head -n 30 "$tmp/hits.$i" | cut -c1-220
        [[ $hits -gt 30 ]] && echo "... ($((hits - 30)) weitere)"
        echo '```'
    } >>"$tmp/body"
done

{
    cat "$tmp/head"
    echo
    if [[ $critical -gt 0 ]]; then
        echo "**$critical kritische Fundstellen – diese Stellen funktionieren unter PHP 8 nicht und müssen angepasst werden.**"
    else
        echo "Keine kritischen Fundstellen gefunden."
    fi
    echo
    echo "Hinweis: Für eine tiefere Analyse kann zusätzlich PHPCompatibility verwendet werden:"
    echo '`composer global require phpcompatibility/php-compatibility && phpcs --standard=PHPCompatibility --runtime-set testVersion 8.3 <pfad>`'
    cat "$tmp/body"
} >"$out"

[[ $critical -eq 0 ]]
