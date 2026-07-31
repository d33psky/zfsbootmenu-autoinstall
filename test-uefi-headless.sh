#!/bin/bash
## Fully-headless UEFI test harness (no GUI, driven over SSH).
##
## Boots an Ubuntu cloud image as the live environment (cloud-init injects an
## SSH key + ZFS tooling) with two blank target disks virtio-nvme0/nvme1, so the
## whole zfs-install.sh + zfs-mirror.sh flow can be driven over ssh localhost:2222.
##
##   prep       - build the cloud-init seed.iso + live overlay + writable NVRAM
##   live       - boot cloud image + seed + nvme0/nvme1 (run with & or in bg)
##   installed  - boot ONLY nvme0/nvme1 (cloud image detached) to test real boot
##   clean      - remove generated artifacts (keeps base cloud image + nvme disks)
##
## Same NVRAM file is reused across live/installed so efibootmgr entries persist.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/test"
RAM="6G"
SSH_PORT="2222"
SSH_USER="${SSH_USER:-ubuntu}"   # must match the user defined in test/user-data

OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_SRC="/usr/share/OVMF/OVMF_VARS_4M.fd"
OVMF_VARS="${TEST_DIR}/OVMF_VARS_headless.fd"

CLOUD_BASE="${TEST_DIR}/noble-server-cloudimg-amd64.img"
LIVE_OVERLAY="${TEST_DIR}/live-overlay.qcow2"
SEED="${TEST_DIR}/seed.iso"
DISK0="${TEST_DIR}/uefi-nvme0.qcow2"
DISK1="${TEST_DIR}/uefi-nvme1.qcow2"

QEMU_BASE=(
    qemu-system-x86_64
    -machine q35 -cpu host -enable-kvm -m "$RAM" -smp 4
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$OVMF_VARS"
    ## 2222 -> guest sshd; 2223 -> dropbear in the ZBM initramfs (encrypted-
    ## install rescue testing; harmless when nothing listens on 222)
    -nic user,model=virtio-net-pci,hostfwd=tcp::"${SSH_PORT}"-:22,hostfwd=tcp::2223-:222
    -display none
)

cmd_prep() {
    echo "=== prep ==="
    [ -f "$CLOUD_BASE" ] || { echo "missing $CLOUD_BASE (download it first)"; exit 1; }
    [ -f "$DISK0" ] && [ -f "$DISK1" ] || { echo "missing target disks - run test-uefi-qemu.sh create"; exit 1; }

    genisoimage -quiet -output "$SEED" -volid CIDATA -joliet -rock \
        "${TEST_DIR}/user-data" "${TEST_DIR}/meta-data"
    echo "seed: $SEED"

    rm -f "$LIVE_OVERLAY"
    qemu-img create -q -f qcow2 -b "$CLOUD_BASE" -F qcow2 "$LIVE_OVERLAY" 10G
    echo "live overlay: $LIVE_OVERLAY"

    cp -f "$OVMF_VARS_SRC" "$OVMF_VARS"
    echo "nvram: $OVMF_VARS"
}

cmd_live() {
    echo "=== live (cloud image + seed + nvme0/nvme1) ; ssh ${SSH_USER}@localhost -p ${SSH_PORT} ==="
    exec "${QEMU_BASE[@]}" \
        -drive file="$LIVE_OVERLAY",format=qcow2,if=virtio \
        -drive file="$SEED",format=raw,if=virtio,readonly=on \
        -drive file="$DISK0",format=qcow2,if=none,id=d0 \
        -device virtio-blk-pci,drive=d0,serial=nvme0 \
        -drive file="$DISK1",format=qcow2,if=none,id=d1 \
        -device virtio-blk-pci,drive=d1,serial=nvme1 \
        -serial file:"${TEST_DIR}/serial-live.log"
}

cmd_installed() {
    echo "=== installed (nvme0/nvme1 only) ; ssh test@localhost -p ${SSH_PORT} ==="
    exec "${QEMU_BASE[@]}" \
        -drive file="$DISK0",format=qcow2,if=none,id=d0 \
        -device virtio-blk-pci,drive=d0,serial=nvme0 \
        -drive file="$DISK1",format=qcow2,if=none,id=d1 \
        -device virtio-blk-pci,drive=d1,serial=nvme1 \
        -serial file:"${TEST_DIR}/serial-installed.log"
}

cmd_clean() {
    rm -f "$SEED" "$LIVE_OVERLAY" "$OVMF_VARS" "${TEST_DIR}"/serial-*.log
    echo "cleaned (kept base cloud image + nvme disks)"
}

case "${1:-}" in
    prep)      cmd_prep ;;
    live)      cmd_live ;;
    installed) cmd_installed ;;
    clean)     cmd_clean ;;
    *) echo "Usage: $0 {prep|live|installed|clean}"; exit 1 ;;
esac
