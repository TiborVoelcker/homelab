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
#   udev + Upholds=   -> remounts the disk and restarts Docker on its own if
#                        the disk ever drops out and comes back
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd lsblk blkid findmnt sfdisk systemd-escape
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
    printf 'UUID=%s %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=30 0 2\n' \
        "$data_uuid" "$DATA_DIR" >> /etc/fstab

    systemctl daemon-reload
    ok "added $DATA_DIR to fstab (UUID=$data_uuid)"
fi

mountpoint -q "$DATA_DIR" || mount "$DATA_DIR" || die "could not mount $DATA_DIR"
ok "$DATA_DIR mounted from $(findmnt -no SOURCE "$DATA_DIR")"

data_uuid=$(findmnt -no UUID "$DATA_DIR")
mount_unit=$(systemd-escape --path --suffix=mount "$DATA_DIR")

[[ -f "$DATA_MARKER" ]] || { touch "$DATA_MARKER"; ok "wrote data marker"; }

# ---------- make Docker depend on the mount ----------
DROPIN=/etc/systemd/system/docker.service.d/10-homelab-data.conf
if [[ -f "$DROPIN" ]]; then
    skip "docker mount dependency present"
else
    mkdir -p "$(dirname "$DROPIN")"
    cat > "$DROPIN" <<EOF
[Unit]
RequiresMountsFor=$DATA_DIR

[Service]
ExecStartPre=/usr/bin/test -f $DATA_MARKER
EOF
    systemctl daemon-reload
    ok "docker will not start unless $DATA_DIR is mounted and verified"
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
