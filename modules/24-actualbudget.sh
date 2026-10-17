#!/usr/bin/env bash
# Actual Budget - personal finance, served over HTTPS on port 5006.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

APP_DIR=/opt/actualbudget
DATA=/data/actualbudget

mkdir -p "$APP_DIR" "$DATA"/{data,certs}

# Actual needs SharedArrayBuffer, which browsers only expose in a secure
# context - HTTPS, or localhost. Plain HTTP over the LAN trips its "requires
# access to SharedArrayBuffer" error. Self-signed is enough for the secure
# context; it costs a one-off browser warning per device. Generated once, so
# devices that already trust it keep doing so.
if [[ -f "$DATA/certs/cert.pem" ]]; then
    skip "certificate present"
else
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$(hostname)" \
        -addext "subjectAltName=DNS:$(hostname),DNS:$(hostname).fritz.box" \
        -keyout "$DATA/certs/key.pem" -out "$DATA/certs/cert.pem" 2>/dev/null
    chmod 600 "$DATA/certs/key.pem"
    ok "generated self-signed certificate"
fi

# Written every run: the file is ours, so re-writing it is how an edit here
# reaches the Pi.
cat > "$APP_DIR/docker-compose.yml" <<EOF
services:
  actualbudget:
    container_name: actualbudget
    image: actualbudget/actual-server:latest
    restart: unless-stopped
    # No host networking: Actual needs no mDNS/broadcast discovery, so a
    # bridge with one published port is enough (the paperless pattern).
    ports:
      - "5006:5006"
    volumes:
      - $DATA/data:/data
      - $DATA/certs:/certs:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      TZ: Europe/Berlin
      ACTUAL_HTTPS_KEY: /certs/key.pem
      ACTUAL_HTTPS_CERT: /certs/cert.pem
    # Keeps Actual from growing at Home Assistant's expense on a 2GB Pi -
    # enforceable only because modules/10-cgroups.sh enabled the memory
    # controller.
    mem_limit: 512m
    # Docker only knows a container is up, not that the service inside it
    # works. otbr-agent crash-looped for 18 days behind its image's own
    # supervisor while the container reported "Up" and Monit's restart check,
    # which watches container starts, saw nothing. A healthcheck is what makes
    # that visible, and the unhealthy check in homelab-check is what reports
    # it. Mind the backticks: this block is inside an unquoted heredoc.
    # This image carries neither curl nor wget, so the probe goes through the
    # node it does have. /health is Actual's own endpoint, and the certificate
    # is self-signed and therefore deliberately not verified - the point is
    # that Actual answers, not that TLS is trusted on loopback.
    healthcheck:
      test: ["CMD", "node", "-e", "require('https').get({host:'127.0.0.1',port:5006,path:'/health',rejectUnauthorized:false,timeout:5000},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 60s
EOF
ok "wrote compose file"

cd "$APP_DIR" && docker compose up -d
ok "actual budget converged"
log "open: https://$(hostname):5006"
