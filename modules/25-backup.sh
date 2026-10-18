#!/usr/bin/env bash
# Off-site backup of /data with restic.
#
# This is the last line of defence and the only one for some of the data. The
# repo rebuilds the machine; /data populates it; nothing rebuilds /data. On
# 2026-10-17 an unattended boot-time fsck destroyed it and Home Assistant's
# entire configuration went with it, because no copy existed anywhere.
#
# restic is used for three properties, in order of why it was chosen:
# encrypted (/data/homeassistant/config/.storage holds password and refresh
# token hashes), off-site (a second copy on this Pi dies with this Pi), and
# snapshotted with retention (so "what did that automation look like last
# week" has an answer).
#
# The schedule, the exclusions and the SQLite handling live in
# bin/homelab-backup; this module installs it and wires it up.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

ENV_DATA=/data/homelab/backup.env
ENV_FILE=/etc/homelab/backup.env
SERVICE=/etc/systemd/system/homelab-backup.service
TIMER=/etc/systemd/system/homelab-backup.timer

apt-get install -y restic sqlite3 >/dev/null
ok "restic and sqlite3 installed"

# ---------- credentials ----------
# Same split as notify.env: generated once and kept on /data so a reset does
# not orphan the repository, copied to /etc so a backup can still run when
# /data is mounted but the repo working tree is not around.
if [[ -f "$ENV_DATA" ]]; then
    skip "backup settings present"
else
    mkdir -p "$(dirname "$ENV_DATA")"
    cat > "$ENV_DATA" <<EOF
# Where the backup goes. restic understands many backends; pick one and put
# its credentials below. Examples:
#   b2:bucket-name:homelab
#   s3:s3.eu-central-1.amazonaws.com/bucket-name/homelab
#   sftp:user@host:/srv/backup/homelab
RESTIC_REPOSITORY=

# Encrypts the repository. Without it the backup cannot be read, by anyone,
# including you. KEEP A COPY SOMEWHERE THAT IS NOT THIS PI.
RESTIC_PASSWORD=$(openssl rand -base64 24)

# Provider credentials, as the backend needs them. For Backblaze B2:
#B2_ACCOUNT_ID=
#B2_ACCOUNT_KEY=
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
