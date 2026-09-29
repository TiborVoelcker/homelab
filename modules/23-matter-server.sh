#!/usr/bin/env bash
# python-matter-server - lets Home Assistant commission and drive Matter
# devices (including Matter-over-Thread ones, e.g. IKEA's Thread bulbs).
# HA's own Matter integration is just a client; the server that actually
# speaks Matter/BLE/mDNS has to run as its own container.
#
# Host networking + apparmor:unconfined + the host's dbus socket are what
# upstream's own docker instructions call for: commissioning goes over BLE
# via BlueZ on the host, and mDNS discovery does not cross a bridge network.
# Once a device is commissioned onto the Thread mesh, traffic to it is
# ordinary IPv6 routed by OTBR - nothing Matter-specific needed for that part.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

APP_DIR=/opt/matter-server
DATA=/data/matter-server

mkdir -p "$APP_DIR" "$DATA"

# Written every run: this file is ours rather than fetched, so rewriting it is
# how an edit here reaches the Pi.
cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  matter-server:
    container_name: matter-server
    image: ghcr.io/home-assistant-libs/python-matter-server:stable
    restart: unless-stopped
    # Host networking for mDNS discovery and so HA (also host-networked)
    # reaches the websocket on localhost with no port mapping to declare.
    network_mode: host
    # BLE commissioning goes through BlueZ on the host; apparmor's default
    # profile blocks that.
    security_opt:
      - apparmor:unconfined
    volumes:
      - $DATA:/data
      - /run/dbus:/run/dbus:ro
EOF
ok "wrote compose file"

cd "$APP_DIR" && docker compose up -d
ok "matter-server converged"
log "in home assistant, add the Matter integration"
log "pointed at ws://127.0.0.1:5580/ws, then commission devices from there"
