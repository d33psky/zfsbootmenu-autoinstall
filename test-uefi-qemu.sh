#!/bin/bash
## Test harness for UEFI boot mode (OVMF) with QEMU.
## Presents TWO virtio disks (virtio-nvme0, virtio-nvme1) so we can test both:
##   - zfs-install.sh  (UEFI rEFInd + ZFSBootMenu, bounded root + reserved part)
##   - zfs-mirror.sh   (UEFI root mirror on the second disk)
##
## The serial= form is required so the disks appear under /dev/disk/by-id/
## as virtio-nvme0 / virtio-nvme1 (matches configs/qemu-uefi-test.conf).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/test"
DISK_SIZE="30G"
RAM="4G"

OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_SRC="/usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_VARS="${TEST_DIR}/OVMF_VARS_test.fd"   ## writable per-VM NVRAM (keeps efibootmgr entries)

DISK0="${TEST_DIR}/uefi-nvme0.qcow2"
DISK1="${TEST_DIR}/uefi-nvme1.qcow2"

ISO_FILE="${TEST_DIR}/ubuntu-24.04-live-server-amd64.iso"
ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso"

usage() {
    cat <<-EOF
	Usage: $0 <command>

	Commands:
	  setup     - Create test dir and download the live ISO (if missing)
	  create    - Create the two virtual disks + a writable OVMF NVRAM copy
	  boot      - Boot QEMU with the live ISO (for installation)
	  bootdisk  - Boot QEMU from the installed disks (no ISO)
	  clean     - Remove the qcow2 disks + NVMR copy (keeps the ISO)

	Requires: qemu-system-x86_64, /dev/kvm, ovmf, sshpass. SSH is forwarded
	on localhost:2222 (hostfwd) for both the live env and the installed system.
	EOF
    exit 1
}

require() {
    [ -e /dev/kvm ] || { echo "ERROR: /dev/kvm not present"; exit 1; }
    command -v qemu-system-x86_64 >/dev/null || { echo "ERROR: qemu-system-x86_64 missing"; exit 1; }
    [ -f "$OVMF_CODE" ] || { echo "ERROR: $OVMF_CODE missing (install ovmf)"; exit 1; }
}

cmd_setup() {
    echo "=== Setup ==="
    mkdir -p "$TEST_DIR"
    if [ ! -f "$ISO_FILE" ]; then
        echo "Downloading $ISO_URL"
        wget -O "$ISO_FILE" "$ISO_URL"
    else
        echo "ISO present: $ISO_FILE"
    fi
}

cmd_create() {
    echo "=== Create disks + NVRAM ==="
    mkdir -p "$TEST_DIR"
    for d in "$DISK0" "$DISK1"; do
        if [ -f "$d" ]; then
            echo "exists: $d (run 'clean' to recreate)"
        else
            qemu-img create -f qcow2 "$d" "$DISK_SIZE"
            echo "created: $d ($DISK_SIZE)"
        fi
    done
    if [ ! -f "$OVMF_VARS" ]; then
        cp "$OVMF_VARS_SRC" "$OVMF_VARS"
        echo "created: $OVMF_VARS (writable UEFI NVRAM)"
    fi
}

cmd_boot() {
    require
    [ -f "$ISO_FILE" ] || { echo "Run 'setup' first."; exit 1; }
    [ -f "$DISK0" ] && [ -f "$DISK1" ] || { echo "Run 'create' first."; exit 1; }
    [ -f "$OVMF_VARS" ] || { echo "Run 'create' first (NVRAM)."; exit 1; }

    cat <<-EOF
	=== Booting live ISO (UEFI) ===
	Disks: /dev/disk/by-id/virtio-nvme0 and virtio-nvme1
	In the live env (get a shell, set a root password, start ssh), then:
	  scp -P 2222 zfs-install.sh zfs-mirror.sh root@localhost:/root/
	  scp -P 2222 configs/qemu-uefi-test.conf root@localhost:/root/
	  ssh -p 2222 root@localhost
	    ./zfs-install.sh qemu-uefi-test.conf initial
	Reboot (bootdisk), finish, then test the mirror:
	    ./zfs-mirror.sh qemu-uefi-test.conf -d   # dry run
	    ./zfs-mirror.sh qemu-uefi-test.conf -r   # attach virtio-nvme1
	EOF

    qemu-system-x86_64 \
        -machine q35 -cpu host -enable-kvm -m "$RAM" -smp 2 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$DISK0",format=qcow2,if=none,id=d0 \
        -device virtio-blk-pci,drive=d0,serial=nvme0 \
        -drive file="$DISK1",format=qcow2,if=none,id=d1 \
        -device virtio-blk-pci,drive=d1,serial=nvme1 \
        -cdrom "$ISO_FILE" -boot menu=on \
        -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
        -display gtk -vga virtio
}

cmd_bootdisk() {
    require
    [ -f "$DISK0" ] && [ -f "$DISK1" ] || { echo "Run 'create' first."; exit 1; }
    [ -f "$OVMF_VARS" ] || { echo "Run 'create' first (NVRAM)."; exit 1; }

    echo "=== Booting from installed disks (UEFI, no ISO) ==="
    qemu-system-x86_64 \
        -machine q35 -cpu host -enable-kvm -m "$RAM" -smp 2 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$DISK0",format=qcow2,if=none,id=d0 \
        -device virtio-blk-pci,drive=d0,serial=nvme0 \
        -drive file="$DISK1",format=qcow2,if=none,id=d1 \
        -device virtio-blk-pci,drive=d1,serial=nvme1 \
        -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
        -display gtk -vga virtio
}

cmd_clean() {
    echo "=== Clean (keeps the ISO) ==="
    rm -f "$DISK0" "$DISK1" "$OVMF_VARS"
    echo "removed disks + NVRAM"
}

case "${1:-}" in
    setup)    cmd_setup ;;
    create)   cmd_create ;;
    boot)     cmd_boot ;;
    bootdisk) cmd_bootdisk ;;
    clean)    cmd_clean ;;
    *)        usage ;;
esac
