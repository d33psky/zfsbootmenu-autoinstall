#!/bin/bash
##
## zfs-install.sh - Standalone ZFS root installation with ZFSBootMenu
##
## Supports:
##   - UEFI boot (rEFInd + ZFSBootMenu)
##   - BIOS boot (syslinux + ZFSBootMenu)
##   - Single disk (extend to mirror post-install with zpool attach)
##   - Ubuntu Server LTS or Kubuntu (noble 24.04+)
##   - Non-interactive, config-file driven
##
## Usage: sudo ./zfs-install.sh <config_file> initial|postreboot
##

set -euo pipefail

# Truly non-interactive, also with NO TTY (ansible async, cron): without these, the
# first debconf-using apt install pops whiptail, which dies with "Failed to open
# terminal" when run headless. Inherited by debootstrap and the chrooted phases.
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOUNTPOINT="/mnt/zfs_install"
UBUNTU_ARCHIVE="http://archive.ubuntu.com/ubuntu"
LOCALE="en_US.UTF-8"
INSTALL_LOG="zfs-install.log"
LOG_DIR="/var/log"
ZFS_PART=""  ## Set during partitioning
SPECIAL_PART=""  ## Set during partitioning when ROOT_SIZE bounds the root pool

##============================================================================
## Helpers
##============================================================================

log() { echo "=== $* ==="; }
die() { echo "ERROR: $*" >&2; exit 1; }

start_logging() {
    exec > >(tee -a "$LOG_DIR/$INSTALL_LOG") 2>&1
    date
}

##============================================================================
## Config
##============================================================================

print_usage() {
    cat <<'USAGE'
Usage: sudo ./zfs-install.sh <config_file> <action>

Actions:
  initial     - Run from live USB to install system
  postreboot  - Run after first boot to complete setup

Config file variables:
  Required:
    DISKID        - Disk ID (from /dev/disk/by-id/)
    HOSTNAME      - System hostname
    USERNAME      - Primary user account name
    USERPASS      - Password for user and root
    TIMEZONE      - e.g., "Europe/Amsterdam"
  Optional:
    POOL_NAME     - ZFS pool name (default: zroot)
    COMPRESSION   - ZFS compression (default: lz4)
    UBUNTU_VER    - Ubuntu version codename (default: noble)
    DISTRO        - "server" or "kubuntu" (default: server)
    SWAP_SIZE     - Swap partition size in MB (default: 0 = no swap)
    BOOT_MODE     - "uefi" or "bios" (default: uefi)
    BOOT_SIZE     - ESP/boot partition size (sgdisk syntax, default: 512M)
    ROOT_SIZE     - Bound the root pool to this size (e.g. 600G); the rest of
                    the disk becomes a reserved partition for a later vdev
                    (e.g. a ZFS special vdev). Default: 0 = root uses whole disk.
    ASHIFT        - ZFS pool ashift (default: 12)
    NETPLAN_FILE  - Path to a netplan YAML installed verbatim (default: DHCP)
    AUTHORIZED_KEYS - Path to a file of SSH public keys, copied verbatim into
                    ~USERNAME/.ssh/authorized_keys (default: none = password-only)
    POOL_COMPATIBILITY - zpool 'compatibility' profile capping pool features so an
                    OLDER target ZFS can import the pool. Matters when the rescue's ZFS
                    is newer than the installed distro's (Hetzner rescue builds the
                    LATEST; Ubuntu noble ships 2.2). e.g. openzfs-2.2-linux
                    (default: unset = all features the running ZFS supports)
  Optional - native ZFS encryption (see configs/host.conf.sample for the full model):
    ENCRYPTION    - "on" = encrypt the pool root (aes-256-gcm, keyformat raw).
                    The key is embedded in the TARGET initramfs, which lives on
                    the encrypted root itself - it never touches plaintext disk.
                    ZFSBootMenu unlocks the pool at boot: via ZBM_KEYFETCH_URL
                    (unattended) or an interactive prompt. (default: off)
    KEYFILE       - Path to the raw 32-byte key used at install time. Generate:
                    head -c 32 /dev/urandom > myhost.key   (never commit it)
    ZBM_KEYFETCH_URL - URL the ZBM initramfs fetches the key from at boot
                    (http:// or https://). Unset = ZBM prompts on console.
    ZBM_KEYFETCH_CA - Path to a CA/cert PEM baked into the ZBM image and pinned
                    for the fetch (self-signed key server). Unset = system CAs.
    ZBM_NET_ARGS  - dracut network args for the ZBM initramfs, verbatim, e.g.
                    "rd.neednet=1 ip=10.0.0.10::10.0.0.1:255.255.255.0::vlan40:none vlan=vlan40:eth0"
                    Embedded in the image via /etc/cmdline.d (no bootloader edit).
                    Required with ZBM_KEYFETCH_URL. Add a second ip= for IPv6.
    ZBM_DROPBEAR  - "on" = dropbear ssh (pubkey-only) in the ZBM initramfs for
                    remote rescue of a stuck boot. (default: off)
    ZBM_DROPBEAR_KEYS - authorized_keys file for dropbear (default: AUTHORIZED_KEYS)
    ZBM_DROPBEAR_PORT - dropbear port (default: 222)
    CMDLINE_EXTRA - extra KERNEL parameters for both the ZBM bootloader entries
                    and the target kernel (org.zfsbootmenu:commandline), e.g.
                    "console=tty0 console=ttyS0" for serial-console visibility,
                    or "iommu=pt". (default: none)

Example config:
  DISKID="nvme-Samsung_SSD_980_PRO_1TB_S5XXXX"
  HOSTNAME="myhost"
  USERNAME="admin"
  USERPASS="changeme"
  TIMEZONE="Europe/Amsterdam"
  BOOT_MODE="bios"
USAGE
    exit 1
}

load_config() {
    local config_file="$1"
    [ -f "$config_file" ] || die "Config file not found: $config_file"
    # shellcheck source=/dev/null
    source "$config_file"

    for var in DISKID HOSTNAME USERNAME USERPASS TIMEZONE; do
        [ -n "${!var:-}" ] || die "Required config variable $var is not set"
    done

    POOL_NAME="${POOL_NAME:-zroot}"
    COMPRESSION="${COMPRESSION:-lz4}"
    UBUNTU_VER="${UBUNTU_VER:-noble}"
    BOOT_MODE="${BOOT_MODE:-uefi}"
    SWAP_SIZE="${SWAP_SIZE:-0}"
    DISTRO="${DISTRO:-server}"
    BOOT_SIZE="${BOOT_SIZE:-512M}"
    ROOT_SIZE="${ROOT_SIZE:-0}"       ## 0 = root takes the whole disk; else bounded root + a reserved partition (rest) for a later vdev (e.g. ZFS special)
    ASHIFT="${ASHIFT:-12}"
    NETPLAN_FILE="${NETPLAN_FILE:-}"  ## if set, this netplan YAML is installed verbatim; else DHCP autoconfig
    AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-}" ## if set, this file's pubkeys go into ~USERNAME/.ssh/authorized_keys
    POOL_COMPATIBILITY="${POOL_COMPATIBILITY:-}" ## if set, zpool create -o compatibility=<this> (cap features for an older target ZFS)
    ENCRYPTION="${ENCRYPTION:-off}"   ## on = native ZFS encryption on the pool root
    KEYFILE="${KEYFILE:-}"            ## raw 32-byte key used at install time (never committed)
    ZBM_KEYFETCH_URL="${ZBM_KEYFETCH_URL:-}" ## ZBM boot-time key fetch URL; unset = console prompt
    ZBM_KEYFETCH_CA="${ZBM_KEYFETCH_CA:-}"   ## pinned CA/cert PEM for the fetch (self-signed server)
    ZBM_NET_ARGS="${ZBM_NET_ARGS:-}"  ## dracut net args for the ZBM initramfs (ip=... vlan=... rd.neednet=1)
    ZBM_DROPBEAR="${ZBM_DROPBEAR:-off}"      ## on = dropbear ssh in the ZBM initramfs (remote rescue)
    ZBM_DROPBEAR_KEYS="${ZBM_DROPBEAR_KEYS:-$AUTHORIZED_KEYS}" ## authorized_keys for dropbear
    ZBM_DROPBEAR_PORT="${ZBM_DROPBEAR_PORT:-222}"
    CMDLINE_EXTRA="${CMDLINE_EXTRA:-}" ## extra KERNEL params for BOTH the ZBM entries and the
                                       ## target kernel (org.zfsbootmenu:commandline) - e.g.
                                       ## "console=tty0 console=ttyS0" or "iommu=pt"

    ## The key/CA/dropbear-keys FILES are consumed by `initial` only - the
    ## postreboot phase runs on the installed box, where preserve_install_files
    ## kept just the .conf (the key already lives at /etc/zfs/<pool>.key there).
    ## Requiring them for every action broke postreboot on the first encrypted
    ## box. Value-sanity checks still apply to all actions.
    case "$ENCRYPTION" in
        on)
            if [ "${ACTION:-}" = "initial" ]; then
                [ -n "$KEYFILE" ] || die "ENCRYPTION=on requires KEYFILE"
                [ -f "$KEYFILE" ] || KEYFILE="$SCRIPT_DIR/$KEYFILE"
                [ -f "$KEYFILE" ] || die "KEYFILE not found: $KEYFILE"
                [ "$(stat -c%s "$KEYFILE")" -eq 32 ] || die "KEYFILE must be exactly 32 raw bytes (head -c 32 /dev/urandom > key)"
                if [ -n "$ZBM_KEYFETCH_CA" ]; then
                    [ -f "$ZBM_KEYFETCH_CA" ] || ZBM_KEYFETCH_CA="$SCRIPT_DIR/$ZBM_KEYFETCH_CA"
                    [ -f "$ZBM_KEYFETCH_CA" ] || die "ZBM_KEYFETCH_CA not found: $ZBM_KEYFETCH_CA"
                fi
            fi
            if [ -n "$ZBM_KEYFETCH_URL" ] && [ -z "$ZBM_NET_ARGS" ]; then
                die "ZBM_KEYFETCH_URL requires ZBM_NET_ARGS (the ZBM initramfs needs network to fetch the key)"
            fi
            ;;
        off) ;;
        *) die "ENCRYPTION must be 'on' or 'off', got: $ENCRYPTION" ;;
    esac
    if [ "$ZBM_DROPBEAR" = "on" ]; then
        [ -n "$ZBM_NET_ARGS" ] || die "ZBM_DROPBEAR=on requires ZBM_NET_ARGS (the ZBM initramfs needs network for ssh)"
        if [ "${ACTION:-}" = "initial" ]; then
            [ -n "$ZBM_DROPBEAR_KEYS" ] || die "ZBM_DROPBEAR=on requires ZBM_DROPBEAR_KEYS (or AUTHORIZED_KEYS)"
            [ -f "$ZBM_DROPBEAR_KEYS" ] || ZBM_DROPBEAR_KEYS="$SCRIPT_DIR/$ZBM_DROPBEAR_KEYS"
            [ -f "$ZBM_DROPBEAR_KEYS" ] || die "ZBM_DROPBEAR_KEYS not found: $ZBM_DROPBEAR_KEYS"
        fi
    fi

    case "$BOOT_MODE" in
        uefi|bios) ;;
        *) die "BOOT_MODE must be 'uefi' or 'bios', got: $BOOT_MODE" ;;
    esac

    case "$DISTRO" in
        server|kubuntu) ;;
        *) die "DISTRO must be 'server' or 'kubuntu', got: $DISTRO" ;;
    esac

    log "Configuration"
    echo "  Disk:        $DISKID"
    echo "  Hostname:    $HOSTNAME"
    echo "  User:        $USERNAME"
    echo "  Timezone:    $TIMEZONE"
    echo "  Pool:        $POOL_NAME"
    echo "  Compression: $COMPRESSION"
    echo "  Ubuntu:      $UBUNTU_VER"
    echo "  Distro:      $DISTRO"
    echo "  Swap:        ${SWAP_SIZE}MB (0 = none)"
    echo "  Boot mode:   $BOOT_MODE"
    echo "  Boot/ESP:    $BOOT_SIZE"
    echo "  Root size:   ${ROOT_SIZE} (0 = whole disk)"
    echo "  ashift:      $ASHIFT"
    if [ -n "$NETPLAN_FILE" ]; then echo "  Netplan:     $NETPLAN_FILE (verbatim)"; else echo "  Netplan:     DHCP (auto)"; fi
    if [ -n "$AUTHORIZED_KEYS" ]; then echo "  SSH keys:    $AUTHORIZED_KEYS"; else echo "  SSH keys:    none (password-only)"; fi
    if [ -n "$POOL_COMPATIBILITY" ]; then echo "  Pool compat: $POOL_COMPATIBILITY"; else echo "  Pool compat: (all features of running ZFS)"; fi
    if [ "$ENCRYPTION" = "on" ]; then
        echo "  Encryption:  on (aes-256-gcm, keyfile $KEYFILE)"
        if [ -n "$ZBM_KEYFETCH_URL" ]; then echo "  ZBM unlock:  fetch $ZBM_KEYFETCH_URL${ZBM_KEYFETCH_CA:+ (pinned CA $ZBM_KEYFETCH_CA)}"; else echo "  ZBM unlock:  console prompt"; fi
        [ -n "$ZBM_NET_ARGS" ] && echo "  ZBM net:     $ZBM_NET_ARGS"
    else
        echo "  Encryption:  off"
    fi
    if [ "$ZBM_DROPBEAR" = "on" ]; then echo "  ZBM ssh:     dropbear port $ZBM_DROPBEAR_PORT, keys $ZBM_DROPBEAR_KEYS"; fi
    if [ -n "$CMDLINE_EXTRA" ]; then echo "  Cmdline+:    $CMDLINE_EXTRA (ZBM entries + target kernel)"; fi
}

##============================================================================
## Environment checks
##============================================================================

check_environment() {
    [ "$(id -u)" -eq 0 ] || die "Must be run as root"

    if grep -qE "casper|live" /proc/cmdline 2>/dev/null || [ -d /cdrom ] || [ -d /rofs ]; then
        log "Live environment detected"
    else
        echo "WARNING: May not be a live environment. Proceeding anyway..."
    fi

    if nc -zw5 archive.ubuntu.com 443 2>/dev/null; then
        log "Internet connectivity OK"
    else
        die "No internet connectivity"
    fi
}

validate_boot_mode() {
    if [ "$BOOT_MODE" = "uefi" ] && [ ! -d /sys/firmware/efi ]; then
        # Hard fail: a UEFI install from a legacy-booted environment produces an
        # UNBOOTABLE system, silently. efibootmgr cannot register an NVRAM boot
        # entry without efivars, so refind falls back to installing only the
        # removable-media path (\EFI\BOOT\BOOTX64.EFI) and reports success -- which
        # boots ONLY if the target firmware itself is UEFI. If the firmware is
        # legacy BIOS (the Hetzner default on many servers) the ESP is ignored
        # entirely and the box never boots. Refuse rather than "complete" a trap.
        echo "ERROR: BOOT_MODE=uefi but the installer is running in LEGACY BIOS mode" >&2
        echo "       (no /sys/firmware/efi present)." >&2
        echo "" >&2
        echo "  A UEFI install from here cannot register a UEFI boot entry and will" >&2
        echo "  likely produce a system that does not boot. Fix one of:" >&2
        echo "    - boot the install environment in UEFI mode, then rerun; or" >&2
        echo "    - set BOOT_MODE=\"bios\" if the target firmware is legacy BIOS." >&2
        echo "" >&2
        echo "  If you are CERTAIN the target firmware is UEFI and want to rely on the" >&2
        echo "  \\EFI\\BOOT\\BOOTX64.EFI removable-media fallback, rerun with" >&2
        echo "  ALLOW_UEFI_FROM_BIOS=1 to override this check." >&2
        if [ "${ALLOW_UEFI_FROM_BIOS:-0}" != "1" ]; then
            die "boot-mode mismatch: uefi requested from a legacy-booted installer"
        fi
        echo "ALLOW_UEFI_FROM_BIOS=1 set -- continuing despite legacy-booted installer." >&2
    elif [ "$BOOT_MODE" = "bios" ]; then
        log "BIOS boot mode (syslinux + MBR)"
    fi
}

##============================================================================
## Live environment setup
##============================================================================

setup_live_apt() {
    log "Configuring apt in live environment"
    cat > /etc/apt/apt.conf.d/30apt_error_on_transient <<EOF
APT::Update::Error-Mode "any";
EOF
    trap 'echo "apt update failed - check network"' ERR
    apt update
    trap - ERR
}

install_live_packages() {
    log "Installing live environment packages"
    apt-get -yq install debootstrap software-properties-common gdisk
    ## ZFS in the LIVE/rescue env is needed only to CREATE the pool. If it's already
    ## present, USE it and do NOT apt-install a packaged ZFS: on the Hetzner rescue you
    ## pre-run its install_openzfs.sh (the rescue's custom kernel has no matching distro
    ## zfs-dkms, so the packaged 2.1.x can't build against it and the install dies right
    ## here). Only fall back to apt where the live env ships no ZFS at all.
    if modprobe zfs 2>/dev/null; then
        log "  ZFS already available in the live env ($(zpool version 2>/dev/null | head -1)) - skipping apt zfs"
    else
        DEBIAN_FRONTEND=noninteractive apt-get -yq install zfs-initramfs
    fi
    if service --status-all 2>/dev/null | grep -Fq 'zfs-zed'; then
        systemctl stop zfs-zed
    fi
}

configure_keyboard_live() {
    log "Configuring keyboard (non-interactive, US layout)"
    apt install -y debconf-utils
    cat > /tmp/keyboard_settings.conf <<EOF
keyboard-configuration keyboard-configuration/layoutcode string us
keyboard-configuration keyboard-configuration/layout select English (US)
keyboard-configuration keyboard-configuration/modelcode string pc105
keyboard-configuration keyboard-configuration/model select Generic 105-key PC (intl.)
keyboard-configuration keyboard-configuration/variantcode string
keyboard-configuration keyboard-configuration/variant select English (US)
keyboard-configuration keyboard-configuration/xkb-keymap select us
keyboard-configuration keyboard-configuration/optionscode string
console-setup console-setup/charmap47 select UTF-8
console-setup console-setup/fontsize-fb47 select 8x16
console-setup console-setup/fontsize-text47 select 8x16
console-setup console-setup/codeset47 select Guess optimal character set
console-setup console-setup/fontface47 select Fixed
EOF
    debconf-set-selections < /tmp/keyboard_settings.conf
    debconf-get-selections | grep keyboard-configuration > /tmp/kb_console_selections.conf || true
    debconf-get-selections | grep console-setup >> /tmp/kb_console_selections.conf || true
}

##============================================================================
## Disk operations
##============================================================================

cleanup_target_disk() {
    log "Cleaning target disk: $DISKID"
    swapoff -a 2>/dev/null || true

    for pool in $(zpool list -H -o name 2>/dev/null); do
        if zpool status "$pool" 2>/dev/null | grep -q "$DISKID"; then
            echo "  Destroying pool '$pool' on target disk"
            zfs unmount -a 2>/dev/null || true
            umount -R "$MOUNTPOINT" 2>/dev/null || true
            ## A previous run that died after its bind-mounts leaves rbind'd
            ## /dev|/proc|/sys submounts umount -R can't unwind - lazy-force
            ## them so the pool can actually be released (found on real HW).
            ## make-rslave FIRST (same as unmount_all): the rbinds share mount
            ## propagation with the LIVE env, and without it the lazy umounts
            ## propagate back and rip out the host's own /dev/pts (this took
            ## down logind + all new ssh PTYs on the HEL rescue - real scar).
            if grep -q "$MOUNTPOINT" /proc/mounts; then
                mount --make-rslave "$MOUNTPOINT"/dev  2>/dev/null || true
                mount --make-rslave "$MOUNTPOINT"/proc 2>/dev/null || true
                mount --make-rslave "$MOUNTPOINT"/sys  2>/dev/null || true
                grep "$MOUNTPOINT" /proc/mounts | cut -f2 -d" " | sort -r | xargs -r umount -lf 2>/dev/null || true
                sleep 2
            fi
            zpool destroy -f "$pool" 2>/dev/null || zpool export -f "$pool" 2>/dev/null || true
            ## Fail LOUDLY if it survived: proceeding would wipe partitions under
            ## an imported pool and wedge the ZFS state until a reboot (been there).
            if zpool list -H -o name 2>/dev/null | grep -qx "$pool"; then
                die "Pool '$pool' on the target disk is still imported (busy) after destroy/export - reboot the live environment and rerun"
            fi
        fi
    done
    sleep 1

    wipefs -a /dev/disk/by-id/"$DISKID" 2>/dev/null || true
    for part in /dev/disk/by-id/"$DISKID"-part*; do
        [ -e "$part" ] && wipefs -a "$part" 2>/dev/null || true
    done
    ## Clear leftover ZFS labels explicitly: wipefs misses the back-of-partition
    ## copies, and a previous install's pool - even cleanly exported, and
    ## especially an ENCRYPTED one we can't import to destroy - otherwise blocks
    ## zpool create with "is part of active pool", -f notwithstanding.
    for part in /dev/disk/by-id/"$DISKID"-part*; do
        [ -e "$part" ] && zpool labelclear -f "$part" 2>/dev/null || true
    done
    zpool labelclear -f /dev/disk/by-id/"$DISKID" 2>/dev/null || true

    ## The FUTURE mirror disk needs the same sweep: a stale pool label there
    ## (reused disk, previous mirror test) makes the target initramfs fail with
    ## "cannot import 'zroot': more than one matching pool" at first boot -
    ## zfs-mirror.sh only attaches it later, AFTER that landmine has gone off.
    if [ -n "${MIRRORDISKID:-}" ]; then
        for part in /dev/disk/by-id/"$MIRRORDISKID"-part*; do
            [ -e "$part" ] && zpool labelclear -f "$part" 2>/dev/null || true
        done
        zpool labelclear -f /dev/disk/by-id/"$MIRRORDISKID" 2>/dev/null || true
    fi
    partprobe 2>/dev/null || true
    sleep 2
}

partition_disk() {
    log "Partitioning disk"
    local disk="/dev/disk/by-id/$DISKID"
    local boot_type boot_part p

    if [ "$BOOT_MODE" = "bios" ]; then
        boot_type="8300"
    else
        boot_type="EF00"
    fi

    sgdisk --zap-all "$disk"

    ## p1: ESP / boot
    p=1
    sgdisk -n"${p}":1M:+"${BOOT_SIZE}" -t"${p}":"${boot_type}" "$disk"
    boot_part=$p; p=$((p+1))

    ## optional swap partition
    if [ "$SWAP_SIZE" != "0" ]; then
        sgdisk -n"${p}":0:+"${SWAP_SIZE}"M -t"${p}":8200 "$disk"
        p=$((p+1))
    fi

    ## root ZFS partition (bounded if ROOT_SIZE set, else rest of disk)
    if [ "$ROOT_SIZE" != "0" ]; then
        sgdisk -n"${p}":0:+"${ROOT_SIZE}" -t"${p}":BF00 "$disk"
        ZFS_PART=$p; p=$((p+1))
        ## remainder: a reserved BF00 partition for a later vdev (e.g. ZFS special).
        ## Created here so zfs-mirror.sh replicates it to the mirror disk; left
        ## untouched by this script (built into a pool later, e.g. by Ansible).
        sgdisk -n"${p}":0:0 -t"${p}":BF00 "$disk"
        SPECIAL_PART=$p
        echo "  Layout: ESP(${BOOT_SIZE}) part${boot_part} + root(${ROOT_SIZE}) part${ZFS_PART} + reserved(rest) part${SPECIAL_PART}"
    else
        sgdisk -n"${p}":0:0 -t"${p}":BF00 "$disk"
        ZFS_PART=$p
        echo "  Layout: ESP(${BOOT_SIZE}) part${boot_part} + ZFS(rest) part${ZFS_PART}"
    fi

    if [ "$BOOT_MODE" = "bios" ]; then
        sgdisk -A "${boot_part}":set:2 "$disk"
    fi

    partprobe
    sleep 2
}

create_zfs_pool() {
    log "Creating ZFS pool on partition ${ZFS_PART}"
    ## Ensure a stable hostid exists BEFORE creating the pool. The pool records
    ## this hostid in its labels; the installed system and the ZFSBootMenu image
    ## must use the SAME hostid (see configure_system_base) or ZFS will refuse to
    ## import an unclean/degraded pool at boot - e.g. after one mirror disk dies.
    [ -e /etc/hostid ] || zgenhostid
    echo "  Pool hostid: $(hostid)"

    ## Native encryption: the pool root is the encryptionroot, so every dataset
    ## inherits it. keylocation points at /etc/zfs/<pool>.key - a path that exists
    ## in BOTH worlds: in the live env now (installed here, so zpool create can read
    ## it) and later inside the encrypted root of the target (setup_encryption_target),
    ## where the target initramfs embeds it. The key therefore never touches
    ## unencrypted storage: ZBM unlocks the pool (network fetch or prompt), reads the
    ## target initrd FROM the unlocked root, and that initrd carries the key.
    local encryption_opts=()
    if [ "$ENCRYPTION" = "on" ]; then
        ## -D: /etc/zfs may not exist in the live env (e.g. the Hetzner rescue
        ## builds ZFS from source - no package, no directory; found on real HW)
        install -D -m 400 "$KEYFILE" /etc/zfs/"$POOL_NAME".key
        encryption_opts=(
            -O encryption=aes-256-gcm
            -O keyformat=raw
            -O keylocation=file:///etc/zfs/"$POOL_NAME".key
        )
    fi

    zpool create -f \
        -o ashift="$ASHIFT" \
        -o autotrim=on \
        ${POOL_COMPATIBILITY:+-o compatibility="$POOL_COMPATIBILITY"} \
        -O acltype=posixacl \
        -O canmount=off \
        -O compression="$COMPRESSION" \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=on \
        -O xattr=sa \
        -O mountpoint=none \
        "${encryption_opts[@]}" \
        -R "$MOUNTPOINT" \
        "$POOL_NAME" /dev/disk/by-id/"${DISKID}"-part"${ZFS_PART}"
}

create_datasets() {
    log "Creating ZFS datasets"
    zfs create -o canmount=off -o mountpoint=none "$POOL_NAME"/ROOT
    zfs create -o canmount=noauto -o mountpoint=/ "$POOL_NAME"/ROOT/ubuntu
    zfs mount "$POOL_NAME"/ROOT/ubuntu
    zpool set bootfs="$POOL_NAME"/ROOT/ubuntu "$POOL_NAME"
    zfs create -o mountpoint=/home "$POOL_NAME"/home

    mkdir -p "$MOUNTPOINT"/run
    mount -t tmpfs tmpfs "$MOUNTPOINT"/run
    zfs list
}

##============================================================================
## System installation
##============================================================================

## Make the LIVE env's debootstrap able to bootstrap the target release, whatever the
## live env is. On an Ubuntu live env this is a no-op; on another (e.g. the Hetzner
## Debian rescue) debootstrap lacks the target's suite script AND archive keyring.
## This is also the seam for future non-Ubuntu targets.
prepare_debootstrap_for_target() {
    log "Preparing debootstrap for target: $UBUNTU_VER"
    ## (1) Suite script: an older live-env debootstrap may not know the target
    ## codename; all Ubuntu releases use the generic 'gutsy' script.
    if [ ! -e "/usr/share/debootstrap/scripts/$UBUNTU_VER" ]; then
        ln -sf gutsy "/usr/share/debootstrap/scripts/$UBUNTU_VER"
        log "  debootstrap script $UBUNTU_VER -> gutsy"
    fi
    ## (2) Ubuntu archive keyring: already present on an Ubuntu live env; elsewhere
    ## fetch it from the target archive's ubuntu-keyring package (it is not a Debian
    ## package, so 'apt install ubuntu-keyring' won't work on the Debian rescue).
    if [ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then
        apt-get -yq install ubuntu-keyring 2>/dev/null || true
    fi
    if [ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]; then
        log "  fetching ubuntu-keyring from $UBUNTU_ARCHIVE"
        local d deb url="$UBUNTU_ARCHIVE/pool/main/u/ubuntu-keyring/"
        d="$(mktemp -d)"
        ( cd "$d" || exit 1
          deb="$(wget -qO- "$url" | grep -oE 'ubuntu-keyring_[^"]+_all\.deb' | sort -V | tail -1)"
          [ -n "$deb" ] && wget -q "$url$deb" && dpkg-deb -x "$deb" . \
            && install -m644 usr/share/keyrings/ubuntu-archive-keyring.gpg /usr/share/keyrings/ )
        rm -rf "$d"
    fi
    [ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ] \
        || die "Could not obtain the Ubuntu archive keyring for debootstrap"
}

run_debootstrap() {
    log "Running debootstrap ($UBUNTU_VER)"
    local free
    free="$(df -k --output=avail "$MOUNTPOINT" | tail -n1)"
    [ "$free" -ge 5242880 ] || die "Less than 5GB free on target"
    prepare_debootstrap_for_target
    debootstrap --keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg \
        "$UBUNTU_VER" "$MOUNTPOINT" "$UBUNTU_ARCHIVE"
}

configure_system_base() {
    log "Configuring base system"

    ## Copy apt error config
    cp /etc/apt/apt.conf.d/30apt_error_on_transient "$MOUNTPOINT"/etc/apt/apt.conf.d/

    ## Hostname
    echo "$HOSTNAME" > "$MOUNTPOINT"/etc/hostname
    echo "127.0.1.1       $HOSTNAME" >> "$MOUNTPOINT"/etc/hosts

    ## Hostid: copy the live environment's /etc/hostid (the one the pool was
    ## created with) into the target, BEFORE the ZFS packages run zgenhostid in
    ## the chroot (which would otherwise mint a DIFFERENT hostid). This keeps the
    ## installed system and its generated ZFSBootMenu image on the pool's hostid,
    ## so an unclean/degraded import (e.g. a dead mirror disk) boots unattended.
    if [ -e /etc/hostid ]; then
        cp /etc/hostid "$MOUNTPOINT"/etc/hostid
        echo "  Copied /etc/hostid ($(hostid)) to target"
    fi

    ## Network: install a provided netplan verbatim, else DHCP on first ethernet
    if [ -n "$NETPLAN_FILE" ]; then
        [ -f "$NETPLAN_FILE" ] || NETPLAN_FILE="$SCRIPT_DIR/$NETPLAN_FILE"
        [ -f "$NETPLAN_FILE" ] || die "NETPLAN_FILE not found: $NETPLAN_FILE"
        echo "  Netplan: installing $NETPLAN_FILE verbatim"
        cp "$NETPLAN_FILE" "$MOUNTPOINT"/etc/netplan/01-netplan.yaml
    else
        local iface
        iface="$(basename "$(find /sys/class/net -maxdepth 1 -mindepth 1 -name "e*" | head -1)")"
        echo "  Ethernet interface: $iface (DHCP)"
        cat > "$MOUNTPOINT"/etc/netplan/01-netplan.yaml <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: yes
EOF
    fi
    chmod 600 "$MOUNTPOINT"/etc/netplan/01-netplan.yaml

    ## Bind virtual filesystems
    mount --rbind /dev  "$MOUNTPOINT"/dev
    mount --rbind /proc "$MOUNTPOINT"/proc
    mount --rbind /sys  "$MOUNTPOINT"/sys

    ## Configure apt sources in chroot
    if [ -f "$MOUNTPOINT"/etc/apt/sources.list.d/ubuntu.sources ]; then
        sed -i '/^Components:/s/.*/Components: main universe restricted multiverse/' \
            "$MOUNTPOINT"/etc/apt/sources.list.d/ubuntu.sources
    else
        cat > "$MOUNTPOINT"/etc/apt/sources.list <<EOF
deb $UBUNTU_ARCHIVE $UBUNTU_VER main universe restricted multiverse
deb $UBUNTU_ARCHIVE $UBUNTU_VER-updates main universe restricted multiverse
deb $UBUNTU_ARCHIVE $UBUNTU_VER-backports main universe restricted multiverse
deb http://security.ubuntu.com/ubuntu $UBUNTU_VER-security main universe restricted multiverse
EOF
    fi

    ## Locale and timezone
    chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
apt update
locale-gen en_US.UTF-8 $LOCALE
echo 'LANG="$LOCALE"' > /etc/default/locale
ln -fs /usr/share/zoneinfo/$TIMEZONE /etc/localtime
dpkg-reconfigure tzdata
EOCHROOT
}

install_zfs_packages() {
    log "Installing kernel and ZFS packages"
    chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
apt update
apt install --no-install-recommends -y linux-headers-generic linux-image-generic
apt install --yes --no-install-recommends dkms wget nano
apt install -yq software-properties-common
apt install --yes zfsutils-linux zfs-zed zfs-initramfs
EOCHROOT
}

setup_encryption_target() {
    [ "$ENCRYPTION" = "on" ] || return 0
    log "Setting up encryption key in target"

    ## The key inside the encrypted root, at the pool's keylocation path.
    install -D -m 400 "$KEYFILE" "$MOUNTPOINT"/etc/zfs/"$POOL_NAME".key

    ## Embed the key in the target initramfs so the kexec'd system imports and
    ## mounts its root without prompting or network. Safe because the initrd
    ## lives on the encrypted root itself (ZBM reads it post-unlock) and
    ## update-initramfs runs with UMASK=0077 (set in install_zfsbootmenu).
    ## Newer zfs-initramfs hooks copy file:// keys themselves; this makes it
    ## explicit and version-proof (cp -p keeps the 0400 mode in the initrd).
    cat > "$MOUNTPOINT"/etc/initramfs-tools/hooks/zfs-keyfile <<KEYHOOK
#!/bin/sh
PREREQ="zfs"
case "\$1" in prereqs) echo "\$PREREQ"; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
mkdir -p "\${DESTDIR}/etc/zfs"
cp -p /etc/zfs/${POOL_NAME}.key "\${DESTDIR}/etc/zfs/"
KEYHOOK
    chmod 755 "$MOUNTPOINT"/etc/initramfs-tools/hooks/zfs-keyfile
}

setup_boot_partition() {
    log "Setting up boot partition ($BOOT_MODE)"
    local disk="/dev/disk/by-id/$DISKID"
    local boot_uuid

    if [ "$BOOT_MODE" = "uefi" ]; then
        apt install --yes dosfstools
        mkdosfs -F 32 -s 1 -n EFI "${disk}"-part1
        partprobe; sleep 2
        boot_uuid="$(blkid -s UUID -o value "${disk}"-part1)"

        chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
mkdir -p /boot/efi
echo "UUID=${boot_uuid} /boot/efi vfat defaults,nofail,x-systemd.device-timeout=5s 0 0" >> /etc/fstab
mount /boot/efi
apt-get -yq install refind kexec-tools dpkg-dev git systemd-sysv
sed -i 's,^timeout .*,timeout 3,' /boot/efi/EFI/refind/refind.conf
echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf
sed -i 's,LOAD_KEXEC=false,LOAD_KEXEC=true,' /etc/default/kexec
EOCHROOT
    else
        apt install --yes e2fsprogs syslinux syslinux-common extlinux
        mkfs.ext4 -O '^64bit' -L BOOT "${disk}"-part1
        partprobe; sleep 2
        boot_uuid="$(blkid -s UUID -o value "${disk}"-part1)"

        chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
mkdir -p /boot/syslinux
echo "UUID=${boot_uuid} /boot/syslinux ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2" >> /etc/fstab
mount /boot/syslinux
apt-get -yq install syslinux syslinux-common extlinux kexec-tools dpkg-dev git systemd-sysv
echo REMAKE_INITRD=yes > /etc/dkms/zfs.conf
sed -i 's,LOAD_KEXEC=false,LOAD_KEXEC=true,' /etc/default/kexec
EOCHROOT
    fi
}

install_keyboard_chroot() {
    log "Installing keyboard in chroot"
    cp /tmp/kb_console_selections.conf "$MOUNTPOINT"/tmp/
    cat > "$MOUNTPOINT"/tmp/kb_setup.sh <<'KBEOF'
#!/bin/bash
set -x
debconf-set-selections < /tmp/kb_console_selections.conf
export DEBIAN_FRONTEND=noninteractive
apt-get install -yq keyboard-configuration console-setup
dpkg-reconfigure -f noninteractive keyboard-configuration
dpkg-reconfigure -f noninteractive console-setup
KBEOF
    chmod +x "$MOUNTPOINT"/tmp/kb_setup.sh
    chroot "$MOUNTPOINT" /bin/bash -x /tmp/kb_setup.sh
}

install_zfsbootmenu() {
    log "Installing ZFSBootMenu ($BOOT_MODE)"

    local zbm_image_dir
    if [ "$BOOT_MODE" = "bios" ]; then
        zbm_image_dir="/boot/syslinux"
    else
        zbm_image_dir="/boot/efi/EFI/zbm"
    fi

    ## Set ZFS boot commandline
    chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
zfs set org.zfsbootmenu:commandline="spl_hostid=\$(hostid) ro${CMDLINE_EXTRA:+ $CMDLINE_EXTRA}" "$POOL_NAME"/ROOT
echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
EOCHROOT

    ## Write ZBM install script (runs inside chroot)
    cat > "$MOUNTPOINT"/tmp/install_zbm.sh <<ZBMEOF
#!/bin/bash
set -x
apt update
apt-get install -y debconf-utils || true

## ZFSBootMenu build dependencies
apt-get install --yes bsdextrautils mbuffer
apt-get install --yes --no-install-recommends \
    libsort-versions-perl \
    libboolean-perl \
    libyaml-pp-perl \
    git \
    fzf \
    make \
    kexec-tools \
    dracut-core \
    cpio
apt-get install --yes curl

## Clone and build ZFSBootMenu
mkdir -p /usr/local/src/zfsbootmenu
cd /usr/local/src/zfsbootmenu
git clone https://github.com/zbm-dev/zfsbootmenu .
make core dracut

## Configure ZBM
kb_layoutcode="\$(debconf-get-selections 2>/dev/null | grep keyboard-configuration/layoutcode | awk '{print \$4}' || echo 'us')"
[ -z "\$kb_layoutcode" ] && kb_layoutcode="us"

sed \
    -e 's,ManageImages:.*,ManageImages: true,' \
    -e "s@ImageDir:.*@ImageDir: ${zbm_image_dir}@" \
    -e 's,Versions:.*,Versions: false,' \
    -e "/CommandLine/s,ro,rd.vconsole.keymap=\${kb_layoutcode} ro," \
    -i /etc/zfsbootmenu/config.yaml

sed -i 's,ro quiet,ro,' /etc/zfsbootmenu/config.yaml

if [ "$BOOT_MODE" = "bios" ]; then
    sed -i 's,BootMountPoint:.*,BootMountPoint: /boot/syslinux,' /etc/zfsbootmenu/config.yaml
fi

update-initramfs -c -k all
generate-zbm --debug

## BIOS: configure syslinux
if [ "$BOOT_MODE" = "bios" ]; then
    mkdir -p /boot/syslinux
    cp /usr/lib/syslinux/modules/bios/*.c32 /boot/syslinux/ || \
    cp /usr/lib/syslinux/*.c32 /boot/syslinux/ || true

    cat > /boot/syslinux/syslinux.cfg <<'SYSCFG'
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT zfsbootmenu

MENU TITLE ZFSBootMenu

LABEL zfsbootmenu
    MENU LABEL ZFSBootMenu
    LINUX /vmlinuz.EFI
    INITRD /initramfs.img
    APPEND zbm.timeout=3 ro loglevel=4

LABEL zfsbootmenu-backup
    MENU LABEL ZFSBootMenu (Backup)
    LINUX /vmlinuz-backup.EFI
    INITRD /initramfs-backup.img
    APPEND zbm.timeout=3 ro loglevel=4
SYSCFG

    ## Symlinks for ZBM image names
    cd /boot/syslinux
    for kernel in vmlinuz*-bootmenu; do
        [ -e "\$kernel" ] && ln -sf "\$kernel" vmlinuz.EFI && echo "Linked \$kernel -> vmlinuz.EFI"
        break
    done
    for initrd in initramfs*-bootmenu.img; do
        [ -e "\$initrd" ] && ln -sf "\$initrd" initramfs.img && echo "Linked \$initrd -> initramfs.img"
        break
    done

    extlinux --install /boot/syslinux
fi

## UEFI: create refind_linux.conf
if [ "$BOOT_MODE" = "uefi" ]; then
    mkdir -p /boot/efi/EFI/zbm
    cat > /boot/efi/EFI/zbm/refind_linux.conf <<'REFIND'
"Boot default"  "zbm.timeout=3 ro loglevel=4"
"Boot to menu"  "zbm.show ro loglevel=4"
REFIND
fi

## Extra kernel params (CMDLINE_EXTRA) on the ZBM entries - kernel-proper
## params like console= must live here, not in the image's /etc/cmdline.d.
if [ -n "$CMDLINE_EXTRA" ]; then
    if [ "$BOOT_MODE" = "bios" ]; then
        sed -i "s@ro loglevel=4@ro loglevel=4 $CMDLINE_EXTRA@g" /boot/syslinux/syslinux.cfg
    else
        sed -i "s@ro loglevel=4@ro loglevel=4 $CMDLINE_EXTRA@g" /boot/efi/EFI/zbm/refind_linux.conf
    fi
fi
ZBMEOF

    ## --- Optional encryption add-ons, appended to the ZBM install script -----
    ## These run AFTER the main body above (so config.yaml + bootloader configs
    ## exist) and end with a second generate-zbm to rebuild the images with the
    ## dracut additions. Guarded here at generation time so a plain install's
    ## ZBM script is unchanged.

    ## Boot-time key fetch: dracut networking + curl + a ZBM setup hook that
    ## fetches the key and load-keys the pool, making the boot countdown
    ## unattended. Any failure falls back to ZBM's normal console prompt.
    ## The hook + dracut conf are written DIRECTLY into the target here (not via
    ## the chroot script) so the hook body needs no nested-heredoc escaping:
    ## it is fully literal ('HOOK'), with __PLACEHOLDERS__ substituted by sed.
    if [ "$ENCRYPTION" = "on" ] && [ -n "$ZBM_KEYFETCH_URL" ]; then
        local ca_path=""
        if [ -n "$ZBM_KEYFETCH_CA" ]; then
            ca_path="/etc/zfsbootmenu/keyfetch-ca.pem"
            ## -D: /etc/zfsbootmenu doesn't exist in the target yet (the mkdir
            ## below and ZBM's make install both come later). The harness never
            ## caught this: its test config uses plain http:// with no CA.
            install -D -m 644 "$ZBM_KEYFETCH_CA" "$MOUNTPOINT$ca_path"
        fi
        ## load-key.d is the documented stage for this: it runs immediately
        ## before EVERY unlock attempt - including the zbm.timeout auto-boot
        ## path. (setup.d hooks are SKIPPED when the countdown expires - a
        ## keyfetch hook there never runs unattended; found the hard way.)
        ## Hooks under /etc/zfsbootmenu/hooks/<stage>.d are auto-installed by
        ## the ZBM dracut module (zfsbootmenu_hook_root default).
        mkdir -p "$MOUNTPOINT"/etc/zfsbootmenu/hooks/load-key.d \
                 "$MOUNTPOINT"/etc/zfsbootmenu/dracut.conf.d

        cat > "$MOUNTPOINT"/etc/zfsbootmenu/hooks/load-key.d/keyfetch.sh <<'HOOK'
#!/bin/sh
## ZBM load-key.d hook: runs right before ZBM attempts to unlock a dataset
## (ZBM_ENCRYPTION_ROOT/ZBM_LOCKED_FS are set by ZBM). Fetch the pool key
## from the key server and load it so the unlock - menu or countdown -
## proceeds unattended. Prefer an IP-literal URL - there is no DNS in this
## initramfs. On failure ZBM falls back to its console prompt (and dropbear,
## if built in). The retry loop rides out DHCP still settling.
POOL="__POOL__"
URL="__URL__"
CA="__CA__"
[ "${ZBM_ENCRYPTION_ROOT:-$POOL}" = "$POOL" ] || exit 0
[ "$(zfs get -H -o value keystatus "$POOL" 2>/dev/null)" = "unavailable" ] || exit 0
i=0
while [ $i -lt 12 ]; do
    if [ -n "$CA" ]; then
        curl -sf --connect-timeout 5 --cacert "$CA" -o /zbm.key "$URL" && break
    else
        curl -sf --connect-timeout 5 -o /zbm.key "$URL" && break
    fi
    i=$((i+1)); sleep 5
done
if [ -s /zbm.key ]; then
    zfs load-key -L file:///zbm.key "$POOL" && echo "keyfetch: key loaded for $POOL"
fi
rm -f /zbm.key
exit 0
HOOK
        sed -i \
            -e "s|__POOL__|$POOL_NAME|" \
            -e "s|__URL__|$ZBM_KEYFETCH_URL|" \
            -e "s|__CA__|$ca_path|" \
            "$MOUNTPOINT"/etc/zfsbootmenu/hooks/load-key.d/keyfetch.sh
        chmod 755 "$MOUNTPOINT"/etc/zfsbootmenu/hooks/load-key.d/keyfetch.sh

        ## Networking for the ZBM initramfs rides INSIDE the image via
        ## /etc/cmdline.d (the documented mechanism) - no bootloader-entry
        ## editing needed for it. Kernel-proper params (console=...) can't go
        ## here; those are CMDLINE_EXTRA's job on the bootloader entries.
        mkdir -p "$MOUNTPOINT"/etc/cmdline.d
        echo "$ZBM_NET_ARGS" > "$MOUNTPOINT"/etc/cmdline.d/dracut-network.conf

        cat > "$MOUNTPOINT"/etc/zfsbootmenu/dracut.conf.d/keyfetch.conf <<DRACUTCONF
add_dracutmodules+=" network-legacy "
install_items+=" /usr/bin/curl ${ca_path:+$ca_path} "
install_optional_items+=" /etc/cmdline.d/dracut-network.conf "
DRACUTCONF

        cat >> "$MOUNTPOINT"/tmp/install_zbm.sh <<'KEYFETCHEOF'

## --- ZBM boot-time key fetch (unattended unlock) ---
## dracut's network/network-legacy modules refuse to install without their
## userspace tools (dhclient, arping) - a minimal debootstrap lacks them.
apt-get install --yes --no-install-recommends dracut-network isc-dhcp-client iputils-arping
KEYFETCHEOF
    fi

    ## Dropbear ssh in the ZBM initramfs (remote rescue of a stuck boot): the
    ## dracut-crypt-ssh module per the upstream ZBM remote-access docs. Its
    ## LUKS console/unlock helpers are compiled binaries we neither build nor
    ## need - strip them from module-setup.sh or the dracut build fails.
    ## Host keys are generated ONCE into /etc/dropbear on the target so ZBM
    ## rebuilds keep a stable ssh host identity.
    if [ "$ZBM_DROPBEAR" = "on" ]; then
        install -D -m 600 "$ZBM_DROPBEAR_KEYS" "$MOUNTPOINT"/etc/dropbear/authorized_keys
        cat >> "$MOUNTPOINT"/tmp/install_zbm.sh <<DROPBEAREOF

## --- ZBM dropbear (remote rescue ssh) ---
## Per the upstream ZBM remote-access docs. crypt-ssh depends on the dracut
## network module (same userspace deps as the keyfetch block; idempotent) AND
## on the dracut crypt module, which refuses to install without cryptsetup.
apt-get install --yes --no-install-recommends dracut-network isc-dhcp-client iputils-arping
apt-get install --yes --no-install-recommends dropbear-bin cryptsetup openssh-client
[ -d /usr/local/src/dracut-crypt-ssh ] || \\
    git clone https://github.com/dracut-crypt-ssh/dracut-crypt-ssh /usr/local/src/dracut-crypt-ssh
cp -r /usr/local/src/dracut-crypt-ssh/modules/60crypt-ssh /usr/lib/dracut/modules.d/
## Strip the LUKS console/unlock helper installs (compiled binaries we neither
## build nor need - the docs' "remove the helper lines from install()" step).
sed -i -E '/console_auth|console_peek|unlock/d' /usr/lib/dracut/modules.d/60crypt-ssh/module-setup.sh

## Host keys: OpenSSH PEM format - the module converts them itself with
## dropbearconvert at image build (dropbearkey-native keys break that step,
## "dropbearconvert for RSA key failed"). Generated once and kept, so rebuilt
## images keep a stable ssh identity.
mkdir -p /etc/dropbear /etc/zfsbootmenu/dracut.conf.d
for keytype in rsa ecdsa; do
    [ -f "/etc/dropbear/ssh_host_\${keytype}_key" ] || \\
        ssh-keygen -N "" -m PEM -t "\$keytype" -f "/etc/dropbear/ssh_host_\${keytype}_key"
done

cat > /etc/zfsbootmenu/dracut.conf.d/dropbear.conf <<DBCONF
add_dracutmodules+=" crypt-ssh "
install_optional_items+=" /etc/cmdline.d/dracut-network.conf "
dropbear_port="$ZBM_DROPBEAR_PORT"
dropbear_acl="/etc/dropbear/authorized_keys"
dropbear_rsa_key="/etc/dropbear/ssh_host_rsa_key"
dropbear_ecdsa_key="/etc/dropbear/ssh_host_ecdsa_key"
DBCONF
DROPBEAREOF
    fi

    ## Rebuild the ZBM images with the additions, and put the network args on
    ## the ZBM kernel commandline (both bootloader flavors, both entries).
    if { [ "$ENCRYPTION" = "on" ] && [ -n "$ZBM_KEYFETCH_URL" ]; } || [ "$ZBM_DROPBEAR" = "on" ]; then
        cat >> "$MOUNTPOINT"/tmp/install_zbm.sh <<REGENEOF

## --- Rebuild ZBM with the encryption add-ons ---
## (Networking args ride inside the image via /etc/cmdline.d - no bootloader
## edits needed for them.) Fail LOUDLY: install_zbm.sh has no set -e, and a
## failed regen would leave the first-pass images (no keyfetch/dropbear) on
## the ESP - a boot-to-prompt trap.
generate-zbm --debug || { echo "FATAL: ZBM regen with encryption add-ons failed"; exit 1; }

## BIOS: the regen ROTATES/PRUNES the image names the main body symlinked
## (vmlinuz-bootmenu -> vmlinuz.old-bootmenu etc.), and syslinux loads FIXED
## names from its cfg - unlike rEFInd it scans nothing. Without this refresh
## the box goes DARK with nothing to load (found on the first real BIOS
## encrypted install; the QEMU encryption harness is UEFI-only).
if [ "$BOOT_MODE" = "bios" ]; then
    cd /boot/syslinux
    for kernel in vmlinuz*-bootmenu; do
        [ -e "\$kernel" ] && ln -sf "\$kernel" vmlinuz.EFI && ln -sf "\$kernel" vmlinuz-backup.EFI && echo "Relinked \$kernel -> vmlinuz.EFI"
        break
    done
    for initrd in initramfs*-bootmenu.img; do
        [ -e "\$initrd" ] && ln -sf "\$initrd" initramfs.img && ln -sf "\$initrd" initramfs-backup.img && echo "Relinked \$initrd -> initramfs.img"
        break
    done
    [ -e vmlinuz.EFI ] && [ -e initramfs.img ] || { echo "FATAL: syslinux image links missing after regen"; exit 1; }
fi
REGENEOF
    fi

    chroot "$MOUNTPOINT" /bin/bash -x /tmp/install_zbm.sh

    ## BIOS: write GPT MBR boot code (must be outside chroot)
    if [ "$BOOT_MODE" = "bios" ]; then
        log "Writing GPT MBR boot code"
        local gptmbr=""
        for loc in /usr/lib/syslinux/mbr/gptmbr.bin \
                   /usr/lib/syslinux/gptmbr.bin \
                   "$MOUNTPOINT"/usr/lib/syslinux/mbr/gptmbr.bin \
                   "$MOUNTPOINT"/usr/lib/syslinux/gptmbr.bin; do
            [ -f "$loc" ] && gptmbr="$loc" && break
        done
        if [ -z "$gptmbr" ]; then
            apt install --yes syslinux-common
            gptmbr="/usr/lib/syslinux/mbr/gptmbr.bin"
        fi
        dd bs=440 count=1 conv=notrunc if="$gptmbr" of=/dev/disk/by-id/"$DISKID"
    fi
}

finalize_system() {
    log "Finalizing system"
    chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
## Root password
echo "root:$USERPASS" | chpasswd -c SHA256

## tmpfs on /tmp
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

## Preserve boot messages on tty1 (don't clear screen at login)
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/noclear.conf <<'NOCLEAR'
[Service]
TTYVTDisallocate=no
NOCLEAR

## System groups
addgroup --system lpadmin 2>/dev/null || true
addgroup --system sambashare 2>/dev/null || true

## Disable log compression (ZFS handles it)
for file in /etc/logrotate.d/*; do
    if grep -Eq "(^|[^#y])compress" "\$file"; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "\$file"
    fi
done

## Update initramfs
update-initramfs -c -k all
EOCHROOT
}

setup_user() {
    log "Setting up user: $USERNAME"
    chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
adduser --disabled-password --gecos "" "$USERNAME"
cp -a /etc/skel/. /home/"$USERNAME"
chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"

for grp in adm cdrom dip plugdev sudo lpadmin sambashare; do
    if getent group "\$grp" >/dev/null 2>&1; then
        usermod -a -G "\$grp" "$USERNAME"
    fi
done

echo "$USERNAME:$USERPASS" | chpasswd
EOCHROOT

    ## Bake in SSH public keys so config-management/CI + operators can reach the
    ## box before any password login. AUTHORIZED_KEYS is a file of pubkeys copied
    ## verbatim into ~USERNAME/.ssh/authorized_keys (same file-path convention as
    ## NETPLAN_FILE; resolved relative to the script dir if not an absolute path).
    if [ -n "$AUTHORIZED_KEYS" ]; then
        [ -f "$AUTHORIZED_KEYS" ] || AUTHORIZED_KEYS="$SCRIPT_DIR/$AUTHORIZED_KEYS"
        [ -f "$AUTHORIZED_KEYS" ] || die "AUTHORIZED_KEYS not found: $AUTHORIZED_KEYS"
        log "Installing authorized_keys for $USERNAME from $AUTHORIZED_KEYS"
        install -d -m 700 "$MOUNTPOINT/home/$USERNAME/.ssh"
        install -m 600 "$AUTHORIZED_KEYS" "$MOUNTPOINT/home/$USERNAME/.ssh/authorized_keys"
        chroot "$MOUNTPOINT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
    fi
}

fix_mount_ordering() {
    log "Fixing ZFS mount ordering"

    ## Set cachefile so ZFSBootMenu can find the pool at boot
    ## (zpool create -R sets cachefile=none by default)
    zpool set cachefile="$MOUNTPOINT"/etc/zfs/zpool.cache "$POOL_NAME"

    chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/$POOL_NAME
zed -F &
sleep 2

while [ ! -s /etc/zfs/zfs-list.cache/$POOL_NAME ]; do
    zfs set canmount=noauto $POOL_NAME/ROOT/ubuntu
    sleep 1
done
cat /etc/zfs/zfs-list.cache/$POOL_NAME

pkill -9 "zed*" || true
sleep 2

sed -Ei "s|$MOUNTPOINT/?|/|" /etc/zfs/zfs-list.cache/$POOL_NAME
cat /etc/zfs/zfs-list.cache/$POOL_NAME
EOCHROOT
}

preserve_install_files() {
    log "Preserving install files to target"
    local install_dir="$MOUNTPOINT/root/zfsbootmenu-autoinstall"
    mkdir -p "$install_dir/configs"

    for f in zfs-install.sh zfs-mirror.sh; do
        [ -f "$SCRIPT_DIR/$f" ] && cp "$SCRIPT_DIR/$f" "$install_dir/"
    done
    cp "$CONFIG_FILE" "$install_dir/configs/"
    [ -f "$LOG_DIR/$INSTALL_LOG" ] && cp "$LOG_DIR/$INSTALL_LOG" "$install_dir/" || true
    ls -la "$install_dir"
}

unmount_all() {
    log "Unmounting"
    mount --make-rslave "$MOUNTPOINT"/dev  2>/dev/null || true
    mount --make-rslave "$MOUNTPOINT"/proc 2>/dev/null || true
    mount --make-rslave "$MOUNTPOINT"/sys  2>/dev/null || true
    grep "$MOUNTPOINT" /proc/mounts | cut -f2 -d" " | sort -r | xargs umount -n 2>/dev/null || true
    umount -R "$MOUNTPOINT" 2>/dev/null || true
    ## A failed export is not fatal (same-hostid force-import handles the next
    ## boot) but must be VISIBLE: a silently-imported leftover pool broke rerun
    ## cleanup badly enough to require a live-env reboot.
    zpool export "$POOL_NAME" \
        || echo "WARNING: could not export $POOL_NAME (busy) - a rerun of this installer needs a rebooted live environment"
}

##============================================================================
## Postreboot functions
##============================================================================

install_distro() {
    log "Installing Ubuntu ($DISTRO)"
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt dist-upgrade --yes

    case "$DISTRO" in
        server)
            apt install --yes ubuntu-server
            ;;
        kubuntu)
            echo sddm shared/default-x-display-manager select sddm | debconf-set-selections
            apt install --yes kubuntu-desktop
            ;;
    esac

    ## For desktop variants only: switch netplan to NetworkManager
    if [ "$DISTRO" != "server" ] && dpkg-query --show --showformat='${db:Status-Status}\n' network-manager 2>/dev/null | grep -q installed; then
        log "Configuring NetworkManager"
        local ethprefix="e"
        local iface
        iface="$(basename "$(find /sys/class/net -maxdepth 1 -mindepth 1 -name "${ethprefix}*" | head -1)")"
        rm -f /etc/netplan/01-netplan.yaml
        cat > /etc/netplan/01-network-manager-all.yaml <<EOF
network:
  version: 2
  renderer: NetworkManager
EOF
        systemctl stop systemd-networkd 2>/dev/null || true
        systemctl disable systemd-networkd 2>/dev/null || true
        netplan apply
    fi
}


install_extra_packages_chroot() {
    log "Installing extra packages in chroot"
    chroot "$MOUNTPOINT" /bin/bash -x <<EOCHROOT
apt install -yq \
    openssh-server \
    command-not-found \
    parted \
    cifs-utils \
    man-db \
    tldr \
    locate
EOCHROOT
}

##============================================================================
## Main
##============================================================================

main_initial() {
    start_logging
    log "INITIAL ZFS INSTALLATION"
    echo "WARNING: This will DESTROY all data on disk $DISKID"
    echo "Proceeding in 5 seconds..."
    sleep 5

    check_environment
    validate_boot_mode

    setup_live_apt
    install_live_packages
    configure_keyboard_live

    cleanup_target_disk
    partition_disk
    create_zfs_pool
    create_datasets

    run_debootstrap

    configure_system_base
    install_zfs_packages
    setup_encryption_target
    setup_boot_partition
    install_keyboard_chroot
    install_zfsbootmenu
    finalize_system
    setup_user
    install_extra_packages_chroot

    rm -f "$MOUNTPOINT"/etc/apt/apt.conf.d/30apt_error_on_transient
    fix_mount_ordering
    preserve_install_files
    unmount_all

    log "INITIAL INSTALLATION COMPLETE"
    echo ""
    echo "=============================================="
    echo "NEXT STEPS:"
    echo "1. Reboot and boot from internal disk"
    echo "2. SSH in as $USERNAME (openssh-server is installed)"
    echo "3. Run: sudo /root/zfsbootmenu-autoinstall/zfs-install.sh configs/$(basename "$CONFIG_FILE") postreboot"
    echo "=============================================="
}

main_postreboot() {
    start_logging
    log "POST-REBOOT SETUP"

    if nc -zw5 archive.ubuntu.com 443 2>/dev/null; then
        log "Internet connectivity OK"
    else
        die "No internet connectivity"
    fi

    install_distro
    rm -f /etc/apt/apt.conf.d/30apt_error_on_transient

    log "INSTALLATION FULLY COMPLETE"
    echo ""
    echo "=============================================="
    echo "Reboot recommended."
    echo "=============================================="
}

## Entry point
CONFIG_FILE="${1:-}"
ACTION="${2:-}"
[ -n "$CONFIG_FILE" ] && [ -n "$ACTION" ] || print_usage
[ "$(id -u)" -eq 0 ] || die "Must be run as root"
load_config "$CONFIG_FILE"

case "$ACTION" in
    initial)    main_initial ;;
    postreboot) main_postreboot ;;
    *)          die "Unknown action: $ACTION (use: initial or postreboot)" ;;
esac
date
