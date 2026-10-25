#!/usr/bin/env bash
# One command to converge this machine to the state described by this repo.
# Safe to re-run: every module no-ops when its work is already done.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/lib/common.sh"

need_root

if [[ "$(current_role)" == "baseline" ]]; then
    die "this is the baseline system - do not provision from here (see README)"
fi
echo main > "$ROLE_FILE"

header "homelab provisioning"
echo

header "installing helper commands"
for helper in "$REPO_DIR"/bin/*; do
    [[ -f "$helper" ]] || continue
    name=$(basename "$helper")
    link="/usr/local/sbin/$name"
    if [[ "$(readlink "$link")" == "$helper" ]]; then
        skip "$name -> $link"
        continue
    fi
    ln -sfn "$helper" "$link"
    ok "$name -> $link"
done
echo

for module in "$REPO_DIR"/modules/*.sh; do
    [[ -e "$module" ]] || continue
    name=$(basename "$module")
    header "$name"
    REPO_DIR="$REPO_DIR" bash "$module"
    echo
done

ok "done"
echo
log "homelab-reset        wipe this system back to the pristine baseline"
log "homelab-status       show partition + baseline state"
