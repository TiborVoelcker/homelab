#!/usr/bin/env bash
# Give back the memory a headless Pi has no use for.
#
# The firmware reserves a slice of RAM for the GPU before Linux ever sees it -
# 76MB by default, which never appears in MemTotal. Nothing here draws, decodes
# video or runs a desktop, so 16MB (the minimum) is plenty and the rest comes
# back as usable RAM. On a 2GB board that is worth having.
#
# Camera and display auto-detection are also turned off: there is no camera and
# no monitor, so probing for them only adds boot work and a device tree overlay
# for hardware that is not there.
#
# What this deliberately does NOT do: remove dtoverlay=vc4-kms-v3d. That would
# shed the 512MB CMA reservation, which looks like a big win and is not - CMA
# is reusable, so the kernel already hands those pages out for ordinary use
# (CmaFree sits near zero because they ARE in use). Dropping it would reclaim
# almost nothing while costing HDMI output, which is a recovery path worth
# keeping on a machine whose whole point is being restorable without a second
# computer.
#
# Takes effect at the next boot; this module does not reboot. No inverse is
# needed in reset/reset-main.sh - a reset rsyncs the baseline's boot partition
# over bootA, dropping these, and the next install.sh puts them back.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root

CONFIG="$BOOT_DIR/config.txt"
[[ -f "$CONFIG" ]] || die "no $CONFIG - is $BOOT_DIR mounted?"

changed=0

# Flip the auto-detects off where they are on. Matched with an anchor and an
# exact value so a line that is already 0, or commented out, is left alone.
for key in camera_auto_detect display_auto_detect; do
    if grep -qE "^${key}=1$" "$CONFIG"; then
        sed -i "s/^${key}=1$/${key}=0/" "$CONFIG"
        ok "$key=0"
        changed=1
    else
        skip "$key already off or absent"
    fi
done

# gpu_mem has no entry in the stock file, so append it under [all] - which is
# the last section, and applies to every model.
if grep -qE "^gpu_mem=" "$CONFIG"; then
    skip "gpu_mem already set ($(grep -m1 -oE '^gpu_mem=.*' "$CONFIG"))"
else
    printf 'gpu_mem=16\n' >> "$CONFIG"
    ok "gpu_mem=16 appended"
    changed=1
fi

# Report against the running firmware, not the file we just wrote.
current_gpu=$(vcgencmd get_mem gpu 2>/dev/null | cut -d= -f2)
if [[ "$current_gpu" == "16M" ]]; then
    ok "firmware is running with gpu=16M"
else
    warn "reboot needed to apply gpu_mem - firmware still at gpu=${current_gpu:-unknown}"
fi
