#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Dedicated Empirical Challenge Verification Script for Challenger 1 (TASK-014 Threading Focus)

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_threading14.log"
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

echo "[CHALLENGER14_HARNESS] Running license guardrail check..."
"$PYTHON_BIN" scripts/check_license_guardrails.py

echo "[CHALLENGER14_HARNESS] Building userland test ELF and dynamic artifacts..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/tmp" "$INITRAMFS_ROOT/lib"

# 1. Build challenger adversarial threading test binary
"$ZIG_BIN" build-exe src/user/adversarial_task14_threading.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task14_threading"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task14_threading.o"

# 2. Build thread_epoll_test as well
if [[ -f "src/user/thread_epoll_test.zig" ]]; then
    "$ZIG_BIN" build-exe src/user/thread_epoll_test.zig \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/thread_epoll_test"
    rm -f "$INITRAMFS_ROOT/bin/thread_epoll_test.o"
fi

# 3. Build busybox / sh if not present
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

# Ensure no /etc/rc.sh
rm -f "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[CHALLENGER14_HARNESS] Packaging initramfs.cpio..."
"$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[CHALLENGER14_HARNESS] Building Tinux kernel for TASK-014..."
"$ZIG_BIN" build -Dtask=TASK-014

echo "[CHALLENGER14_HARNESS] Locating QEMU binary..."
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    for cand_dir in "/c/Users/takashi/bin/qemu" "/c/Program Files/qemu" "$HOME/bin/qemu" "/c/qemu"; do
        if [[ -f "$cand_dir/qemu-system-x86_64.exe" ]] || [[ -f "$cand_dir/qemu-system-x86_64" ]]; then
            export PATH="$cand_dir:$PATH"
            break
        fi
    done
fi

echo "[CHALLENGER14_HARNESS] Executing QEMU with interactive adversarial stdin streamer..."
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

send("/bin/adversarial_task14_threading\n")
time.sleep(1.0)
send("exit 0\n")
'
    sleep 2
) | timeout 20 qemu-system-x86_64 \
    -kernel "$KERNEL_BIN" \
    -nographic \
    -no-reboot \
    -serial stdio \
    -monitor none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 > "$LOG_FILE" 2>&1 || true

cat "$LOG_FILE"

# Clean up binaries in .cache/initramfs_root to satisfy license guardrails
rm -f "$INITRAMFS_ROOT/bin/"* "$INITRAMFS_ROOT/lib/"* "$INITRAMFS_ROOT/tmp/"* 2>/dev/null || true
rm -rf "$INITRAMFS_ROOT/usr" 2>/dev/null || true

echo "[CHALLENGER14_HARNESS] Validating test markers..."
if grep -q "\[CHALLENGER_PASS\] All TASK-014 adversarial threading challenges passed cleanly!" "$LOG_FILE"; then
    echo "[CHALLENGER14_HARNESS] SUCCESS: All TASK-014 adversarial threading challenges passed cleanly!"
    exit 0
else
    echo "[CHALLENGER14_HARNESS] FAILURE: Verification did not produce success marker!"
    exit 1
fi
