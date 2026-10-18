#!/usr/bin/env bash
# Off-site backup of /data with restic.
#
# This is the last line of defence and the only one for some of the data. The
# repo rebuilds the machine; /data populates it; nothing rebuilds /data. On
# 2026-10-17 an unattended boot-time fsck destroyed it and Home Assistant's
# entire configuration went with it, because no copy existed anywhere.
#
# restic rather than rsync or plain rclone, because a MIRROR is not protection
# against what actually happened: the data was destroyed in place, and a sync
# would have faithfully replicated that destruction to the far end. Sync tools
# protect against losing a device; they treat this side as the truth. Snapshots
# with retention survive corruption, a bad fsck and a fat-fingered rm.
#
# The other two reasons: restic encrypts by default, which is not optional when
# /data/homeassistant/config/.storage holds password and refresh token hashes;
# and `restic check` can say whether the repository is still readable, which a
# mirror has no concept of.
#
# rclone is the transport underneath it. restic has a first-class rclone:
# backend, and rclone is the only one of these that speaks Google Drive's API.
#
# The schedule, the exclusions and the SQLite handling live in
# bin/homelab-backup; this module installs it and wires it up.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

ENV_DATA=/data/homelab/backup.env
ENV_FILE=/etc/homelab/backup.env
# rclone's own config holds the Google Drive OAuth token: a credential, so it
# follows notify.env's split - kept on /data so a reset does not de-authorise
# the backup, copied to /etc so a backup still runs when /data is mounted but
# the repo working tree is not around.
RCLONE_DATA=/data/homelab/rclone.conf
RCLONE_FILE=/etc/homelab/rclone.conf
SERVICE=/etc/systemd/system/homelab-backup.service
TIMER=/etc/systemd/system/homelab-backup.timer

apt-get install -y restic rclone sqlite3 >/dev/null
ok "restic, rclone and sqlite3 installed"

# ---------- credentials ----------
# Same split as notify.env: generated once and kept on /data so a reset does
# not orphan the repository, copied to /etc so a backup can still run when
# /data is mounted but the repo working tree is not around.
if [[ -f "$ENV_DATA" ]]; then
    skip "backup settings present"
else
    mkdir -p "$(dirname "$ENV_DATA")"
    cat > "$ENV_DATA" <<EOF
# Where the backup goes. Anything rclone speaks works, via the rclone:
# backend - the remote name here must match the one in rclone.conf:
#   rclone:gdrive:homelab
# restic's own backends work too, if this ever moves off Drive:
#   b2:bucket-name:homelab
#   sftp:user@host:/srv/backup/homelab
RESTIC_REPOSITORY=

# Encrypts the repository. Without it the backup cannot be read, by anyone,
# including you. KEEP A COPY SOMEWHERE THAT IS NOT THIS PI.
RESTIC_PASSWORD=$(openssl rand -base64 24)

# rclone reads its remotes from here rather than from root's home, so the
# token travels with /data.
RCLONE_CONFIG=$RCLONE_FILE
EOF
    chmod 600 "$ENV_DATA"
    ok "generated backup settings"
fi
install -D -m 600 "$ENV_DATA" "$ENV_FILE"

# ---------- schedule ----------
# Deliberately not Persistent=true: a missed night should show up as a stale
# stamp that `homelab-check backup` reports, not as a backup firing into a
# boot that may still be settling.
cat > "$SERVICE" <<EOF
[Unit]
Description=Off-site backup of /data
# No point starting without the data, and nothing to do if it is read-only.
RequiresMountsFor=/data
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/homelab-backup
# Backups lose every race against the services they are backing up.
Nice=10
IOSchedulingClass=idle
EOF

cat > "$TIMER" <<EOF
[Unit]
Description=Nightly off-site backup of /data

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
ok "wrote backup service and timer"

# ---------- rclone's remote ----------
# OAuth needs a browser, which a headless Pi does not have, so this part
# cannot be automated - it is written once by hand and then just copied.
if [[ -f "$RCLONE_DATA" ]]; then
    install -D -m 600 "$RCLONE_DATA" "$RCLONE_FILE"
    ok "rclone remote present: $(sed -n 's/^\[\(.*\)\]$/\1/p' "$RCLONE_FILE" | paste -sd, -)"
else
    warn "no rclone remote yet - the timer stays off"
    log "on a machine with a browser:  rclone authorize \"drive\" --drive-scope=drive.file"
    log "then write the token it prints into $RCLONE_DATA as:"
    log "    [gdrive]"
    log "    type = drive"
    log "    scope = drive.file"
    log "    token = {\"access_token\":...}"
    log "drive.file scope keeps rclone to the files it creates itself, nothing else in Drive"
    exit 0
fi

# ---------- enable, once there is somewhere to back up to ----------
repo=$(sed -n 's/^RESTIC_REPOSITORY=//p' "$ENV_FILE")
if [[ -z "$repo" ]]; then
    systemctl disable --now homelab-backup.timer >/dev/null 2>&1 || true
    warn "no backup target yet - the timer stays off"
    log "set RESTIC_REPOSITORY (and its credentials) in $ENV_DATA, then re-run this module"
    log "and copy RESTIC_PASSWORD out of $ENV_DATA into a password manager first:"
    log "    without it the backup cannot be restored, by anyone"
    exit 0
fi

# init is idempotent in effect but not in exit code, so ask first.
set -a; source "$ENV_FILE"; set +a
if restic cat config >/dev/null 2>&1; then
    skip "restic repository already initialised"
else
    restic init >/dev/null
    ok "initialised restic repository at $repo"
fi

systemctl enable --now homelab-backup.timer >/dev/null
ok "nightly backup enabled ($(systemctl show -p NextElapseUSecRealtime --value homelab-backup.timer | cut -d. -f1))"
log "run one now with: sudo systemctl start homelab-backup.service"
