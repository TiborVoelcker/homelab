#!/usr/bin/env bash
# Install Docker Engine + the Compose plugin from Debian's own repos - no
# third-party apt source or curl-pipe-to-shell needed.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    skip "docker and the compose plugin already installed"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y docker.io docker-compose
    ok "installed docker.io + docker-compose"
fi

# Service modules all use `docker compose`. A package providing only the
# standalone docker-compose binary would install cleanly and then fail in
# 20-paperless.sh instead of here.
docker compose version >/dev/null 2>&1 \
    || die "'docker compose' is not available - the installed compose package does not provide the CLI plugin"

# Container stdout lands in /var/lib/docker/containers/<id>/<id>-json.log on
# the SD card, and the json-file driver keeps every line of it forever by
# default. That had already cost 2.8GB here: 1.6GB of Home Assistant and 1.3GB
# of OTBR, which runs at its most verbose log level. Nothing reads logs that
# old, and writing them is wear on the card that also carries the baseline a
# reset restores from.
#
# Capping it on the daemon rather than per service is what makes it cover
# paperless as well: that compose file comes from upstream and is fetched once,
# so it is not ours to add a `logging:` block to. 10m x 3 bounds each container
# at 30MB, and the stack as it stands at under 200MB.
#
# This file is ours in the same sense as the compose files - written whole, so
# an edit here reaches the host. Anything else that ever needs a daemon-wide
# Docker setting belongs in this block, not in a second writer.
DAEMON_JSON=/etc/docker/daemon.json
mkdir -p "$(dirname "$DAEMON_JSON")"

desired=$(mktemp)
cat > "$desired" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

if cmp -s "$desired" "$DAEMON_JSON"; then
    rm -f "$desired"
    skip "container log limits already in place"
else
    mv "$desired" "$DAEMON_JSON"
    chmod 644 "$DAEMON_JSON"
    ok "capped container logs at 10MB x 3 per container"
    # A daemon that is already up has to be restarted to read this; one that is
    # down picks it up from the `enable --now` below.
    #
    # Either way Docker applies the limit when a container is *created*, and
    # the `docker compose up -d` in each service module only recreates a
    # container whose own config changed - daemon.json is not part of that. So
    # containers predating this block keep logging without a limit until
    # something recreates them explicitly:
    #
    #     cd /opt/<service> && docker compose up -d --force-recreate
    #
    # On a reset there is nothing to migrate: every container is created fresh
    # by install.sh, after this module has run.
    if systemctl is-active --quiet docker; then
        systemctl restart docker
        ok "restarted docker to apply it"
    fi
fi

systemctl enable --now docker >/dev/null
ok "docker running"
