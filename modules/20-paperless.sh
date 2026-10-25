#!/usr/bin/env bash
# Example service module. The shape to copy for the rest of the stack:
#   1. directories on the DATA partition, so a reset preserves them
#   2. config from upstream, fetched once
#   3. secrets generated once, guarded, and kept on the DATA partition too
#   4. `docker compose up -d` - already idempotent, needs no guard
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

APP_DIR=/opt/paperless
DATA=/data/paperless

mkdir -p "$APP_DIR" "$DATA"/{data,media,export,consume}

# The paperless image runs as uid/gid 1000, and these are bind-mounted into it
# below. Left root-owned they mount read-only from the container's point of
# view and paperless fails on its first write.
chown 1000:1000 "$DATA"/{data,media,export,consume}

if [[ -f "$APP_DIR/docker-compose.yml" ]]; then
    skip "compose file present"
else
    curl -fsSL -o "$APP_DIR/docker-compose.yml" \
      https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/main/docker/compose/docker-compose.sqlite.yml
    ok "fetched compose file"
fi

# Generate the secret exactly once - regenerating it would orphan existing data.
# It lives on /data, because a reset wipes /opt and this module would then
# generate a new one; the upstream compose file reads it from $APP_DIR, so
# that gets a symlink.
ENV_FILE="$DATA/docker-compose.env"
if [[ -f "$ENV_FILE" ]]; then
    skip "env file present"
elif [[ -f "$APP_DIR/docker-compose.env" && ! -L "$APP_DIR/docker-compose.env" ]]; then
    mv "$APP_DIR/docker-compose.env" "$ENV_FILE"
    ok "moved env file to $ENV_FILE"
else
    cat > "$ENV_FILE" <<EOF
PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
PAPERLESS_TIME_ZONE=Europe/Berlin
PAPERLESS_OCR_LANGUAGE=deu+eng
EOF
    chmod 600 "$ENV_FILE"
    ok "generated env file"
fi
# A regular file here next to the one on /data means two secrets, and only a
# human can tell which one the data was made with.
if [[ -f "$APP_DIR/docker-compose.env" && ! -L "$APP_DIR/docker-compose.env" ]] \
    && ! cmp -s "$APP_DIR/docker-compose.env" "$ENV_FILE"; then
    die "$APP_DIR/docker-compose.env differs from $ENV_FILE - keep the right one on /data, delete the other"
fi
ln -sfn "$ENV_FILE" "$APP_DIR/docker-compose.env"

# Memory caps, as a compose override rather than an edit to the file above:
# that one comes from upstream and is fetched once, so editing it would be
# undone by a re-fetch and would conflict on upstream changes. Compose merges
# docker-compose.override.yml automatically. Written every run, because unlike
# the upstream file this one is ours and re-writing it is how an edit here
# reaches the host.
#
# Paperless is the greediest service here: OCR on a large scan can
# balloon the webserver container well past its idle ~200MB. Without a cap the
# kernel's OOM killer picks a victim by its own heuristics when memory runs
# out, and Home Assistant - large and long-lived - is an attractive target. A
# cap means a runaway OCR job dies instead of taking the house automation with
# it. 768M leaves normal OCR plenty of room while still bounding the worst
# case; the broker is a small key-value store and never needs much.
#
# Enforceable because the kernel has the cgroup memory controller on -
# without it Docker ignores these silently.
# The override also carries the volume paths, and that part is not a tuning
# choice - it is what makes the first line of this file's header true.
#
# Upstream's compose declares `data:` and `media:` as *named volumes*, which
# Docker places under /var/lib/docker/volumes on the SD card, and binds
# `./export` and `./consume` relative to this directory, i.e. also the SD card.
# A reset wipes both. So without these four lines the directories created above
# stay empty, every scanned document lives on the disposable half of this
# machine, and `homelab-reset` destroys the library. Compose merges volumes by
# target path rather than appending, so naming the same four targets here
# replaces the upstream mounts outright - check with `docker compose config`.
#
# The broker keeps its named volume on purpose: it is a Celery task queue, not
# state worth preserving, and losing it on a reset costs nothing but a few
# queued jobs.
# The healthcheck entries are the third thing this override carries. Upstream
# gives the webserver a probe but no start period, so its five retries all
# fire before Django is listening and a cold start reports "unhealthy" for a
# minute before recovering - noise that would page us on every reboot. A
# mapping merges key by key, so naming start_period alone keeps upstream's
# test command.
#
# 300s rather than something tighter because this is the slowest service here
# to come up: measured at over three minutes before it accepts a connection,
# and a cold boot with every other container starting at once is slower still.
# A dead paperless is then five minutes late to report, which costs nothing.
#
# The broker has no probe at all; valkey-cli ping is the whole question worth
# asking of a key-value store.
cat > "$APP_DIR/docker-compose.override.yml" <<EOF
services:
  webserver:
    mem_limit: 768m
    volumes:
      - $DATA/data:/usr/src/paperless/data
      - $DATA/media:/usr/src/paperless/media
      - $DATA/export:/usr/src/paperless/export
      - $DATA/consume:/usr/src/paperless/consume
    healthcheck:
      start_period: 300s
  broker:
    mem_limit: 128m
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 60s
      timeout: 5s
      retries: 3
      start_period: 30s
EOF
ok "wrote memory caps, data paths and healthchecks override"

cd "$APP_DIR" && docker compose up -d
ok "paperless converged"
