#!/usr/bin/env bash
# =============================================================================
#  Legt den NEUEN Amazon-Linux-2023-Server neben dem alten an und bereitet
#  alles für migrate.sh vor. Gedacht für die AWS CloudShell (Browser-Konsole,
#  aws-cli und Zugangsdaten sind dort schon vorhanden).
#
#    bash aws/provision-target.sh --old-instance i-0123456789abcdef0
#
#  Was passiert:
#   1. Daten des alten Servers lesen (VPC, Subnetz, Security Groups,
#      Schlüsselpaar, Instanztyp, Plattengröße, Elastic IP)
#   2. IAM-Rolle "LinuxServerMigrationRole" anlegen (Session Manager +
#      Elastic IP umhängen) – falls noch nicht vorhanden
#   3. Security Group "linuxservermigration-<id>" anlegen und beim alten
#      Server SSH (Port 22) NUR von dieser Gruppe erlauben
#   4. Neuen Server starten: gleiches Subnetz, gleiche Security Groups,
#      gleiches Schlüsselpaar, aktuelles AL2023, verschlüsselte gp3-Platte
#      (oder mit --new-instance einen schon vorhandenen Server übernehmen)
#   5. Über Session Manager auf dem neuen Server das Migrations-Tool nach
#      /opt/linuxservermigration installieren (aws/setup-target.sh)
#   6. Dessen SSH-Schlüssel beim alten Server hinterlegen – automatisch über
#      Session Manager, sonst mit einer Anleitung für einen Befehl.
#
#  Optionen:
#    --old-instance ID   Instance-ID des alten Servers (Pflicht)
#    --src-ssh-port P    SSH-Port des alten Servers (Standard: 22)
#    --instance-type T   Instanztyp des neuen Servers (Standard: wie alt,
#                        t2/m4/c4/r4 werden auf die aktuelle Generation gehoben)
#    --disk-size GB      Größe der Systemplatte (Standard: Summe der Platten
#                        des alten Servers, mindestens 20)
#    --new-instance ID   einen bereits angelegten AL2023-Server verwenden,
#                        statt einen neuen zu starten
#    --name NAME         Name des neuen Servers (Standard: <alter Name>-al2023)
#    --region R          AWS-Region (Standard: Region der CloudShell)
#    --yes               nicht nachfragen
#    --cleanup           nach der Migration: SSH-Freigabe und Schlüssel auf
#                        dem alten Server wieder entfernen
#
#  Wiederholbar: Ein bereits angelegter neuer Server wird wiederverwendet.
# =============================================================================
set -euo pipefail

OLD=""; NEWARG=""; SRCPORT=22; TYPE=""; DISK=""; NAME=""; YES=0; CLEANUP=0
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
REPO_URL=${REPO_URL:-https://github.com/Zwernemann/LinuxServerMigration.git}
REPO_BRANCH=${REPO_BRANCH:-$(git -C "$(dirname "$0")" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}
ROLE=LinuxServerMigrationRole

usage() { sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [[ $# -gt 0 ]]; do
    case "$1" in
    --old-instance | -i) OLD=$2; shift 2 ;;
    --new-instance) NEWARG=$2; shift 2 ;;
    --src-ssh-port) SRCPORT=$2; shift 2 ;;
    --instance-type) TYPE=$2; shift 2 ;;
    --disk-size) DISK=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --region) REGION=$2; shift 2 ;;
    --yes | -y) YES=1; shift ;;
    --cleanup) CLEANUP=1; shift ;;
    -h | --help) usage ;;
    *) echo "Unbekannte Option: $1" >&2; usage 2 ;;
    esac
done
[[ -n "$OLD" ]] || { echo "Bitte --old-instance i-... angeben (EC2-Konsole -> Instanzen -> Instance-ID)." >&2; exit 2; }

say() { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
die() { printf '\n\033[31mFEHLER: %s\033[0m\n' "$*" >&2; exit 1; }
ask() { [[ $YES == 1 ]] && return 0; local a; read -r -p "$1 [j/N] " a; [[ "${a,,}" == j* || "${a,,}" == y* ]]; }
none() { [[ -z "$1" || "$1" == None || "$1" == null ]]; }

aws() { if [[ -n "$REGION" ]]; then command aws --region "$REGION" "$@"; else command aws "$@"; fi; }
command -v aws >/dev/null || die "aws-cli nicht gefunden – bitte in der AWS CloudShell ausführen."
[[ -n "$REGION" ]] || REGION=$(command aws configure get region 2>/dev/null || true)
[[ -n "$REGION" ]] || die "Keine Region bekannt – bitte --region angeben (z.B. --region eu-central-1)."

# Shell-Skript per Session Manager auf einer Instanz ausführen, Ausgabe auf stdout
ssm_online() {
    [[ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$1" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" == Online ]]
}
ssm_run() { # ssm_run <instance-id> <skript>
    local id b64 status i
    b64=$(printf '%s' "$2" | base64 -w0)
    id=$(aws ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript \
        --parameters "commands=[\"echo $b64 | base64 -d | bash\"]" --timeout-seconds 600 \
        --query Command.CommandId --output text)
    for i in $(seq 1 120); do
        status=$(aws ssm get-command-invocation --command-id "$id" --instance-id "$1" \
            --query Status --output text 2>/dev/null || echo Pending)
        case "$status" in
        Success) aws ssm get-command-invocation --command-id "$id" --instance-id "$1" \
            --query StandardOutputContent --output text; return 0 ;;
        Failed | Cancelled | TimedOut | Undeliverable | Terminated)
            aws ssm get-command-invocation --command-id "$id" --instance-id "$1" \
                --query StandardOutputContent --output text 2>/dev/null | tail -n 20 >&2 || true
            aws ssm get-command-invocation --command-id "$id" --instance-id "$1" \
                --query StandardErrorContent --output text 2>/dev/null | tail -n 20 >&2 || true
            return 1 ;;
        esac
        sleep 5
    done
    return 1
}
wait_ssm() { # wait_ssm <instance-id> <sekunden>
    local t=0
    while ! ssm_online "$1"; do
        [[ $t -lt $2 ]] || return 1
        sleep 10; t=$((t + 10))
        printf '.' >&2
    done
    echo >&2
}

# ---------------------------------------------------------------------------
say "Alter Server $OLD"
aws ec2 describe-instances --instance-ids "$OLD" >/dev/null ||
    die "Instanz $OLD nicht gefunden (richtige Region $REGION? Rechte für EC2?)."
read -r VPC SUBNET OLDTYPE KEY PRIV PUB PROFILE AZ ARCH STATE <<<"$(aws ec2 describe-instances --instance-ids "$OLD" \
    --query 'Reservations[0].Instances[0].[VpcId,SubnetId,InstanceType,KeyName,PrivateIpAddress,PublicIpAddress,IamInstanceProfile.Arn,Placement.AvailabilityZone,Architecture,State.Name]' \
    --output text)"
OLDNAME=$(aws ec2 describe-instances --instance-ids "$OLD" --query "Reservations[0].Instances[0].Tags[?Key=='Name']|[0].Value" --output text)
read -ra OLDSGS <<<"$(aws ec2 describe-instances --instance-ids "$OLD" --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)"
EIP=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$OLD" --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)
none "$EIP" && EIP=""
none "$OLDNAME" && OLDNAME=$OLD
info "Name: $OLDNAME   Typ: $OLDTYPE   Zustand: $STATE   Zone: $AZ"
info "Private IP: $PRIV   Öffentliche IP: ${PUB/None/-}   Elastic IP: ${EIP:-keine}"
info "Schlüsselpaar: ${KEY/None/-}   Security Groups: ${OLDSGS[*]}"
[[ "$STATE" == running ]] || die "Der alte Server muss laufen (Zustand: $STATE)."
MIGSG_NAME="linuxservermigration-$OLD"

# ---------------------------------------------------------------------------
if [[ $CLEANUP == 1 ]]; then
    say "Aufräumen"
    MIGSG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$MIGSG_NAME" "Name=vpc-id,Values=$VPC" \
        --query 'SecurityGroups[0].GroupId' --output text)
    if ! none "$MIGSG"; then
        if aws ec2 revoke-security-group-ingress --group-id "${OLDSGS[0]}" \
            --ip-permissions "IpProtocol=tcp,FromPort=$SRCPORT,ToPort=$SRCPORT,UserIdGroupPairs=[{GroupId=$MIGSG}]" >/dev/null 2>&1; then
            info "SSH-Freigabe in ${OLDSGS[0]} entfernt"
        else
            info "SSH-Freigabe war schon entfernt"
        fi
    fi
    if ssm_online "$OLD"; then
        ssm_run "$OLD" "sed -i '/linuxservermigration\$/d' /home/ec2-user/.ssh/authorized_keys; rm -f /etc/sudoers.d/99-linuxservermigration" >/dev/null &&
            info "Migrations-Schlüssel auf dem alten Server entfernt"
    else
        info "Auf dem alten Server bitte die Zeile mit 'linuxservermigration' aus ~/.ssh/authorized_keys löschen."
    fi
    info "Den alten Server erst nach einigen Tagen und einem AMI-Backup terminieren."
    exit 0
fi

# ---------------------------------------------------------------------------
if [[ -n "$NEWARG" ]]; then
    NEW=$NEWARG
    read -r NEWVPC NEWPROFILE <<<"$(aws ec2 describe-instances --instance-ids "$NEW" \
        --query 'Reservations[0].Instances[0].[VpcId,IamInstanceProfile.Arn]' --output text)" ||
        die "Instanz $NEW nicht gefunden."
    [[ "$NEWVPC" == "$VPC" ]] || die "Der neue Server $NEW liegt in einem anderen VPC ($NEWVPC) als der alte ($VPC)."
else
    NEW=$(aws ec2 describe-instances --filters "Name=tag:linuxservermigration,Values=$OLD" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text)
    none "$NEW" && NEW=""
    NEWPROFILE=managed
fi

# IAM-Rolle (Session Manager + Elastic IP umhängen)
ensure_role() {
    say "IAM-Rolle $ROLE"
    local part
    part=$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)
    if aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
        info "vorhanden"
        return 0
    fi
    aws iam create-role --role-name "$ROLE" --description "LinuxServerMigration: Session Manager + Elastic IP" \
        --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$ROLE" --policy-arn "arn:$part:iam::aws:policy/AmazonSSMManagedInstanceCore"
    aws iam put-role-policy --role-name "$ROLE" --policy-name elastic-ip-cutover \
        --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ec2:AssociateAddress","ec2:DescribeAddresses","ec2:DescribeInstances"],"Resource":"*"}]}'
    aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
    info "angelegt"
}

# Security Group für den neuen Server + SSH-Freigabe beim alten
ensure_sg() {
    say "Security Groups"
    MIGSG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$MIGSG_NAME" "Name=vpc-id,Values=$VPC" \
        --query 'SecurityGroups[0].GroupId' --output text)
    if none "$MIGSG"; then
        MIGSG=$(aws ec2 create-security-group --group-name "$MIGSG_NAME" --vpc-id "$VPC" \
            --description "LinuxServerMigration: neuer Server darf per SSH auf $OLD" --query GroupId --output text)
    fi
    aws ec2 authorize-security-group-ingress --group-id "${OLDSGS[0]}" \
        --ip-permissions "IpProtocol=tcp,FromPort=$SRCPORT,ToPort=$SRCPORT,UserIdGroupPairs=[{GroupId=$MIGSG,Description=LinuxServerMigration}]" \
        >/dev/null 2>&1 || true
    info "$MIGSG_NAME ($MIGSG); SSH-Freigabe in ${OLDSGS[0]}"
}

if [[ -z "$NEW" ]]; then
    # Instanztyp: ältere Generationen auf die aktuelle heben (gleiche Größe)
    if [[ -z "$TYPE" ]]; then
        TYPE=$(sed -E 's/^t2\./t3./; s/^(m1|m3|m4)\./m5./; s/^(c1|c3|c4)\./c5./; s/^(r3|r4)\./r5./' <<<"$OLDTYPE")
        if [[ "$TYPE" != "$OLDTYPE" ]] && none "$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
            --filters "Name=location,Values=$AZ" "Name=instance-type,Values=$TYPE" \
            --query 'InstanceTypeOfferings[0].InstanceType' --output text)"; then
            TYPE=$OLDTYPE
        fi
    fi
    # Plattengröße: Summe aller Platten des alten Servers, mindestens 20 GB
    if [[ -z "$DISK" ]]; then
        DISK=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$OLD" \
            --query 'sum(Volumes[].Size)' --output text)
        [[ "$DISK" =~ ^[0-9]+$ && $DISK -ge 20 ]] || DISK=20
    fi
    [[ "$ARCH" == arm64 ]] && AMIARCH=arm64 || AMIARCH=x86_64
    AMI=$(aws ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$AMIARCH" \
        --query Parameter.Value --output text)
    NAME=${NAME:-$OLDNAME-al2023}

    say "Geplanter neuer Server"
    info "Name: $NAME   Typ: $TYPE   Platte: $DISK GB gp3 (verschlüsselt)"
    info "AMI: $AMI (aktuelles Amazon Linux 2023)"
    info "Subnetz: $SUBNET (wie alt)   Security Groups: ${OLDSGS[*]} + $MIGSG_NAME"
    info "Schlüsselpaar: ${KEY/None/keins – Zugang nur über Session Manager}"
    info "Tool: $REPO_URL (Branch $REPO_BRANCH) -> /opt/linuxservermigration"
    info "Beim alten Server wird SSH (Port $SRCPORT) von $MIGSG_NAME erlaubt."
    echo >&2
    info "Kosten: der neue Server läuft parallel zum alten (Preis siehe EC2-Preisliste für $TYPE)."
    ask "Neuen Server so anlegen?" || die "Abgebrochen."

    ensure_role
    ensure_sg
    say "Starte neuen Server"
    args=(--image-id "$AMI" --instance-type "$TYPE" --subnet-id "$SUBNET"
        --security-group-ids "${OLDSGS[@]}" "$MIGSG"
        --iam-instance-profile "Name=$ROLE"
        --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$DISK,VolumeType=gp3,Encrypted=true}"
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=linuxservermigration,Value=$OLD}]"
        --query 'Instances[0].InstanceId' --output text)
    none "$KEY" || args+=(--key-name "$KEY")
    none "$PUB" || args+=(--associate-public-ip-address)
    # Neue IAM-Rollen brauchen einige Sekunden, bis EC2 sie kennt
    err=$(mktemp)
    for i in $(seq 1 12); do
        if NEW=$(aws ec2 run-instances "${args[@]}" 2>"$err"); then break; fi
        grep -q 'iamInstanceProfile' "$err" || { cat "$err" >&2; die "Start fehlgeschlagen."; }
        [[ $i -lt 12 ]] || die "IAM-Rolle wird von EC2 nicht gefunden."
        sleep 10
    done
    rm -f "$err"
    info "Instanz $NEW gestartet"
else
    say "Neuer Server: $NEW"
    ensure_role
    ensure_sg
    if [[ -n "$NEWARG" ]]; then
        aws ec2 create-tags --resources "$NEW" --tags "Key=linuxservermigration,Value=$OLD"
        read -ra NEWSGS <<<"$(aws ec2 describe-instances --instance-ids "$NEW" \
            --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text)"
        if [[ " ${NEWSGS[*]} " != *" $MIGSG "* ]]; then
            aws ec2 modify-instance-attribute --instance-id "$NEW" --groups "${NEWSGS[@]}" "$MIGSG"
            info "Security Group $MIGSG_NAME zum neuen Server hinzugefügt"
        fi
        if none "$NEWPROFILE"; then
            aws ec2 associate-iam-instance-profile --instance-id "$NEW" --iam-instance-profile "Name=$ROLE" >/dev/null
            info "Rolle $ROLE dem neuen Server zugewiesen"
        elif [[ "$NEWPROFILE" != *"/$ROLE" ]]; then
            info "Der neue Server hat schon eine eigene IAM-Rolle – für 'cutover' mit Elastic IP braucht sie ec2:AssociateAddress."
        fi
    fi
fi

aws ec2 wait instance-running --instance-ids "$NEW"
read -r NEWPRIV NEWPUB <<<"$(aws ec2 describe-instances --instance-ids "$NEW" \
    --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress]' --output text)"

say "Warte, bis sich der neue Server beim Session Manager meldet (ca. 1-3 Minuten)"
wait_ssm "$NEW" 600 || die "Neuer Server meldet sich nicht beim Session Manager. Hat das Subnetz Internetzugang (Internet- oder NAT-Gateway)? Läuft er mit der Rolle $ROLE?"

say "Installiere das Migrations-Tool auf dem neuen Server"
BOOT="set -e
exec 2>&1
command -v git >/dev/null || dnf -y -q install git
if [ -d /opt/linuxservermigration/.git ]; then
  git -C /opt/linuxservermigration pull -q --ff-only || echo 'Hinweis: git pull nicht möglich, vorhandene Version bleibt'
else
  git clone -q -b '$REPO_BRANCH' '$REPO_URL' /opt/linuxservermigration
fi
bash /opt/linuxservermigration/aws/setup-target.sh --src-host '$PRIV' --src-port '$SRCPORT' --src-instance '$OLD' --region '$REGION' --eip '$EIP'"
OUT=$(ssm_run "$NEW" "$BOOT") || die "Einrichtung des neuen Servers fehlgeschlagen (Ausgabe siehe oben)."
PUBKEY=$(sed -n 's/^PUBKEY=//p' <<<"$OUT" | tr -d '\r' | tail -n 1)
[[ "$PUBKEY" == ssh-ed25519* ]] || { echo "$OUT" | tail -n 20 >&2; die "Kein SSH-Schlüssel auf dem neuen Server gefunden."; }
info "Tool installiert: /opt/linuxservermigration"

# ---------------------------------------------------------------------------
say "Zugang vom neuen zum alten Server"
OLD_SCRIPT="set -e
install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
touch /home/ec2-user/.ssh/authorized_keys
grep -qF '$PUBKEY' /home/ec2-user/.ssh/authorized_keys || echo '$PUBKEY' >>/home/ec2-user/.ssh/authorized_keys
chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys; chmod 600 /home/ec2-user/.ssh/authorized_keys
if grep -qs '^Defaults.*requiretty' /etc/sudoers /etc/sudoers.d/*; then
  echo 'Defaults:ec2-user !requiretty' >/etc/sudoers.d/99-linuxservermigration; chmod 440 /etc/sudoers.d/99-linuxservermigration
fi
echo ok"
done_key=0
if ! ssm_online "$OLD" && none "$PROFILE"; then
    info "Der alte Server ist nicht beim Session Manager angemeldet."
    info "Ihm kann dafür jetzt die Rolle $ROLE zugewiesen werden (ohne Neustart; ändert sonst nichts)."
    if ask "Rolle dem alten Server zuweisen?"; then
        aws ec2 associate-iam-instance-profile --instance-id "$OLD" --iam-instance-profile "Name=$ROLE" >/dev/null
        info "Warte bis zu 5 Minuten, ob sich der SSM-Agent des alten Servers meldet"
        wait_ssm "$OLD" 300 || info "Kein SSM-Agent aktiv auf dem alten Server."
    fi
fi
if ssm_online "$OLD"; then
    if ssm_run "$OLD" "$OLD_SCRIPT" >/dev/null; then
        info "Schlüssel automatisch beim alten Server hinterlegt."
        done_key=1
    fi
fi
if [[ $done_key == 0 ]]; then
    cat >&2 <<EOF

    Bitte EINMAL auf dem ALTEN Server ausführen (Anmeldung wie gewohnt, z.B.
    ssh -p $SRCPORT -i ihr-schluessel.pem ec2-user@${PUB/None/$PRIV}):

      echo '$PUBKEY' >> ~/.ssh/authorized_keys

    Danach auf dem neuen Server "sudo ./migrate.sh preflight" ausführen.
EOF
fi

# ---------------------------------------------------------------------------
say "Fertig"
cat >&2 <<EOF
    Neuer Server: $NEW ($NAME)
      private IP:     $NEWPRIV
      öffentliche IP: ${NEWPUB/None/-}

    Anmelden am neuen Server (im Browser, ohne Schlüssel):
      https://$REGION.console.aws.amazon.com/systems-manager/session-manager/$NEW?region=$REGION
    oder: EC2-Konsole -> Instanz $NEW -> "Verbinden" -> "Session Manager"

    Dort:
      sudo -i
      tmux new -s migration            # Sitzung bleibt bei Verbindungsabbruch erhalten
      cd /opt/linuxservermigration
      vi migration.conf                # SRC_DB_PASS eintragen (MySQL-root-Passwort des alten Servers)
      ./migrate.sh preflight
      ./migrate.sh all

    Nach abgebrochener Verbindung: sudo -i; tmux attach -t migration
EOF
[[ -n "$EIP" ]] || info "Hinweis: Der alte Server hat keine Elastic IP – nach dem Umzug muss der DNS-Eintrag geändert werden."
