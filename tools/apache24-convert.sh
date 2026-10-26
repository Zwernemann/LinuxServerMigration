#!/usr/bin/env bash
# Konvertiert Apache-2.2-Zugriffsregeln (Order/Allow/Deny) in die
# Apache-2.4-Syntax (Require). Funktioniert für httpd-Konfigurationsdateien
# und .htaccess-Dateien.
#
#   apache24-convert.sh [-i] datei...
#     -i   Datei direkt ändern (Sicherung: datei.pre-migration)
#     ohne -i wird das Ergebnis auf stdout ausgegeben
#
# Kontexte mit "Satisfy" oder bereits vorhandenem "Require" werden NICHT
# angefasst (mod_access_compat ist in AL2023 geladen, die alte Syntax
# funktioniert dort weiterhin) – sie werden nach stderr gemeldet.
set -euo pipefail

inplace=0
if [[ "${1:-}" == "-i" ]]; then inplace=1; shift; fi
[[ $# -gt 0 ]] || { echo "Aufruf: $0 [-i] datei..." >&2; exit 2; }

convert() {
    awk -v FNAME="$1" '
    function lc(s) { return tolower(s) }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function isip(t) { return (t ~ /^[0-9.]+(\/[0-9.]+)?$/ || t ~ /:/) }
    # Tokenliste -> "Require [not] ip ..." / "Require [not] host ..." Zeilen
    function req(list, neg, ind,    n, a, i, ips, hosts, envs, out, pre) {
        n = split(list, a, " "); ips = ""; hosts = ""; envs = ""; out = ""
        pre = ind "Require " (neg ? "not " : "")
        for (i = 1; i <= n; i++) {
            if (a[i] == "") continue
            if (a[i] ~ /^env=/) { envs = envs " " substr(a[i], 5) }
            else if (isip(a[i])) ips = ips " " a[i]
            else hosts = hosts " " a[i]
        }
        if (ips != "")   out = out pre "ip" ips "\n"
        if (hosts != "") out = out pre "host" hosts "\n"
        if (envs != "") {
            n = split(trim(envs), a, " ")
            for (i = 1; i <= n; i++) out = out pre "env " a[i] "\n"
        }
        return out
    }
    {
        line[NR] = $0
        t = trim($0)
        if (t ~ /^<\//) { if (sp > 0) sp--; ctx[NR] = stack[sp]; next }
        if (t ~ /^<[A-Za-z]/) {
            ctx[NR] = stack[sp]
            nctx++; sp++; stack[sp] = nctx
            next
        }
        c = stack[sp]; ctx[NR] = c
        if (t ~ /^#/ || t == "") next
        split(t, w, /[ \t]+/); d = lc(w[1])
        rest = t; sub(/^[^ \t]+[ \t]*/, "", rest)
        if (d == "order") {
            ord[c] = lc(rest); gsub(/[ \t]/, "", ord[c]); acc[NR] = 1
        } else if ((d == "allow" || d == "deny") && lc(w[2]) == "from") {
            sub(/^[Ff][Rr][Oo][Mm][ \t]+/, "", rest)
            if (d == "allow") al[c] = al[c] " " rest; else de[c] = de[c] " " rest
            acc[NR] = 1
        } else if (d == "satisfy") {
            bad[c] = "Satisfy"
        } else if (d == "require") {
            bad[c] = "Require"
        } else next
        if (acc[NR] && !(c in first)) { first[c] = NR; m = $0; sub(/[^ \t].*$/, "", m); indent[c] = m }
        if (acc[NR]) has[c] = 1
    }
    END {
        for (c in has) {
            if (c in bad) {
                printf "%s: Kontext mit %s – Zugriffsregeln nicht automatisch konvertiert (mod_access_compat)\n", FNAME, bad[c] > "/dev/stderr"
                skip[c] = 1; continue
            }
            o = (c in ord) ? ord[c] : "deny,allow"
            A = " " lc(al[c]) " "; D = " " lc(de[c]) " "
            aall = (A ~ / all /); dall = (D ~ / all /)
            a = trim(al[c]); dd = trim(de[c]); ind = indent[c]
            if (o == "allow,deny") {
                if (dall || a == "") r = ind "Require all denied\n"
                else if (dd == "") r = aall ? ind "Require all granted\n" : req(a, 0, ind)
                else r = ind "<RequireAll>\n" (aall ? ind "    Require all granted\n" : req(a, 0, ind "    ")) req(dd, 1, ind "    ") ind "</RequireAll>\n"
            } else if (o == "deny,allow") {
                if (aall || dd == "") r = ind "Require all granted\n"
                else if (dall) r = (a == "") ? ind "Require all denied\n" : req(a, 0, ind)
                else if (a == "") r = ind "<RequireAll>\n" ind "    Require all granted\n" req(dd, 1, ind "    ") ind "</RequireAll>\n"
                else r = ind "<RequireAny>\n" req(a, 0, ind "    ") ind "    <RequireAll>\n" ind "        Require all granted\n" req(dd, 1, ind "        ") ind "    </RequireAll>\n" ind "</RequireAny>\n"
            } else {
                printf "%s: unbekannte Order \"%s\" – nicht konvertiert\n", FNAME, o > "/dev/stderr"
                skip[c] = 1; continue
            }
            repl[c] = r
        }
        for (i = 1; i <= NR; i++) {
            c = ctx[i]
            if (acc[i] && !(c in skip)) {
                if (first[c] == i) printf "%s", repl[c]
                printf "%s# [migration 2.2] %s\n", indent[c], trim(line[i])
                continue
            }
            print line[i]
        }
    }' "$1"
}

for f in "$@"; do
    if [[ $inplace == 1 ]]; then
        tmp=$(mktemp)
        convert "$f" >"$tmp"
        if ! cmp -s "$f" "$tmp"; then
            cp -p "$f" "$f.pre-migration"
            cat "$tmp" >"$f"
            echo "konvertiert: $f" >&2
        fi
        rm -f "$tmp"
    else
        convert "$f"
    fi
done
