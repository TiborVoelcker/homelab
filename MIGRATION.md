# Migration to x86: FUJITSU ESPRIMO Q556/2

**TEMPORARY.** Working notes for the move off the Pi, written 2026-10-22 while
the new machine was still headless. Delete this file once the migration has
landed: everything in it either becomes code, or becomes a paragraph in a
module header or in `AGENTS.md`, which is where this repo keeps its reasoning.

Nothing here has run on the new hardware. Every claim about Debian on x86 or
about this board is marked where it needs confirming, and "Verify first" at the
bottom collects the commands.

## State on 2026-10-24

Carried over from the Pi agent's memory, which did not survive the Pi.

- **The Q556/2 has a console now.** A Debian 13 "rescue" OS runs from the
  internal HDD (`sda`, 1 TB Seagate ST1000LX015). It is a stopgap, not the
  target install.
- **The SSD is NVMe**, not SATA: `nvme0n1`, 447 GB Corsair Force MP510. It
  still holds Windows (ESP, MSR, NTFS system and recovery partitions).
  Confirmed wipeable: nothing of value on it.
- **The Pi is stopped on purpose.** Its `/data` USB stick became the (failed)
  rescue stick, so `/data` there is an empty mountpoint. All six containers
  were `docker compose stop`ped, and `docker.service` refuses to start because
  of the `/data` guard in `02-data.sh`. That is the guard working; do not
  "fix" it.
- **`/data` content exists in two places:**
  `homelab-data-2026-10-22.tar.gz` (21 MB, checksum-verified, copied off the
  Pi's `/var/backups/homelab-data-2026-10-22`; a copy is in `~tibor` on the
  rescue HDD), and restic snapshot `1b2a34cf` on Google Drive. The tarball
  carries `homelab/backup.env` and `homelab/rclone.conf` itself. The restic
  route needs those from elsewhere: the restic password must be in the
  password manager before the Pi is wiped, since nothing else can decrypt the
  backups.

## What is changing

| | Pi | Q556/2 |
| --- | --- | --- |
| Boot | Raspberry Pi firmware, `autoboot.txt`, `tryboot` | UEFI, GRUB, `BootNext` |
| Partition table | MBR, four primaries, hard limit | GPT, no practical limit |
| OS | Raspberry Pi OS (Debian trixie) | Debian 13 (trixie), amd64 |
| System disk | SD card | internal SSD |
| `/data` | external USB disk, forced off-disk by the MBR limit | a partition like any other |
| Second disk | none | internal HDD, previously used, condition unknown |
| RAM | 2GB | to be confirmed on first boot |

The service layer is unaffected. All five images are multi-arch, so
`20-paperless` through `24-actualbudget` should come up unchanged. The work is
all in the boot, storage and tuning layers.

## The reset button is a wiping tool

`AGENTS.md` currently frames the baseline as recovery - "if the live system
gets into a bad state, restore a pristine copy". That is not what it is for.
It is a **wipe-and-rebuild button**: a way to get back to a clean slate and
re-provision from this repo without preparing external media and without the
whole SSH-into-a-rescue-system dance. Recovery is a side effect of that, not
the goal.

This matters for the port, because the two framings lead to different
decisions. Framed as recovery, the baseline competes with a rescue USB stick
and loses the moment the machine has a working display output. Framed as a
wiping tool, the USB stick is not a substitute at all - the whole value is that
nothing has to be prepared. So the mechanism gets ported, not dropped, and when
porting forces a choice it goes the way that keeps "one command, one reboot,
no media".

`AGENTS.md` already uses this framing (fixed 2026-10-24).

## tryboot -> UEFI BootNext

`BootNext` is a UEFI variable naming one boot entry to use for the next boot
only. It is the genuine analogue of `tryboot`, down to the fail-safe: the
firmware is specified to clear it before attempting that boot, so a power cut
or a baseline that fails to start lands back on the normal `BootOrder` with no
action needed. **Confirm on this board** - the documented intent is clear, this
firmware's actual behaviour is not yet tested.

Set and inspected with `efibootmgr`:

```
efibootmgr -v                 # BootCurrent, BootOrder, BootNext if set
efibootmgr -n <num>           # set BootNext
efibootmgr -N                 # delete BootNext
```

### Layout

Each root carries its **own `/boot`**, as an ordinary directory, not a separate
partition. Do not let the installer put `/boot` on its own partition. This is
cleaner than the Pi ever managed: kernels and `grub.cfg` live inside the
filesystem they belong to, so a kernel upgrade on the live system cannot reach
the baseline's kernel, which is the entire point the two-boot-partition layout
existed to achieve.

The ESPs are the only shared-looking thing, and they are kept separate too:

```
SSD (GPT)
  p1  ESP-A    512M  vfat   live system's EFI, bootloader-id "debian"
  p2  rootA     60G  ext4   live system, carries its own /boot
  p3  ESP-B    512M  vfat   baseline's EFI, bootloader-id "homelab-baseline"
  p4  rootB     20G  ext4   baseline (only ever a pristine install: ~6G used)
  p5  data     rest  ext4   /data

HDD
  one partition, role still to be decided - see "The HDD" below
```

Debian's ESP holds `shimx64.efi`, `grubx64.efi` and a stub `grub.cfg` that does
`search --fs-uuid <root-uuid>` and then `configfile /boot/grub/grub.cfg`. So
one UUID per ESP is the whole of the binding, and ESP-A points at rootA while
ESP-B points at rootB. That is the x86 spelling of "each system mounts its own
boot partition".

Give the two installs **different `--bootloader-id` values**, or they write
colliding NVRAM entries and you cannot tell them apart in `efibootmgr -v`.

### The three gates

| Pi | x86 |
| --- | --- |
| `/etc/homelab-role` says `baseline` | unchanged |
| booted via tryboot | the baseline is **absent from `BootOrder`** |
| arm marker on bootB | arm marker on ESP-B |

The middle gate gets *stronger*, not weaker. On the Pi, "was this a tryboot
boot" had to be read out of the device tree. Here, if the baseline entry is
never placed in `BootOrder`, then the only ways to boot it at all are a
deliberate `BootNext` or someone standing at the machine picking it out of the
firmware menu. Booting it is inherently deliberate, so the property the gate
was checking is a consequence of the layout rather than something to test.

Keep the arm marker anyway. It is what makes booting the baseline by hand safe,
and it is one `touch`.

### The one genuinely new piece of machinery

On the Pi, restoring the boot side was an `rsync` of a FAT partition and a
`sed` on `cmdline.txt`. On x86 a bootloader is not just files, so `reset-main.sh`
gains a step.

What does **not** need fixing, pleasantly: the reset restores by rsyncing into
an existing filesystem, and that does not change the filesystem's UUID. So
rootA's UUID is stable across a reset, and **ESP-A needs no changes at all** -
its stub still points at the right place.

What does need fixing is inside the restored root, which has just been
overwritten with rootB's copies of two UUID-bearing files:

- `/etc/fstab` - retarget at rootA and ESP-A. This is today's
  `retarget_fstab()`, except matching on filesystem UUID instead of
  `PARTUUID=<diskid>-NN`, which is an MBR-only convention.
- `/boot/grub/grub.cfg` - came from rootB and names rootB's UUID in every
  `linux` line. Regenerate rather than patch: chroot into the restored rootA
  with `/dev`, `/proc` and `/sys` bind-mounted, then `update-grub` and
  `grub-install --no-nvram --efi-directory=/boot/efi`.

`--no-nvram` matters. Without it the baseline rewrites NVRAM and `BootOrder`
while running, which is the one piece of state a reset must leave alone.

Sed-ing the UUIDs in `grub.cfg` would avoid the chroot and is tempting. It is
also exactly the kind of shortcut that works until a GRUB update changes the
file's shape, and it fails by leaving an unbootable live system - the single
worst failure this repo can have. Use the chroot.

## Module by module

| Path | On Debian/x86 | Action |
| --- | --- | --- |
| `lib/common.sh` | `need_tryboot_support`, MBR guard in `detect_disk`, `partuuid_for`, `add_cmdline_params`, `set_cmdline_root` all Pi-only | Rewrite that layer for GPT + UUIDs + `efibootmgr`. Output helpers, guards, `age_days`/`human_age`, rsync helpers all stay. |
| `install.sh` | works | unchanged |
| `00-storage.sh` | dies twice over | The Debian installer does the partitioning. Replace with a **verify-only** module that asserts the five-partition layout and fails loudly if it is wrong. Deleting it outright loses the one place that documents the layout in executable form. |
| `01-create-baseline.sh` | dies: `autoboot.txt`, `cmdline.txt` | Rewrite: rsync to rootB, retarget its fstab, `grub-install` into ESP-B with its own bootloader-id, create the NVRAM entry, then **remove it from `BootOrder`**. |
| `02-data.sh` | `detect_disk`'s MBR guard dies; rest is sound | See "/data" below. |
| `03-upgrade.sh` | works | Keep. Overlaps `unattended-upgrades` if that gets installed. |
| `04-journal.sh` | works, reasoning is probably wrong | Stock Debian should keep the journal on disk (confirm: `/var/log/journal` exists), so the RPi-OS `Storage=volatile` story no longer applies. Keep the module for the 200M cap; rewrite the header. |
| `05-arp.sh` | harmless, pointless | The whole rationale is "eth0 and wlan0 share one subnet". Delete if the Q556/2 is single-homed. |
| `06-mdns.sh` | works | Keep. Already skips absent units, and avahi may not even be installed. `<host>.fritz.box` naming is unaffected. |
| `08-psi.sh` | dies on missing `cmdline.txt`; also unnecessary | Delete once `/proc/pressure` is confirmed present. |
| `09-headless.sh` | dies; meaningless | Delete. No firmware GPU reservation, no `vcgencmd`. |
| `10-cgroups.sh` | dies; unnecessary | Delete once the memory controller is confirmed on. |
| `11-docker.sh` | works | Keep. Same Debian trixie packages as the Pi, where `docker-compose` is already Compose v2. |
| `12-claude-code.sh` | works | Keep. Installer is a `curl` script, arch-neutral. Drop the "~285MB of RAM" caveat. |
| `13-monit.sh` | works | Keep; recalibrate thresholds. |
| `20`-`24` | work | Unchanged. All images are multi-arch. |
| `25-backup.sh` | works | Keep. Possibly extend for a second repo - see "The HDD". |
| `bin/homelab-backup` | works | Keep. Fixed 2026-10-22: decides what is a database by content, not by filename. |
| `bin/homelab-check` | `temp` threshold is Pi-calibrated | Recalibrate `temp`, `kmem`, memory/swap. |
| `bin/homelab-reset` | tryboot | Rewrite around `efibootmgr -n`. |
| `bin/homelab-status` | tryboot, MBR | Rewrite: boot entries, `BootNext`, GPT partitions, baseline age. |
| `bin/homelab-forget-data-disk` | works | Keep. |
| `reset/reset-main.sh` | tryboot, cmdline, no GRUB step | Rewrite per above. |
| `.claude/worktrees/restic-default-repo/` | untracked duplicate of the whole repo | Delete. It shadows every grep. |

## Debian on x86 traps

The Pi already ran Debian trixie, so the package layer carries over as-is.
What differs is the installer and the firmware.

1. **Swap must stay outside the rsync scope.** `RSYNC_EXCLUDES` excludes
   `/var/swap`, the Raspberry Pi OS path. The layout above has no swap
   partition; if a swapfile is added, exclude its path too. Miss this and every
   baseline capture and every reset copies a multi-gigabyte swapfile.
2. **`unattended-upgrades`** may get installed depending on what the installer
   is told. Kernel upgrades would then land unasked. The per-root `/boot`
   layout means they cannot touch the baseline, so this is safe - but decide
   deliberately, given `03-upgrade.sh` already upgrades on every `install.sh`.
3. **Secure Boot can stay enabled.** Debian's shim is Microsoft-signed, for
   both ESPs. Worth stating plainly because the opposite is true of the rescue
   stick we built, and that difference is the most likely reason the stick did
   not come up.
4. **Networking is `ifupdown`** (`/etc/network/interfaces`) on a netinst
   install without a desktop. Any static-IP decision belongs there.
5. **No `fsck.repair=yes`.** The stock Pi cmdline carried it, which is what ran
   `e2fsck -y` unattended and destroyed `/data` on 2026-10-17. Debian on x86
   has no such default, so the hazard is genuinely different - but keep
   `passno=0` and `errors=remount-ro` anyway. The lesson was that unattended
   repair did the damage, and that has not changed. Rewrite `02-data.sh`'s
   header so the next reader is not misled about why those settings are there.

## /data

GPT has no four-primary limit, so the constraint that forced `/data` onto a
separate USB disk is gone and it becomes an ordinary partition.

**Keep** the three layers that earned their place: `RequiresMountsFor`, the
`.homelab-data` marker, and the read-write `ExecStartPre` check. That trio is
why Docker refused to start on 2026-10-22 when `/data` was pulled out from
under it, instead of Home Assistant quietly reinitialising an empty
configuration onto the system disk. It is the most valuable twelve lines in the
repo.

**Consider dropping** the UUID-keyed udev rule and the `Upholds=docker.service`
drop-in on the mount unit. They exist because a USB hotplug elsewhere on the
bus - the Thread radio, specifically - could reset the controller and knock the
disk offline mid-session. Internal SATA does not do that. They are harmless if
kept; this is a simplification, not a fix.

## The HDD

Decide its role from its SMART data, not in advance - it is an old disk.

The case for `/data` on the **SSD** rather than the HDD: SQLite is the one
workload here that would actually notice a spinning disk.

That frees the HDD for the more interesting job: a **local restic repository**
as a second backup tier. Restores in seconds instead of over Google Drive, no
API rate limits, and it speaks directly to the incident that `25-backup.sh`
exists because of. `bin/homelab-backup` would loop over two repositories; Drive
stays as the off-site copy, because a second copy inside the same box is not an
off-site backup and does not replace one.

## Monit recalibration

Every threshold in `13-monit.sh` and `bin/homelab-check` was tuned to a 2GB Pi.

- `temp` trips at 75C because a Pi throttles at 80. An i5-class desktop CPU can
  sit near 75 under normal load and throttles around 100. Also confirm which
  `thermal_zone` is real on this board - x86 often exposes an `acpitz` zone
  that reports something unrelated to the CPU.
- `kmem`'s 200MB ceiling was calibrated against one specific Pi leak from
  container crash-looping.
- `check system` memory at 90% and swap at 80% assume 2GB and an SD card.

## Open decisions

1. `/data` on the SSD, with the HDD as a local restic repo - or `/data` on the
   HDD? Depends on its SMART report.
2. rootB size. 20G is generous for a pristine Debian install; the only cost of
   generosity is SSD space.
3. Keep `unattended-upgrades`, or leave upgrades to `03-upgrade.sh`?
4. Delete `05-arp.sh`, or keep it as harmless insurance in case a second NIC
   or Wi-Fi ever gets used?
5. Rename the repo. "raspi-config" stops being true.
6. Does the Thread radio move across as-is? It is the same USB dongle, so
   `22-otbr.sh`'s `/dev/serial/by-id` pinning should just work, but the pin
   file on `/data` names the old path and may need clearing.

## Verify first

On the new machine, before writing any code:

```
# the two modules we plan to delete - confirm they are unnecessary
ls /proc/pressure                          # expect cpu, io, memory
cat /sys/fs/cgroup/cgroup.controllers      # expect "memory" present

# BootNext really is one-shot on this firmware
efibootmgr -v                              # note BootOrder and BootCurrent
efibootmgr -n <other-entry> && reboot      # then check BootNext is gone
# and that an entry absent from BootOrder is genuinely not booted by accident

# thermal zones: which one is the CPU
for z in /sys/class/thermal/thermal_zone*; do echo "$z $(cat $z/type) $(cat $z/temp)"; done

# the disks, before trusting either of them
smartctl -a /dev/sda                       # HDD
smartctl -a /dev/nvme0n1                   # SSD

# what the box actually is
dmidecode -t system -t baseboard -t processor -t memory
lscpu
```

## Provisioning order

1. ~~Get a console on it.~~ Done 2026-10-24: rescue OS on the HDD, and the
   SSD's Windows is confirmed wipeable.
2. Read the SMART data on both disks and decide the HDD's role.
3. Install Debian 13 (netinst, no desktop) to the SSD with the manual
   partition layout above: ESP-A, rootA, ESP-B (leave unformatted or format vfat, unmounted),
   rootB (leave empty), data. `/boot` **not** separate. Nothing mounted at
   `/data` yet.
4. Run the "Verify first" commands and record the answers here.
5. Clone this repo, then port in dependency order: `lib/common.sh` first, then
   `00-storage` as a verifier, then `02-data`, then the deletions, then
   `01-create-baseline` and `reset/`, which are the real work.
6. Move `/data` across from `homelab-data-2026-10-22.tar.gz`, or restore
   restic snapshot `1b2a34cf`. The tarball is the faster path and was verified
   byte-for-byte; restic is the one that proves the backups work. Do the
   restic restore at least once as a drill.
7. Exercise the reset once, before trusting it, on a system that has nothing to
   lose yet.
