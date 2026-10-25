#!/usr/bin/env bash
# Upgrade the OS, every time install.sh runs - and only then. Deliberately no
# unattended-upgrades: nothing changes on this machine between runs that the
# repo did not ask for. To bring it up to date, run install.sh again (a reset
# followed by install.sh does the same from a clean slate). A kernel update
# needs a reboot, which this reports below rather than doing.
set -euo pipefail
source "${REPO_DIR:?}/lib/common.sh"
need_root

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
ok "system upgraded"

if [[ -f /run/reboot-required ]]; then
    warn "reboot required to finish the upgrade"
fi
