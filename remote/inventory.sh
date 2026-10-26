# shellcheck shell=bash
# Läuft auf der QUELLE: sammelt alle Informationen über den Server und gibt
# sie als tar.gz auf stdout aus. Alle Meldungen gehen nach stderr.
# Erwartet: PHP_INI_KEYS

OUT=$(mktemp -d /tmp/.migration-inventory.XXXXXX)
_cleanup_files+=("$OUT")
exec 3>&1 1>&2
cd "$OUT" || exit 1

# cmd <datei> <befehl...>  – Ausgabe in Datei, Fehler werden ignoriert
cmd() {
    local f=$1
    shift
    "$@" >"$f" 2>/dev/null </dev/null || true
}

summary() { printf '%s=%s\n' "$1" "$2" >>summary.env; }

rlog "Sammle System-Informationen ..."
cmd system-release.txt cat /etc/system-release
cmd uname.txt uname -a
cmd hostname.txt hostname -f
cmd packages.tsv sh -c "rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' | sort"
# Amazon Linux 2 nutzt systemd, Amazon Linux AMI 2018 SysV-Init (chkconfig)
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cmd services-enabled.txt sh -c "systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '\$2==\"enabled\" {sub(/\\.service\$/, \"\", \$1); print \$1}' | sort -u"
    cmd services-running.txt sh -c "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print \$1}'"
else
    cmd services-enabled.txt sh -c "chkconfig --list 2>/dev/null | awk '/3:on/{print \$1}'"
    cmd services-running.txt sh -c "service --status-all 2>/dev/null | grep -i 'running' "
fi
cmd listen.txt sh -c 'netstat -tlnp 2>/dev/null || ss -tlnp'
cmd df.txt df -hP
cmd crontab-users.txt ls -1 /var/spool/cron
cmd sudoers.d.txt ls -1 /etc/sudoers.d

# AL2 (timedatectl): /etc/localtime ist ein Symlink, /etc/sysconfig/clock oft
# veraltet. AMI 2018: /etc/localtime ist eine Kopie, Zone in sysconfig/clock.
ZONE=""
if [ -L /etc/localtime ]; then
    ZONE=$(readlink -f /etc/localtime | sed -n 's#^.*/zoneinfo/##p')
fi
if [ -z "$ZONE" ] && [ -r /etc/sysconfig/clock ]; then
    # shellcheck disable=SC1091
    ZONE=$(. /etc/sysconfig/clock 2>/dev/null; echo "${ZONE:-}")
fi
ZONE=${ZONE:-UTC}

# Ab welcher UID/GID beginnen "echte" Benutzer? AMI 2018: 500, AL2: 1000
UID_MIN=$(awk '$1=="UID_MIN" {print $2}' /etc/login.defs 2>/dev/null)
GID_MIN=$(awk '$1=="GID_MIN" {print $2}' /etc/login.defs 2>/dev/null)
if [ -z "$UID_MIN" ]; then
    if grep -q 'Amazon Linux AMI' /etc/system-release 2>/dev/null; then UID_MIN=500; else UID_MIN=1000; fi
fi
summary SRC_UID_MIN "$UID_MIN"
summary SRC_GID_MIN "${GID_MIN:-$UID_MIN}"
summary SRC_OS "$(cat /etc/system-release 2>/dev/null)"
summary SRC_HOSTNAME "$(hostname -f 2>/dev/null || cat /proc/sys/kernel/hostname)"
summary SRC_TIMEZONE "$ZONE"

MTA=none
for s in postfix sendmail exim; do
    if systemctl is-active -q "$s" 2>/dev/null || service "$s" status >/dev/null 2>&1; then MTA=$s; break; fi
done
summary SRC_MTA "$MTA"

# ---------------------------------------------------------------- Dateien,
# die zu keinem Paket gehören bzw. gegenüber dem Paket geändert wurden
rlog "Ermittle eigene/geänderte Konfigurationsdateien ..."
: >custom-files.tsv
for d in /etc/httpd/conf /etc/httpd/conf.d /etc/php.d /etc/cron.d /etc/cron.hourly \
    /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/logrotate.d /etc/my.cnf.d; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        if ! rpm -qf "$f" >/dev/null 2>&1; then
            printf 'custom\t%s\n' "$f" >>custom-files.tsv
        elif rpm -Vf "$f" 2>/dev/null | awk -v f="$f" '$NF==f && $1 ~ /5/ {found=1} END{exit !found}'; then
            printf 'modified\t%s\n' "$f" >>custom-files.tsv
        fi
    done
done
for f in /etc/php.ini /etc/my.cnf; do
    [ -f "$f" ] || continue
    if rpm -Vf "$f" 2>/dev/null | awk -v f="$f" '$NF==f && $1 ~ /5/ {found=1} END{exit !found}'; then
        printf 'modified\t%s\n' "$f" >>custom-files.tsv
    fi
done

# ---------------------------------------------------------------- Apache
if command -v httpd >/dev/null 2>&1; then
    rlog "Apache ..."
    cmd httpd-version.txt httpd -v
    cmd httpd-modules.txt sh -c "httpd -M 2>/dev/null | awk 'NR>1 && \$1 ~ /_module\$/ {print \$1}' | sort -u"
    cmd httpd-S.txt sh -c 'httpd -S 2>&1'
    summary SRC_HTTPD_VERSION "$(httpd -v 2>/dev/null | sed -n 's/^Server version: Apache\/\([0-9.]*\).*/\1/p')"
    # DocumentRoots und Zertifikatsdateien aus allen Konfigurationsdateien
    find /etc/httpd -name '*.conf' -type f -print0 2>/dev/null |
        xargs -0 -r grep -hiE '^[[:space:]]*(DocumentRoot|SSLCertificateFile|SSLCertificateKeyFile|SSLCertificateChainFile|SSLCACertificateFile)[[:space:]]' 2>/dev/null |
        awk '{d=$1; $1=""; sub(/^ +/,""); gsub(/"/,""); print d "\t" $0}' | sort -u >httpd-paths.tsv
fi

# ---------------------------------------------------------------- PHP
# Auf Amazon Linux 2 ist PHP 5.6/7.x oft aus den Remi-Repos installiert –
# als System-PHP oder als Software Collection unter /opt/remi/phpXX
PHPBIN=$(command -v php 2>/dev/null || true)
if [ -z "$PHPBIN" ]; then
    for f in /opt/remi/php*/root/usr/bin/php; do [ -x "$f" ] && PHPBIN=$f; done
fi
if [ -n "$PHPBIN" ]; then
    rlog "PHP ($PHPBIN) ..."
    summary SRC_PHP_BIN "$PHPBIN"
    summary SRC_PHP_VERSION "$("$PHPBIN" -r 'echo PHP_VERSION;' 2>/dev/null)"
    cmd php-modules.txt sh -c "'$PHPBIN' -m 2>/dev/null | grep -v '^\[' | grep -v '^\$' | tr 'A-Z' 'a-z' | sort -u"
    PHP_INI_KEYS=${PHP_INI_KEYS:-} "$PHPBIN" -r '
        foreach (preg_split("/\s+/", getenv("PHP_INI_KEYS"), -1, PREG_SPLIT_NO_EMPTY) as $k) {
            $v = ini_get($k);
            if ($v !== false) { echo $k, "\t", str_replace(array("\t", "\n"), " ", $v), "\n"; }
        }' >php-ini.tsv 2>/dev/null </dev/null || true
    cmd php-ini-files.txt "$PHPBIN" --ini
else
    summary SRC_PHP_VERSION ""
fi

# ---------------------------------------------------------------- MySQL
mysql_setup
if [ -n "$(mysql_bin)" ] && q "SELECT 1" >/dev/null 2>mysql-error.txt; then
    rlog "MySQL ..."
    summary SRC_MYSQL_OK 1
    summary SRC_MYSQL_VERSION "$(q 'SELECT VERSION()')"
    q "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('sql_mode','character_set_server','collation_server','max_allowed_packet','lower_case_table_names','event_scheduler','innodb_buffer_pool_size','max_connections','wait_timeout','ft_min_word_len','group_concat_max_len','default_storage_engine','time_zone')" >mysql-variables.tsv
    q "SELECT s.schema_name, COALESCE(SUM(t.data_length + t.index_length), 0)
         FROM information_schema.schemata s
         LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
        GROUP BY s.schema_name ORDER BY s.schema_name" >mysql-databases.tsv
    q "SELECT table_schema, engine, COUNT(*) FROM information_schema.tables
        WHERE table_type = 'BASE TABLE' GROUP BY table_schema, engine" >mysql-engines.tsv
    q "SELECT User, Host FROM mysql.user ORDER BY User, Host" >mysql-users.tsv
else
    summary SRC_MYSQL_OK 0
    : >mysql-databases.tsv
    rlog "MySQL nicht erreichbar: $(head -c 300 mysql-error.txt 2>/dev/null)"
fi

# ---------------------------------------------------------------- Größen
cmd du.txt sh -c 'du -sk /var/www /home 2>/dev/null'

tar -czf - . >&3
