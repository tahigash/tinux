#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Dedicated Empirical Challenge Verification Script for Challenger 1 (TASK-015)

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_challenger15_1.log"
LOG_FILE_NO_DEV="/tmp/tinux_adversarial_challenger15_1_nodev.log"
DISK_IMG="/tmp/tinux_disk_challenger15_1.img"
KERNEL_BIN="zig-out/bin/tinux"

ZIG_BIN="zig"
if ! command -v "$ZIG_BIN" >/dev/null 2>&1; then
    for cand_dir in "/c/Users/takashi/bin/zig-windows-x86_64-0.13.0" "$HOME/bin/zig"; do
        if [[ -f "$cand_dir/zig.exe" ]] || [[ -f "$cand_dir/zig" ]]; then
            ZIG_BIN="$cand_dir/zig"
            break
        fi
    done
fi

PYTHON_BIN="python"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    PYTHON_BIN="python3"
fi

echo "[CHALLENGER1_HARNESS] Running license guardrail check..."
"$PYTHON_BIN" scripts/check_license_guardrails.py

echo "[CHALLENGER1_HARNESS] Locating QEMU binary..."
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    for cand_dir in "/c/Users/takashi/bin/qemu" "/c/Program Files/qemu" "$HOME/bin/qemu" "/c/qemu"; do
        if [[ -f "$cand_dir/qemu-system-x86_64.exe" ]] || [[ -f "$cand_dir/qemu-system-x86_64" ]]; then
            export PATH="$cand_dir:$PATH"
            break
        fi
    done
fi

echo "[CHALLENGER1_HARNESS] Building userland test ELF and artifacts..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/tmp" "$INITRAMFS_ROOT/lib"

# 1. Build Challenger 1 adversarial test binary
"$ZIG_BIN" build-exe src/user/adversarial_task15_challenger1.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task15_challenger1"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task15_challenger1.o"

# 2. Build busybox / sh if not present
if [[ ! -f "$INITRAMFS_ROOT/bin/sh" ]]; then
    "$ZIG_BIN" build-exe src/user/tinux_busybox.zig \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/busybox"
    rm -f "$INITRAMFS_ROOT/bin/busybox.o"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/sh"
fi
chmod +x "$INITRAMFS_ROOT/bin/"*

# Ensure no /etc/rc.sh for interactive shell
rm -f "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[CHALLENGER1_HARNESS] Packaging initramfs.cpio..."
"$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[CHALLENGER1_HARNESS] Building Tinux kernel for TASK-015..."
"$ZIG_BIN" build -Dtask=TASK-015

# ==============================================================================
# PHASE 1: Positive Test with VirtIO-Block PCI Device Attached
# ==============================================================================
echo "[CHALLENGER1_HARNESS] Phase 1: Preparing host disk image for DMA verification..."
rm -f "$DISK_IMG"
dd if=/dev/zero of="$DISK_IMG" bs=1M count=1 status=none
printf "[TINUX_DISK_SECTOR0] Host-provisioned VirtIO-Block image ready!\n" | dd of="$DISK_IMG" conv=notrunc status=none

echo "[CHALLENGER1_HARNESS] Executing QEMU with VirtIO-Block DMA..."
(
    sleep 1.6
    "$PYTHON_BIN" -c '
import sys, time
def send(msg):
    try:
        if isinstance(msg, str):
            msg = msg.encode("latin1")
        for b in msg:
            sys.stdout.buffer.write(bytes([b]))
            sys.stdout.buffer.flush()
            time.sleep(0.001)
        time.sleep(0.05)
    except (OSError, BrokenPipeError):
        pass

send("/bin/adversarial_task15_challenger1\n")
time.sleep(1.0)
send("exit 0\n")
'
    sleep 2
) | timeout 25 qemu-system-x86_64 \
    -kernel "$KERNEL_BIN" \
    -nographic \
    -no-reboot \
    -serial stdio \
    -monitor none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -drive "file=$DISK_IMG,format=raw,if=none,id=drv0" \
    -device "virtio-blk-pci,drive=drv0,disable-legacy=off" > "$LOG_FILE" 2>&1 || true

cat "$LOG_FILE"

echo "[CHALLENGER1_HARNESS] Validating test markers in Phase 1..."
if ! grep -q "\[CHALLENGER_M15_1\] ALL EMPIRICAL CHALLENGES PASSED!" "$LOG_FILE"; then
    echo "[CHALLENGER1_HARNESS] FAILURE: Verification did not produce success marker!"
    exit 1
fi

echo "[CHALLENGER1_HARNESS] Validating host-side disk persistence for Sector 0 (token 0)..."
if ! head -c 64 "$DISK_IMG" | grep -q "TINUX_PERSISTENCE_VERIFIED_ON_VIRTIO_BLK"; then
    echo "[CHALLENGER1_HARNESS] FAILURE: Sector 0 standard persistence token missing on host disk!"
    exit 1
fi
echo "[CHALLENGER1_HARNESS] Confirmed Sector 0 standard persistence token on host!"

echo "[CHALLENGER1_HARNESS] Validating host-side disk persistence for Sector 0 (Challenger 1 token)..."
if ! dd if="$DISK_IMG" bs=1 skip=128 count=64 status=none | grep -q "CHALLENGER_M15_1_PERSISTENCE_SECTOR0_VERIFIED"; then
    echo "[CHALLENGER1_HARNESS] FAILURE: Sector 0 Challenger 1 token missing on host disk!"
    exit 1
fi
echo "[CHALLENGER1_HARNESS] Confirmed Sector 0 Challenger 1 persistence token on host!"

# ==============================================================================
# PHASE 2: Negative Test — PCI Bus Scan Without VirtIO-Block Device
# ==============================================================================
echo "[CHALLENGER1_HARNESS] Phase 2: Testing PCI bus scan without VirtIO-Block attached..."
(
    sleep 1.6
    "$PYTHON_BIN" -c '
import sys, time
def send(msg):
    try:
        if isinstance(msg, str):
            msg = msg.encode("latin1")
        for b in msg:
            sys.stdout.buffer.write(bytes([b]))
            sys.stdout.buffer.flush()
            time.sleep(0.001)
        time.sleep(0.05)
    except (OSError, BrokenPipeError):
        pass

send("exit 0\n")
'
    sleep 2
) | timeout 15 qemu-system-x86_64 \
    -kernel "$KERNEL_BIN" \
    -nographic \
    -no-reboot \
    -serial stdio \
    -monitor none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 > "$LOG_FILE_NO_DEV" 2>&1 || true

cat "$LOG_FILE_NO_DEV"

if ! grep -q "\[TINUX_BLK\] VirtIO-Block PCI device not found" "$LOG_FILE_NO_DEV"; then
    echo "[CHALLENGER1_HARNESS] FAILURE: Kernel did not report missing device when VirtIO-Block was absent!"
    exit 1
fi
echo "[CHALLENGER1_HARNESS] Confirmed clean negative scan: unpopulated slots handled properly!"

# Clean up binaries in .cache/initramfs_root to satisfy license guardrails
rm -f "$INITRAMFS_ROOT/bin/"* "$INITRAMFS_ROOT/lib/"* "$INITRAMFS_ROOT/tmp/"* 2>/dev/null || true
rm -rf "$INITRAMFS_ROOT/usr" 2>/dev/null || true

echo "==========================================================================="
echo "[CHALLENGER1_HARNESS] SUCCESS: All TASK-015 Challenger 1 empirical challenges PASSED!"
echo "==========================================================================="
exit 0
