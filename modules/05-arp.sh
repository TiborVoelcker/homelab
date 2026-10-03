#!/usr/bin/env bash
# Make ARP behave on a host with two NICs on one subnet.
#
# This Pi is dual-homed: eth0 and wlan0 both sit on 192.168.178.0/24, each with
# its own address. Linux defaults to a "weak host model", where an address
# belongs to the machine rather than to a card - so by default the Pi answers
# an ARP query for ANY of its addresses out of ANY interface. Ask "who has the
# wired address?" and the WiFi card may answer first, after which the router
# records the wired IP as living behind the WiFi MAC and sends traffic for it
# over WiFi. Which card wins is a race, so the mapping flips between boots and
# the resulting breakage is intermittent. That is ARP flux.
#
# It only bites servers. A client picks its route outbound and replies come
# back to the address it used, so a dual-homed laptop never notices. This Pi is
# dialled INTO by address - Home Assistant on 8123, Paperless on 8000 - which
# is precisely what flux makes unreliable.
#
#   arp_ignore=1    answer only for addresses belonging to the receiving card
#   arp_announce=2  when we initiate, advertise the source address that matches
#                   the card we are sending from
#
# The kernel takes the max of conf/all and conf/<iface>, so setting all/ is
# enough to raise the floor for every interface, present and future.
#
# The permissive default is not an oversight: direct-routing load balancers and
# IP failover setups rely on it, which is why strictness is opt-in.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root

DROPIN=/etc/sysctl.d/90-arp-dual-homed.conf
read -r -d '' WANT <<'EOF' || true
# Dual-homed host: eth0 and wlan0 share one subnet. See modules/05-arp.sh.
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
EOF

if [[ -f "$DROPIN" ]] && [[ "$(cat "$DROPIN")" == "$WANT" ]]; then
    skip "arp settings already configured"
else
    printf '%s\n' "$WANT" > "$DROPIN"
    ok "wrote $DROPIN"
fi

# Applies now as well as at the next boot.
sysctl -q -p "$DROPIN"

ignore=$(sysctl -n net.ipv4.conf.all.arp_ignore)
announce=$(sysctl -n net.ipv4.conf.all.arp_announce)
if [[ "$ignore" == "1" && "$announce" == "2" ]]; then
    ok "arp_ignore=$ignore arp_announce=$announce active"
else
    warn "arp sysctls did not take (ignore=$ignore announce=$announce)"
fi
