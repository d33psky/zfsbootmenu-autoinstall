# CLAUDE.md - ZFS Install Script

## Overview

Standalone ZFS root installation script with ZFSBootMenu. Supports UEFI (rEFInd) and BIOS (syslinux) boot modes.

## Files

- `zfs-install.sh` - Main install script (standalone, config-driven; UEFI/rEFInd or BIOS/syslinux)
- `zfs-mirror.sh` - Add a mirror disk to an existing zroot pool (UEFI or BIOS); also installs deps + the ESP-sync hook
- `configs/` - Config files. Public samples only: `host.conf.sample` (annotated template) plus `qemu-uefi-test.conf` / `qemu-bios-test.conf`. Bring your own per-host config and pass its path as the first argument (kept in a separate private repo)
- `examples/` - `user-data.sample.yaml` for the headless harness (copy to `test/user-data`, add your SSH pubkey)
- `test-uefi-headless.sh` - **Fully headless** harness: cloud-init-seeded Ubuntu cloud image as the live env, driven entirely over SSH (no GUI). Preferred for automated testing
- `test-uefi-qemu.sh` - UEFI (OVMF) harness with two serial'd disks (interactive live-ISO install)
- `test-bios-qemu.sh` - BIOS (syslinux) harness
- `test/` - QEMU scratch, **gitignored** (disks, OVMF NVRAM, seed.iso, cloud image, serial logs)

## QEMU Testing

### Headless UEFI testing (preferred)

`test-uefi-headless.sh` runs the whole install / mirror / degraded-boot cycle with **no GUI** - it boots an Ubuntu
cloud image as the live environment (cloud-init from `test/user-data` injects an SSH key + ZFS tooling) with two
blank target disks `virtio-nvme0`/`virtio-nvme1`, so everything is driven over `ssh -p 2222`.

```bash
./test-uefi-qemu.sh create        # make the two blank target disks (uefi-nvme0/1.qcow2)
./test-uefi-headless.sh prep      # build seed.iso + live overlay + a fresh writable OVMF NVRAM
./test-uefi-headless.sh live      # boot cloud image + both targets (run in background)
# then over ssh ubuntu@localhost -p 2222: scp the scripts+config, run zfs-install.sh initial, then zfs-mirror.sh -r
./test-uefi-headless.sh installed # boot ONLY the target disks (no cloud image) = the real installed system
```
To simulate **nvme0 death**, boot a QEMU with only `uefi-nvme1.qcow2` attached, reusing `OVMF_VARS_headless.fd`
(it holds the rEFInd boot entries). A correctly-fixed install comes up `running` with a DEGRADED pool, unattended.

Notes:
- Cloud image `noble-server-cloudimg-amd64.img` is downloaded once into `test/`; the cloud-init user + your SSH pubkey come from `test/user-data` (copy it from `examples/user-data.sample.yaml`).
- The cloud live env's hostid becomes the pool's hostid; the install copies it to the target (see fault-tolerance section).
- Reuse ONE `OVMF_VARS_headless.fd` across live/installed/degraded boots so `efibootmgr` entries persist.
- **Never** run two QEMUs against the same qcow2 at once (corruption). Confirm the prior VM is gone with `ps -C qemu-system-x86_64` before the next boot. `pkill -f <pattern>` can match its own shell - prefer killing by PID.

### Prerequisites

- KVM-capable host (`/dev/kvm`)
- Ubuntu live server ISO (symlinked to `test/live.iso`)
- `qemu-system-x86_64`, `qemu-img`, `sshpass`

### Setup

```bash
cd test/

# Create or recreate test disk (20G)
rm -f test-disk.qcow2
qemu-img create -f qcow2 test-disk.qcow2 20G

# Symlink ISO (if not done)
ln -sf /path/to/ubuntu-24.04.1-live-server-amd64.iso live.iso
```

### Boot from live ISO (for initial install)

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -m 4G \
  -smp 2 \
  -drive file=test-disk.qcow2,format=qcow2,if=none,id=test-disk \
  -device virtio-blk-pci,drive=test-disk,serial=test-disk \
  -cdrom live.iso \
  -boot d \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::2222-:22 \
  -display gtk \
  -vga std
```

### Key: virtio disk serial number

The `-device virtio-blk-pci,drive=test-disk,serial=test-disk` is critical.
Without the `serial=` parameter, the disk will NOT appear in `/dev/disk/by-id/`.
The disk shows up as `/dev/disk/by-id/virtio-test-disk`.

Do NOT put `serial=` on the `-drive` line - qcow2 format does not support it.
Must use separate `-drive if=none,id=...` + `-device virtio-blk-pci,drive=...,serial=...`.

### In the live VM

The live server ISO boots to the Subiquity installer. To get a shell:
- Select "Help" in the installer menu (Alt+F2 may be captured by the host desktop)
- Install openssh-server: `apt update && apt install -y openssh-server`
- Set root password: `passwd root` (to allow SSH login)
- Permit root login: `echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && systemctl restart ssh`

Then from the host:
```bash
scp -P 2222 ../zfs-install.sh ../configs/qemu-bios-test.conf root@localhost:/root/
ssh -p 2222 root@localhost
cd /root && ./zfs-install.sh qemu-bios-test.conf initial
```

### Boot from installed disk (testing the result)

```bash
qemu-system-x86_64 \
  -enable-kvm \
  -m 4G \
  -smp 2 \
  -drive file=test-disk.qcow2,format=qcow2,if=none,id=test-disk \
  -device virtio-blk-pci,drive=test-disk,serial=test-disk \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::2222-:22 \
  -display gtk \
  -vga std
```

No `-cdrom` and no `-boot d` - boots from disk via syslinux -> ZFSBootMenu -> Ubuntu.

SSH in with the user/password from the config file:
```bash
sshpass -p '<password>' ssh -p 2222 <user>@localhost
```

### Host key changes

Each fresh install generates new SSH host keys. Clear old ones:
```bash
ssh-keygen -f ~/.ssh/known_hosts -R '[localhost]:2222'
```

### Gotchas

- 9p virtfs with `security_model=mapped-xattr` breaks on symlinks; use `passthrough` or just scp files
- The live server ISO Subiquity installer captures Alt+F2; use the Help menu instead
- After install, `zpool list` needs sudo (the test user isn't root)
- **Serial shows only up to the EFI stub** (`EFI stub: Loaded initrd...`) then goes quiet - the kernel console is tty0, not ttyS0, unless you add `console=ttyS0,115200` to the ZBM cmdline (`refind_linux.conf` options) and/or `org.zfsbootmenu:commandline`. Quiet serial after the stub is NOT a hang.
- **`spl_hostid=` on the kernel cmdline is parsed DECIMAL** unless it has hex letters or a `0x` prefix. `zdb` prints hostid in DECIMAL; `hostid`(1) and `/etc/hostid` are HEX. Mixing these up silently sets the wrong hostid - and writing to the pool then stamps it into the labels.
- **`generate-zbm` names the kernel image `vmlinuz.old-bootmenu`** even on a fresh build - cosmetic; rEFInd auto-scans and boots it fine.

## Config file format

```bash
DISKID="virtio-test-disk"      # /dev/disk/by-id/ name (no path prefix)
HOSTNAME="qemu-test"
USERNAME="test"
USERPASS="test"
TIMEZONE="UTC"
POOL_NAME="zroot"              # default: zroot
COMPRESSION="lz4"              # default: lz4
UBUNTU_VER="noble"             # default: noble
DISTRO="server"                # server or kubuntu
SWAP_SIZE="0"                  # MB, 0 = no swap
BOOT_MODE="uefi"               # uefi or bios (default: uefi)
# --- optional, for production / bounded-root layouts ---
BOOT_SIZE="512M"               # ESP/boot partition size (sgdisk syntax). Use 1G for prod boxes (ZBM image headroom)
ROOT_SIZE="0"                  # 0 = root takes the whole disk. If set (e.g. 600G), root is bounded and the
                               #     REMAINDER becomes a reserved BF00 partition (part3) - intended for a later
                               #     vdev such as a ZFS `special` vdev. zfs-mirror.sh replicates
                               #     this layout (incl. part3) to the mirror disk.
ASHIFT="12"                    # ZFS pool ashift (default 12 = 4K)
NETPLAN_FILE="configs/foo.yaml" # if set, this netplan YAML is installed verbatim; else DHCP autoconfig
MIRRORDISKID="ata-..."         # mirror disk for zfs-mirror.sh (optional)
# --- optional, native ZFS encryption (see configs/host.conf.sample for the full model) ---
ENCRYPTION="on"                # aes-256-gcm on the pool root; default off
KEYFILE="myhost.key"           # raw 32 bytes, install-time; keep with PRIVATE configs, never in this repo
ZBM_KEYFETCH_URL="https://10.0.0.2:8443/keys/myhost.key" # ZBM fetches at boot (IP-literal; no DNS in initramfs)
ZBM_KEYFETCH_CA="ca.pem"       # pin the key server's self-signed cert (optional)
ZBM_NET_ARGS="rd.neednet=1 ip=...:vlan40:none vlan=vlan40:eth0" # dracut net for the ZBM initramfs
ZBM_DROPBEAR="on"              # dropbear ssh in ZBM for remote rescue (default off; port 222)
```

Layout with `ROOT_SIZE` set (bounded-root shape): `p1` ESP, `p2` zroot (ROOT_SIZE), `p3` reserved (rest).
Without it: `p1` ESP, `p2` zroot (whole disk). Swap, if any, is a partition between ESP and root.

### Encryption model (ENCRYPTION=on)

- Pool root is the encryptionroot (`keyformat=raw`, key = KEYFILE). `keylocation` points at
  `/etc/zfs/<pool>.key`, a path valid in the live env at create time AND inside the encrypted
  root afterwards (`setup_encryption_target`). An initramfs-tools hook embeds the key in the
  TARGET initrd - which itself lives on the encrypted root (ZBM reads it post-unlock), so the
  key never touches plaintext storage and the kexec'd system boots without prompting.
- The ZBM image unlocks the pool via a **`load-key.d` hook** (`hooks/load-key.d/keyfetch.sh`,
  written directly into the target by the installer - deliberately NOT via the nested chroot
  script, to avoid multi-level heredoc escaping): retry-loop `curl` of ZBM_KEYFETCH_URL, then
  `zfs load-key -L`. ⚠️ load-key.d is the ONLY correct stage: it runs immediately before every
  unlock attempt, countdown included - `setup.d` hooks are SKIPPED when the zbm.timeout
  countdown expires, so a keyfetch there never runs unattended (validated the hard way).
  Networking rides INSIDE the image via `/etc/cmdline.d/dracut-network.conf`
  (`install_optional_items`) - ZBM_NET_ARGS never touches the bootloader entries; only
  CMDLINE_EXTRA (kernel-proper params like console=) is patched into those.
- Dropbear (`ZBM_DROPBEAR=on`) uses the dracut-crypt-ssh module per the upstream ZBM
  remote-access docs: host keys are **OpenSSH PEM** (`ssh-keygen -m PEM`, converted by the
  module via dropbearconvert - dropbearkey-native keys break that), `cryptsetup` must be
  installed (the module depends on dracut's `crypt` module), and the LUKS console/unlock
  helper lines are stripped from module-setup.sh (compiled binaries we don't build). Host
  keys are generated once into `/etc/dropbear/` so rebuilt images keep a stable ssh identity.
  Rescue flow (validated in the harness): ssh -p 222 root@box -> push key ->
  `zfs load-key -L file:///tmp/k <pool>` -> run `zbm` -> select BE -> boots.
- Rerun/reuse safety: cleanup labelclears BOTH the target disk AND MIRRORDISKID (a stale pool
  label on a reused second disk fails the target initramfs with "more than one matching
  pool"), dies loudly if a leftover pool stays imported (reboot the live env then), and the
  final export warns visibly on failure.

## Install flow

1. `initial` action (from live USB/ISO):
   - Partitions disk, creates ZFS pool+datasets
   - Debootstraps minimal Ubuntu
   - Installs kernel, ZFS, ZFSBootMenu
   - Sets up syslinux (BIOS) or rEFInd (UEFI)
   - Installs openssh-server (SSH available on first boot)
   - Creates user, preserves install files

2. `postreboot` action (via SSH after first boot):
   - `apt dist-upgrade`
   - Installs `ubuntu-server` or `kubuntu-desktop`
   - Configures NetworkManager if desktop variant

## Adding a ZFS root mirror

Use `zfs-mirror.sh` to add a second disk as a mirror to an existing single-disk zroot pool.
The config file must define `MIRRORDISKID` (the `/dev/disk/by-id/` name of the mirror disk).
**Supports both UEFI (rEFInd) and BIOS (syslinux).**

```bash
# On the target host (run from the booted system):
sudo ./zfs-mirror.sh <conf> -d    # dry run
sudo ./zfs-mirror.sh <conf> -r    # run for real
```

Steps performed:
1. `ensure_deps` - apt-installs `gdisk dosfstools rsync efibootmgr util-linux` if missing (a minimal install lacks them)
2. Validates disks/pool (primary in pool, pool not already mirrored, mirror disk blank, sane layout incl. `EF00`)
3. Copies the **whole** partition table primary -> mirror (`sgdisk -R` + `-G` to randomize GUIDs). This replicates `part3` (the reserved special-vdev slice) too.
4. Boot setup on the mirror:
   - **UEFI**: format mirror ESP (FAT32), `rsync` the primary `/boot/efi` (rEFInd + ZBM images) onto it, register a 2nd UEFI boot entry via `efibootmgr` (so the box still boots if the primary disk dies).
   - **BIOS**: format boot part, copy syslinux files, install MBR.
5. `wipefs` the mirror ZFS partition, `zpool attach` (resilver starts automatically).
6. **UEFI only**: installs the **ESP-sync hook** (see below).

### ESP-sync hook
The two ESPs are independent FAT32 filesystems - **ZFS does not mirror them**. Without syncing, the mirror ESP
keeps the install-time images and goes stale after a kernel/ZBM update, so a later boot from the surviving disk
could run an outdated/incompatible image. `zfs-mirror.sh` installs:
- `/usr/local/sbin/sync-esp-mirror` - rsync `/boot/efi` -> mirror ESP (mirror ESP found by baked-in PARTUUID; no-op if the disk is absent)
- `/etc/kernel/postinst.d/zzz-sync-esp-mirror` - runs it after kernel/initramfs updates (also safe to run by hand after `generate-zbm`)

## Mirror fault-tolerance: two things a mirror needs to actually boot on one disk (CRITICAL)

A ZFS root **mirror is not automatically fault-tolerant for boot.** Two bugs (found 2026-06 by simulating a dead
disk in QEMU) each silently break single-disk-failure boot - both are now fixed in `zfs-install.sh`:

1. **Consistent hostid.** The pool records the hostid of the system that created it. If the installed system (and
   the ZBM image it builds) carry a *different* `/etc/hostid`, then an **unclean + degraded** import (the exact
   state after a disk dies + reboot) is **refused** -> ZBM loops `"Unable to import pool"`. (A clean pool, or a
   pool with all disks present, imports leniently and hides the bug.) Fix: `zfs-install.sh` ensures `/etc/hostid`
   exists before pool creation and **copies it into the target** before the zfs packages would `zgenhostid` a new
   one - so pool labels, installed system, and ZBM all share one hostid.
2. **`nofail` on the ESP mount.** `/boot/efi` is mounted by the primary ESP's UUID. If that disk is gone, the
   mount fails -> `local-fs.target` fails -> **emergency mode**. Fix: `/boot/efi` (and `/boot/syslinux`) get
   `nofail,x-systemd.device-timeout=5s`. The `[DEPEND] Dependency failed for boot-efi.mount` log line then becomes
   cosmetic - boot continues to the login prompt. (The ESP is only needed for bootloader *updates*, never at runtime.)

### In-place remediation runbook (rescue a box that won't boot degraded, no wipe)
On the affected box (boot it with the surviving disk, or temporarily both):
```bash
# 1. find the pool's hostid (zdb prints it in DECIMAL; convert to hex)
zdb -l /dev/disk/by-id/<surviving>-part2 | grep hostid     # e.g. 275762177
printf '0x%08x\n' 275762177                                # -> 0x106fcc01
# 2. align /etc/hostid to the pool, rebuild the ZBM image so its initramfs carries the matching hostid
zgenhostid -f 0x106fcc01
generate-zbm
# 3. refresh the mirror ESP, and make /boot/efi non-fatal
rsync -a /boot/efi/ /mnt/<mirror-esp>/      # or: /usr/local/sbin/sync-esp-mirror
#   ensure /etc/fstab has: UUID=... /boot/efi vfat defaults,nofail,x-systemd.device-timeout=5s 0 0
```

## Logging

The script logs all output to `/var/log/zfs-install.log` via tee.
A copy is preserved to `/root/zfsbootmenu-autoinstall/zfs-install.log` on the installed system.
