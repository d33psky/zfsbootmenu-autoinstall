#!/bin/bash
## Fully-headless BIOS (SeaBIOS) test harness - the legacy-boot sibling of
## test-uefi-headless.sh (no GUI, driven over SSH + a serial socket).
##
## Boots the Ubuntu cloud image as the live environment (cloud-init from
## test/user-data injects an SSH key) with one blank target disk virtio-bios0,
## on QEMU's default SeaBIOS firmware - the same legacy path as e.g. a
## coreboot/SeaBIOS Chromebook.
##
##   create     - make the blank target disk (bios-disk0.qcow2, sparse)
##   prep       - build the cloud-init seed.iso + a fresh live overlay
##   live       - boot cloud image + seed + target (run with & or in bg)
##   installed  - boot ONLY the target disk = the real installed system
##   clean      - remove this harness's generated artifacts (keeps the cloud image)
##
## The serial port is a UNIX socket (test/serial-bios.sock) logged to
## test/serial-bios-<mode>.log, so a test can TYPE at the console - e.g. the
## ZBM passphrase prompt of a KEYFORMAT=passphrase install:
##   printf 'my passphrase\r' | socat - UNIX-CONNECT:test/serial-bios.sock
## For ZBM/kernel output on serial, the config needs CMDLINE_EXTRA="console=tty0 console=ttyS0".

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/test"
RAM="${RAM:-4G}"
DISK_SIZE="${DISK_SIZE:-64G}"
SSH_PORT="2222"

CLOUD_BASE="${TEST_DIR}/noble-server-cloudimg-amd64.img"
LIVE_OVERLAY="${TEST_DIR}/bios-live-overlay.qcow2"
SEED="${TEST_DIR}/seed.iso"
DISK0="${TEST_DIR}/bios-disk0.qcow2"
SERIAL_SOCK="${TEST_DIR}/serial-bios.sock"

QEMU_BASE=(
    qemu-system-x86_64
    -machine pc -cpu host -enable-kvm -m "$RAM" -smp 2
    -nic user,model=virtio-net-pci,hostfwd=tcp::"${SSH_PORT}"-:22
    -display none
    ## HMP monitor: screen dumps when serial is silent (firmware/bootloader stage)
    ##   echo 'screendump test/console.ppm' | socat - UNIX-CONNECT:test/monitor-bios.sock
    -monitor unix:"${TEST_DIR}/monitor-bios.sock",server=on,wait=off
)

serial_args() {   ## $1 = mode (live|installed)
    rm -f "$SERIAL_SOCK"
    echo -chardev "socket,id=ser0,path=${SERIAL_SOCK},server=on,wait=off,logfile=${TEST_DIR}/serial-bios-$1.log" \
         -serial chardev:ser0
}

cmd_create() {
    [ -f "$DISK0" ] && { echo "exists: $DISK0 (clean first)"; exit 1; }
    qemu-img create -q -f qcow2 "$DISK0" "$DISK_SIZE"
    echo "target: $DISK0 ($DISK_SIZE, sparse)"
}

cmd_prep() {
    [ -f "$CLOUD_BASE" ] || { echo "missing $CLOUD_BASE (download it first)"; exit 1; }
    [ -f "$DISK0" ] || { echo "missing $DISK0 - run: $0 create"; exit 1; }
    genisoimage -quiet -output "$SEED" -volid CIDATA -joliet -rock \
        "${TEST_DIR}/user-data" "${TEST_DIR}/meta-data"
    rm -f "$LIVE_OVERLAY"
    qemu-img create -q -f qcow2 -b "$CLOUD_BASE" -F qcow2 "$LIVE_OVERLAY" 10G
    echo "seed: $SEED ; live overlay: $LIVE_OVERLAY"
}

cmd_live() {
    echo "=== live (cloud image + seed + target) ; ssh -p ${SSH_PORT} <user-data user>@localhost ==="
    # shellcheck disable=SC2046
    exec "${QEMU_BASE[@]}" \
        -drive file="$LIVE_OVERLAY",format=qcow2,if=none,id=live \
        -device virtio-blk-pci,drive=live,bootindex=0 \
        -drive file="$SEED",format=raw,if=virtio,readonly=on \
        -drive file="$DISK0",format=qcow2,if=none,id=d0 \
        -device virtio-blk-pci,drive=d0,serial=bios0 \
        $(serial_args live)
}

cmd_installed() {
    echo "=== installed (target only) ; serial: ${SERIAL_SOCK} ==="
    # shellcheck disable=SC2046
    exec "${QEMU_BASE[@]}" \
        -drive file="$DISK0",format=qcow2,if=none,id=d0 \
        -device virtio-blk-pci,drive=d0,serial=bios0,bootindex=0 \
        $(serial_args installed)
}

cmd_clean() {
    rm -f "$LIVE_OVERLAY" "$DISK0" "$SERIAL_SOCK" "${TEST_DIR}"/serial-bios-*.log
}

case "${1:-}" in
    create|prep|live|installed|clean) "cmd_$1" ;;
    *) sed -n '2,21p' "$0" | sed 's/^## \{0,1\}//'; exit 1 ;;
esac
