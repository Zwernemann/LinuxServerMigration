# shellcheck shell=bash
# Phase "users": lokale Linux-Benutzer und Gruppen (UID/GID >= 500) übernehmen.
# Amazon Linux AMI 2018 vergibt UIDs ab 500, AL2023 ab 1000 – vorhandene
# UIDs werden beibehalten, sofern sie auf dem Ziel frei sind.

phase_users() {
    require_inventory
    if ! is_yes "$MIGRATE_USERS"; then log "MIGRATE_USERS=no – übersprungen."; return 0; fi
    local passwd group shadow
    passwd=$(snap /etc/passwd) group=$(snap /etc/group) shadow=$(snap /etc/shadow)
    [[ -f "$passwd" && -f "$group" ]] || die "Kein passwd/group im Schnappschuss – 'inventory' erneut ausführen."

    local name gid members uid gecos home shell hash args
    # 1) Gruppen (eigene Gruppen der Quelle)
    while IFS=: read -r name _ gid _; do
        [[ "$gid" =~ ^[0-9]+$ ]] || continue
        (( gid >= 500 && gid < 65534 )) || continue
        getent group "$name" >/dev/null && continue
        if getent group "$gid" >/dev/null; then
            run groupadd "$name"
            warn "Gruppe $name: GID $gid auf dem Ziel belegt – neue GID $(getent group "$name" | cut -d: -f3) vergeben"
        else
            run groupadd -g "$gid" "$name"
        fi
    done <"$group"

    # 2) Benutzer
    while IFS=: read -r name _ uid gid gecos home shell; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= 500 && uid < 65534 )) || continue
        [[ "$name" == ec2-user ]] && continue
        if getent passwd "$name" >/dev/null; then
            log "Benutzer $name existiert bereits."
            continue
        fi
        local pgroup
        pgroup=$(awk -F: -v g="$gid" '$3==g {print $1; exit}' "$group")
        [[ -n "$pgroup" ]] && getent group "$pgroup" >/dev/null || pgroup=""
        [[ -x "$shell" ]] || shell=/bin/bash
        args=(-M -d "$home" -s "$shell" -c "$gecos")
        [[ -n "$pgroup" ]] && args+=(-g "$pgroup") || args+=(-N)
        if getent passwd "$uid" >/dev/null; then
            warn "Benutzer $name: UID $uid auf dem Ziel belegt – neue UID wird vergeben (Dateien werden über den Namen zugeordnet)"
        else
            args+=(-u "$uid")
        fi
        run useradd "${args[@]}" "$name"
        if [[ -f "$shadow" ]]; then
            hash=$(awk -F: -v u="$name" '$1==u {print $2; exit}' "$shadow")
            # Passwort-Hash übernehmen (Login-Passwörter bleiben gleich)
            [[ -n "$hash" ]] && usermod -p "$hash" "$name"
        fi
    done <"$passwd"

    # 3) Gruppenmitgliedschaften (auch ec2-user, z.B. in der Gruppe apache)
    local m
    while IFS=: read -r name _ _ members; do
        [[ -n "$members" ]] || continue
        getent group "$name" >/dev/null || continue
        for m in ${members//,/ }; do
            getent passwd "$m" >/dev/null || continue
            id -nG "$m" | tr ' ' '\n' | grep -qx "$name" && continue
            run usermod -aG "$name" "$m"
        done
    done <"$group"
}
