#!/usr/bin/env bash
# Home Assistant Container - the plain Docker flavour, not Home Assistant OS
# or the Supervised install. Those two want to own the whole machine; this one
# is a single container that behaves like any other service here.
#
# It keeps everything in one config directory, so /data is the whole of its
# state and a reset leaves the installation untouched.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

APP_DIR=/opt/homeassistant
DATA=/data/homeassistant

mkdir -p "$APP_DIR" "$DATA/config"

# Written every run rather than guarded like paperless's: that one comes from
# upstream and must not be re-fetched, this one is ours, so re-writing it is
# how an edit here reaches the host.
cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    restart: unless-stopped
    # Discovery is the reason for both of these. Home Assistant finds devices
    # through mDNS, SSDP and DHCP traffic, which is broadcast and does not
    # cross a bridge network; privileged + the host's dbus socket is what the
    # Bluetooth and USB (Zigbee/Z-Wave stick) integrations need to see the
    # hardware. Host networking also means the port is 8123 on the host itself,
    # with no port mapping to declare.
    network_mode: host
    privileged: true
    volumes:
      - $DATA/config:/config
      - /run/dbus:/run/dbus:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      TZ: Europe/Berlin
    # Docker only knows a container is up, not that the service inside it
    # works. otbr-agent crash-looped for 18 days behind its image's own
    # supervisor while the container reported "Up" and Monit's restart check,
    # which watches container starts, saw nothing. A healthcheck is what makes
    # that visible, and the unhealthy check in homelab-check is what reports
    # it. Mind the backticks: this block is inside an unquoted heredoc.
    # A cold start took a minute or two on the Pi - recorder alone logs that
    # it is taking over 10 seconds - so the start period is generous. Until it
    # expires the state is "starting", which deliberately alerts no one.
    healthcheck:
      test: ["CMD", "curl", "-fsS", "--max-time", "5", "-o", "/dev/null", "http://127.0.0.1:8123/"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 300s
EOF
ok "wrote compose file"

cd "$APP_DIR" && docker compose up -d
ok "home assistant converged"
log "onboarding: http://$(hostname):8123 (first start takes a minute or two)"
