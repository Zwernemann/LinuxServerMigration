#!/usr/bin/env bash
# =============================================================================
#  Richtet den NEUEN Amazon-Linux-2023-Server für migrate.sh ein.
#  Läuft als root auf dem neuen Server; kann beliebig oft ausgeführt werden.
#
#  Wird von aws/provision-target.sh automatisch aufgerufen, geht aber auch
#  von Hand (z.B. wenn der Server selbst angelegt wurde):
#
#    sudo dnf -y install git
#    sudo git clone https://github.com/Zwernemann/LinuxServerMigration.git /opt/linuxservermigration
#    sudo /opt/linuxservermigration/aws/setup-target.sh --src-host 172.30.0.12
#
#  Optionen:
#    --src-host IP        PRIVATE IP des alten Servers
#    --src-port PORT      SSH-Port des alten Servers (Standard: 22)
#    --src-instance ID    Instance-ID des alten Servers (für rollback)
#    --region R           AWS-Region
#    --eip ALLOC          Allocation-ID der Elastic IP (für cutover)
#    --data-mount DIR     leere Zusatzplatte formatieren und unter DIR einhängen
#                         (z.B. /daten wie auf dem alten Server)
#    --conf KEY=WERT      Einstellung in migration.conf setzen (mehrfach möglich),
#                         z.B. --conf 'EXTRA_PACKAGES=mc s-nail'
#    --ssh-port PORT      SSH auf dem neuen Server auf diesen Port legen
#                         (z.B. denselben wie auf dem alten Server)
#    --no-swap            keine Auslagerungsdatei anlegen (sonst automatisch
#                         2 GB, wenn der Server weniger als 2 GB RAM hat)
#
#  Danach steht der öffentliche Schlüssel in der letzten Zeile (PUBKEY=…);
#  er muss beim alten Server in ~ec2-user/.ssh/authorized_keys stehen.
# =============================================================================
set -euo pipefail

SRC_HOST=""; SRC_PORT=22; SRC_INSTANCE=""; REGION=""; EIP=""; DATA_MOUNT=""; SWAP=1; SSH_PORT=""
CONF_SET=()
while [[ $# -gt 0 ]]; do
    case "$1" in
    --src-host) SRC_HOST=$2; shift 2 ;;
    --src-port) SRC_PORT=$2; shift 2 ;;
    --src-instance) SRC_INSTANCE=$2; shift 2 ;;
    --region) REGION=$2; shift 2 ;;
    --eip) EIP=$2; shift 2 ;;
    --data-mount) DATA_MOUNT=$2; shift 2 ;;
    --conf) CONF_SET+=("$2"); shift 2 ;;
    --no-swap) SWAP=0; shift ;;
    --ssh-port) SSH_PORT=$2; shift 2 ;;
    -h | --help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    esac
done
[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }

TOOL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KEY=/root/.ssh/migration_key
CONF="$TOOL_DIR/migration.conf"

echo "==> Pakete (git, tmux, rsync)"
missing=()
for p in git tmux rsync; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then
    ok=0
    for _ in 1 2 3; do
        if dnf -y -q install "${missing[@]}"; then ok=1; break; fi
        echo "    dnf fehlgeschlagen – neuer Versuch in 15 s" >&2
        sleep 15
    done
    [[ $ok == 1 ]] || { echo "FEHLER: Pakete nicht installierbar. Hat der Server Internetzugang?" >&2; exit 1; }
fi

# Leere Zusatzplatte (kein Dateisystem, keine Partitionen, nicht die
# Systemplatte) formatieren und dauerhaft einhängen
setup_data_mount() {
    local dir=$1 rootdisk dev d uuid
    if mountpoint -q "$dir"; then
        echo "    $dir ist bereits eingehängt"
        return 0
    fi
    if grep -qE "[[:space:]]${dir}[[:space:]]" /etc/fstab; then
        mkdir -p "$dir"
        mount "$dir" && { echo "    $dir eingehängt (fstab)"; return 0; }
    fi
    rootdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -n 1)
    dev=""
    while read -r d; do
        [[ "$(basename "$d")" == "$rootdisk" ]] && continue
        [[ $(lsblk -no NAME "$d" | wc -l) -eq 1 ]] || continue          # hat Partitionen
        [[ -z "$(lsblk -no FSTYPE "$d" | tr -d '[:space:]')" ]] || continue  # hat ein Dateisystem
        [[ -z "$(lsblk -no MOUNTPOINT "$d" | tr -d '[:space:]')" ]] || continue
        dev=$d
        break
    done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')
    if [[ -z "$dev" ]]; then
        echo "FEHLER: keine leere Zusatzplatte für $dir gefunden (lsblk prüfen)." >&2
        return 1
    fi
    echo "    formatiere $dev (xfs) und hänge es unter $dir ein"
    mkfs.xfs -q "$dev"
    mkdir -p "$dir"
    uuid=$(blkid -s UUID -o value "$dev")
    echo "UUID=$uuid $dir xfs defaults,nofail 0 2" >>/etc/fstab
    mount "$dir"
    df -h "$dir" | tail -n 1 | sed 's/^/    /'
}

if [[ -n "$DATA_MOUNT" ]]; then
    echo "==> Datenplatte $DATA_MOUNT"
    setup_data_mount "$DATA_MOUNT"
fi

# Wenig Arbeitsspeicher (z.B. t3.micro mit 1 GB): MySQL 8 + PHP-FPM brauchen Swap
if [[ $SWAP == 1 && -z "$(swapon --noheadings 2>/dev/null)" ]] &&
    [[ $(awk '/MemTotal/ {print $2}' /proc/meminfo) -lt 2000000 ]]; then
    echo "==> Auslagerungsdatei /swapfile (2 GB) – der Server hat weniger als 2 GB RAM"
    if [[ ! -f /swapfile ]]; then
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
        chmod 600 /swapfile
        mkswap -q /swapfile 2>/dev/null || mkswap /swapfile >/dev/null
    fi
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >>/etc/fstab
fi

# SSH-Port wie auf dem alten Server (Port 22 bleibt dann zu)
if [[ -n "$SSH_PORT" && "$SSH_PORT" != 22 ]]; then
    echo "==> SSH auf Port $SSH_PORT"
    echo "Port $SSH_PORT" >/etc/ssh/sshd_config.d/10-port.conf
    if [[ "$(getenforce 2>/dev/null)" == Enforcing ]]; then
        rpm -q policycoreutils-python-utils >/dev/null 2>&1 || dnf -y -q install policycoreutils-python-utils
        semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null ||
            semanage port -m -t ssh_port_t -p tcp "$SSH_PORT"
    fi
    if sshd -t; then
        systemctl restart sshd
    else
        rm -f /etc/ssh/sshd_config.d/10-port.conf
        echo "FEHLER: sshd-Konfiguration ungültig – Port nicht geändert." >&2
    fi
fi

echo "==> SSH-Schlüssel für den Zugriff auf den alten Server"
install -d -m 700 /root/.ssh
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C linuxservermigration -f "$KEY"

echo "==> Konfiguration $CONF"
if [[ ! -f "$CONF" ]]; then
    if [[ -z "$SRC_HOST" && -t 0 ]]; then
        read -r -p "    Private IP des ALTEN Servers (EC2-Konsole -> alter Server -> 'Private IPv4-Adresse'): " SRC_HOST
    fi
    if [[ -z "$REGION" ]]; then
        tok=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
        REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/placement/region || true)
    fi
    (
        umask 077
        cat >"$CONF" <<EOF
# Vorbelegt von aws/setup-target.sh – alle Optionen: migration.conf.example
SRC_HOST="$SRC_HOST"
SRC_SSH_USER="ec2-user"
SRC_SSH_PORT="$SRC_PORT"
SRC_SSH_KEY="$KEY"
# MySQL-root-Passwort des alten Servers (leer = /root/.my.cnf dort verwenden)
SRC_DB_PASS=""
TARGET_PHP_VERSION="8.3"
TARGET_DB_ENGINE="auto"
AWS_REGION="$REGION"
SRC_INSTANCE_ID="$SRC_INSTANCE"
ELASTIC_IP_ALLOCATION_ID="$EIP"
EOF
    )
    echo "    angelegt"
else
    echo "    existiert bereits – unverändert"
fi
# --conf KEY=WERT: Einstellung setzen (vorhandene Zeile wird ersetzt)
for kv in ${CONF_SET[@]+"${CONF_SET[@]}"}; do
    k=${kv%%=*}
    v=${kv#*=}
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ && "$kv" == *=* ]] || { echo "FEHLER: ungültige Einstellung '$kv'" >&2; exit 2; }
    v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}; v=${v//\`/\\\`}
    grep -v "^$k=" "$CONF" >"$CONF.tmp" || true
    printf '%s="%s"\n' "$k" "$v" >>"$CONF.tmp"
    cat "$CONF.tmp" >"$CONF"
    rm -f "$CONF.tmp"
    echo "    $k=\"$v\""
done
grep -q '^SRC_HOST="[^"]' "$CONF" || echo "    ACHTUNG: SRC_HOST ist leer – bitte in $CONF eintragen." >&2

touch /var/lib/linuxservermigration-ready
echo
echo "Fertig. Nächste Schritte:"
echo "  1. Den folgenden Schlüssel beim ALTEN Server eintragen (falls nicht automatisch geschehen):"
echo "       echo '$(cat "$KEY.pub")' >> ~/.ssh/authorized_keys"
echo "  2. Migration starten:"
echo "       tmux new -s migration"
echo "       cd $TOOL_DIR"
echo "       ./migrate.sh preflight"
echo "PUBKEY=$(cat "$KEY.pub")"
