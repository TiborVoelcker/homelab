#!/usr/bin/env bash
# Verify the SSD's layout. Partitioning happens once, by hand, when the OS is
# installed (see README.md) - a running system cannot repartition the disk it
# boots from. This module is the layout in executable form, and stops
# install.sh before anything is built on a disk that does not match it:
#
#   p1 ESP-A  vfat | p2 rootA ext4 | p3 ESP-B vfat | p4 rootB ext4
#   p5 swap   swap | p6 data  ext4
#
# Swap is its own partition so that no rsync between the roots ever copies
# it; /data is its own so that a reset never touches it.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd lsblk findmnt
detect_disk

# usage: expect <dev> <fstype> <partlabel>
expect() {
    local got
    [[ -b "$1" ]] || die "$1 does not exist - the disk is not partitioned as lib/common.sh expects"
    got=$(lsblk -rno FSTYPE,PARTLABEL "$1")
    [[ "$got" == "$2 $3" ]] || die "$1 is '$got', expected '$2 $3'"
}
expect "$DEV_ESP_A"  vfat ESP-A
expect "$DEV_ROOT_A" ext4 rootA
expect "$DEV_ESP_B"  vfat ESP-B
expect "$DEV_ROOT_B" ext4 rootB
expect "$DEV_SWAP"   swap swap
expect "$DEV_DATA"   ext4 data

[[ "$(findmnt -no SOURCE /)" == "$DEV_ROOT_A" ]] \
    || die "/ is not $DEV_ROOT_A - provision only from the live system"
[[ "$(findmnt -no SOURCE "$ESP_DIR")" == "$DEV_ESP_A" ]] \
    || die "$ESP_DIR is not $DEV_ESP_A - the live system must mount its own ESP"
ok "$DISK has the six-partition layout"
