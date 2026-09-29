# Agent notes

Context for whoever (human or AI) picks this repo up next. Keep it reflecting
current reality, not the day it was written. Each script's own header comment
explains what that script does; this file covers what you cannot see from
inside a single file. `README.md` is the setup and day-to-day guide.

## What we're trying to achieve

Reproducible, script-driven provisioning for a Raspberry Pi homelab, plus a
self-hosted "reset button": if the live system gets into a bad state, restore
a pristine copy of the flashed OS - no second computer, no fresh SD card, no
physical access beyond a reboot.

The design rests on one decision: **`install.sh` is the only thing that defines
the desired state.** Everything it builds is disposable, because it can be
rebuilt. So recovery is one path, whatever went wrong:

```
bad state -> homelab-reset -> pristine baseline -> install.sh -> working homelab
fresh card                 -> pristine baseline -> install.sh -> working homelab
```

Those two rows must stay interchangeable. Anything that makes a reset system
differ from a freshly flashed one is a bug.

Two mechanisms make it work:

1. **Convergent provisioning.** `install.sh` runs small idempotent modules in
   lexicographic order. Each either does its job or no-ops, so re-running after
   adding a module only does the new work.
2. **A baseline on its own partitions**, carved out of unallocated space at the
   end of the SD card and reached through the firmware's `tryboot` mechanism.
   Its own boot partition means a kernel upgrade on the live system can never
   disturb it.

Service state (Paperless documents, databases) lives on a **separate external
disk**, so a reset never touches it.

## The baseline

A copy of the system **exactly as it came off the SD card image**, captured
once by `01-create-baseline.sh` before any other module runs, then left alone.
No `/data` mount, no apt upgrade, no Docker, no services. Because it is never
refreshed it cannot drift, and cannot accumulate whatever you are resetting to
escape.

Worth knowing:

- A reset removes everything - packages, containers, config under `/opt`.
  `install.sh` puts it back, which is why anything you want to survive has to
  live in `install.sh` or on `/data`.
- The baseline ages: it is never apt-upgraded. `03-upgrade.sh` runs on every
  `install.sh`, so the system you land on is current regardless. After a Debian
  major release upgrade, recapture it - see `README.md`.
- It is booted only to run the reset. To look at it or change it, mount `p4`
  from the live system.

## How it's wired together

### Partition layout (MBR, four primaries, no extended container)

```
p1  FAT32  bootA   live system's boot partition, holds autoboot.txt
p2  ext4   rootA   live system
p3  FAT32  bootB   baseline's OWN boot partition
p4  ext4   rootB   baseline
```

Plus a separate USB disk at `/data`. Putting `/data` on its own disk is what
frees the fourth MBR slot for rootB, and it keeps service data out of the reset
scope entirely.

Each system mounts *its own* boot partition at `/boot/firmware`. That is the
whole point of the layout: a kernel upgrade on one cannot touch the other's
kernel, overlays or cmdline.

`p3`/`p4` are carved from unallocated space at the end of the card, which is
why the card must **not** auto-expand `p2` on first boot - a mounted ext4
filesystem cannot be shrunk, so this has to be handled before the first boot,
not fixed up after. See `README.md`, "Before first boot".

### tryboot / autoboot.txt

`autoboot.txt` (on bootA) drives the switch between live and baseline:

```
[all]
tryboot_a_b=1
boot_partition=1

[tryboot]
boot_partition=3
```

`tryboot_a_b=1` makes the firmware read the ordinary `config.txt` from
whichever partition it lands on, so the switch happens at the *partition*
level rather than by swapping individual files. The tryboot flag is one-shot
and cannot be set by a cold boot, so an ordinary reboot or a power cut always
lands back on bootA with no action needed - that's the fail-safe the whole
design leans on.

The reset boots into the baseline because you cannot rsync over the
filesystem you are running from. That is the only reason the baseline needs to
be bootable.

### Repo layout

| Path | Role |
| --- | --- |
| `install.sh` | Entry point: symlinks `bin/` into `/usr/local/sbin`, then runs `modules/*.sh` in order. |
| `lib/common.sh` | Sourced by everything, including `reset-main.sh` inside the baseline. Output helpers, guards, layout constants, copy primitives. |
| `modules/00-storage.sh` | Carves `p3`/`p4` out of unallocated space. |
| `modules/01-create-baseline.sh` | Captures the baseline onto `p3`/`p4`, once; writes `autoboot.txt`. |
| `modules/02-data.sh` | Mounts the external disk at `/data` by UUID; makes Docker refuse to start unless it is genuinely mounted; recovers on its own (remount + `Upholds=`) if the disk drops out mid-session. |
| `modules/03-upgrade.sh` | `apt-get update && upgrade`. |
| `modules/11-docker.sh` | Docker Engine + Compose plugin from Debian's repos. |
| `modules/12-claude-code.sh` | Claude Code, installed into `$SUDO_USER`'s home. |
| `modules/20-paperless.sh` | Paperless-ngx, and the template the other service modules follow. |
| `modules/21-home-assistant.sh` | Home Assistant Container - host networking, config on `/data`. |
| `modules/22-otbr.sh` | OpenThread Border Router. Needs a Thread radio on USB; skips when none is plugged in. |
| `modules/23-matter-server.sh` | python-matter-server - lets Home Assistant commission Matter (incl. Matter-over-Thread) devices. |
| `bin/homelab-reset` | Arms the reset and triggers a tryboot. |
| `bin/homelab-status` | Read-only snapshot: role, tryboot, partitions, `/data`, baseline age, armed? |
| `reset/reset-main.sh` | Installed into the baseline as `/usr/local/sbin/homelab-reset-main`. Overwrites `p1`/`p2` with itself, behind three gates. |
| `reset/homelab-reset-main.service` | Runs `reset-main.sh` at boot on the baseline. |

**Module numbering is load-bearing.** `01-create-baseline.sh` captures the
baseline, so everything numbered after it is by definition absent from that
baseline. A new module that must survive a reset does not exist - put its state
on `/data` instead.

### Reset gates

`homelab-reset-main` runs on every baseline boot and refuses to do anything
unless all three hold:

1. `/etc/homelab-role` says `baseline` - we are not the live system
2. this boot came via tryboot - it was deliberate
3. the arm marker exists on bootB - a reset was actually requested

`homelab-reset` sets up all three. The marker lives on **bootB**, not bootA:
each system mounts its own boot partition, so a marker on bootA would be
invisible to the baseline, and `arm_reset()` in `lib/common.sh` mounts bootB
explicitly to place it.

### The capture/reset pair

`01-create-baseline.sh` makes three changes to the clone: retarget its fstab at
p3/p4, write `baseline` to the role file, and install the reset machinery.
`reset/reset-main.sh` undoes exactly those on the way back, plus the cmdline.
**Change one and check the other** - an edit with no inverse is silently
inherited by the live system after a reset.

That list is also the complete set of ways the baseline differs from a freshly
flashed card, which is why it is worth keeping short.

## Current status

Everything above is implemented, and the full cycle - install, reset, reinstall
- has been exercised on real hardware.

## Things to watch for when extending this

- New service modules follow `20-paperless.sh`: state on `/data`, everything
  else treated as disposable by a reset.
- A module that runs a service outside Docker (not the `20-paperless.sh`
  pattern) and needs `/data` present to start must add its unit to the
  `Upholds=docker.service` line in `modules/02-data.sh`, or it won't come
  back on its own after a transient USB drop of the data disk. Docker-based
  modules don't need this - Docker restarts its own containers once it's
  back up.
- Never regenerate a secret that already exists on disk - that orphans whatever
  data was encrypted or keyed with the old one.
- Keep the baseline minimal. Every addition is a way a reset system can
  differ from a freshly flashed one.
- `reset-main.sh` runs from a copy of `lib/common.sh` installed at
  `/usr/local/lib/homelab/common.sh`. A new `common.sh` helper that assumes it
  is running on the live system will break the reset side.
- Write docs and comments for someone seeing this repo for the first time.
  Explain what is here and why it works this way; leave what it replaced to the
  commit history.
