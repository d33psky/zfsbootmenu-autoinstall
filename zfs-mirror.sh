#!/bin/bash
##
## zfs-mirror.sh - Add mirror disk to existing ZFS root pool
##
## Adds a second SSD as a mirror to an existing single-disk zroot pool.
## Copies partition table, sets up boot on the mirror disk, and attaches
## it to the ZFS pool.
##
## Supports:
##   - BIOS boot (syslinux)
##   - UEFI boot (rEFInd)
##
## Usage: sudo ./zfs-mirror.sh <config_file> [-d|-r]
##
## Config file must define MIRRORDISKID in addition to the standard variables.
##

set -euo pipefail

DRYRUN=""

##============================================================================
## Helpers
##============================================================================

log() { echo "=== $* ==="; }
die() { echo "ERROR: $*" >&2; exit 1; }

##============================================================================
## Config
##============================================================================

print_usage() {
    cat <<'USAGE'
Usage: sudo ./zfs-mirror.sh <config_file> -d|-r

  -d  Dry run (validate and show what would be done)
  -r  Run (actually perform the mirror setup)

Adds a mirror disk to an existing ZFS root pool.

Config file variables used:
  DISKID        - Primary disk ID (must match existing pool member)
  MIRRORDISKID  - Mirror disk ID (from /dev/disk/by-id/)
  POOL_NAME     - ZFS pool name (default: zroot)
  BOOT_MODE     - "bios" or "uefi" (default: bios)

Example:
  DISKID="ata-Samsung_SSD_850_EVO_250GB_S2R6NX1JB46618Y"
  MIRRORDISKID="ata-SanDisk_X300_2.5_7MM_256GB_152564404423"
  POOL_NAME="zroot"
  BOOT_MODE="bios"
USAGE
    exit 1
}

run() {
    echo "  >> $*"
    if [ -z "$DRYRUN" ]; then
        "$@"
    else
        echo "     (dry run)"
    fi
}

load_config() {
    local config_file="$1"
    [ -f "$config_file" ] || die "Config file not found: $config_file"
    # shellcheck source=/dev/null
    source "$config_file"

    for var in DISKID MIRRORDISKID; do
        [ -n "${!var:-}" ] || die "Required config variable $var is not set"
    done

    POOL_NAME="${POOL_NAME:-zroot}"
    BOOT_MODE="${BOOT_MODE:-bios}"

    case "$BOOT_MODE" in
        bios|uefi) ;;
        *) die "BOOT_MODE must be 'bios' or 'uefi', got: $BOOT_MODE" ;;
    esac
}

##============================================================================
## Validation
##============================================================================

validate() {
    log "Validating configuration"

    local primary="/dev/disk/by-id/${DISKID}"
    local mirror="/dev/disk/by-id/${MIRRORDISKID}"

    [ -b "$primary" ] || die "Primary disk not found: $primary"
    [ -b "$mirror" ] || die "Mirror disk not found: $mirror"

    # Verify primary disk is in the pool
    if ! zpool status "$POOL_NAME" | grep -q "$DISKID"; then
        die "Primary disk $DISKID not found in pool $POOL_NAME"
    fi

    # Verify pool is not already mirrored
    if zpool status "$POOL_NAME" | grep -q "mirror"; then
        die "Pool $POOL_NAME is already mirrored"
    fi

    # Verify mirror disk has no partitions (safety check)
    local mirror_dev
    mirror_dev=$(readlink -f "$mirror")
    local part_count
    part_count=$(lsblk -n -o NAME "$mirror_dev" | wc -l)
    if [ "$part_count" -gt 1 ]; then
        die "Mirror disk $mirror_dev already has partitions. Wipe it first if you're sure: wipefs -a $mirror_dev"
    fi

    # Verify primary has expected partition layout
    local primary_dev
    primary_dev=$(readlink -f "$primary")
    if ! sgdisk -p "$primary_dev" | grep -qE "EF02|EF00|8300"; then
        die "Primary disk partition layout doesn't look right"
    fi

    echo "  Primary disk: $primary ($primary_dev)"
    echo "  Mirror disk:  $mirror ($mirror_dev)"
    echo "  Pool:         $POOL_NAME"
    echo "  Boot mode:    $BOOT_MODE"
}

##============================================================================
## Partition mirror disk
##============================================================================

partition_mirror() {
    log "Copying partition table to mirror disk"

    local primary="/dev/disk/by-id/${DISKID}"
    local mirror="/dev/disk/by-id/${MIRRORDISKID}"

    local primary_dev
    primary_dev=$(readlink -f "$primary")
    local mirror_dev
    mirror_dev=$(readlink -f "$mirror")

    # Copy partition table and randomize GUIDs
    run sgdisk -R "$mirror_dev" "$primary_dev"
    run sgdisk -G "$mirror_dev"

    # Wait for kernel to pick up new partitions
    run partprobe "$mirror_dev"
    [ -z "$DRYRUN" ] && sleep 2

    run sgdisk -p "$mirror_dev"
}

##============================================================================
## Setup boot on mirror (BIOS/syslinux)
##============================================================================

setup_bios_boot() {
    log "Setting up syslinux boot on mirror disk"

    local mirror="/dev/disk/by-id/${MIRRORDISKID}"
    local mirror_dev
    mirror_dev=$(readlink -f "$mirror")

    # Find the boot partition (partition 1)
    local boot_part="${mirror}-part1"
    if [ -z "$DRYRUN" ]; then
        [ -b "$boot_part" ] || die "Boot partition not found: $boot_part"
    fi

    # Format boot partition
    log "Formatting boot partition"
    run mkfs.ext4 -L BOOT2 "$boot_part"

    # Mount and copy boot files
    log "Copying boot files"
    local mnt="/mnt/boot_mirror"
    if [ -z "$DRYRUN" ]; then
        mkdir -p "$mnt"
        mount "$boot_part" "$mnt"
        rsync -av /boot/syslinux/ "$mnt/"
    else
        echo "  >> mkdir -p $mnt"
        echo "     (dry run)"
        echo "  >> mount $boot_part $mnt"
        echo "     (dry run)"
        echo "  >> rsync -av /boot/syslinux/ $mnt/"
        echo "     (dry run)"
    fi

    # Install syslinux bootloader
    log "Installing syslinux"
    run extlinux --install "$mnt"

    # Install MBR
    log "Installing MBR"
    run dd if=/usr/lib/syslinux/mbr/mbr.bin of="$mirror_dev" bs=440 count=1 conv=notrunc

    if [ -z "$DRYRUN" ]; then
        umount "$mnt"
        rmdir "$mnt"
    else
        echo "  >> umount $mnt"
        echo "     (dry run)"
    fi
}

##============================================================================
## Setup boot on mirror (UEFI/rEFInd)
##============================================================================

setup_uefi_boot() {
    log "Setting up UEFI boot (rEFInd) on mirror disk"

    local mirror="/dev/disk/by-id/${MIRRORDISKID}"
    local mirror_dev
    mirror_dev=$(readlink -f "$mirror")

    ## ESP is partition 1 (EF00), replicated by sgdisk -R in partition_mirror
    local boot_part="${mirror}-part1"
    if [ -z "$DRYRUN" ]; then
        [ -b "$boot_part" ] || die "Mirror ESP not found: $boot_part"
    fi

    ## Format mirror ESP as FAT32
    log "Formatting mirror ESP (FAT32)"
    run mkdosfs -F 32 -s 1 -n EFI2 "$boot_part"

    ## Copy the primary ESP contents (rEFInd + ZFSBootMenu EFI images) verbatim
    log "Copying ESP contents from primary (/boot/efi)"
    local mnt="/mnt/efi_mirror"
    if [ -z "$DRYRUN" ]; then
        mountpoint -q /boot/efi || die "Primary ESP is not mounted at /boot/efi"
        mkdir -p "$mnt"
        mount "$boot_part" "$mnt"
        rsync -a /boot/efi/ "$mnt/"
        umount "$mnt"
        rmdir "$mnt"
    else
        echo "  >> mount $boot_part $mnt"
        echo "     (dry run)"
        echo "  >> rsync -a /boot/efi/ $mnt/"
        echo "     (dry run)"
        echo "  >> umount $mnt"
        echo "     (dry run)"
    fi

    ## Register a UEFI boot entry for the mirror's rEFInd loader
    log "Registering UEFI boot entry for mirror"
    run efibootmgr --create --disk "$mirror_dev" --part 1 \
        --loader '\EFI\refind\refind_x64.efi' --label 'rEFInd (mirror)'

    ## NOTE: the two ESPs are independent FAT32 partitions - ZFS does not mirror
    ## them. After kernel/ZBM image updates the mirror ESP goes stale. Keep them
    ## in sync with a hook/timer (rsync /boot/efi -> mirror ESP); see follow-ups.
}

##============================================================================
## Attach mirror to ZFS pool
##============================================================================

attach_mirror() {
    log "Attaching mirror disk to pool $POOL_NAME"

    local primary_part="${DISKID}-part2"
    local mirror_part="${MIRRORDISKID}-part2"

    # Verify partitions exist (skip in dry run - they're created by partition_mirror)
    [ -b "/dev/disk/by-id/${primary_part}" ] || die "Primary ZFS partition not found: $primary_part"
    if [ -z "$DRYRUN" ]; then
        [ -b "/dev/disk/by-id/${mirror_part}" ] || die "Mirror ZFS partition not found: $mirror_part"
    fi

    # Wipe old filesystem signatures (e.g. swap) that would cause zpool attach to refuse
    run wipefs -a "/dev/disk/by-id/${mirror_part}"

    run zpool attach "$POOL_NAME" "$primary_part" "$mirror_part"

    log "Mirror attached - resilvering started"
    if [ -z "$DRYRUN" ]; then
        zpool status "$POOL_NAME"
    fi
}

##============================================================================
## Dependencies
##============================================================================

ensure_deps() {
    local miss=""
    local b
    for b in sgdisk mkdosfs rsync efibootmgr wipefs; do
        command -v "$b" >/dev/null 2>&1 || miss="$miss $b"
    done
    [ -z "$miss" ] && return 0
    if [ -n "$DRYRUN" ]; then
        echo "  (dry run) would install missing tools:$miss (pkgs: gdisk dosfstools rsync efibootmgr util-linux)"
        return 0
    fi
    log "Installing mirror dependencies:$miss"
    apt-get update -qq
    apt-get install -y -qq gdisk dosfstools rsync efibootmgr util-linux
}

##============================================================================
## ESP sync hook - keep the mirror ESP current after kernel/ZBM updates
##============================================================================
## The two ESPs are independent FAT32 filesystems (ZFS does not mirror them).
## Without this, the mirror ESP keeps the install-time boot images and goes
## stale after a kernel/ZBM update - so a later boot from the surviving disk
## could run an outdated/incompatible image. This installs a kernel postinst.d
## hook that rsyncs /boot/efi -> the mirror ESP after such updates.

install_esp_sync() {
    log "Installing mirror-ESP sync hook"
    if [ -n "$DRYRUN" ]; then
        echo "  (dry run) would install /usr/local/sbin/sync-esp-mirror + /etc/kernel/postinst.d/zzz-sync-esp-mirror"
        return 0
    fi

    local mirror_partuuid
    mirror_partuuid="$(blkid -s PARTUUID -o value /dev/disk/by-id/"${MIRRORDISKID}"-part1)"
    [ -n "$mirror_partuuid" ] || die "Could not read mirror ESP PARTUUID"

    cat > /usr/local/sbin/sync-esp-mirror <<SYNC
#!/bin/bash
## Sync the primary ESP (/boot/efi) to the mirror ESP. Installed by zfs-mirror.sh.
## Invoked from /etc/kernel/postinst.d after kernel/initramfs/ZBM image updates;
## also safe to run by hand after 'generate-zbm'.
set -e
SRC=/boot/efi
DEV=/dev/disk/by-partuuid/${mirror_partuuid}
mountpoint -q "\$SRC" || exit 0      # primary ESP not mounted - nothing to do
[ -b "\$DEV" ] || exit 0             # mirror disk absent (degraded) - skip quietly
M=\$(mktemp -d)
mount "\$DEV" "\$M"
rsync -a --delete "\$SRC"/ "\$M"/
umount "\$M"; rmdir "\$M"
SYNC
    chmod +x /usr/local/sbin/sync-esp-mirror

    mkdir -p /etc/kernel/postinst.d
    cat > /etc/kernel/postinst.d/zzz-sync-esp-mirror <<'HOOK'
#!/bin/sh
exec /usr/local/sbin/sync-esp-mirror
HOOK
    chmod +x /etc/kernel/postinst.d/zzz-sync-esp-mirror

    echo "  Installed sync-esp-mirror (mirror ESP PARTUUID ${mirror_partuuid})"
    /usr/local/sbin/sync-esp-mirror && echo "  initial ESP sync OK"
}

##============================================================================
## Main
##============================================================================

main() {
    [ $# -ge 2 ] || print_usage

    local config_file="$1"
    local mode="$2"

    case "$mode" in
        -d) DRYRUN=1 ;;
        -r) DRYRUN="" ;;
        *)  print_usage ;;
    esac

    [ "$(id -u)" -eq 0 ] || die "Must run as root"

    # Resolve config path (check configs/ subdirectory too)
    if [ ! -f "$config_file" ] && [ -f "configs/$config_file" ]; then
        config_file="configs/$config_file"
    fi

    load_config "$config_file"
    ensure_deps
    validate

    [ -n "$DRYRUN" ] && echo "" && echo "=== DRY RUN ==="

    echo ""
    echo "Steps:"
    echo "  1. Copy partition table from primary to mirror disk"
    echo "  2. Set up ${BOOT_MODE} boot on the mirror boot partition"
    echo "  3. Attach mirror to ZFS pool (starts resilver)"
    echo ""

    partition_mirror
    if [ "$BOOT_MODE" = "uefi" ]; then
        setup_uefi_boot
    else
        setup_bios_boot
    fi
    attach_mirror
    if [ "$BOOT_MODE" = "uefi" ]; then
        install_esp_sync
    fi

    log "ZFS mirror setup complete"
    if [ -z "$DRYRUN" ]; then
        echo ""
        echo "Resilvering is in progress. Monitor with:"
        echo "  zpool status $POOL_NAME"
    fi
}

main "$@"
