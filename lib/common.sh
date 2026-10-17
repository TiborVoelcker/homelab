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

need_tryboot_support() {
    [[ -e /proc/device-tree/chosen/bootloader/tryboot ]] \
        || die "firmware does not expose tryboot (needs Pi 4/5 with current EEPROM)"
}

booted_via_tryboot() {
    local v
    v=$(od -An -tu4 --endian=big /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null \
        | tr -d ' ') || return 1
    [[ "$v" == "1" ]]
}

ROLE_FILE=/etc/homelab-role
current_role() { cat "$ROLE_FILE" 2>/dev/null || echo main; }

# ---------- SD card layout ----------
# MBR, four primaries: p1 bootA, p2 rootA, p3 bootB, p4 rootB - see AGENTS.md
# for why. Do not convert to GPT: the firmware counts partition numbers
# differently there and tryboot becomes hard to reason about.
PART_BOOT_A=1
PART_ROOT_A=2
PART_BOOT_B=3
PART_ROOT_B=4

BOOT_DIR=/boot/firmware
DATA_DIR=/data

BASELINE_ROOT_MNT=/mnt/baseline
BASELINE_BOOT_MNT=/mnt/baseline-boot
MAIN_ROOT_MNT=/mnt/main
MAIN_BOOT_MNT=/mnt/main-boot

# Where the baseline keeps its own copy of this file.
COMMON_LIB=/usr/local/lib/homelab/common.sh

# $BOOT_DIR resolves to bootB only from INSIDE the baseline; the live system
# reaches the marker through arm_reset()/reset_armed() at the bottom.
ARM_NAME=homelab-reset.arm
ARM_MARKER="$BOOT_DIR/$ARM_NAME"

# Written into the baseline when it is captured, and the proof that rootB holds
# a real system rather than an empty filesystem.
BASELINE_STAMP=/etc/homelab-baseline

# Proves the external disk is really mounted and is really ours. Docker refuses
# to start without it, which is what stops containers initialising fresh
# databases into an empty mount point.
DATA_MARKER="$DATA_DIR/.homelab-data"

# Populates: DISK, DISK_ID, DEV_BOOT_A, DEV_ROOT_A, DEV_BOOT_B, DEV_ROOT_B.
# Works from either system - both boot off the same card.
detect_disk() {
    local root_src pk
    # -r throughout: without it lsblk pads its columns for human reading.
    root_src=$(findmnt -no SOURCE /) || die "cannot determine root source"
    pk=$(lsblk -rno PKNAME "$root_src" | head -1)
    [[ -n "$pk" ]] || die "cannot determine parent disk of $root_src"
    DISK="/dev/$pk"

    [[ "$(lsblk -rno PTTYPE "$DISK" | head -1)" == "dos" ]] \
        || die "partition table on $DISK is not MBR - see lib/common.sh layout notes"

    # An MBR disk id is exactly 8 hex digits. A malformed one would be written
    # into fstab and cmdline as a PARTUUID, and the card would stop booting.
    DISK_ID=$(sfdisk --disk-id "$DISK" | sed 's/^0x//' | tr -dc '0-9a-fA-F')
    [[ "$DISK_ID" =~ ^[0-9a-fA-F]{8}$ ]] \
        || die "cannot read the MBR disk id of $DISK (got '$DISK_ID')"

    local sep=""
    [[ "$DISK" =~ [0-9]$ ]] && sep="p"
    DEV_BOOT_A="${DISK}${sep}${PART_BOOT_A}"
    DEV_ROOT_A="${DISK}${sep}${PART_ROOT_A}"
    DEV_BOOT_B="${DISK}${sep}${PART_BOOT_B}"
    DEV_ROOT_B="${DISK}${sep}${PART_ROOT_B}"
}

partuuid_for() { printf '%s-%02d\n' "$DISK_ID" "$1"; }

# ---------- copying one system onto the other ----------
# Excluded from every rootfs copy. /data is excluded because it is a separate
# disk entirely; /boot/firmware because it is copied separately, with its own
# per-system edits.
RSYNC_EXCLUDES=(
    --exclude=/dev/*      --exclude=/proc/*  --exclude=/sys/*
    --exclude=/tmp/*      --exclude=/run/*   --exclude=/mnt/*
    --exclude=/media/*    --exclude=/lost+found
    --exclude=/data/*     --exclude=/boot/firmware/*
    --exclude=/var/swap
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
    for d in dev proc sys tmp run mnt media data boot/firmware; do
        mkdir -p "$root/$d"
    done
    chmod 1777 "$root/tmp"
}

# Rewrite a cloned system's fstab so it points at its own partitions.
# usage: retarget_fstab <fstab-path> <boot-partnum> <root-partnum>
#
# Matches on mountpoint rather than on the old UUID, so it is safe to run
# repeatedly and in either direction.
retarget_fstab() {
    local fstab="$1" bootn="$2" rootn="$3"
    local boot_uuid root_uuid
    boot_uuid="PARTUUID=$(partuuid_for "$bootn")"
    root_uuid="PARTUUID=$(partuuid_for "$rootn")"

    awk -v b="$boot_uuid" -v r="$root_uuid" '
        $2 == "/boot/firmware" { print b, $2, $3, $4, $5, $6; next }
        $2 == "/"              { print r, $2, $3, $4, $5, $6; next }
        { print }
    ' "$fstab" > "${fstab}.new" && mv "${fstab}.new" "$fstab"
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

# Append kernel parameters to a boot partition's cmdline.txt, skipping any
# already there. Prints the parameters it added and returns 1 when there was
# nothing to add, so a caller can tell ok from skip.
#
# The firmware reads only the FIRST line of cmdline.txt, and every parameter
# has to stay on it - a stray newline silently drops everything after it.
add_cmdline_params() {
    local cmdline="$1"; shift
    local line p missing=()
    read -r line < "$cmdline"
    for p in "$@"; do
        # Padded compare, so a parameter is matched as a whole token rather
        # than as a substring of a longer one.
        [[ " $line " == *" $p "* ]] || missing+=("$p")
    done
    (( ${#missing[@]} )) || return 1
    printf '%s %s\n' "$line" "${missing[*]}" > "$cmdline"
    printf '%s\n' "${missing[*]}"
}

# Point a boot partition's cmdline.txt at a given root partition.
set_cmdline_root() {
    local cmdline="$1" rootn="$2"
    sed -i "s|root=PARTUUID=[^[:space:]]*|root=PARTUUID=$(partuuid_for "$rootn")|" "$cmdline"

    # The first-boot auto-expand must never fire again on either system: the
    # only free space it could grow the root partition into is where p3/p4
    # live. Word-bounded, so noresize and resize2fs_once= are left alone.
    sed -i 's|\bresize\b||g; s|  *| |g; s|^ *||; s| *$||' "$cmdline"
}

# ---------- arming the reset, from the live system ----------
# The marker lives on bootB, so the live system has to mount it to place or
# read it. Returns 1 rather than dying when there is no bootB yet, so
# homelab-status can report on a half-provisioned card.
_with_baseline_boot() {
    local action="$1" mounted=0 rc=0
    [[ -b "${DEV_BOOT_B:?run detect_disk first}" ]] || return 1

    mkdir -p "$BASELINE_BOOT_MNT"
    if mountpoint -q "$BASELINE_BOOT_MNT"; then
        mounted=1
    else
        local opts=()
        [[ "$action" == check ]] && opts=(-o ro)
        if ! mount "${opts[@]}" "$DEV_BOOT_B" "$BASELINE_BOOT_MNT" 2>/dev/null; then
            # Arming has to fail loudly. Reporting must not: homelab-status is
            # the tool you reach for when the card is in a state like this.
            if [[ "$action" == check ]]; then
                warn "cannot read bootB - whether a reset is armed is unknown"
                return 1
            fi
            die "cannot mount the baseline boot partition"
        fi
    fi

    local marker="$BASELINE_BOOT_MNT/$ARM_NAME"
    case "$action" in
        arm)   touch "$marker"; sync ;;
        check) [[ -f "$marker" ]] || rc=1 ;;
    esac

    (( mounted )) || umount "$BASELINE_BOOT_MNT"
    return "$rc"
}

arm_reset()   { _with_baseline_boot arm; }
reset_armed() { _with_baseline_boot check; }
