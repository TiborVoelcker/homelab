#!/usr/bin/env bash
# Install Claude Code for the account that ran install.sh, and keep a session
# of it running with Remote Control enabled, so the Pi can be driven from a
# phone without SSHing in first.
#
# The one place in the repo that pipes curl into a shell: there is no Debian
# package, and the npm package needs Node 22 where trixie ships 20. The
# installer works per-home rather than system-wide, so it runs as $SUDO_USER -
# root would get its own copy in /root, which is not the one you type `claude`
# at.
#
# Three things decide the shape of the service:
#
#   Remote Control needs an INTERACTIVE session, so it needs a pty. tmux
#   supplies one and has the side benefit that the same session can be
#   attached to locally with `tmux attach -t claude`.
#
#   It is a system unit with User= rather than a user unit, because lingering
#   is off for this account (`loginctl show-user`: Linger=no) and a user unit
#   would only start when somebody logs in - which is exactly the case this is
#   meant to avoid.
#
#   Authentication is a file, ~/.claude/.credentials.json, so it survives a
#   reboot unattended. If the OAuth token ever fully expires the session will
#   come up sitting at a login prompt with nobody watching, which is what
#   remain-on-exit below is for: the window stays so the reason is visible.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"

need_root
need_cmd curl

# Optional tooling: a missing $SUDO_USER should not abort provisioning.
user="${SUDO_USER:-}"
if [[ -z "$user" || "$user" == root ]]; then
    warn "no SUDO_USER - skipping claude code (run install.sh with sudo from your own account)"
    exit 0
fi
home=$(getent passwd "$user" | cut -d: -f6)
[[ -n "$home" && -d "$home" ]] || die "cannot find a home directory for $user"
WORKSPACE="$home/claude_workspace"
UNIT=/etc/systemd/system/claude-remote.service

# ---------- install ----------
if sudo -u "$user" -H bash -lc 'command -v claude' >/dev/null 2>&1; then
    skip "claude code already installed for $user"
else
    log "installing claude code for $user"
    # pipefail inside the inner shell too: without it a failed download reports
    # success, because the exit status is bash's after reading nothing at all.
    sudo -u "$user" -H bash -lc \
        'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash' \
        || die "the claude code installer failed"

    sudo -u "$user" -H bash -lc 'command -v claude' >/dev/null 2>&1 \
        || die "claude is not on $user's PATH after installing - open a new shell and check ~/.local/bin"
    ok "installed claude code for $user"
fi

apt-get install -y tmux >/dev/null
ok "tmux installed"

install -d -o "$user" -g "$user" -m 755 "$WORKSPACE"

# ---------- the session ----------
# Type=oneshot with RemainAfterExit: `tmux new-session -d` returns as soon as
# the tmux server has the session, so there is no long-running foreground
# process for systemd to track. Deliberately NOT --dangerously-skip-permissions:
# this session is reachable by anyone who can reach the Anthropic account, and
# sudo here needs no password, so it must keep asking before it acts.
unit=$(cat <<EOF
[Unit]
Description=Claude Code with Remote Control, in a tmux session
Documentation=man:tmux(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
WorkingDirectory=$WORKSPACE
Environment=HOME=$home
ExecStart=/usr/bin/tmux new-session -d -s claude -c $WORKSPACE $home/.local/bin/claude --remote-control
# Keeps the pane after claude exits, so a failed login or a crash can be read
# with \`tmux attach -t claude\` instead of vanishing with the session.
ExecStartPost=/usr/bin/tmux set-option -t claude remain-on-exit on
ExecStop=/usr/bin/tmux kill-session -t claude

[Install]
WantedBy=multi-user.target
EOF
)
if [[ "$(cat "$UNIT" 2>/dev/null)" == "$unit" ]]; then
    skip "claude-remote.service present"
else
    printf '%s\n' "$unit" > "$UNIT"
    systemctl daemon-reload
    ok "wrote claude-remote.service"
fi

systemctl enable claude-remote.service >/dev/null 2>&1 \
    && ok "claude code will start with remote control at boot" \
    || warn "could not enable claude-remote.service"
log "attach locally with: tmux attach -t claude"
log "a session costs ~200-320MB of RAM, which is material on this Pi -"
log "stop it with: sudo systemctl stop claude-remote"
