#!/usr/bin/env bash
# Runs inside the BASELINE system only, at boot, via
# homelab-reset-main.service. Overwrites the live system (rootA) with a copy
# of itself, makes it bootable again, then reboots back into it. The result is
# equivalent to a fresh install: re-run install.sh afterwards to rebuild the
# homelab.
#
# Three independent gates, all of which must pass:
#   1. /etc/homelab-role says "baseline"      - we are not the live system
#   2. BootCurrent is the baseline's entry    - this boot was deliberate
#   3. arm marker on ESP-B                    - a reset was actually requested
#
# Gate 3 is what makes booting the baseline by hand safe: with no marker this
# exits before touching anything.
#
# Only four things here differ from what rootA should hold: the partitions its
# fstab points at, the root its grub.cfg names, the role file, and this reset
# machinery. Those are what gets undone below, so anything added to
# 01-create-baseline.sh needs its inverse here. ESP-A needs nothing: rsyncing
# into rootA keeps its filesystem UUID, so ESP-A's stub still points at it.
# NVRAM is never written. /data is never mounted at all.
set -euo pipefail
# Path must match $COMMON_LIB in lib/common.sh - it cannot be read from there
# before that file is sourced.
# shellcheck source=../lib/common.sh
source /usr/local/lib/homelab/common.sh

LOG="$ESP_DIR/homelab-reset.log"
# One generation back rather than appending: the rsync progress below is
# written as carriage-return updates, which is a lot of bytes for a small FAT
# partition to accumulate across resets.
[[ -f "$LOG" ]] && mv -f "$LOG" "$LOG.prev"
exec > >(tee "$LOG") 2>&1
header "homelab-reset-main $(date -Is)"

need_root
[[ "$(current_role)" == "baseline" ]] || { log "not the baseline system - refusing"; exit 0; }
booted_via_baseline_entry || { log "not booted through the $BASELINE_LABEL entry - refusing"; exit 0; }
[[ -f "$ARM_MARKER" ]] || { log "no reset armed - leaving the live system alone"; exit 0; }

detect_disk
log "resetting rootfs -> $DEV_ROOT_A"

mkdir -p "$MAIN_ROOT_MNT"
mountpoint -q "$MAIN_ROOT_MNT" || mount "$DEV_ROOT_A" "$MAIN_ROOT_MNT"

# progress2 so `tail -f` on the log shows the copy moving. It has no newlines,
# so journalctl holds it back until the end - watch the log file instead.
rsync_live -aAXH --delete --info=progress2 "${RSYNC_EXCLUDES[@]}" / "$MAIN_ROOT_MNT/"
make_runtime_dirs "$MAIN_ROOT_MNT"

# ---- point the freshly written system back at p1/p2 ----
retarget_fstab "$MAIN_ROOT_MNT/etc/fstab" "$DEV_ESP_A" "$DEV_ROOT_A" || true

echo main > "$MAIN_ROOT_MNT$ROLE_FILE"
rm -f "$MAIN_ROOT_MNT$BASELINE_STAMP"

# The system we just wrote is not a baseline and must never reset anything.
rm -f "$MAIN_ROOT_MNT/etc/systemd/system/multi-user.target.wants/homelab-reset-main.service" \
      "$MAIN_ROOT_MNT/etc/systemd/system/homelab-reset-main.service" \
      "$MAIN_ROOT_MNT/usr/local/sbin/homelab-reset-main" \
      "$MAIN_ROOT_MNT$COMMON_LIB"

# Last, because until now rootA's grub.cfg (copied from here) names rootB, and
# regenerating it is what makes rootA boot as itself.
install_bootloader "$MAIN_ROOT_MNT" "$DEV_ESP_A"

sync
umount "$MAIN_ROOT_MNT"

rm -f "$ARM_MARKER"
sync
ok "reset complete - rebooting. Re-run install.sh to rebuild the homelab."
sleep 2
# --no-block: we are the job systemd would otherwise wait on. BootNext was
# used up by this boot, so the reboot follows BootOrder back to rootA.
systemctl --no-block reboot
