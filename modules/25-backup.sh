#!/usr/bin/env bash
# Backup of /data with restic: off-site to Google Drive, plus a second copy on
# the internal HDD.
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

# Both live on /data only: a reset must not orphan the repository or
# de-authorise Drive, and the backup cannot run without /data anyway.
ENV_DATA=/data/homelab/backup.env
RCLONE_DATA=/data/homelab/rclone.conf
SERVICE=/etc/systemd/system/homelab-backup.service
TIMER=/etc/systemd/system/homelab-backup.timer

apt-get install -y restic rclone sqlite3 >/dev/null
ok "restic, rclone and sqlite3 installed"

# ---------- credentials ----------
if [[ -f "$ENV_DATA" ]]; then
    skip "backup settings present"
else
    mkdir -p "$(dirname "$ENV_DATA")"
    cat > "$ENV_DATA" <<EOF
# Where the backup goes: the 'gdrive' remote in rclone.conf. Any rclone remote
# works the same way, and so do restic's own backends if this moves off Drive:
#   b2:bucket-name:homelab
#   sftp:user@host:/srv/backup/homelab
RESTIC_REPOSITORY=rclone:gdrive:homelab

# Encrypts the repository. Without it the backup cannot be read, by anyone,
# including you. KEEP A COPY SOMEWHERE THAT IS NOT THIS MACHINE.
RESTIC_PASSWORD=$(openssl rand -base64 24)

# rclone reads its remotes, and writes refreshed tokens, here rather than in
# root's home, so the token travels with /data.
RCLONE_CONFIG=$RCLONE_DATA
EOF
    chmod 600 "$ENV_DATA"
    ok "generated backup settings"
fi

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

# ---------- enable, once there is somewhere to back up to ----------
# rclone's remote holds an OAuth token, and OAuth needs a browser, which a
# headless machine does not have - so it is set up once by hand.
if [[ -f "$RCLONE_DATA" ]]; then
    ok "rclone remote present: $(sed -n 's/^\[\(.*\)\]$/\1/p' "$RCLONE_DATA" | paste -sd, -)"
fi
repo=$(sed -n 's/^RESTIC_REPOSITORY=//p' "$ENV_DATA")
if [[ ! -f "$RCLONE_DATA" || -z "$repo" ]]; then
    systemctl disable --now homelab-backup.timer >/dev/null 2>&1 || true
    warn "backup not configured yet - the timer stays off"
    log "1. copy RESTIC_PASSWORD out of $ENV_DATA into a password manager:"
    log "     without it the backup cannot be restored, by anyone"
    log "2. create a Google client ID - the shared default one is heavily rate-limited:"
    log "     https://rclone.org/drive/#making-your-own-client-id"
    log "3. sudo rclone config --config $RCLONE_DATA"
    log "     new remote 'gdrive', type drive, your client ID and secret, scope drive.file"
    log "     (only the files rclone creates itself); answer n to auto config, run the"
    log "     command it prints on a machine with a browser, paste the result back"
    log "4. re-run this module"
    exit 0
fi

# init is idempotent in effect but not in exit code, so ask first.
set -a; source "$ENV_DATA"; set +a
if restic cat config >/dev/null 2>&1; then
    skip "restic repository already initialised"
else
    restic init >/dev/null
    ok "initialised restic repository at $repo"
fi

# ---------- second copy on the internal HDD ----------
# Restores in seconds, with no API rate limits, and survives Drive being
# unreachable. Not a replacement for Drive: a copy inside the same box goes
# down with the box. Same password, so there is still only one to keep. Found
# by its label, so a reset needs no prompt; formatting it is a manual step
# (README.md), like every filesystem here.
BACKUP_DIR=/backup
LOCAL_REPO=$BACKUP_DIR/restic
if [[ ! -e /dev/disk/by-label/homelab-backup ]]; then
    warn "no filesystem labelled homelab-backup - only the Drive copy is made (see README.md)"
else
    mkdir -p "$BACKUP_DIR"
    if grep -q "[[:space:]]${BACKUP_DIR}[[:space:]]" /etc/fstab; then
        skip "fstab already has $BACKUP_DIR"
    else
        # passno 2 and preen, for the same reasons as /data - see 02-data.sh.
        printf 'UUID=%s %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2\n' \
            "$(uuid_of /dev/disk/by-label/homelab-backup)" "$BACKUP_DIR" >> /etc/fstab
        systemctl daemon-reload
        ok "added $BACKUP_DIR to fstab"
    fi
    mountpoint -q "$BACKUP_DIR" || mount "$BACKUP_DIR" || die "could not mount $BACKUP_DIR"
    if [[ -f "$LOCAL_REPO/config" ]]; then
        skip "local restic repository present at $LOCAL_REPO"
    else
        RESTIC_REPOSITORY=$LOCAL_REPO restic init >/dev/null
        ok "initialised local restic repository at $LOCAL_REPO"
    fi
fi

systemctl enable --now homelab-backup.timer >/dev/null
ok "nightly backup enabled ($(systemctl show -p NextElapseUSecRealtime --value homelab-backup.timer | cut -d. -f1))"
log "run one now with: sudo systemctl start homelab-backup.service"
