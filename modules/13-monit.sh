#!/usr/bin/env bash
# Monitoring: Monit checks this machine every 30s, acts where it can and
# pushes to the phone via ntfy. healthchecks.io covers what nothing on the
# machine can - the machine itself being dead or frozen.
#
# Monit runs on the host, not in Docker and not from /data, so it keeps
# working when exactly those break. The checks themselves live in
# bin/homelab-check.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

ENV_DATA=/data/homelab/notify.env
ENV_FILE=/etc/homelab/notify.env

apt-get install -y monit >/dev/null
ok "monit installed"

# ---------- notification settings ----------
# The ntfy topic is the only thing protecting the alerts - anyone who knows it
# can read and post - so it is random and kept out of the repo. Generated once
# and kept on /data, so a reset does not unsubscribe the phone; copied to
# /etc so alerting still works when /data is the thing that broke.
if [[ -f "$ENV_DATA" ]]; then
    skip "notification settings present"
else
    mkdir -p "$(dirname "$ENV_DATA")"
    cat > "$ENV_DATA" <<EOF
NTFY_URL=https://ntfy.sh/homelab-$(openssl rand -hex 8)
# Ping URL from healthchecks.io, e.g. https://hc-ping.com/<uuid>
HC_URL=${HOMELAB_HC_URL:-}
EOF
    chmod 600 "$ENV_DATA"
    ok "generated notification settings"
fi
install -D -m 600 "$ENV_DATA" "$ENV_FILE"
log "subscribe in the ntfy app to: $(sed -n 's/^NTFY_URL=//p' "$ENV_FILE")"

# ---------- monit checks ----------
# exec fires on a change of state only (failed, then recovered), so a problem
# that persists notifies once rather than every cycle.
NOTIFY='exec "/usr/local/sbin/homelab-notify"'
cat > /etc/monit/conf.d/homelab <<EOF
set daemon 30
set httpd port 2812 and use address localhost allow localhost

check program data with path "/usr/local/sbin/homelab-check data"
    if status != 0 then $NOTIFY else if succeeded then $NOTIFY
check program restarts with path "/usr/local/sbin/homelab-check restarts"
    if status != 0 then $NOTIFY else if succeeded then $NOTIFY
check program docker with path "/usr/local/sbin/homelab-check docker"
    if status != 0 for 2 cycles then $NOTIFY else if succeeded then $NOTIFY
check program unhealthy with path "/usr/local/sbin/homelab-check unhealthy"
    if status != 0 for 3 cycles then $NOTIFY else if succeeded then $NOTIFY
check program backup with path "/usr/local/sbin/homelab-check backup"
    if status != 0 then $NOTIFY else if succeeded then $NOTIFY
check program kmem with path "/usr/local/sbin/homelab-check kmem"
    if status != 0 then $NOTIFY else if succeeded then $NOTIFY
check program temp with path "/usr/local/sbin/homelab-check temp"
    if status != 0 for 4 cycles then $NOTIFY else if succeeded then $NOTIFY

check system \$HOST
    if memory usage > 90% for 10 cycles then $NOTIFY else if succeeded then $NOTIFY
    if swap usage > 80% for 10 cycles then $NOTIFY else if succeeded then $NOTIFY

check filesystem rootfs with path /
    if space usage > 85% then $NOTIFY else if succeeded then $NOTIFY
check filesystem datafs with path $DATA_DIR
    if space usage > 85% then $NOTIFY else if succeeded then $NOTIFY
EOF
monit -t || die "monit config invalid"

# Replaces Debian's unit, whose sandbox hides /home - where bin/ and so the
# check scripts live - and withholds what stopping Docker needs. Restart on
# any failure, not just crashes: a monitor that quietly exits is worse than none.
cat > /etc/systemd/system/monit.service <<'EOF'
[Unit]
Description=Pro-active monitoring utility for unix systems
Documentation=man:monit(1) https://mmonit.com/wiki/Monit/HowTo
After=network-online.target

[Service]
ExecStart=/usr/bin/monit -I
ExecStop=/usr/bin/monit quit
ExecReload=/usr/bin/monit reload
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q monit
systemctl restart monit
ok "monit checks active"

# ---------- healthchecks.io ----------
# Pings every 5 minutes; healthchecks.io alerts when the pings stop.
cat > /etc/cron.d/homelab-healthcheck <<'EOF'
*/5 * * * * root . /etc/homelab/notify.env && [ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL"
EOF
if grep -q '^HC_URL=.' "$ENV_FILE"; then
    ok "healthchecks.io ping every 5 minutes"
else
    warn "no healthchecks.io URL yet - set HC_URL in $ENV_DATA and re-run this module"
fi
