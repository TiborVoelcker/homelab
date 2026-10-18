#!/usr/bin/env bash
# Mount the external USB disk at /data, and make Docker refuse to start without
# it. If the disk is absent but Docker starts anyway, bind mounts CREATE empty
# directories under /data and services initialise fresh state onto the SD card
# while the real data sits on the unmounted disk. Four layers stop that, and
# recover if the disk drops off USB mid-session (a hotplug event elsewhere on
# the bus, e.g. the Matter/Thread radio, can reset the whole controller and
# knock this disk offline for a second):
#   nofail            -> the Pi still boots without the disk, so you can SSH in
#   RequiresMountsFor -> Docker will not start until /data is genuinely mounted
#   marker file       -> catches "mounted, but it is the wrong disk"
#                        (and Docker also refuses a read-only /data)
#   udev + Upholds=   -> remounts the disk and restarts Docker on its own if
#                        the disk ever drops out and comes back
#
# Error behaviour is set on the filesystem itself rather than as a mount
# option, so it holds however this disk gets mounted - see the note on
# tune2fs -e below. Together with Monit's `data` check it is the whole of the
# corruption defence: nothing checks or repairs this filesystem at boot - see
# the note on the fstab line for why.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd lsblk blkid findmnt sfdisk systemd-escape tune2fs
detect_disk

mkdir -p "$DATA_DIR"

# ---------- is the configured disk attached? ----------
# A missing disk may have been replaced or may just be unplugged, and only a
# human can tell which - so stop rather than guess.
uuid=$(awk -v d="$DATA_DIR" \
    '$1 ~ /^UUID=/ && $2 == d { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab)
if [[ -n "$uuid" && ! -e "/dev/disk/by-uuid/$uuid" ]]; then
    die "fstab mounts $DATA_DIR from UUID=$uuid, which is not attached - plug it in, or if you replaced it: sudo homelab-forget-data-disk"
fi

# ---------- already configured? ----------
if grep -q "[[:space:]]${DATA_DIR}[[:space:]]" /etc/fstab; then
    skip "fstab already has $DATA_DIR"
else
    # Candidates: block devices that are not the SD card we booted from.
    mapfile -t candidates < <(
        lsblk -rno NAME,TYPE,SIZE,FSTYPE,LABEL \
            | awk '$2=="part"{print $1, $3, $4, $5}' \
            | grep -v "^$(basename "$DISK")"
    )

    if [[ -n "${HOMELAB_DATA_UUID:-}" ]]; then
        data_uuid="$HOMELAB_DATA_UUID"
    else
        [[ ${#candidates[@]} -gt 0 ]] \
            || die "no external partitions found - plug in the data disk and re-run"

        log "external partitions found:"
        for i in "${!candidates[@]}"; do
            log "$(printf '  [%d] %s' "$i" "${candidates[$i]}")"
        done
        echo
        log "Pick the partition to mount at $DATA_DIR."
        log "This script never formats anything - format it yourself first with:"
        log "    sudo mkfs.ext4 -L homelab-data /dev/sdXN"
        log "ext4 is required; exFAT and NTFS cannot store Unix ownership,"
        log "which container volumes need."
        echo
        read -rp "      index: " idx
        [[ "$idx" =~ ^[0-9]+$ && -n "${candidates[$idx]:-}" ]] || die "invalid selection"

        dev="/dev/$(echo "${candidates[$idx]}" | awk '{print $1}')"
        fstype=$(blkid -o value -s TYPE "$dev" || echo "")
        [[ "$fstype" == "ext4" ]] || die "$dev is '${fstype:-unformatted}', expected ext4"

        data_uuid=$(blkid -o value -s UUID "$dev")
        [[ -n "$data_uuid" ]] || die "could not read UUID of $dev"
    fi

    # UUID, never /dev/sdX - device letters shift with enumeration order.
    #
    # The final 0 (passno) means no fsck at boot. The stock Raspberry Pi
    # cmdline carries fsck.repair=yes, so a boot check runs as `e2fsck -y`:
    # yes to every repair, with nobody watching. On a filesystem that is
    # already damaged that can destroy more than the fault - on 2026-10-17 it
    # erased this disk's directory tree. Detection is left to errors=remount-ro
    # below and Monit's `data` check, which only ever report. To check by hand,
    # unmount and run `e2fsck -fn /dev/sdXN`: -n reports without writing.
    # fsck.repair=yes itself stays, because it also governs the root
    # filesystem, which does want unattended repair on a headless Pi.
    printf 'UUID=%s %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 0\n' \
        "$data_uuid" "$DATA_DIR" >> /etc/fstab

    systemctl daemon-reload
    ok "added $DATA_DIR to fstab (UUID=$data_uuid)"
fi

mountpoint -q "$DATA_DIR" || mount "$DATA_DIR" || die "could not mount $DATA_DIR"
ok "$DATA_DIR mounted from $(findmnt -no SOURCE "$DATA_DIR")"

data_uuid=$(findmnt -no UUID "$DATA_DIR")
mount_unit=$(systemd-escape --path --suffix=mount "$DATA_DIR")

[[ -f "$DATA_MARKER" ]] || { touch "$DATA_MARKER"; ok "wrote data marker"; }

data_dev=$(findmnt -no SOURCE "$DATA_DIR")

# ---------- how the kernel reacts to an error ----------
# ext4 defaults to "Continue": log the I/O error and carry on taking writes, so
# a disk returning bad data goes on corrupting itself quietly. remount-ro makes
# the kernel flip the filesystem read-only the instant it sees one, which stops
# the damage spreading and is what Monit's `data` check then notices.
#
# This is a different mechanism from the boot-time fsck. It is the
# running kernel reacting to an error it meets during normal use; e2fsck is an
# offline tool that never consults it. What ties them together is that the
# kernel also records "this filesystem had an error" in the superblock on its
# way out, which is what later tells e2fsck something happened here.
#
# It goes in the superblock, not in the fstab options, so it holds for every
# mount of this disk - a manual `mount /dev/sdX` elsewhere, a rescue boot, a
# different machine - and not just for the one fstab line we control. A mount
# option would OVERRIDE the superblock, which is why the fstab line above
# carries none.
if tune2fs -l "$data_dev" | grep -qi '^Errors behavior:[[:space:]]*Remount read-only'; then
    skip "$DATA_DIR already goes read-only on error"
else
    tune2fs -e remount-ro "$data_dev" >/dev/null
    ok "$DATA_DIR will go read-only on the first I/O error"
fi

# The kernel reads s_errors once, at mount time, and then keeps its own copy,
# so writing the superblock does not reach a filesystem that is already
# mounted - and a plain `mount -o remount` does not re-read it either, only an
# explicit option does. Without this, a first install against a fresh mkfs
# leaves /data running on errors=continue (the mkfs default) until the next
# reboot - and with no check at boot, this is the only guard there is.
#
# /proc/fs/ext4/<dev>/options is the only view that shows what the kernel is
# really using. /proc/mounts and findmnt do not report it.
live_errors=$(sed -n 's/^errors=//p' "/proc/fs/ext4/$(basename "$data_dev")/options" 2>/dev/null)
if [[ "$live_errors" != "remount-ro" ]]; then
    mount -o remount,errors=remount-ro "$DATA_DIR"
    ok "applied errors=remount-ro to the running mount too"
fi

# ---------- make Docker depend on the mount ----------
# The rw check matters because a read-only /data is still a mounted /data:
# without it, Upholds= below would restart Docker straight after Monit stopped
# it (see bin/homelab-check data), and the containers would crash-loop again.
DROPIN=/etc/systemd/system/docker.service.d/10-homelab-data.conf
dropin=$(cat <<EOF
[Unit]
RequiresMountsFor=$DATA_DIR

[Service]
ExecStartPre=/usr/bin/test -f $DATA_MARKER
ExecStartPre=/usr/bin/findmnt -O rw $DATA_DIR
EOF
)
if [[ "$(cat "$DROPIN" 2>/dev/null)" == "$dropin" ]]; then
    skip "docker mount dependency present"
else
    mkdir -p "$(dirname "$DROPIN")"
    printf '%s\n' "$dropin" > "$DROPIN"
    systemctl daemon-reload
    ok "docker will not start unless $DATA_DIR is mounted, verified and writable"
fi

# ---------- recover on our own if the disk drops off USB ----------
# When the disk disappears mid-session it loses its block device node
# entirely; when it reconnects it gets an unrelated new one (sda instead of
# sdb, say). There is no "resume" at the filesystem level, only a fresh
# mount - and nothing remounts it automatically, since plain fstab entries
# are only pulled in once at boot (WantedBy=local-fs.target), not
# re-triggered when the device reappears later. udev noticing the device
# come back is the standard, built-in hook for that.
# Compared by content, not just existence: the rule embeds the disk's UUID, so
# replacing the data disk leaves a rule that matches a disk which no longer
# exists and silently stops recovering the new one.
UDEV_RULE=/etc/udev/rules.d/99-data-recover.rules
rule="ACTION==\"add\", SUBSYSTEM==\"block\", ENV{ID_FS_UUID}==\"$data_uuid\", RUN+=\"/usr/bin/systemctl --no-block start $mount_unit\""
if [[ "$(cat "$UDEV_RULE" 2>/dev/null)" == "$rule" ]]; then
    skip "data-recover udev rule present"
else
    printf '%s\n' "$rule" > "$UDEV_RULE"
    udevadm control --reload-rules
    ok "udev will remount $DATA_DIR when the disk reappears after a drop"
fi

# Upholds= is the reverse of RequiresMountsFor=: as long as the mount is
# active, systemd restarts anything listed here the instant it's found
# down, no polling. The udev rule above only ever has to know how to get
# the disk back; anything else that needs /data just gets added to this
# same line.
MOUNT_DROPIN_DIR="/etc/systemd/system/${mount_unit}.d"
MOUNT_DROPIN="$MOUNT_DROPIN_DIR/10-uphold-dependents.conf"
if [[ -f "$MOUNT_DROPIN" ]]; then
    skip "mount uphold dependency present"
else
    mkdir -p "$MOUNT_DROPIN_DIR"
    cat > "$MOUNT_DROPIN" <<EOF
[Unit]
Upholds=docker.service
EOF
    systemctl daemon-reload
    ok "docker will restart automatically whenever $DATA_DIR comes back"
fi
