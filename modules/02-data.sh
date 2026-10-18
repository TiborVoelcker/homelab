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
# The mount also asks for errors=remount-ro. ext4 otherwise defaults to
# "Continue" - log an I/O error and keep taking writes - so a disk returning
# bad data can go on corrupting itself quietly. It does nothing for the
# common case here, a disk that drops off USB entirely (ext4 shuts the
# filesystem down on its own then), but together with Monit's `data` check it
# is now the whole of the corruption defence - see the long note further down
# on why nothing checks or repairs this filesystem at boot any more.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd lsblk blkid findmnt sfdisk systemd-escape tune2fs
detect_disk

mkdir -p "$DATA_DIR"

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
    printf 'UUID=%s %s ext4 defaults,noatime,nofail,errors=remount-ro,x-systemd.device-timeout=30 0 0\n' \
        "$data_uuid" "$DATA_DIR" >> /etc/fstab

    systemctl daemon-reload
    ok "added $DATA_DIR to fstab (UUID=$data_uuid)"
fi

mountpoint -q "$DATA_DIR" || mount "$DATA_DIR" || die "could not mount $DATA_DIR"
ok "$DATA_DIR mounted from $(findmnt -no SOURCE "$DATA_DIR")"

data_uuid=$(findmnt -no UUID "$DATA_DIR")
mount_unit=$(systemd-escape --path --suffix=mount "$DATA_DIR")

[[ -f "$DATA_MARKER" ]] || { touch "$DATA_MARKER"; ok "wrote data marker"; }

# ---------- no check, and above all no repair, at boot ----------
# This filesystem used to be configured with `tune2fs -c 1`, which makes ext4
# demand a full check at every single mount. The reasoning was sound:
# systemd-fsck runs `e2fsck -a` (preen mode), preen SKIPS a filesystem that is
# marked clean, and a filesystem gets marked clean whenever its journal
# replayed - which says nothing at all about whether its metadata is
# consistent. So damage left by an unclean USB drop could sail through the boot
# check and only detonate later, in use.
#
# The flaw was not the checking. It was that checking and REPAIRING were the
# same unattended action. The stock Raspberry Pi cmdline carries
# fsck.repair=yes, so the forced check ran as `e2fsck -y` - say yes to every
# question - and on a filesystem whose root directory was already damaged it
# said yes to "Resize inode not valid. Recreate?". It declared success; the
# kernel rejected the filesystem one second later; the directory tree was
# gone. An automatic repairer with nobody watching can destroy more than the
# fault it was sent to fix.
#
# So nothing here checks or repairs at boot any more. Detection is left to the
# guards that only ever REPORT: errors=remount-ro flips the mount read-only the
# moment the kernel sees an I/O error, and Monit's `data` check then stops
# Docker and pushes a notification. To check this filesystem deliberately,
# unmount it and run `e2fsck -fn /dev/sdXN` - `-n` answers no to every
# question, so it reports without writing a single block.
#
# fsck.repair=yes itself stays exactly as Raspberry Pi OS ships it. It also
# governs the ROOT filesystem, which does want unattended repair: a headless
# Pi that drops to an emergency console after a power cut is a Pi you cannot
# reach.
data_dev=$(findmnt -no SOURCE "$DATA_DIR")
fs_info=$(tune2fs -l "$data_dev")
max_mounts=$(sed -n 's/^Maximum mount count:[[:space:]]*//p' <<<"$fs_info")
interval=$(sed -n 's/^Check interval:[[:space:]]*//p' <<<"$fs_info")
if [[ "$max_mounts" == "-1" && "$interval" == 0* ]]; then
    skip "$DATA_DIR has no forced check"
else
    tune2fs -c 0 -i 0 "$data_dev" >/dev/null
    ok "removed the forced check from $DATA_DIR"
fi

# Field 6 of an fstab line is the "passno": anything non-zero asks systemd to
# generate an fsck unit for that mount at boot. Zero is the half of the above
# that fsck.repair=yes cannot override, so it is what actually stops the
# unattended repair. Installs made before this change were written with 2;
# correct them in place rather than making the repo disagree with the disk.
if awk -v d="$DATA_DIR" \
    '$1 !~ /^#/ && $2 == d && NF == 6 && $6 != "0" { found = 1 } END { exit !found }' \
    /etc/fstab
then
    awk -v d="$DATA_DIR" '
        $1 !~ /^#/ && $2 == d && NF == 6 { print $1, $2, $3, $4, $5, "0"; next }
        { print }
    ' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
    systemctl daemon-reload
    ok "fstab: systemd will no longer fsck $DATA_DIR at boot"
else
    skip "fstab already tells systemd not to fsck $DATA_DIR"
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
UDEV_RULE=/etc/udev/rules.d/99-data-recover.rules
if [[ -f "$UDEV_RULE" ]]; then
    skip "data-recover udev rule present"
else
    cat > "$UDEV_RULE" <<EOF
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="$data_uuid", RUN+="/usr/bin/systemctl --no-block start $mount_unit"
EOF
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
