# Agent notes

Context for whoever (human or AI) picks this repo up next. Keep it reflecting
current reality, not the day it was written. Each script's own header comment
explains what that script does; this file covers what you cannot see from
inside a single file. `README.md` is the setup and day-to-day guide.

## What we're trying to achieve

Reproducible, script-driven provisioning for a homelab on a Fujitsu ESPRIMO
Q556/2 (x86, UEFI, headless), plus a self-hosted "reset button": a
wipe-and-rebuild that puts back a pristine copy of the installed OS so the
repo can re-provision from a clean slate - no second computer, no prepared
media, no physical access beyond a reboot. It is a wiping tool first; getting
out of a bad state is a side effect. A rescue stick is therefore no substitute
for it, because the whole value is that nothing has to be prepared.

The design rests on one decision: **`install.sh` is the only thing that defines
the desired state.** Everything it builds is disposable, because it can be
rebuilt. So there is one path back to a known system, from any state:

```
any state     -> homelab-reset -> pristine baseline -> install.sh -> working homelab
fresh install                  -> pristine baseline -> install.sh -> working homelab
```

Those two rows must stay interchangeable. Anything that makes a reset system
differ from a fresh install is a bug.

Two mechanisms make it work:

1. **Convergent provisioning.** `install.sh` runs small idempotent modules in
   lexicographic order. Each either does its job or no-ops, so re-running after
   adding a module only does the new work.
2. **A baseline on its own partitions** (its own ESP and root), reached
   through UEFI's one-shot `BootNext`. Because each root carries its own
   `/boot` and each ESP's stub names only its own root, a kernel or GRUB
   upgrade on the live system can never disturb it.

Service state (Paperless documents, databases) lives on a **separate data
partition**, so a reset never touches it.

## The baseline

A copy of the system **exactly as it was installed**, captured once by
`01-create-baseline.sh` before any other module runs, then left alone. No
`/data` mount, no apt upgrade, no Docker, no services. Because it is never
refreshed it cannot drift, and cannot accumulate whatever you are resetting to
escape.

Worth knowing:

- A reset removes everything on rootA - packages, containers, config under
  `/opt`, and every home directory. `install.sh` puts the system back, which is
  why anything you want to survive has to live in `install.sh` or on `/data`.
- The baseline ages: it is never apt-upgraded. `03-upgrade.sh` runs on every
  `install.sh`, so the system you land on is current regardless. After a Debian
  major release upgrade, recapture it - see `README.md`.
- It is booted only to run the reset. To look at it or change it, mount `p4`
  from the live system.

## How it's wired together

### Partition layout (GPT, one SSD)

```
p1  ESP-A    512M  vfat   live system's EFI: shim, GRUB, stub grub.cfg -> rootA
p2  rootA     60G  ext4   live system, carries its own /boot
p3  ESP-B    512M  vfat   baseline's OWN EFI: stub grub.cfg -> rootB
p4  rootB     20G  ext4   baseline, carries its own /boot
p5  swap       4G  swap   outside both roots, so no rsync ever sees it
p6  data     rest  ext4   /data
```

The names are the GPT partition labels; `00-storage.sh` checks them. The
partitioning itself is done once, by hand, at install time - see `README.md`.

Each system mounts *its own* ESP at `/boot/efi`, and `/boot` is a plain
directory inside each root, never a partition of its own. Debian's ESP stub
does `search.fs_uuid <root-uuid>` and then loads that root's
`/boot/grub/grub.cfg`, so one UUID per ESP is the whole binding.

Both ESPs use the directory `\EFI\debian\`: Debian's signed GRUB has that
prefix built in, so any other bootloader-id leaves it unable to find its stub.
The two NVRAM entries are told apart by label instead - `homelab` for the
live system, `homelab-baseline` for the baseline.

The internal HDD is not part of this layout.

### BootNext

`BootNext` is a UEFI variable naming one boot entry for the next boot only.
The firmware clears it before attempting that boot, so an ordinary reboot or
a power cut always lands back on `BootOrder` with no action needed - that's
the fail-safe the whole design leans on. Confirmed on this board.

The baseline's entry is created with `efibootmgr -C`, which leaves it out of
`BootOrder`. This firmware edits NVRAM on its own, though - it has been seen
adding entries to `BootOrder` and creating extra `debian` entries pointing
straight at `grubx64.efi` - so `01-create-baseline.sh` re-checks `BootOrder`
on every run, and the reset never relies on it (see "Reset gates").

The reset boots into the baseline because you cannot rsync over the
filesystem you are running from. That is the only reason the baseline needs to
be bootable.

### Repo layout

| Path | Role |
| --- | --- |
| `install.sh` | Entry point: symlinks `bin/` into `/usr/local/sbin`, then runs `modules/*.sh` in order. |
| `lib/common.sh` | Sourced by everything, including `reset-main.sh` inside the baseline. Output helpers, guards, layout constants, boot-entry lookups, copy, fstab and bootloader primitives. |
| `modules/00-storage.sh` | Verifies the six-partition layout and that the live system runs from rootA and ESP-A. Changes nothing. |
| `modules/01-create-baseline.sh` | Captures the baseline onto rootB, once; makes ESP-B boot it; creates the `homelab-baseline` NVRAM entry and keeps it out of `BootOrder`. |
| `modules/02-data.sh` | Mounts p6 at `/data` by UUID; makes Docker refuse to start unless it is genuinely mounted and writable. Boot-checked in fsck's preen mode (passno `2`), and `errors=remount-ro` in the superblock; the module's own header explains why. |
| `modules/03-upgrade.sh` | `apt-get update && upgrade`. |
| `modules/06-mdns.sh` | Masks avahi. The host is named by the router's DNS (`<host>.fritz.box`) instead of mDNS `.local`; containers keep their own mDNS. |
| `modules/11-docker.sh` | Docker Engine + Compose plugin from Debian's repos. Owns `/etc/docker/daemon.json`, which caps every container's log at 10MB x 3. |
| `modules/12-claude-code.sh` | Claude Code, installed into `$SUDO_USER`'s home, plus `claude-remote.service`: a tmux session with Remote Control enabled, started at boot so the machine can be driven from a phone. |
| `modules/13-monit.sh` | Monit: stops Docker on a read-only `/data`, stops crash-looping containers, watches kernel memory, RAM, disk, temperature, the age of the last successful backup, and any container Docker reports unhealthy; alerts via ntfy. Plus a healthchecks.io ping every 5 min. Topic and ping URL live in `/data/homelab/notify.env`, outside the repo. |
| `modules/20-paperless.sh` | Paperless-ngx, and the template the other service modules follow. |
| `modules/21-home-assistant.sh` | Home Assistant Container - host networking, config on `/data`. |
| `modules/22-otbr.sh` | OpenThread Border Router. Needs a Thread radio on USB; skips when none is plugged in. |
| `modules/23-matter-server.sh` | python-matter-server - lets Home Assistant commission Matter (incl. Matter-over-Thread) devices. |
| `modules/24-actualbudget.sh` | Actual Budget on port 5006, HTTPS with a self-signed cert (it needs a secure context). |
| `modules/25-backup.sh` | Nightly encrypted off-site backup of `/data` with restic over rclone (Google Drive). Installs the timer; stays off until `/data/homelab/rclone.conf` exists. |
| `bin/homelab-check` | The checks Monit runs. |
| `bin/homelab-backup` | The nightly backup: `VACUUM INTO` every database on `/data`, then restic. Run by `homelab-backup.timer`. |
| `bin/homelab-forget-data-disk` | Removes the `/data` fstab line, so the next `install.sh` mounts p6 afresh. Only after reformatting the data partition. |
| `bin/homelab-notify` | Sends an ntfy push; used by Monit, usable by hand. |
| `bin/homelab-reset` | Arms the reset and reboots into the baseline via `BootNext`. |
| `bin/homelab-status` | Read-only snapshot: role, boot variables, baseline entry, partitions, `/data`, baseline age, armed? |
| `reset/reset-main.sh` | Installed into the baseline as `/usr/local/sbin/homelab-reset-main`. Overwrites rootA with itself and makes it bootable again, behind three gates. |
| `reset/homelab-reset-main.service` | Runs `reset-main.sh` at boot on the baseline. |

**Module numbering is load-bearing.** `01-create-baseline.sh` captures the
baseline, so everything numbered after it is by definition absent from that
baseline. A new module that must survive a reset does not exist - put its state
on `/data` instead.

### Reset gates

`homelab-reset-main` runs on every baseline boot and refuses to do anything
unless all three hold:

1. `/etc/homelab-role` says `baseline` - we are not the live system
2. `BootCurrent` is the `homelab-baseline` entry - it was deliberate, not the
   firmware falling through to the baseline after the live entry failed
3. the arm marker exists on ESP-B - a reset was actually requested

`homelab-reset` sets up gates 2 and 3. The marker lives on **ESP-B**, not
ESP-A: each system mounts its own ESP, so a marker on ESP-A would be invisible
to the baseline, and `arm_reset()` in `lib/common.sh` mounts ESP-B explicitly
to place it. The marker is the gate that actually holds.

### The capture/reset pair

`01-create-baseline.sh` makes four changes to the clone: retarget its fstab at
ESP-B/rootB, regenerate its `grub.cfg` for rootB (with GRUB on ESP-B), write
`baseline` to the role file, and install the reset machinery.
`reset/reset-main.sh` undoes exactly those on the way back. **Change one and
check the other** - an edit with no inverse is silently inherited by the live
system after a reset.

ESP-A needs nothing on the way back: the reset rsyncs into the existing rootA
filesystem, which keeps its UUID, so ESP-A's stub still points at it. The
reset regenerates rootA's `grub.cfg` in a chroot rather than patching UUIDs
with sed, because a patch that misses after a GRUB update leaves an unbootable
live system - the worst failure this repo can have. Every `grub-install` runs
with `--no-nvram`: NVRAM is changed only by `01-create-baseline.sh`.

That list is also the complete set of ways the baseline differs from a fresh
install, which is why it is worth keeping short.

## Current status

The boot and storage layer has been ported from the Raspberry Pi to this
machine and the baseline is in place, but a reset has **not** yet been
exercised here. `MIGRATION.md` tracks what is left.

## Things to watch for when extending this

- New service modules follow `20-paperless.sh`: state on `/data`, everything
  else treated as disposable by a reset, and a `healthcheck:` in the compose
  file. Without one the container counts as unwatched: Docker reports it `Up`
  as long as its PID 1 lives, which says nothing about the service inside.
  `otbr-agent` crash-looped for 18 days behind the s6 supervisor in its own
  image while `docker ps` looked fine. `homelab-check unhealthy` reports
  whatever the probes find, so the probe is the part that has to exist.
- A new service needs **no backup changes**. `bin/homelab-backup` finds every
  `*.db` and `*.sqlite3` under `/data`, takes a `VACUUM INTO` copy of each one
  whose header really is SQLite, and excludes the live files by glob. A file
  that only looks like a database by its name is reported and skipped, not
  treated as a failure. Just put the service's state on `/data`. Do
  not give a snapshot its source's extension, or the excludes will swallow it.
- Compose files are written from unquoted heredocs, so a backtick or a bare
  `$` in one - including in a YAML comment - is expanded by the shell before
  it reaches the file.
- A module that runs a service outside Docker (not the `20-paperless.sh`
  pattern) and needs `/data` present to start must give its unit
  `RequiresMountsFor=/data`, the same guard `modules/02-data.sh` gives Docker.
  Docker-based modules don't need this.
- Never regenerate a secret that already exists on disk - that orphans whatever
  data was encrypted or keyed with the old one. `RESTIC_PASSWORD` is the worst
  case: it is the only thing that can decrypt the backups, and it needs a copy
  somewhere that is not this machine at all.
- Keep the baseline minimal. Every addition is a way a reset system can
  differ from a fresh install.
- `reset-main.sh` runs from a copy of `lib/common.sh` installed at
  `/usr/local/lib/homelab/common.sh`. A new `common.sh` helper that assumes it
  is running on the live system will break the reset side.
- A change made only on the live machine is temporary: the next reset wipes
  it. If it should last, it goes in a module.
- The repo builds the shape of the system; `/data` holds its content. Home
  Assistant mixes config and content in one directory, so all of it counts as
  content and is **never committed** - it changes too often for the repo to
  stay truthful. Backups are its only safety net.
- Write docs and comments for someone seeing this repo for the first time.
  Explain what is here and why it works this way; leave what it replaced to the
  commit history.
- No `docs/` folder and no decision records. Rationale for shipped behaviour
  goes in its module's header comment, repo-wide conventions here, setup in
  `README.md`. Ideas that were not taken are not recorded anywhere.
