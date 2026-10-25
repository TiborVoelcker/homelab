# shellcheck shell=bash
# Shared helpers. Sourced by install.sh, every module, and - once installed
# into the baseline as $COMMON_LIB - by reset/reset-main.sh.

set -euo pipefail

# ---------- output ----------
_c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
header() { _c '1;34' "==> $*"; }
ok()     { _c '1;32' "ok  $*"; }
skip()   { _c '0;90' "--  $*"; }
warn()   { _c '1;33' "!!  $*" >&2; }
die()    { _c '1;31' "XX  $*" >&2; exit 1; }
log()    { printf    '    %s\n' "$*"; }

confirm() {
    [[ "${HOMELAB_ASSUME_YES:-0}" == "1" ]] && return 0
    read -rp "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------- guards ----------
need_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }

need_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null || die "missing command: $c"
    done
}

ROLE_FILE=/etc/homelab-role
current_role() { cat "$ROLE_FILE" 2>/dev/null || echo main; }

# ---------- SSD layout ----------
# GPT, six partitions - see AGENTS.md for why. Each root carries its own /boot
# as a plain directory; the ESPs hold only shim, GRUB and a stub grub.cfg that
# names its root by filesystem UUID.
PART_ESP_A=1
PART_ROOT_A=2
PART_ESP_B=3
PART_ROOT_B=4
PART_SWAP=5
PART_DATA=6

ESP_DIR=/boot/efi
DATA_DIR=/data

BASELINE_ROOT_MNT=/mnt/baseline
BASELINE_ESP_MNT=/mnt/baseline-esp
MAIN_ROOT_MNT=/mnt/main

# Where the baseline keeps its own copy of this file.
COMMON_LIB=/usr/local/lib/homelab/common.sh

# $ESP_DIR resolves to ESP-B only from INSIDE the baseline; the live system
# reaches the marker through arm_reset()/reset_armed() at the bottom.
ARM_NAME=homelab-reset.arm
ARM_MARKER="$ESP_DIR/$ARM_NAME"

# Written into the baseline when it is captured, and the proof that rootB holds
# a real system rather than an empty filesystem.
BASELINE_STAMP=/etc/homelab-baseline

# Proves the data partition is really mounted and is really ours. Docker refuses
# to start without it, which is what stops containers initialising fresh
# databases into an empty mount point.
DATA_MARKER="$DATA_DIR/.homelab-data"

# Populates: DISK, DEV_ESP_A, DEV_ROOT_A, DEV_ESP_B, DEV_ROOT_B, DEV_SWAP,
# DEV_DATA. Works from either system - both boot off the same SSD.
detect_disk() {
    local root_src pk
    # -r throughout: without it lsblk pads its columns for human reading.
    root_src=$(findmnt -no SOURCE /) || die "cannot determine root source"
    pk=$(lsblk -rno PKNAME "$root_src" | head -1)
    [[ -n "$pk" ]] || die "cannot determine parent disk of $root_src"
    DISK="/dev/$pk"

    [[ "$(lsblk -rno PTTYPE "$DISK" | head -1)" == "gpt" ]] \
        || die "partition table on $DISK is not GPT - see lib/common.sh layout notes"

    local sep=""
    [[ "$DISK" =~ [0-9]$ ]] && sep="p"
    DEV_ESP_A="${DISK}${sep}${PART_ESP_A}"
    DEV_ROOT_A="${DISK}${sep}${PART_ROOT_A}"
    DEV_ESP_B="${DISK}${sep}${PART_ESP_B}"
    DEV_ROOT_B="${DISK}${sep}${PART_ROOT_B}"
    DEV_SWAP="${DISK}${sep}${PART_SWAP}"
    DEV_DATA="${DISK}${sep}${PART_DATA}"
}

# Filesystem UUID of a block device. Dies rather than print nothing: an empty
# UUID written into fstab leaves a system that does not boot.
uuid_of() {
    local u
    u=$(blkid -o value -s UUID "$1") && [[ -n "$u" ]] \
        || die "cannot read the filesystem UUID of $1"
    echo "$u"
}

# ---------- UEFI boot entries ----------
# The NVRAM label of the baseline's entry. Not its bootloader-id: Debian's
# signed GRUB has the prefix /EFI/debian built in, so both ESPs use that
# directory and the two entries are told apart by label alone.
BASELINE_LABEL=homelab-baseline

# The four-hex-digit numbers of the boot entries labelled $1, one per line.
# Prints nothing when there is none.
boot_entries_for() {
    efibootmgr | awk -F'\t' -v l="$1" '
        /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*? / {
            n = substr($1, 5, 4)
            sub(/^Boot....\*? /, "", $1)
            if ($1 == l) print n
        }'
}

# Gate 2 of the reset: this boot came through the baseline's own entry, i.e.
# via BootNext, rather than the firmware falling through to it. This firmware
# adds entries to BootOrder by itself, so being absent from BootOrder proves
# nothing.
booted_via_baseline_entry() {
    local cur
    cur=$(efibootmgr 2>/dev/null | sed -n 's/^BootCurrent: //p')
    [[ -n "$cur" ]] && boot_entries_for "$BASELINE_LABEL" | grep -qix "$cur"
}

# ---------- copying one system onto the other ----------
# Excluded from every rootfs copy. /data is excluded because it is a separate
# partition; /boot/efi because each root has its own ESP, and the rsyncs do
# not stay on one filesystem.
RSYNC_EXCLUDES=(
    --exclude=/dev/*      --exclude=/proc/*  --exclude=/sys/*
    --exclude=/tmp/*      --exclude=/run/*   --exclude=/mnt/*
    --exclude=/media/*    --exclude=/lost+found
    --exclude=/data/*     --exclude=/boot/efi/*
)

# rsync exits 24 when files vanish mid-copy. Both callers copy a rootfs that is
# currently booted, so that is expected rather than a failure.
rsync_live() {
    local rc=0
    rsync "$@" || rc=$?
    (( rc == 0 || rc == 24 )) || die "rsync failed (exit $rc)"
}

# Recreate the mount points whose contents RSYNC_EXCLUDES skipped.
make_runtime_dirs() {
    local root="$1" d
    for d in dev proc sys tmp run mnt media data boot/efi; do
        mkdir -p "$root/$d"
    done
    chmod 1777 "$root/tmp"
}

# Rewrite a cloned system's fstab so it points at its own partitions.
# usage: retarget_fstab <fstab-path> <esp-dev> <root-dev>
#
# Matches on mountpoint rather than on the old UUID, so it is safe to run
# repeatedly and in either direction. Returns 1 when there was nothing to
# change, so a caller can tell ok from skip.
retarget_fstab() {
    local fstab="$1" esp_uuid root_uuid
    esp_uuid=$(uuid_of "$2")
    root_uuid=$(uuid_of "$3")

    awk -v e="UUID=$esp_uuid" -v r="UUID=$root_uuid" '
        $2 == "/boot/efi" && $1 != e { print e, $2, $3, $4, $5, $6; next }
        $2 == "/"         && $1 != r { print r, $2, $3, $4, $5, $6; next }
        { print }
    ' "$fstab" > "${fstab}.new"
    if cmp -s "$fstab" "${fstab}.new"; then
        rm -f "${fstab}.new"
        return 1
    fi
    mv "${fstab}.new" "$fstab"
}

# Make a mounted root bootable from an ESP: regenerate its grub.cfg, and put
# signed shim + GRUB and a stub naming that root onto the ESP. Runs inside
# the root, so its own GRUB packages and UUIDs are used. Regenerated rather
# than sed-patched: a GRUB update that changes the file's shape would turn a
# patch into an unbootable system.
#
# --no-nvram: boot entries are changed only on purpose, by
# 01-create-baseline.sh. A reset in particular must leave NVRAM alone.
# usage: install_bootloader <root-mnt> <esp-dev>
install_bootloader() {
    local root="$1" esp="$2" d
    mountpoint -q "$root$ESP_DIR" || mount "$esp" "$root$ESP_DIR"
    for d in dev proc sys; do
        mountpoint -q "$root/$d" || mount --bind "/$d" "$root/$d"
    done
    chroot "$root" update-grub
    chroot "$root" grub-install --target=x86_64-efi --efi-directory="$ESP_DIR" \
        --bootloader-id=debian --uefi-secure-boot --no-nvram
    umount "$root/sys" "$root/proc" "$root/dev" "$root$ESP_DIR"
}

# Whole days since an ISO-8601 timestamp. Fails if it cannot be parsed.
# The empty-string check is not redundant: `date -d ""` succeeds and returns
# midnight today, which would report a missing stamp as "today".
age_days() {
    local at
    [[ -n "${1// /}" ]] || return 1
    at=$(date -d "$1" +%s 2>/dev/null) || return 1
    echo $(( ($(date +%s) - at) / 86400 ))
}

# Days -> "14 months ago".
human_age() {
    local days="$1"
    if   (( days <   0 )); then echo "in the future"
    elif (( days ==  0 )); then echo "today"
    elif (( days ==  1 )); then echo "yesterday"
    elif (( days <  60 )); then echo "$days days ago"
    elif (( days < 730 )); then echo "$(( days / 30 )) months ago"
    else                        echo "$(( days / 365 )) years ago"
    fi
}

# Past roughly two years the baseline's apt sources can stop resolving, at
# which point a reset leaves a system install.sh cannot build on.
BASELINE_STALE_DAYS=730

# ---------- arming the reset, from the live system ----------
# The marker lives on ESP-B, so the live system has to mount it to place or
# read it. Returns 1 rather than dying when there is no ESP-B yet, so
# homelab-status can report on a half-provisioned disk.
_with_baseline_esp() {
    local action="$1" mounted=0 rc=0
    [[ -b "${DEV_ESP_B:?run detect_disk first}" ]] || return 1

    mkdir -p "$BASELINE_ESP_MNT"
    if mountpoint -q "$BASELINE_ESP_MNT"; then
        mounted=1
    else
        local opts=()
        [[ "$action" == check ]] && opts=(-o ro)
        if ! mount "${opts[@]}" "$DEV_ESP_B" "$BASELINE_ESP_MNT" 2>/dev/null; then
            # Arming has to fail loudly. Reporting must not: homelab-status is
            # the tool you reach for when the disk is in a state like this.
            if [[ "$action" == check ]]; then
                warn "cannot read ESP-B - whether a reset is armed is unknown"
                return 1
            fi
            die "cannot mount the baseline's ESP"
        fi
    fi

    local marker="$BASELINE_ESP_MNT/$ARM_NAME"
    case "$action" in
        arm)   touch "$marker"; sync ;;
        check) [[ -f "$marker" ]] || rc=1 ;;
    esac

    (( mounted )) || umount "$BASELINE_ESP_MNT"
    return "$rc"
}

arm_reset()   { _with_baseline_esp arm; }
reset_armed() { _with_baseline_esp check; }
