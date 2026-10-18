# Storage decisions

Why `/data` is arranged the way it is, and why several tempting alternatives
were rejected. Written after 2026-10-17, when `/data` was destroyed and Home
Assistant's entire configuration was lost with it.

## What happened, in one paragraph

A USB fault on 2026-09-29 left multiply-claimed blocks on the `/data` thumb
drive. The journal replayed, which marks a filesystem *clean* without proving
its metadata consistent, so `e2fsck -a` - which skips clean filesystems -
never looked. Three weeks later `tune2fs -c 1` (added in `bdf27eb` to defeat
exactly that blind spot) forced a check at mount. The stock Raspberry Pi
cmdline carries `fsck.repair=yes`, so that check ran as `e2fsck -y`, answered
"yes" to `Resize inode not valid. Recreate?` on a filesystem whose root inode
was already damaged, declared success, and was rejected by the kernel one
second later. 2325 files became 146.

The detection was right. Pairing it with an unattended repair was not.

## The split

| | Owns | Survives |
|---|---|---|
| `~/raspi-config` | the machine's *shape*: packages, compose files, mounts, `daemon.json`, Monit, systemd drop-ins | a `homelab-reset`, an SD card failure |
| `/data` | every service's *content* | a reset, an OS rebuild |
| the backup | a copy of `/data` | losing the Pi entirely |

**The repo builds a working but empty setup; `/data` populates it.** Service
content that changes as the system is lived with - Home Assistant's
`configuration.yaml`, automations, dashboards, `.storage/`, the devices added
over time - is deliberately **not** version-controlled. Committing it would
mean either committing daily or letting the repo drift and start lying about
the real state, which would destroy the one property that makes `install.sh`
trustworthy.

The consequence is that **the backup is the only safety net for that data.**
There is no second mechanism. This is why `25-backup.sh` ranks above every
other storage improvement.

## No check and no repair at boot

`02-data.sh` sets `tune2fs -c 0 -i 0` and fstab passno `0`. Both are needed and
they are not the same thing: passno decides whether anything *runs* fsck at
boot, while the mount counter only decides what an already-running e2fsck does.
passno `0` is the half that `fsck.repair=yes` cannot override.

`fsck.repair=yes` itself is left exactly as Raspberry Pi OS ships it. It also
governs the *root* filesystem, which does want unattended repair - a headless
Pi that drops to an emergency console after a power cut is unreachable.

Detection is left to the guards that only ever **report**:

- `tune2fs -e remount-ro` on the superblock, not `errors=` in fstab, so it
  holds for a manual `mount` or a rescue boot too. A mount option would
  override the superblock, so fstab deliberately carries none.
- Monit's `data` check, which stops Docker when `/data` goes read-only.

To check deliberately: unmount and run `e2fsck -fn /dev/sdXN`. `-n` answers no
to every question, so it reports without writing a block.

## The backup

`bin/homelab-backup`, nightly at 03:30 via `homelab-backup.timer`.

SQLite cannot be copied while it is being written - a file-level copy of a live
WAL-mode database may be torn and may not open - so every database gets a
`VACUUM INTO` copy first, which takes a read transaction and needs nothing
stopped. The live files are then excluded from the backup by extension.

Two choices keep this free of per-service knowledge: the databases are
**found**, not listed, and the exclusions are globs. A service added later is
covered without editing anything. The snapshots are named `*.sqlite-snapshot`
precisely so the `*.db` and `*.sqlite3` excludes cannot swallow them.

`homelab-check backup` reports the age of the last *successful* run from a
stamp on the SD card - not on `/data`, so it still answers when `/data` is what
broke. A failed run leaves the stamp stale, so a backup that silently stops
working is a backup that pages you.

Retention is 7 daily, 4 weekly, 12 monthly. That incidentally provides the one
thing version control would have: *what did that automation look like last
week*.

**`RESTIC_PASSWORD` must exist somewhere that is not this Pi.** It is in
`/data/homelab/backup.env` and copied to `/etc/homelab/`, which covers an SD
card failure and a reset - but not losing both, and without it the backup
cannot be restored by anyone.

## Rejected alternatives

**A separate `/state` partition** for high-churn data (databases, Docker's
data-root, the journal), leaving `/data` as "everything here is backed up".
Architecturally tidy, and it would have resolved the btrfs/SQLite tension
below. Rejected because it pushes a second mount, a second gating contract and
path indirection into the base layer that every module then has to know about,
to buy an endurance optimisation that measurement showed was unnecessary. The
same invariant is achieved by a glob exclude inside one module.

**Moving the databases to the SD card.** Backwards: an SD card is the worst
endurance medium in the box and small synchronous SQLite commits are the
pathological pattern for it. It would also have been *more* work than leaving
them on `/data`, where Home Assistant puts them by default.

**Moving `/var/log/journal` and `/var/lib/docker` off the SD card.** Measured
at 50-100 MB/day, which is decades of headroom, and an SD card failure costs a
rebuild rather than data. Standard paths are worth more than the optimisation.
Replacing a seven-year-old card is the proportionate version of this worry.

**btrfs on `/data`**, for data checksums (ext4 checksums only metadata),
`scrub`, and snapshots. Still attractive and deferred rather than rejected -
its value is *detecting* corruption, which is only useful once there is a
backup to recover from. The known cost is that copy-on-write fragments SQLite
badly and the `chattr +C` fix disables the checksums it was adopted for; the
answer is a nested subvolume with `+C` on Home Assistant's config directory,
which also excludes the database from btrfs snapshots automatically. Revisit
after a restore has been tested.

**A second local copy on a 3.5" HDD.** ~6-9 W continuous against the Pi's own
3-5 W, to hold tens of megabytes, protecting against very little the first
copy does not. A cold copy powered up by hand is the better version of this
idea, and draws nothing when unplugged.
