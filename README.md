# raspi-homelab

Convergent, script-driven provisioning for my Raspberry Pi homelab, plus a
self-hosted "reset button": re-image the card without taking it out of the Pi.
A pristine copy of the flashed OS lives on spare SD card space and can be put
back at any time - no second computer, no card reader, just a reboot. Service
data lives on a separate external disk, so a reset never touches it.

`install.sh` is the single source of truth for what this Pi should look like.
It runs small idempotent modules and is safe to re-run. Early on it captures a
**baseline** - the system exactly as it came off the SD card image - onto its
own pair of partitions, and never touches it again.

`homelab-reset` puts that baseline back. The result is equivalent to
re-flashing the card, so recovery is always the same two steps: reset, then
re-run `install.sh`.

See `AGENTS.md` for how it works underneath.

## Before first boot - the one manual step

The baseline partitions are carved from unallocated space at the end of the
card. ext4 can be grown online but never shrunk, so if Raspberry Pi OS
auto-expands the root partition on first boot that space is gone for good.

Flash with Raspberry Pi Imager as usual (customisation is fine), then
**before the first boot** mount the small FAT partition on your laptop and
delete the `resize` token from `cmdline.txt`:

```
console=serial0,115200 console=tty1 root=PARTUUID=041bba91-02 rootfstype=ext4 fsck.repair=yes rootwait resize cfg80211.ieee80211_regdom=DE
```

Leave the rest of the line alone - anything baked into it, like the
`cfg80211.ieee80211_regdom=DE` above, is a real setting and must stay. Imager's
own customisation is applied through `custom.toml` and keeps working. Check
with `lsblk` afterwards that `p2` is roughly image-sized rather than
card-sized.

If you forget, `install.sh` refuses to touch the partition table and tells you
to re-image rather than improvising.

## The data disk

Format it yourself first - the scripts never format anything:

```bash
sudo mkfs.ext4 -e remount-ro -L homelab-data /dev/sdXN
```

**ext4 specifically.** exFAT and NTFS cannot store Unix ownership, which
container volumes need.

`02-data.sh` adds an fstab entry by UUID with `nofail`, so the Pi still boots
without the disk, and installs a systemd drop-in so Docker refuses to start
unless `/data` is mounted *and* carries its marker file. Without that guard an
absent disk means bind mounts silently create empty directories under `/data`;
Paperless finds no database, concludes it is a fresh install, and initialises
one on the SD card while your real documents sit untouched on the unmounted
disk.

To replace the disk, copy its contents onto the new one *before* running
`install.sh` - otherwise the services start fresh on an empty disk:

```bash
sudo systemctl stop docker.socket docker.service
sudo rsync -aHAX /data/ /mnt/new/      # new disk mounted at /mnt/new
sudo umount /data /mnt/new
sudo homelab-forget-data-disk
sudo ./install.sh                      # pick the new disk
```

Hardware notes:

- **SSD over spinning disk.** A bus-powered HDD can exceed the Pi's USB budget
  and drop out under load. Otherwise use a powered hub.
- **Check your USB-SATA bridge.** Some enclosures misbehave with UAS on the Pi
  and can corrupt data. If yours is on a known-bad list, apply the matching
  `usb-storage.quirks` workaround in `cmdline.txt`.
- **A separate disk is not a backup.** It protects against SD card failure and
  makes resets safe, nothing more. `modules/25-backup.sh` backs `/data` up
  off-site every night; it prints its remaining setup steps until configured.

## Install

```bash
git clone <this-repo> ~/raspi-homelab
cd ~/raspi-homelab
sudo ./install.sh
```

**Run it early.** `01-create-baseline.sh` captures the baseline from whatever
state the system is in at that moment, and never recaptures. A freshly flashed
card gives you a clean baseline; a Pi you have been using for six months bakes
those six months in permanently.

Re-run any time. Every module no-ops where its work is already done, so adding
a module and re-running only does the new work.

Before trusting any of it: after the first install do a plain `sudo reboot` and
confirm you land back on the live system, which proves the tryboot fail-safe on
your hardware. Only then try a real reset, with a throwaway change in place to
check it actually disappears.

## Day to day

```bash
sudo homelab-status          # partitions, data disk, baseline age, armed?
sudo homelab-reset           # wipe live, overwrite with baseline
```

Recovery is always the same two steps:

```bash
sudo homelab-reset           # reboots twice, lands on the pristine system
sudo ./install.sh            # rebuilds the homelab on top
```

`homelab-reset` shows when the baseline was captured and asks for confirmation
before it arms anything. It refuses outright if there is no baseline.

After a reset, `02-data.sh` asks you to pick the data disk again - the reset
system has no `/data` fstab entry, just like a freshly flashed card. Your
documents are untouched on the disk; only the fstab line is rebuilt. Set
`HOMELAB_DATA_UUID` to skip the prompt:

```bash
sudo HOMELAB_DATA_UUID=<uuid> ./install.sh
```

### Watching a reset

The baseline keeps the live system's hostname, address and SSH host keys, so
you can log in while it works:

```bash
sudo tail -f /boot/firmware/homelab-reset.log
```

The rootfs copy reports progress, so that line moves. Your session drops when
it finishes and reboots - that is how you know it is done.

Afterwards the log is on bootB, which the live system does not mount:

```bash
sudo mount /dev/mmcblk0p3 /mnt && cat /mnt/homelab-reset.log
```

The reset before it is kept alongside as `homelab-reset.log.prev`. These are
the first place to look if a reset did not do what you expected.

To disarm by hand - say a reset failed partway and you want to stop it
retrying - remove the marker from that same partition:

```bash
sudo mount /dev/mmcblk0p3 /mnt && sudo rm /mnt/homelab-reset.arm && sudo umount /mnt
```

To look at the baseline, mount `p4` from the live system rather than booting
it. Booting it directly is safe - without an arm marker the reset service exits
immediately.

### Recapturing the baseline

Normally you never do this. But the baseline is never apt-upgraded, so after a
Debian major release upgrade it can be old enough that its apt sources no
longer resolve - at which point a reset lands you somewhere `install.sh` cannot
build on.

Delete the stamp and re-run from a system as close to freshly-flashed as you
can manage; whatever is live at that moment becomes the new baseline:

```bash
sudo mount /dev/mmcblk0p4 /mnt
sudo rm /mnt/etc/homelab-baseline /mnt/etc/homelab-role
sudo umount /mnt
sudo ./install.sh
```

## Things to keep in mind

**Service data belongs on `/data`.** Anything under `/opt` or `/var/lib` is in
the reset scope and gets rolled back. `20-paperless.sh` shows the split: config
in `/opt`, state in `/data`.

**A reset goes all the way back to the flashed image**, not to yesterday. If
you want "the state I had last Tuesday", this is the wrong tool - back up
`/data` and keep your changes in `install.sh`.

**Keep one physical spare.** This protects against a broken system, not dead
hardware. A second SD card with a known-good image in a drawer is the actual
disaster recovery answer.

## Adding a service

Copy `modules/20-paperless.sh`:

- directories on `/data` so a reset preserves them - and check with
  `docker compose config` that the service really mounts them. Creating the
  directories is not the same as using them, and an upstream compose file
  that declares named volumes instead will happily ignore them
- upstream config fetched once, guarded by a file test
- secrets generated once - regenerating orphans existing data
- a `healthcheck:` that asks whether the service works, not whether the port
  is open. `docker ps` says `Up` while a service crash-loops inside its own
  container; `homelab-check unhealthy` only sees what the probes report
- `docker compose up -d` unguarded; Compose reconciles state itself

Most install instructions paste in nearly verbatim. Only lines that would be
destructive to repeat need a guard.

Not a Docker container? Add its unit to the `Upholds=` line in
`modules/02-data.sh` too, or it won't come back after a `/data` drop.
