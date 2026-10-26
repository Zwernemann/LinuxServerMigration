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
#
#  Danach steht der öffentliche Schlüssel in der letzten Zeile (PUBKEY=…);
#  er muss beim alten Server in ~ec2-user/.ssh/authorized_keys stehen.
# =============================================================================
set -euo pipefail

SRC_HOST=""; SRC_PORT=22; SRC_INSTANCE=""; REGION=""; EIP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    --src-host) SRC_HOST=$2; shift 2 ;;
    --src-port) SRC_PORT=$2; shift 2 ;;
    --src-instance) SRC_INSTANCE=$2; shift 2 ;;
    --region) REGION=$2; shift 2 ;;
    --eip) EIP=$2; shift 2 ;;
    -h | --help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
TARGET_DB_ENGINE="mariadb"
AWS_REGION="$REGION"
SRC_INSTANCE_ID="$SRC_INSTANCE"
ELASTIC_IP_ALLOCATION_ID="$EIP"
EOF
    )
    echo "    angelegt"
else
    echo "    existiert bereits – unverändert"
fi
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
