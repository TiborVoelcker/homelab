#!/usr/bin/env bash
# OpenThread Border Router - the Thread half of the smart home. It owns the
# 802.15.4 radio and bridges the mesh onto the LAN; Home Assistant drives it
# over a REST API and does the commissioning, so there is nothing to configure
# here beyond pointing it at the right dongle and interface.
#
# Follows https://openthread.io/guides/border-router/build-docker, with two
# departures:
#   - upstream's host prep is a curl-pipe-to-shell (`setup-host`); it is four
#     sysctls, so they are written out below instead
#   - the radio is found through /dev/serial/by-id rather than hardcoded to
#     /dev/ttyACM0, which is allocated in USB probe order and moves
#
# The container appends its own ip6tables/NAT64 rules to the HOST firewall on
# every start - host networking plus NET_ADMIN. They accumulate across
# restarts; a reboot is the cleanup.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

APP_DIR=/opt/otbr
DATA=/data/otbr

# The dongle we settled on. Remembered so that plugging in a second USB serial
# device later cannot silently move OTBR onto the wrong radio.
PIN_FILE="$APP_DIR/rcp-device"

# nRF52840 dongles running stock ot-rcp firmware usually want 460800 instead.
BAUD="${HOMELAB_OTBR_BAUD:-1000000}"

mkdir -p "$APP_DIR" "$DATA"

# ---- the LAN-facing interface ----
# OTBR advertises the Thread prefix onto this one and must accept the router
# advertisements coming back from it.
infra_if="${HOMELAB_OTBR_INFRA_IF:-}"
[[ -n "$infra_if" ]] || infra_if=$(ip -o route show default | awk '{print $5; exit}')
[[ -n "$infra_if" ]] \
    || die "no default route - cannot tell which interface faces the LAN (set HOMELAB_OTBR_INFRA_IF)"

# ---- the radio ----
# Everything else in this repo provisions software. This module needs hardware
# plugged in, so an absent dongle warns and skips rather than failing the run.
rcp="${HOMELAB_OTBR_DEVICE:-}"

if [[ -z "$rcp" && -f "$PIN_FILE" ]]; then
    rcp=$(<"$PIN_FILE")
    if [[ ! -e "$rcp" ]]; then
        warn "pinned radio $rcp is gone - looking again"
        rcp=""
    fi
fi

if [[ -z "$rcp" ]]; then
    shopt -s nullglob
    candidates=(/dev/serial/by-id/*)
    shopt -u nullglob

    case ${#candidates[@]} in
        0)  warn "no usb serial device - skipping otbr (plug the thread radio in and re-run)"
            exit 0 ;;
        1)  rcp="${candidates[0]}" ;;
        # A Zigbee stick alongside the Thread one lands here. Guessing would
        # mean handing OTBR the wrong radio, so ask instead.
        *)  warn "several usb serial devices - re-run with HOMELAB_OTBR_DEVICE set to the thread radio:"
            for c in "${candidates[@]}"; do log "$c"; done
            exit 0 ;;
    esac
fi

[[ -e "$rcp" ]] || die "radio $rcp does not exist"
printf '%s\n' "$rcp" > "$PIN_FILE"
ok "radio $(basename "$rcp")"

# ---- host prep ----
# Filenames match upstream's `setup-host`, so running that script later
# overwrites these rather than leaving a second, conflicting copy.
#
# Thread is IPv6 all the way down. With ipv6.disable=1 on the kernel cmdline
# these keys do not exist at all, and sysctl -p below would abort the whole
# install over one optional service.
if [[ ! -e "/proc/sys/net/ipv6/conf/$infra_if/accept_ra" ]]; then
    warn "ipv6 is disabled on $infra_if - skipping otbr (thread cannot run without it)"
    exit 0
fi

# accept_ra=2 because a host with forwarding enabled ignores router
# advertisements otherwise, which would cost the host its own default route the
# moment the next line takes effect. The RIO prefix length lets it learn the
# route back into the Thread mesh.
cat > /etc/sysctl.d/60-otbr-accept-ra.conf <<EOF
net.ipv6.conf.$infra_if.accept_ra = 2
net.ipv6.conf.$infra_if.accept_ra_rt_info_max_plen = 64
EOF
cat > /etc/sysctl.d/60-otbr-ip-forward.conf <<EOF
net.ipv6.conf.all.forwarding = 1
net.ipv4.ip_forward = 1
EOF
sysctl -q -p /etc/sysctl.d/60-otbr-accept-ra.conf
sysctl -q -p /etc/sysctl.d/60-otbr-ip-forward.conf
ok "ipv6 forwarding and ra on $infra_if"

# Written every run: this file is ours rather than fetched, so rewriting it is
# how an edit here, a new dongle or a new interface reaches the container.
cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  otbr:
    container_name: otbr
    image: openthread/border-router:latest
    restart: unless-stopped
    # Thread's whole job is routing between the mesh and the LAN, so it needs
    # the host's interfaces directly and the capability to add routes and
    # firewall rules on them.
    network_mode: host
    cap_add:
      - NET_ADMIN
    # Long syntax, because the short host:container:perms form is split on
    # colons and a by-id name embeds the radio's MAC, which has six of its own.
    # permissions is spelled out: the short form defaults it to rwm, the long
    # form has no default at all and would hand the container a device it is
    # not allowed to read.
    devices:
      - source: $rcp
        target: /dev/ttyACM0
        permissions: rwm
      - source: /dev/net/tun
        target: /dev/net/tun
        permissions: rwm
    # Holds thread/, and with it the network key and PAN id. Lose this and
    # every Thread device has to be commissioned onto a new network again.
    volumes:
      - $DATA:/data
    environment:
      OT_RCP_DEVICE: spinel+hdlc+uart:///dev/ttyACM0?uart-baudrate=$BAUD
      OT_INFRA_IF: $infra_if
      OT_THREAD_IF: wpan0
      # Loopback is enough: Home Assistant is host-networked too, so it shares
      # this one. Only widen it if Home Assistant moves off this host - the REST
      # API is unauthenticated and can re-form the Thread network.
      OT_REST_LISTEN_ADDR: "127.0.0.1"
      OT_REST_LISTEN_PORT: "8081"
      # Upstream defaults to 7 (debug), which is a lot of writes to an SD card
      # for a service that should just sit there. 5 is notice.
      OT_LOG_LEVEL: "5"
    # Docker only knows a container is up, not that the service inside it
    # works. otbr-agent crash-looped for 18 days behind its image's own
    # supervisor while the container reported "Up" and Monit's restart check,
    # which watches container starts, saw nothing. A healthcheck is what makes
    # that visible, and the unhealthy check in homelab-check is what reports
    # it. Mind the backticks: this block is inside an unquoted heredoc.
    # This is the service that taught us to do this, so the probe asks the
    # question that actually matters: is this node on the Thread mesh? Any of
    # leader, router or child means yes. "detached" or "disabled" - or an
    # ot-ctl that cannot reach a dead agent at all - means the border router
    # is there in name only, which is exactly how it sat for 18 days.
    healthcheck:
      test: ["CMD-SHELL", "ot-ctl state | grep -qE '^(leader|router|child)'"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 120s
EOF
ok "wrote compose file"

cd "$APP_DIR" && docker compose up -d
ok "otbr converged"
log "in home assistant, add the OpenThread Border Router integration"
log "pointed at http://127.0.0.1:8081, then commission from Settings > Thread"
