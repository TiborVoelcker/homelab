#!/usr/bin/env bash
# Keep the systemd journal on disk instead of in RAM.
#
# Raspberry Pi OS ships /usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf
# setting Storage=volatile, which holds the whole journal in a tmpfs under
# /run to spare the SD card. The cost is that a reboot or a power cut destroys
# every log line, including the ones that would explain what just went wrong -
# you reach for the logs precisely when they have been erased.
#
# The trade is real, so the size is capped rather than left to grow: 200M total
# and a 3 month horizon is plenty to explain an incident, and small enough that
# it is not a meaningful extra load on the card.
#
# A drop-in under /etc wins over the one under /usr/lib because systemd merges
# both directories and applies them in filename order - 50- lands after 40-.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root

DROPIN=/etc/systemd/journald.conf.d/50-persistent.conf
read -r -d '' WANT <<'EOF' || true
# Overrides Raspberry Pi OS's 40-rpi-volatile-storage.conf, which keeps the
# journal in RAM and therefore loses it on every reboot or power cut.
[Journal]
Storage=persistent
SystemMaxUse=200M
SystemMaxFileSize=20M
SystemKeepFree=500M
MaxRetentionSec=3month
# Nothing consumes syslog on this system, so forwarding only burns CPU.
ForwardToSyslog=no
EOF

if [[ -f "$DROPIN" ]] && [[ "$(cat "$DROPIN")" == "$WANT" ]]; then
    skip "journald already configured for persistent storage"
else
    mkdir -p "$(dirname "$DROPIN")"
    printf '%s\n' "$WANT" > "$DROPIN"
    # journald only creates /var/log/journal when told to by tmpfiles; without
    # the directory it silently stays in the runtime journal.
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    ok "journald will keep logs in /var/log/journal"
fi

# Moves whatever is still in the runtime journal onto disk. Without this the
# switch only takes effect at the next boot, which is the boot whose logs we
# most want to keep.
journalctl --flush --quiet 2>/dev/null || true

# Checked by looking for the journal files themselves rather than by grepping
# journalctl's output: `journalctl --header | grep -q` makes journalctl die of
# SIGPIPE when grep exits early, and under `set -o pipefail` that reads as a
# failure even when the journal is perfectly healthy.
journal_dir="/var/log/journal/$(cat /etc/machine-id 2>/dev/null)"
if compgen -G "$journal_dir/*.journal" >/dev/null; then
    ok "persistent journal active in $journal_dir"
else
    warn "journal is still runtime-only - check $DROPIN"
fi
