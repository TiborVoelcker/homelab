#!/usr/bin/env bash
# Capture the baseline: a copy of this system exactly as it was installed,
# onto rootB, made bootable from its own ESP-B and given its own NVRAM boot
# entry, which homelab-reset reaches through BootNext.
#
# Runs FIRST, before any module that changes the system, so the baseline is the
# pristine install - no /data mount, no apt upgrade, no Docker, no services.
# Captured exactly once. The baseline only ever boots, overwrites the main
# system and reboots, so nothing here goes further than making it bootable.
#
#   ESP-A (p1) stub -> rootA's /boot/grub   entry "homelab", in BootOrder
#   ESP-B (p3) stub -> rootB's /boot/grub   entry "homelab-baseline", not in
#                                           BootOrder, booted only via BootNext
#
# BootNext is one-shot: the firmware clears it before trying the entry, so a
# power cut or a baseline that fails to start lands back on BootOrder.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd rsync efibootmgr chroot
detect_disk

mkdir -p "$BASELINE_ROOT_MNT"
mountpoint -q "$BASELINE_ROOT_MNT" || mount "$DEV_ROOT_B" "$BASELINE_ROOT_MNT"

# ---------- the baseline itself ----------
# Guarded on the stamp rather than the role file, which is written later: a
# clone interrupted midway should be finished by the next install.sh run, not
# skipped as if it were complete.
if [[ -f "$BASELINE_ROOT_MNT$BASELINE_STAMP" ]]; then
    skip "baseline captured $(cat "$BASELINE_ROOT_MNT$BASELINE_STAMP")"
else
    log "capturing baseline to rootB - this takes a few minutes"
    # --delete so a recapture onto a used rootB leaves the installed system
    # and nothing else. On a first capture rootB is empty and it does nothing.
    rsync_live -aAXH --delete --info=progress2 "${RSYNC_EXCLUDES[@]}" / "$BASELINE_ROOT_MNT/"
    make_runtime_dirs "$BASELINE_ROOT_MNT"
    date -Is > "$BASELINE_ROOT_MNT$BASELINE_STAMP"
    ok "baseline captured"
fi

# Everything below is outside the guard, so re-running install.sh picks up
# repo changes without recapturing the baseline.

# Point the clone at ITS OWN partitions. If it mounted ESP-A instead, a GRUB
# upgrade there would point the live system's stub at rootB.
if retarget_fstab "$BASELINE_ROOT_MNT/etc/fstab" "$DEV_ESP_B" "$DEV_ROOT_B"; then
    ok "baseline fstab points at ESP-B and rootB"
else
    skip "baseline fstab points at ESP-B and rootB"
fi

# Gate 1 of the reset, and what stops install.sh provisioning from here.
echo baseline > "$BASELINE_ROOT_MNT$ROLE_FILE"
install -Dm755 "$REPO_DIR/reset/reset-main.sh" \
    "$BASELINE_ROOT_MNT/usr/local/sbin/homelab-reset-main"
install -Dm644 "$REPO_DIR/lib/common.sh" "$BASELINE_ROOT_MNT$COMMON_LIB"
install -Dm644 "$REPO_DIR/reset/homelab-reset-main.service" \
    "$BASELINE_ROOT_MNT/etc/systemd/system/homelab-reset-main.service"
mkdir -p "$BASELINE_ROOT_MNT/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/homelab-reset-main.service \
    "$BASELINE_ROOT_MNT/etc/systemd/system/multi-user.target.wants/homelab-reset-main.service"
ok "reset service installed into the baseline"

# ---------- bootloader on ESP-B ----------
# Done once both halves name rootB: its grub.cfg (copied from rootA by the
# capture, so it starts out naming rootA) and the stub on ESP-B.
root_b_uuid=$(uuid_of "$DEV_ROOT_B")
esp_mnt="$BASELINE_ROOT_MNT$ESP_DIR"
mountpoint -q "$esp_mnt" || mount "$DEV_ESP_B" "$esp_mnt"
if grep -qs "root=UUID=$root_b_uuid" "$BASELINE_ROOT_MNT/boot/grub/grub.cfg" \
    && grep -qs "$root_b_uuid" "$esp_mnt/EFI/debian/grub.cfg"; then
    umount "$esp_mnt"
    skip "ESP-B boots rootB"
else
    log "installing shim and GRUB onto ESP-B"
    install_bootloader "$BASELINE_ROOT_MNT" "$DEV_ESP_B"
    ok "ESP-B boots rootB"
fi

# ---------- NVRAM boot entry ----------
# -C creates the entry WITHOUT adding it to BootOrder, so there is no moment
# at which an ordinary reboot would land in the baseline.
mapfile -t entries < <(boot_entries_for "$BASELINE_LABEL")
if (( ${#entries[@]} > 1 )); then
    die "more than one '$BASELINE_LABEL' boot entry (${entries[*]}) - delete the extras with efibootmgr -b <num> -B"
elif (( ${#entries[@]} == 1 )); then
    skip "boot entry $BASELINE_LABEL is Boot${entries[0]}"
else
    efibootmgr -C --disk "$DISK" --part "$PART_ESP_B" \
        --label "$BASELINE_LABEL" --loader '\EFI\debian\shimx64.efi' >/dev/null
    mapfile -t entries < <(boot_entries_for "$BASELINE_LABEL")
    (( ${#entries[@]} == 1 )) || die "efibootmgr did not create the $BASELINE_LABEL entry"
    ok "created boot entry $BASELINE_LABEL as Boot${entries[0]}"
fi

# The firmware appends entries to BootOrder by itself, so check every run.
# Not a safety gate (that is BootCurrent, in reset-main.sh) - it keeps an
# ordinary fall-through boot from landing in the baseline.
#
# Also kept out: the "debian" entries this firmware creates by itself, one per
# ESP the first time it boots from it, which load grubx64.efi directly and
# skip the shim. With Secure Boot on they cannot start anything, and a
# rejected image may stop at a prompt nobody is there to answer. They are not
# deleted: that would only have the firmware create them again.
mapfile -t strays < <(efibootmgr | awk -F'\t' \
    'tolower($2) ~ /\\efi\\debian\\grubx64\.efi/ { print substr($1, 5, 4) }')
order=$(efibootmgr | sed -n 's/^BootOrder: //p')
new_order=$(tr ',' '\n' <<<"$order" \
    | grep -vixF -f <(printf '%s\n' "${entries[0]}" "${strays[@]}") | paste -sd, || true)
if [[ "$new_order" == "$order" ]]; then
    skip "BootOrder holds neither $BASELINE_LABEL nor shim-less entries"
else
    [[ -n "$new_order" ]] || die "BootOrder would be empty - fix it by hand"
    efibootmgr -o "$new_order" >/dev/null
    ok "BootOrder is now $new_order ($BASELINE_LABEL and shim-less entries removed)"
fi

sync
umount "$BASELINE_ROOT_MNT" || warn "could not unmount $BASELINE_ROOT_MNT"
