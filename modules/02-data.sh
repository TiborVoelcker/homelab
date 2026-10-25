#!/usr/bin/env bash
# Mount the data partition (p6) at /data, and make Docker refuse to start
# without it. If /data is not mounted but Docker starts anyway, bind mounts
# CREATE empty directories under /data and services initialise fresh state
# onto rootA while the real data sits on the unmounted partition - which a
# reset would then wipe. Three layers stop that:
#   nofail            -> the system still boots without /data, so you can SSH in
#   RequiresMountsFor -> Docker will not start until /data is genuinely mounted
#   marker file       -> catches "mounted, but it is the wrong filesystem"
#                        (and Docker also refuses a read-only /data)
#
# Error behaviour is set on the filesystem itself rather than as a mount
# option, so it holds however this partition gets mounted - see the note on
# tune2fs -e below. The boot-time check is fsck's preen mode, which only makes
# repairs that are safe without a human - see the note on the fstab line.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd blkid findmnt tune2fs
detect_disk

mkdir -p "$DATA_DIR"

# ---------- is the configured filesystem still there? ----------
# A different UUID means p6 was reformatted, and only a human can tell whether
# its content was copied across first - so stop rather than guess.
uuid=$(awk -v d="$DATA_DIR" \
    '$1 ~ /^UUID=/ && $2 == d { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab)
if [[ -n "$uuid" && ! -e "/dev/disk/by-uuid/$uuid" ]]; then
    die "fstab mounts $DATA_DIR from UUID=$uuid, which does not exist - if you reformatted $DEV_DATA: sudo homelab-forget-data-disk"
fi

# ---------- already configured? ----------
if grep -q "[[:space:]]${DATA_DIR}[[:space:]]" /etc/fstab; then
    skip "fstab already has $DATA_DIR"
else
    # This script never formats anything. ext4 is required: container volumes
    # need Unix ownership.
    fstype=$(blkid -o value -s TYPE "$DEV_DATA" || echo "")
    [[ "$fstype" == "ext4" ]] \
        || die "$DEV_DATA is '${fstype:-unformatted}', expected ext4 - format it with: sudo mkfs.ext4 -e remount-ro -L homelab-data $DEV_DATA"
    data_uuid=$(uuid_of "$DEV_DATA")

    # UUID, never /dev/nvme0n1p6 - device names can shift between boots.
    #
    # passno 2: checked at boot after root, in fsck's default preen mode,
    # which makes only the repairs that are safe without a human and refuses
    # the rest. Never put fsck.repair=yes on the kernel cmdline: that turns
    # every boot check into `e2fsck -y`, yes to every repair with nobody
    # watching, and on 2026-10-17 it erased the old data disk's directory
    # tree. Damage preen refuses leaves /data unmounted (nofail), Docker down
    # (the drop-in below) and Monit alerting. To check by hand, unmount and
    # run `e2fsck -fn` on the partition: -n reports without writing.
    printf 'UUID=%s %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2\n' \
        "$data_uuid" "$DATA_DIR" >> /etc/fstab

    systemctl daemon-reload
    ok "added $DATA_DIR to fstab (UUID=$data_uuid)"
fi

mountpoint -q "$DATA_DIR" || mount "$DATA_DIR" || die "could not mount $DATA_DIR"
ok "$DATA_DIR mounted from $(findmnt -no SOURCE "$DATA_DIR")"
# Read-only means the kernel met an error. The remount below would make it
# writable again (fstab's "defaults" include rw), so repair comes first.
findmnt -O rw "$DATA_DIR" >/dev/null \
    || die "$DATA_DIR is read-only - unmount it, repair with e2fsck, then re-run"

[[ -f "$DATA_MARKER" ]] || { touch "$DATA_MARKER"; ok "wrote data marker"; }

data_dev=$(findmnt -no SOURCE "$DATA_DIR")

# ---------- how the kernel reacts to an error ----------
# ext4 defaults to "Continue": log the I/O error and keep taking writes, so a
# failing disk goes on corrupting itself quietly. remount-ro flips it read-only
# on the first error, which stops the damage and is what Monit's `data` check
# notices. Set in the superblock rather than fstab, so it holds for every mount
# of this filesystem, not just this fstab line.
if tune2fs -l "$data_dev" | grep -qi '^Errors behavior:[[:space:]]*Remount read-only'; then
    skip "$DATA_DIR already goes read-only on error"
else
    tune2fs -e remount-ro "$data_dev" >/dev/null
    ok "$DATA_DIR will go read-only on the first I/O error"
fi

# The kernel reads the superblock setting only at mount time, so the running
# mount gets it explicitly. Idempotent.
mount -o remount,errors=remount-ro "$DATA_DIR"
ok "running mount goes read-only on error"

# ---------- make Docker depend on the mount ----------
# The rw check matters because a read-only /data is still a mounted /data:
# without it, a restart of Docker after Monit stopped it (see bin/homelab-check
# data) would bring the containers back to crash-loop again.
DROPIN=/etc/systemd/system/docker.service.d/10-homelab-data.conf
dropin=$(cat <<EOT
[Unit]
RequiresMountsFor=$DATA_DIR

[Service]
ExecStartPre=/usr/bin/test -f $DATA_MARKER
ExecStartPre=/usr/bin/findmnt -O rw $DATA_DIR
EOT
)
if [[ "$(cat "$DROPIN" 2>/dev/null)" == "$dropin" ]]; then
    skip "docker mount dependency present"
else
    mkdir -p "$(dirname "$DROPIN")"
    printf '%s\n' "$dropin" > "$DROPIN"
    systemctl daemon-reload
    ok "docker will not start unless $DATA_DIR is mounted, verified and writable"
fi
