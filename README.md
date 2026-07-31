# zfsbootmenu-autoinstall

Config-driven, unattended installer for a **ZFS root pool** (currently limited to Ubuntu) booted by [ZFSBootMenu](https://github.com/zbm-dev/zfsbootmenu).
Script `zfs-install.sh` partitions a disk, builds the pool, debootstraps Ubuntu, and sets up the bootloader with UEFI (rEFInd) or BIOS (syslinux).
Script `zfs-mirror.sh` adds a **fault-tolerant root mirror** that allows booting when one disk dies.

It is built to be driven by unattended automation (Ansible, OpenTofu/Terraform, or your own glue): every choice comes from a config file passed as an argument, and the flow runs non-interactively over SSH.

If unattended automation is no requirement then it is probably easier to use Sithuk's [ubuntu-server-zfsbootmenu](https://github.com/Sithuk/ubuntu-server-zfsbootmenu) which also offers more options.

## Features

- Ubuntu root-on-ZFS with ZFSBootMenu
- **UEFI (rEFInd)** and **BIOS (syslinux)** boot modes
- Fully **config-driven**, no interactive prompts; ideal for automation
- Optional **root mirror** (`zfs-mirror.sh`) with two fixes that make a degraded pool boot unattended on a single surviving disk (consistent hostid + `nofail` ESP mount)
- ESP-sync hook keeps the mirror's EFI partition current after kernel/ZBM updates
- Optional bounded root + reserved partition (e.g. for a later ZFS `special` vdev)
- Optional **native ZFS encryption** (aes-256-gcm) with **unattended remote unlock**:
  the ZFSBootMenu initramfs brings up static networking (VLANs supported, unicast
  only) and fetches the pool key over HTTP(S) from a key server you control; the
  target initramfs carries the key *inside the encrypted root*, so the key never
  touches plaintext storage. Falls back to a console prompt if the fetch fails
- Optional **dropbear ssh in the ZBM initramfs** (pubkey-only) to remotely rescue a
  stuck boot - diagnose, or paste the key by hand (`zfs load-key -L file:///tmp/key`)
- Headless **QEMU test harness** that exercises install -> mirror -> dead-disk boot

## Future plans

- Debian support

## Requirements

- A target booted into an Ubuntu **live environment** (live server ISO, or a cloud image as used by the test harness) with network access, run as root

## Quick start

```bash
# 1. From the live environment, fetch the scripts and your config:
git clone https://github.com/d33psky/zfsbootmenu-autoinstall.git
cd zfsbootmenu-autoinstall

# 2. Create a config for your host (start from the annotated template):
cp configs/host.conf.sample configs/myhost.conf
${EDITOR:-vim} configs/myhost.conf        # set DISKID, HOSTNAME, USERNAME, ...

# 3. Install (partitions the disk, builds the pool, installs Ubuntu + ZFSBootMenu):
sudo ./zfs-install.sh configs/myhost.conf initial

# 4. Reboot into the new system, then finish setup over SSH:
sudo /root/zfsbootmenu-autoinstall/zfs-install.sh configs/myhost.conf postreboot
```

`DISKID` / `MIRRORDISKID` use `/dev/disk/by-id/` names (no path prefix) so they are stable across reboots. List them with `ls -l /dev/disk/by-id/`.

## Configuration

All behaviour comes from a config file. See [`configs/host.conf.sample`](configs/host.conf.sample) for every option with inline documentation.
The `configs/qemu-*-test.conf` files are working examples used by the test harness.

**Keep real host configs out of this repo.** Maintain them in your own private repo or directory and pass the path as the first argument:
```bash
sudo ./zfs-install.sh /path/to/private-configs/myhost.conf initial
```

### Network

By default the install configures **DHCP** on the first ethernet interface. For a static address, set `NETPLAN_FILE` in your config to a [netplan](https://netplan.io/) YAML; it is installed verbatim as `/etc/netplan/01-netplan.yaml`. A relative path is resolved against the script directory.

```bash
NETPLAN_FILE="examples/netplan-static.yaml"
```

See [`examples/netplan-static.yaml`](examples/netplan-static.yaml) for an annotated static-IPv4 template (including how to pin an interface name by MAC address). Find the live-environment interface name with `ip -br link`.

## Adding a root mirror

`zfs-mirror.sh` attaches a second disk as a mirror of an existing single-disk
`zroot` pool (UEFI or BIOS). The config must define `MIRRORDISKID`.

```bash
sudo ./zfs-mirror.sh configs/myhost.conf -d    # dry run
sudo ./zfs-mirror.sh configs/myhost.conf -r    # run for real
```

It copies the partition table to the mirror, sets up its bootloader/ESP, `zpool attach`es it (resilver starts automatically), and installs an ESP-sync hook so the mirror's EFI partition stays current.

A mirror is not automatically fault-tolerant *for boot*. Two issues silently break single-disk-failure boot, both handled here:
1. **Consistent hostid** an unclean + degraded import is refused if the installed system / ZBM image carry a different `/etc/hostid` than the pool.
2. **`nofail` ESP mount** a missing primary ESP otherwise drops the box to emergency mode.

Full explanation and an in-place rescue runbook are in
[`CLAUDE.md`](CLAUDE.md#mirror-fault-tolerance-two-things-a-mirror-needs-to-actually-boot-on-one-disk-critical).

## Testing

QEMU harnesses allows testing the whole flow without dedicated hardware.
The headless UEFI harness boots an Ubuntu cloud image as the live environment and drives the install over SSH:

```bash
./test-uefi-qemu.sh create        # two blank target disks
cp examples/user-data.sample.yaml test/user-data   # add your SSH pubkey
./test-uefi-headless.sh prep
./test-uefi-headless.sh live      # boot live env + targets (background)
# ... ssh in, run zfs-install.sh + zfs-mirror.sh ...
./test-uefi-headless.sh installed # boot only the targets = the real installed system
```
To simulate a dead disk, boot with only the mirror disk attached: a correct install comes up `running` with a `DEGRADED` pool, unattended.
See also [`CLAUDE.md`](CLAUDE.md) for the BIOS harness and details.

## Credits

- [ZFSBootMenu](https://github.com/zbm-dev/zfsbootmenu) the boot environment this repo builds on. MIT.
- [OpenZFS root-on-ZFS guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/) the canonical reference for the install steps. CC BY-SA 3.0.
- [Sithuk/ubuntu-server-zfsbootmenu](https://github.com/Sithuk/ubuntu-server-zfsbootmenu) interactive alternative with more options. MIT.

## License

[MIT](LICENSE)
