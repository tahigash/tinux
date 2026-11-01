#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Dedicated Empirical Challenge Verification Script for Challenger (TASK-017)

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_task17.log"
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

echo "[CHALLENGER17_HARNESS] Running license guardrail check..."
"$PYTHON_BIN" scripts/check_license_guardrails.py

echo "[CHALLENGER17_HARNESS] Building userland test ELF..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/proc" "$INITRAMFS_ROOT/tmp"

# 1. Build challenger adversarial test binary
"$ZIG_BIN" build-exe src/user/adversarial_task17_challenger.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task17_challenger"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task17_challenger.o"

# 2. Build busybox / sh
if [[ ! -f "$INITRAMFS_ROOT/bin/sh" ]]; then
    "$ZIG_BIN" build-exe src/user/tinux_busybox.zig \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/busybox"
    rm -f "$INITRAMFS_ROOT/bin/busybox.o"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/sh"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/cat"
fi
chmod +x "$INITRAMFS_ROOT/bin/"*

# Ensure no /etc/rc.sh
rm -f "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[CHALLENGER17_HARNESS] Packaging initramfs.cpio..."
"$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[CHALLENGER17_HARNESS] Building Tinux kernel for TASK-017..."
"$ZIG_BIN" build -Dtask=TASK-017

echo "[CHALLENGER17_HARNESS] Locating QEMU binary..."
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    for cand_dir in "/c/Users/takashi/bin/qemu" "/c/Program Files/qemu" "$HOME/bin/qemu" "/c/qemu"; do
        if [[ -f "$cand_dir/qemu-system-x86_64.exe" ]] || [[ -f "$cand_dir/qemu-system-x86_64" ]]; then
            export PATH="$cand_dir:$PATH"
            break
        fi
    done
fi

echo "[CHALLENGER17_HARNESS] Executing QEMU with VirtIO-Net hardware attached..."
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

send("/bin/adversarial_task17_challenger\n")
time.sleep(2.0)
send("/bin/cat /proc/net/arp\n")
time.sleep(0.5)
send("/bin/cat /proc/net/dev\n")
time.sleep(0.5)
send("exit 0\n")
'
    sleep 2
) | timeout 25 qemu-system-x86_64 \
    -kernel "$KERNEL_BIN" \
    -nographic \
    -no-reboot \
    -serial stdio \
    -monitor none \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0,disable-legacy=off \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 > "$LOG_FILE" 2>&1 || true

cat "$LOG_FILE"

# Clean up binaries in .cache/initramfs_root to satisfy license guardrails
rm -f "$INITRAMFS_ROOT/bin/"* "$INITRAMFS_ROOT/lib/"* "$INITRAMFS_ROOT/tmp/"* 2>/dev/null || true
rm -rf "$INITRAMFS_ROOT/usr" 2>/dev/null || true

echo "[CHALLENGER17_HARNESS] Verifying log assertions..."
grep -F "[CHALLENGER_M17] ALL EMPIRICAL CHALLENGES PASSED CLEANLY!" "$LOG_FILE"
grep -F "10.0.2.2         0x1         0x2         52:55:0a:00:02:02     *        eth0" "$LOG_FILE"
grep -F "  eth0:     102       2    0    0    0     0          0         0      102       2" "$LOG_FILE"

echo "[CHALLENGER17_HARNESS] SUCCESS: All TASK-017 empirical adversarial tests passed!"
