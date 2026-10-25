#!/usr/bin/env bash
# Turn off mDNS on the host, and let the router's DNS name it.
#
# mDNS is the serverless name system behind .local: there is no central
# authority, every machine answers queries for its own name over multicast.
# avahi is the daemon that does that here, and it advertises EVERY address on
# EVERY interface it can see - which on a Docker host means the bridge
# networks too. On the Pi, raspberrypi.local resolved to 172.17.0.1 (docker0)
# at one point, an address that exists only inside the host, so clients that
# picked it simply hung. Which address wins is decided by the order
# interfaces come up, so it changes from boot to boot and the breakage is
# intermittent.
#
# The FRITZ!Box already publishes a DNS name per DHCP lease, so the host is
# reachable as <hostname>.fritz.box (homelab.fritz.box) with no mDNS at all.
# It is ordinary unicast DNS, which means it works from devices whose .local
# support is unreliable, and over a VPN, where multicast does not reach.
#
# Nothing here needs the host's mDNS responder:
#   home-assistant  - runs its own python-zeroconf inside the container
#   matter-server   - likewise; its /run/dbus mount is for BlueZ, not avahi
#   otbr            - has no /run/dbus mount at all, so it cannot reach avahi
# Device discovery therefore keeps working; only the HOST's own .local name
# goes away.
#
# Masked rather than disabled: avahi is also D-Bus activatable, so merely
# disabling the unit leaves it able to start on demand.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root

UNITS=(avahi-daemon.socket avahi-daemon.service)

for unit in "${UNITS[@]}"; do
    systemctl list-unit-files "$unit" >/dev/null 2>&1 || continue

    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" == "masked" ]]; then
        skip "$unit already masked"
    else
        systemctl mask --now "$unit" >/dev/null 2>&1
        ok "masked $unit"
    fi
done

if systemctl is-active --quiet avahi-daemon; then
    warn "avahi is still running - .local may still be advertised"
else
    ok "mDNS responder is off; use <hostname>.fritz.box"
fi
