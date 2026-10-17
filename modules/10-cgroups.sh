#!/usr/bin/env bash
# Turn on the kernel's memory cgroup controller.
#
# A cgroup ("control group") is the kernel feature that caps how much CPU or
# memory a group of processes may use - it is the machinery behind
# `docker run --memory=`. Raspberry Pi OS ships the memory controller off,
# because accounting every page costs a little RAM and speed. The visible
# symptom is Docker starting with:
#
#     WARNING: No memory limit support
#
# and `/sys/fs/cgroup/cgroup.controllers` listing only "cpuset cpu io pids".
#
# Without it no container can be given a memory limit at all. On a 2GB Pi
# running Home Assistant, Matter, OTBR and Paperless side by side that matters:
# when memory runs out the kernel's OOM killer picks a victim by its own
# heuristics, and Home Assistant - large, long-lived - is an attractive target.
# With the controller on, the greedy services can be capped so the important
# ones survive.
#
# This module only edits the cmdline; the parameters take effect on the next
# boot and it deliberately does not reboot on its own.
#
# Nothing here needs an inverse in reset/reset-main.sh: a reset rsyncs the
# baseline's boot partition over bootA, which drops these parameters, and the
# next install.sh run puts them back.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root

CMDLINE="$BOOT_DIR/cmdline.txt"
[[ -f "$CMDLINE" ]] || die "no $CMDLINE - is $BOOT_DIR mounted?"

# cgroup_enable=memory is what cgroup v2 reads; cgroup_memory=1 is the older
# v1 spelling. Both are set because they are harmless together and every
# Raspberry Pi guide pairs them, so a future reader finds what they expect.
if added=$(add_cmdline_params "$CMDLINE" cgroup_enable=memory cgroup_memory=1); then
    ok "added $added to cmdline.txt"
else
    skip "memory cgroup already on the kernel cmdline"
fi

# Whether it is actually in effect is a property of the running kernel, not of
# the file we just wrote.
if grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
    ok "memory controller active"
else
    warn "memory controller needs a reboot to become active"
fi
