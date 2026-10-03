#!/usr/bin/env bash
# Example service module. The shape to copy for the rest of the stack:
#   1. directories on the DATA partition, so a reset preserves them
#   2. config from upstream, fetched once
#   3. secrets generated once, guarded
#   4. `docker compose up -d` - already idempotent, needs no guard
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

APP_DIR=/opt/paperless
DATA=/data/paperless

mkdir -p "$APP_DIR" "$DATA"/{data,media,export,consume}

if [[ -f "$APP_DIR/docker-compose.yml" ]]; then
    skip "compose file present"
else
    curl -fsSL -o "$APP_DIR/docker-compose.yml" \
      https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/main/docker/compose/docker-compose.sqlite.yml
    ok "fetched compose file"
fi

# Generate the secret exactly once - regenerating it would orphan existing data.
if [[ -f "$APP_DIR/docker-compose.env" ]]; then
    skip "env file present"
else
    cat > "$APP_DIR/docker-compose.env" <<EOF
PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
PAPERLESS_TIME_ZONE=Europe/Berlin
PAPERLESS_OCR_LANGUAGE=deu+eng
EOF
    chmod 600 "$APP_DIR/docker-compose.env"
    ok "generated env file"
fi

# Memory caps, as a compose override rather than an edit to the file above:
# that one comes from upstream and is fetched once, so editing it would be
# undone by a re-fetch and would conflict on upstream changes. Compose merges
# docker-compose.override.yml automatically. Written every run, because unlike
# the upstream file this one is ours and re-writing it is how an edit here
# reaches the Pi.
#
# Paperless is the greediest service on a 2GB Pi: OCR on a large scan can
# balloon the webserver container well past its idle ~200MB. Without a cap the
# kernel's OOM killer picks a victim by its own heuristics when memory runs
# out, and Home Assistant - large and long-lived - is an attractive target. A
# cap means a runaway OCR job dies instead of taking the house automation with
# it. 768M leaves normal OCR plenty of room while still bounding the worst
# case; the broker is a small key-value store and never needs much.
#
# This is only enforceable because modules/10-cgroups.sh turned on the memory
# controller - without it Docker ignores these silently.
cat > "$APP_DIR/docker-compose.override.yml" <<EOF
services:
  webserver:
    mem_limit: 768m
  broker:
    mem_limit: 128m
EOF
ok "wrote memory caps override"

cd "$APP_DIR" && docker compose up -d
ok "paperless converged"
