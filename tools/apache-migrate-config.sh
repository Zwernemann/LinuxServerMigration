#!/usr/bin/env bash
# Überträgt Apache-Konfiguration vom alten Server (httpd 2.2/2.4 mit mod_php)
# auf den neuen (httpd 2.4 mit PHP-FPM).
#
#   apache-migrate-config.sh <modus> <datei> <seitendateien-präfix>
#
# Modus:
#   main  – Haupt-httpd.conf: nur VirtualHosts, <Directory>/<Location>/<Files>-
#           Blöcke und wenige globale Direktiven (DocumentRoot, ServerName, …)
#   ssl   – ssl.conf: nur VirtualHosts (der unveränderte Standard-VHost
#           _default_:443 mit localhost.crt wird übersprungen)
#   file  – eigene Konfigurationsdatei: alles
#
# Ausgabe: konvertierte Konfiguration auf stdout. Zusätzlich:
#   <präfix>.php     verzeichnis<TAB>name<TAB>wert   (php_value & Co.)
#   <präfix>.listen  zusätzliche Listen-Direktiven
#   <präfix>.modules geladene Module (LoadModule)
#   <präfix>.notes   Hinweise
set -euo pipefail
[[ $# -eq 3 ]] || { echo "Aufruf: $0 main|ssl|file <datei> <präfix>" >&2; exit 2; }
mode=$1 file=$2 prefix=$3
: >"$prefix.php"; : >"$prefix.listen"; : >"$prefix.modules"; : >"$prefix.notes"

awk -v MODE="$mode" -v PHP="$prefix.php" -v LISTEN="$prefix.listen" \
    -v MODS="$prefix.modules" -v NOTES="$prefix.notes" -v SRC="$file" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function unq(s) { s = trim(s); gsub(/^"|"$/, "", s); return s }
function dirname_of(t,   a) { a = t; sub(/^<[A-Za-z]+[ \t]+/, "", a); sub(/>.*$/, "", a); a = unq(a); sub(/\/+$/, "", a); return a == "" ? "/" : a }
function tag_of(t,   a) { a = t; sub(/^<\/?/, "", a); sub(/[ \t>].*$/, "", a); return tolower(a) }
function note(s) { print SRC ": " s >> NOTES }
function indent_of(l,   m) { m = l; sub(/[^ \t].*$/, "", m); return m }

# Gibt die (ggf. veränderte) Zeile zurück oder "\001" zum Verwerfen
function xf(l,    t, w, d, rest, n, a, port, dir) {
    t = trim(l)
    if (t == "" || t ~ /^#/) return l
    split(t, w, /[ \t]+/); d = tolower(w[1])
    rest = t; sub(/^[^ \t]+[ \t]*/, "", rest)
    if (d == "namevirtualhost") { note("NameVirtualHost entfernt (in 2.4 überflüssig)"); return "\001" }
    if (d == "listen") {
        port = w[2]; sub(/^.*:/, "", port)
        if (port != "80" && port != "443") print "Listen " rest >> LISTEN
        return "\001"
    }
    if (d == "loadmodule") { print w[2] >> MODS; return "\001" }
    if (d == "sslmutex" || d == "lockfile" || d == "sslsessioncache" || d == "sslpassphrasedialog" || d == "sslrandomseed" || d == "sslcryptodevice") return "\001"
    if (d == "sslprotocol" || d == "sslciphersuite") {
        return indent_of(l) "# [migration: AL2023-Crypto-Policy wird verwendet] " t
    }
    if (d ~ /^php_(admin_)?(value|flag)$/) {
        dir = (dsp > 0) ? dstack[dsp] : (blockroot[blk] != "" ? blockroot[blk] : globalroot)
        n = split(rest, a, /[ \t]+/)
        val = rest; sub(/^[^ \t]+[ \t]*/, "", val)
        print dir "\t" a[1] "\t" val >> PHP
        return indent_of(l) "# [migration -> " dir "/.user.ini] " t
    }
    if ((d == "addhandler" || d == "addtype" || d == "sethandler" || d == "action") && tolower(rest) ~ /php/) {
        return indent_of(l) "# [migration: PHP läuft über PHP-FPM] " t
    }
    if (d == "authzldapauthoritative" || d == "defaulttype") return indent_of(l) "# [migration: in 2.4 entfernt] " t
    return l
}

function keep_top(t,    w, d, rest) {
    split(t, w, /[ \t]+/); d = tolower(w[1]); rest = t; sub(/^[^ \t]+[ \t]*/, "", rest)
    if (d == "documentroot") return unq(rest) != "/var/www/html"
    if (d == "directoryindex") return rest != "index.html index.html.var" && rest != "index.html"
    if (d == "alias") return rest !~ /^"?\/icons\//
    if (d == "scriptalias") return rest !~ /^"?\/cgi-bin\//
    if (d ~ /^(servername|serveradmin|serversignature|servertokens|traceenable|timeout|keepalive|maxkeepaliverequests|keepalivetimeout|errordocument|redirect|redirectmatch|redirectpermanent|rewriteengine|rewritecond|rewriterule|rewritemap|header|requestheader|addtype|addhandler|adddefaultcharset|addcharset|addoutputfilterbytype|setenv|setenvif|expiresactive|expiresbytype|expiresdefault|limitrequestbody|fileetag|php_value|php_flag|php_admin_value|php_admin_flag)$/) return 1
    return 0
}

function keep_block(t,   tag, arg) {
    tag = tag_of(t); arg = dirname_of(t)
    if (MODE == "ssl") return tag == "virtualhost"
    if (tag == "virtualhost" || tag == "location" || tag == "locationmatch" || tag == "proxy" || tag == "directorymatch") return 1
    if (tag == "directory") return arg != "/" && arg != "/var/www/icons" && arg != "/var/www/cgi-bin"
    if (tag == "files" || tag == "filesmatch") return t !~ /\.ht/
    return 0
}

# ---------------- Pass 1: DocumentRoot je Top-Level-Block
NR == FNR {
    t = trim($0)
    if (t ~ /^<\//) { depth--; next }
    if (t ~ /^<[A-Za-z]/) { if (depth == 0) b++; depth++; next }
    if (tolower(t) ~ /^documentroot[ \t]/) {
        r = t; sub(/^[^ \t]+[ \t]+/, "", r); r = unq(r); sub(/\/+$/, "", r)
        if (depth == 0) { if (globalroot == "") globalroot = r }
        else if (!(b in blockroot)) blockroot[b] = r
    }
    next
}
FNR == 1 { depth = 0; blk = 0; if (globalroot == "") globalroot = "/var/www/html"; dsp = 0 }

# ---------------- Pass 2
{
    t = trim($0)
    if (t ~ /^<\//) {
        depth--
        if (tag_of(t) == "directory" && dsp > 0) dsp--
        if (inblock) {
            buf = buf $0 "\n"
            if (depth == 0) {
                inblock = 0
                if (MODE == "ssl" && buf ~ /_default_:443/ && buf ~ /localhost\.crt/ && buf !~ /\n[ \t]*ServerName[ \t]/) {
                    note("Standard-SSL-VirtualHost (_default_:443, localhost.crt) übersprungen")
                } else printf "%s", buf
                buf = ""
            }
        } else if (MODE == "file") print
        next
    }
    if (t ~ /^<[A-Za-z]/) {
        if (depth == 0) {
            blk++
            if (MODE == "file" || keep_block(t)) { inblock = 1; buf = "" }
            else if (tag_of(t) == "ifmodule" || tag_of(t) == "ifdefine") skipping_if = 1
        }
        depth++
        if (tag_of(t) == "directory") { dstack[++dsp] = dirname_of(t) }
        if (inblock) buf = buf $0 "\n"
        else if (MODE == "file") print
        next
    }
    if (inblock) {
        l = xf($0); if (l != "\001") buf = buf l "\n"
        next
    }
    if (depth > 0) next          # Inhalt nicht übernommener Blöcke (IfModule …)
    if (MODE == "file") { l = xf($0); if (l != "\001") print l; next }
    # main/ssl: nur ausgewählte globale Direktiven
    if (t == "" || t ~ /^#/) next
    if (tolower(t) ~ /^listen[ \t]/) { xf($0); next }
    if (tolower(t) ~ /^loadmodule[ \t]/) { xf($0); next }
    if (MODE == "main" && keep_top(t)) { l = xf($0); if (l != "\001") print l }
}
END { if (skipping_if && MODE == "main") note("globale <IfModule>-Blöcke der alten httpd.conf wurden nicht übernommen – bei Bedarf manuell prüfen") }
' "$file" "$file"
