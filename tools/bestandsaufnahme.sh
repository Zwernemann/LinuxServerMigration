#!/usr/bin/env bash
# Bestandsaufnahme eines Servers (System, Apache, PHP, MySQL, Dienste, Ports,
# Cron, Zertifikate, Mail) – nur lesend. Auf dem ALTEN Server ausführen:
#
#   curl -fsSL https://raw.githubusercontent.com/Zwernemann/LinuxServerMigration/main/tools/bestandsaufnahme.sh | sudo bash | tee ~/bestand.txt
#
# Zusätzlich hilfreich für den provision-target.sh-Aufruf:
#   df -h ; sudo crontab -l ; grep -r datadir /etc/my.cnf /etc/my.cnf.d
# shellcheck disable=SC2010,SC2012,SC2035  # ls nur zur Anzeige
exec 2>/dev/null
h() { printf '\n=== %s ===\n' "$*"; }
h SYSTEM
cat /etc/system-release 2>/dev/null || grep PRETTY /etc/os-release
TZN=$(readlink /etc/localtime | sed -n 's#.*zoneinfo/##p'); [ -n "$TZN" ] || TZN=$(sed -n 's/^ZONE="\{0,1\}\([^"]*\).*/\1/p' /etc/sysconfig/clock); [ -n "$TZN" ] || TZN=$(date +%Z)
echo "Host: $(hostname -f 2>/dev/null || cat /proc/sys/kernel/hostname)   Kernel: $(uname -r)   Uptime: $(awk '{printf "%d Tage", $1/86400}' /proc/uptime)"
echo "CPU: $(nproc) Kerne   RAM: $(awk '/MemTotal/ {printf "%d MB", $2/1024}' /proc/meminfo)   Zeitzone: $TZN"
df -hP -x tmpfs -x devtmpfs | awk 'NR==1 || /^\//'
h APACHE
if command -v httpd >/dev/null; then
  httpd -v | head -1; httpd -V | grep -i 'mpm'
  httpd -S 2>&1 | grep -E 'namevhost|^[^ ]+:[0-9]+ ' | sed 's/ (.*//'
else echo "kein Apache (httpd)"; fi
h PHP
P=$(command -v php); [ -n "$P" ] || for f in /opt/remi/php*/root/usr/bin/php; do [ -x "$f" ] && P=$f; done
if [ -n "$P" ]; then
  "$P" -v | head -1; "$P" --ini | grep 'Loaded'
  echo "Module: $("$P" -m | grep -v '^\[' | grep . | sort -fu | tr '\n' ' ')"
  "$P" -r 'foreach(["memory_limit","upload_max_filesize","post_max_size","max_execution_time","date.timezone","short_open_tag","display_errors"] as $k) printf("  %-20s %s\n",$k,ini_get($k));'
  pgrep -x php-fpm >/dev/null && echo "Betrieb: PHP-FPM"; httpd -M 2>/dev/null | grep -qi php && echo "Betrieb: mod_php"
else echo "kein PHP"; fi
h DATENBANK
mysql --version || echo "kein mysql-Client"
pgrep -x mysqld >/dev/null && echo "Server läuft: mysqld"; pgrep -x mariadbd >/dev/null && echo "Server läuft: mariadbd"
mysql --connect-timeout=3 -N -e "SELECT CONCAT('Version: ',VERSION()); SELECT CONCAT('  ',table_schema,'  ',ROUND(SUM(data_length+index_length)/1048576,1),' MB') FROM information_schema.tables GROUP BY table_schema;" ||
  echo "(Datenbanken nur mit Passwort sichtbar: mysql -u root -p -e 'SHOW DATABASES')"
h DIENSTE beim Start
if [ -d /run/systemd/system ]; then systemctl list-unit-files --type=service --no-legend | awk '$2=="enabled"{sub(/\.service$/,"",$1); printf "%s ",$1}'
else chkconfig --list | awk '/3:on/{printf "%s ",$1}'; fi; echo
h OFFENE PORTS
{ ss -tlnp || netstat -tlnp; } | awk 'NR>1 {print $4, $NF}' | sed 's/users:(("\([^"]*\)".*/\1/' | sort -u
h CRON / ZERTIFIKATE / MAIL
for f in /var/spool/cron/*; do [ -f "$f" ] && echo "crontab $(basename "$f"): $(grep -cv '^\s*\(#\|$\)' "$f") Jobs"; done
echo "/etc/cron.d: $(ls /etc/cron.d | tr '\n' ' ')"
[ -d /etc/letsencrypt/live ] && echo "certbot: $(ls /etc/letsencrypt/live | grep -v README | tr '\n' ' ')"
[ -d /root/.acme.sh ] && echo "acme.sh: $(cd /root/.acme.sh && ls -d *.*/ | tr -d / | tr '\n' ' ')"
for s in postfix sendmail exim; do pgrep -x "$s" >/dev/null && echo "Mailserver: $s"; done
pgrep -x master >/dev/null && echo "Mailserver: postfix"
true
