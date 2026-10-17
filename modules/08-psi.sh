#!/usr/bin/env bash
# Turn on the kernel's Pressure Stall Information.
#
# PSI is the kernel's own answer to "is this machine struggling?". For cpu,
# memory and io it reports the share of time tasks spent *waiting* for that
# resource, averaged over 10, 60 and 300 seconds, in /proc/pressure/<resource>.
# On a box like this one it beats load average and free memory: 1.5GB "used"
# with most of a gigabyte swapped out says nothing about whether anything is
# actually stalling, and memory pressure says exactly that.
#
# Raspberry Pi OS compiles the feature in but leaves it switched off -
# CONFIG_PSI=y together with CONFIG_PSI_DEFAULT_DISABLED=y - so /proc/pressure
# does not exist until the kernel is booted with psi=1. The visible symptom is
# Home Assistant's System Monitor integration offering CPU, memory and IO
# pressure sensors that never produce a value. It reads /proc/pressure
# directly, and a container shares the host kernel's copy, so switching it on
# here is the whole fix - nothing changes in Home Assistant itself.
#
# This module only edits the cmdline; psi=1 takes effect at the next boot and
# it deliberately does not reboot on its own.
#
# Nothing here needs an inverse in reset/reset-main.sh, for the same reason as
# modules/10-cgroups.sh: a reset rsyncs the baseline's boot partition over
# bootA, which drops the parameter, and the next install.sh run puts it back.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root

CMDLINE="$BOOT_DIR/cmdline.txt"
[[ -f "$CMDLINE" ]] || die "no $CMDLINE - is $BOOT_DIR mounted?"

if added=$(add_cmdline_params "$CMDLINE" psi=1); then
    ok "added $added to cmdline.txt"
else
    skip "psi already on the kernel cmdline"
fi

# Whether it is actually in effect is a property of the running kernel, not of
# the file we just wrote.
if [[ -r /proc/pressure/memory ]]; then
    ok "pressure stall information active"
else
    warn "psi needs a reboot to become active"
fi
