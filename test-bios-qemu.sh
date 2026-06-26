#!/bin/bash
##Test script for BIOS boot mode with QEMU
##Creates a virtual disk and boots Ubuntu live ISO to test the installation script

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/test"
DISK_SIZE="20G"
RAM="4G"

##Ubuntu 24.04 live server ISO URL
ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso"
ISO_FILE="${TEST_DIR}/ubuntu-24.04-live-server-amd64.iso"

usage() {
    cat <<-EOF
	Usage: $0 <command>

	Commands:
	  setup     - Create test directory and download ISO
	  create    - Create virtual disk
	  boot      - Boot QEMU with live ISO (for installation)
	  bootdisk  - Boot QEMU from installed disk (for testing)
	  clean     - Remove test directory

	Requirements:
	  - qemu-system-x86_64
	  - At least ${DISK_SIZE} free disk space
	  - At least ${RAM} RAM for VM

	EOF
    exit 1
}

cmd_setup() {
    echo "=== Setting up test environment ==="
    mkdir -p "$TEST_DIR"

    if [ ! -f "$ISO_FILE" ]; then
        echo "Downloading Ubuntu 24.04 live server ISO..."
        echo "URL: $ISO_URL"
        wget -O "$ISO_FILE" "$ISO_URL"
    else
        echo "ISO already exists: $ISO_FILE"
    fi

    echo "Setup complete."
}

cmd_create() {
    echo "=== Creating virtual disk ==="
    mkdir -p "$TEST_DIR"

    if [ -f "${TEST_DIR}/test-disk.qcow2" ]; then
        echo "Disk already exists. Remove with 'clean' command first."
        exit 1
    fi

    qemu-img create -f qcow2 "${TEST_DIR}/test-disk.qcow2" "$DISK_SIZE"
    echo "Created: ${TEST_DIR}/test-disk.qcow2 (${DISK_SIZE})"
}

cmd_boot() {
    echo "=== Booting QEMU with live ISO (BIOS mode) ==="

    if [ ! -f "$ISO_FILE" ]; then
        echo "Error: ISO not found. Run 'setup' first."
        exit 1
    fi

    if [ ! -f "${TEST_DIR}/test-disk.qcow2" ]; then
        echo "Error: Virtual disk not found. Run 'create' first."
        exit 1
    fi

    echo ""
    echo "Once booted to live environment:"
    echo "1. Open terminal"
    echo "2. Run: sudo -i"
    echo "3. Install packages: apt update && apt install -y git"
    echo "4. Clone or copy the zfsbootmenu-autoinstall directory"
    echo "5. Use existing config: configs/qemu-bios-test.conf (BOOT_MODE=bios, DISKID=virtio-test-disk)"
    echo "6. Run: ./zfs-install.sh configs/qemu-bios-test.conf initial"
    echo ""
    echo "The virtual disk will appear as /dev/vda"
    echo "Disk ID: virtio-test-disk"
    echo ""

    qemu-system-x86_64 \
        -machine pc \
        -cpu host \
        -enable-kvm \
        -m "$RAM" \
        -smp 2 \
        -drive file="${TEST_DIR}/test-disk.qcow2",format=qcow2,if=virtio,id=test-disk \
        -cdrom "$ISO_FILE" \
        -boot d \
        -nic user,model=virtio-net-pci \
        -display gtk \
        -vga virtio
}

cmd_bootdisk() {
    echo "=== Booting from installed disk (BIOS mode) ==="

    if [ ! -f "${TEST_DIR}/test-disk.qcow2" ]; then
        echo "Error: Virtual disk not found."
        exit 1
    fi

    qemu-system-x86_64 \
        -machine pc \
        -cpu host \
        -enable-kvm \
        -m "$RAM" \
        -smp 2 \
        -drive file="${TEST_DIR}/test-disk.qcow2",format=qcow2,if=virtio,id=test-disk \
        -boot c \
        -nic user,model=virtio-net-pci \
        -display gtk \
        -vga virtio
}

cmd_clean() {
    echo "=== Cleaning test directory ==="
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
        echo "Removed: $TEST_DIR"
    else
        echo "Test directory doesn't exist."
    fi
}

##Main
case "${1:-}" in
    setup)    cmd_setup ;;
    create)   cmd_create ;;
    boot)     cmd_boot ;;
    bootdisk) cmd_bootdisk ;;
    clean)    cmd_clean ;;
    *)        usage ;;
esac
