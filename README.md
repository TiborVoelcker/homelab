# homelab

Convergent, script-driven provisioning for my homelab - a headless Fujitsu
ESPRIMO Q556/2 (x86, UEFI) that took over from a Raspberry Pi, hence the
name - plus a self-hosted "reset button": a wipe-and-reinstall without a USB
stick, a display or a second computer, just a reboot. A pristine copy of the
installed OS lives on its own partitions and can be put back at any time.
Service data lives on a separate partition, so a reset never touches it.

`install.sh` is the single source of truth for what this machine should look
like. It runs small idempotent modules and is safe to re-run. Early on it
finishes a **baseline** - the system exactly as it was installed - on its own
pair of partitions, and never touches it again.

`homelab-reset` puts that baseline back. The result is equivalent to a fresh
install, so recovery is always the same two steps: reset, then re-run
`install.sh`.

See `AGENTS.md` for how it works underneath.

## Fresh install - the one manual step

The partition layout has to exist before the OS does: the root filesystem
cannot be shrunk while it is running, so the installed system cannot make
room for the baseline itself. `modules/00-storage.sh` only checks the layout,
and stops `install.sh` if it is wrong.

From any Linux that is not running off the target SSD, with `debootstrap`,
`dosfstools` and `efibootmgr` installed. The first install ran from a Debian
system on the internal HDD, over SSH; that disk is the backup disk now, so
next time it is a Debian live USB stick, which needs a monitor and keyboard.
**This erases the whole SSD:**

```bash
DISK=/dev/nvme0n1
sudo wipefs -a "$DISK"
sudo sfdisk -q "$DISK" <<'EOF'
label: gpt
size=512MiB, type=uefi,   name=ESP-A
size=60GiB,  type=linux,  name=rootA
size=512MiB, type=uefi,   name=ESP-B
size=20GiB,  type=linux,  name=rootB
size=4GiB,   type=swap,   name=swap
             type=linux,  name=data
EOF
sudo udevadm settle

sudo mkfs.vfat -F 32 -n ESP-A "${DISK}p1"
sudo mkfs.ext4 -q -L rootA     "${DISK}p2"
sudo mkfs.vfat -F 32 -n ESP-B "${DISK}p3"
sudo mkfs.ext4 -q -L rootB     "${DISK}p4"
sudo mkswap -q -L swap         "${DISK}p5"
sudo mkfs.ext4 -q -e remount-ro -L homelab-data "${DISK}p6"
```

The `name=` values are the GPT partition labels `00-storage.sh` checks; the
partition numbers are what `lib/common.sh` relies on, so keep the order.
`/data` is ext4 specifically: exFAT and NTFS cannot store Unix ownership,
which container volumes need.

Then install Debian 13 into rootA:

```bash
sudo mkdir -p /mnt/rootA && sudo mount "${DISK}p2" /mnt/rootA
sudo debootstrap --arch=amd64 --components=main,non-free-firmware \
  --include=linux-image-amd64,grub-efi-amd64,grub-efi-amd64-signed,shim-signed,efibootmgr,openssh-server,sudo,dbus,systemd-resolved,intel-microcode,firmware-misc-nonfree,locales,ca-certificates,curl,git,rsync \
  trixie /mnt/rootA https://deb.debian.org/debian
```

`non-free-firmware` carries `intel-microcode` (the BIOS's own microcode dates
from 2018) and `firmware-misc-nonfree` (the i915 DMC firmware, without which
the GPU never reaches its low-power states). `dbus` is named because
debootstrap skips "either/or" dependencies, and `systemd-resolved` needs it.

and finish it in a chroot (with `/dev`, `/proc` and `/sys` bind-mounted, and
ESP-A at `/mnt/rootA/boot/efi`):

- `/etc/fstab` by filesystem UUID: rootA at `/` (`errors=remount-ro`, pass
  `1`), ESP-A at `/boot/efi` (`umask=0077`, pass `2`), the swap partition.
  No `/data` line - `02-data.sh` adds it.
- `/etc/hostname`, and `systemd-networkd` with DHCP on the NIC
  (`/etc/systemd/network/20-wired.network`). Purge `ifupdown`, which
  debootstrap installs anyway, so there is one network stack.
- A user in group `sudo` with your SSH key in `~/.ssh/authorized_keys`.
- `update-grub`, then `grub-install --target=x86_64-efi
  --efi-directory=/boot/efi --bootloader-id=debian --uefi-secure-boot
  --no-nvram`, and outside the chroot `efibootmgr -C --disk "$DISK" --part 1
  --label homelab --loader '\EFI\debian\shimx64.efi'`. Secure Boot can stay
  on: the shim is Microsoft-signed.

Boot it once with `sudo efibootmgr -n <entry>`. BootNext is one-shot, so if it
fails to come up the next reboot lands back on the rescue system. Only once it
has booted, put it first with `efibootmgr -o`.

Then take the baseline's content **before anything else touches rootA** -
from the rescue system, with rootA unmounted:

```bash
sudo mount "${DISK}p2" /mnt/rootA && sudo mkdir -p /mnt/rootB && sudo mount "${DISK}p4" /mnt/rootB
sudo rsync -aHAXx --numeric-ids --delete /mnt/rootA/ /mnt/rootB/
date -Is | sudo tee /mnt/rootB/etc/homelab-baseline
sudo umount /mnt/rootA /mnt/rootB
```

Writing the stamp tells `01-create-baseline.sh` that the content is already
there, so it only makes it bootable instead of copying the running system.
Without the stamp it captures rootA as it is when `install.sh` first runs,
which is just as good as long as that is straight after the first boot.

## The data partition

`02-data.sh` mounts p6 at `/data` by UUID with `nofail`, so the system still
boots without it, and installs a systemd drop-in so Docker refuses to start
unless `/data` is mounted, writable *and* carries its marker file. Without
that guard an unmounted `/data` means bind mounts silently create empty
directories on rootA; Paperless finds no database, concludes it is a fresh
install, and initialises one there while your real documents sit untouched on
the unmounted partition - and the next reset wipes the impostor along with
whatever was written to it.

`/data` is checked at boot in fsck's preen mode, which makes only the repairs
that are safe without a human. Damage it refuses leaves `/data` unmounted,
Docker down and Monit alerting; `02-data.sh`'s header has the details.

To reformat it, copy its contents somewhere *before* running `install.sh` -
otherwise the services start fresh on an empty filesystem:

```bash
sudo systemctl stop docker.socket docker.service
sudo rsync -aHAX /data/ /mnt/elsewhere/
sudo umount /data
sudo mkfs.ext4 -e remount-ro -L homelab-data /dev/nvme0n1p6
sudo homelab-forget-data-disk
sudo ./install.sh                      # mounts the new filesystem
sudo rsync -aHAX /mnt/elsewhere/ /data/
```

**A separate partition is not a backup.** It makes resets safe, nothing more.
`modules/25-backup.sh` backs `/data` up every night, to Google Drive and to the
internal HDD; it prints its remaining setup steps until configured.

## The backup disk

The internal HDD holds the local copy of the backup: a restic repository at
`/backup/restic`, with the same password as the one on Drive. It restores in
seconds and does not depend on the internet, but it is in the same box, so
Drive stays the off-site copy. Format it once, by hand - the scripts never
format anything. **This erases the whole HDD:**

```bash
sudo wipefs -a /dev/sda
echo 'label: gpt
type=linux, name=backup' | sudo sfdisk -q /dev/sda
sudo mkfs.ext4 -q -e remount-ro -L homelab-backup /dev/sda1
```

`25-backup.sh` finds it by that label, mounts it at `/backup` and creates the
repository. Without it only the Drive copy is made; once it is in fstab, a
missing HDD fails the nightly backup, so Monit reports it.

To restore, from either copy (the Drive one needs no HDD):

```bash
sudo bash -c 'set -a; source /data/homelab/backup.env; set +a
  RESTIC_REPOSITORY=/backup/restic restic snapshots'   # drop RESTIC_REPOSITORY=... for Drive
sudo bash -c 'set -a; source /data/homelab/backup.env; set +a
  RESTIC_REPOSITORY=/backup/restic restic restore latest --target /var/tmp/restore'
```

Databases come back as `*.sqlite-snapshot` copies under `snapshots/`, taken
consistently while the services ran: copy each one over its original path
(minus the suffix) with the service stopped.

## BIOS

The board runs BIOS R1.19.0 from 2018. Fujitsu's R1.35.0 package is in
`/data/homelab/bios/`. Flashing it needs a monitor and keyboard: a failed or
interrupted flash may leave nothing to SSH into.

## Install

```bash
git clone <this-repo> ~/homelab
cd ~/homelab
sudo ./install.sh
```

**Run it early** if rootB has no stamp yet. `01-create-baseline.sh` then
captures the baseline from whatever state the system is in at that moment,
and never recaptures. A fresh install gives you a clean baseline; a system you
have been using for six months bakes those six months in permanently.

Re-run any time. Every module no-ops where its work is already done, so adding
a module and re-running only does the new work.

Before trusting any of it: try a real reset with a throwaway change in place,
and check it actually disappears.

## Day to day

```bash
sudo homelab-status          # boot entries, partitions, /data, baseline age, armed?
sudo homelab-reset           # wipe live, overwrite with baseline
```

Recovery is always the same two steps:

```bash
sudo homelab-reset           # reboots twice, lands on the pristine system
sudo ./install.sh            # rebuilds the homelab on top
```

`homelab-reset` shows when the baseline was captured and asks for confirmation
before it arms anything. It refuses outright if there is no baseline.

A reset wipes **all** of rootA, `/home` included: your clone of this repo,
Claude Code's login, anything in your home directory. Push the repo first and
keep anything else you need on `/data`. After the reset, clone the repo again
and run `install.sh`; `02-data.sh` re-adds the `/data` fstab line by itself.

### Watching a reset

The baseline keeps the live system's hostname, address and SSH host keys, so
you can log in while it works:

```bash
sudo tail -f /boot/efi/homelab-reset.log
```

The rootfs copy reports progress, so that line moves. Your session drops when
it finishes and reboots - that is how you know it is done.

Afterwards the log is on ESP-B, which the live system does not mount:

```bash
sudo mount /dev/nvme0n1p3 /mnt && sudo cat /mnt/homelab-reset.log; sudo umount /mnt
```

The reset before it is kept alongside as `homelab-reset.log.prev`. These are
the first place to look if a reset did not do what you expected.

If the baseline fails to start, BootNext is already used up, so the next
reboot lands on the live system untouched. To disarm by hand - say a reset
failed partway and you do not want the next baseline boot to retry - remove
the marker from that same partition:

```bash
sudo mount /dev/nvme0n1p3 /mnt && sudo rm /mnt/homelab-reset.arm && sudo umount /mnt
```

To look at the baseline, mount `p4` from the live system rather than booting
it. Booting it directly is safe - unless it came up through its own boot entry
with an arm marker present, the reset service exits immediately.

### Recapturing the baseline

Normally you never do this. But the baseline is never apt-upgraded, so after a
Debian major release upgrade it can be old enough that its apt sources no
longer resolve - at which point a reset lands you somewhere `install.sh` cannot
build on.

Delete the stamp and re-run from a system as close to a fresh install as you
can manage; whatever is live at that moment becomes the new baseline:

```bash
sudo mount /dev/nvme0n1p4 /mnt
sudo rm /mnt/etc/homelab-baseline /mnt/etc/homelab-role
sudo umount /mnt
sudo ./install.sh
```

## Things to keep in mind

**Service data belongs on `/data`.** Anything under `/opt` or `/var/lib` is in
the reset scope and gets rolled back. `20-paperless.sh` shows the split: config
in `/opt`, state in `/data`.

**A reset goes all the way back to the fresh install**, not to yesterday. If
you want "the state I had last Tuesday", this is the wrong tool - back up
`/data` and keep your changes in `install.sh`.

**This protects against a broken system, not dead hardware.** A dead SSD takes
the baseline and `/data` with it; the off-site backup is the disaster recovery
answer.

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

Not a Docker container? Give its unit `RequiresMountsFor=/data`, the same
guard `02-data.sh` gives Docker.
