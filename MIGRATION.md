# Migration to x86: what is still open

**TEMPORARY.** The move off the Raspberry Pi onto the Fujitsu ESPRIMO Q556/2
landed on 2026-10-25: boot and storage layer ported, baseline in place, `/data`
restored, every service up, and one full install-reset-reinstall cycle
exercised. How it works now is in `AGENTS.md` and `README.md`; how it got there
is in the commit history. Delete this file once the list below is empty.

1. **Restic restore drill.** `/data` came back from the Pi's tarball, not from
   restic. Restore snapshot `1b2a34cf` (or a newer one) somewhere scratch at
   least once, to prove the backups can be read. The restic password is in the
   password manager. The first backup from this machine runs on the night of
   2026-10-25.
2. **The internal HDD** still holds the Debian rescue system, and with it
   NVRAM entries `Debian rescue (shim)` (in `BootOrder` as the fallback) and a
   shim-less `debian`. Once it is no longer wanted as a fallback, it becomes
   the local restic repository: a second backup tier that restores in seconds
   and has no API rate limits, with Google Drive staying the off-site copy.
   `bin/homelab-backup` would loop over both repositories.
3. **Automatic security updates.** Nothing installs updates between
   `install.sh` runs: `unattended-upgrades` is not installed, so the stock
   `apt-daily-upgrade.timer` does nothing. Decide whether to install it (a
   kernel update would then land unasked, which the per-root `/boot` layout
   makes safe for the baseline) or to rely on running `install.sh`.
4. **Rename the repo.** "raspi-config" stopped being true. The docs already
   call it `homelab`; renaming on GitHub keeps a redirect from the old URL.
   Then update the clone path on this machine.
5. **BIOS** is R1.19.0 from 2018; Fujitsu's R1.35.0 package was downloaded to
   the rescue HDD. Optional, and the riskiest thing that can be done to a
   headless box: a failed flash may leave nothing to SSH into.
