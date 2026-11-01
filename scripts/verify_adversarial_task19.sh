#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Dedicated Empirical Challenge Verification Script for Challenger (TASK-019)

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_task19.log"
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

echo "[CHALLENGER19_HARNESS] Running license guardrail check..."
"$PYTHON_BIN" scripts/check_license_guardrails.py

echo "[CHALLENGER19_HARNESS] Building userland test ELFs..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/proc" "$INITRAMFS_ROOT/tmp"

# 1. Build challenger adversarial test binary
"$ZIG_BIN" build-exe src/user/adversarial_task19_challenger.zig \
    -target x86_64-freestanding \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task19_challenger"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task19_challenger.o"

# 2. Build dns_test if needed
if [[ -f src/user/dns_test.zig ]]; then
    "$ZIG_BIN" build-exe src/user/dns_test.zig \
        -target x86_64-freestanding \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/dns_test"
    rm -f "$INITRAMFS_ROOT/bin/dns_test.o"
fi

# 3. Build busybox / sh if needed
if [[ ! -f "$INITRAMFS_ROOT/bin/sh" ]]; then
    "$ZIG_BIN" build-exe src/user/tinux_busybox.zig \
        -target x86_64-freestanding \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/busybox"
    rm -f "$INITRAMFS_ROOT/bin/busybox.o"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/sh"
fi
chmod +x "$INITRAMFS_ROOT/bin/"*

# Ensure no /etc/rc.sh
rm -f "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[CHALLENGER19_HARNESS] Packaging initramfs.cpio..."
"$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[CHALLENGER19_HARNESS] Building Tinux kernel for TASK-019..."
"$ZIG_BIN" build -Dtask=TASK-019

echo "[CHALLENGER19_HARNESS] Launching QEMU with interactive feeder..."
rm -f "$LOG_FILE"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    for cand_dir in "/c/Users/takashi/bin/qemu" "/c/Program Files/qemu" "$HOME/bin/qemu" "/c/qemu"; do
        if [[ -f "$cand_dir/qemu-system-x86_64.exe" ]] || [[ -f "$cand_dir/qemu-system-x86_64" ]]; then
            export PATH="$cand_dir:$PATH"
            break
        fi
    done
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "[CHALLENGER19_HARNESS] Error: qemu-system-x86_64 not found!"
    exit 1
fi
QEMU_BIN="qemu-system-x86_64"

DISK_IMG="/tmp/tinux_disk_TASK-019.img"
DISK_STAGE="/tmp/tinux_disk_stage_TASK-019"
rm -rf "$DISK_STAGE" "$DISK_IMG" && mkdir -p "$DISK_STAGE"
echo "[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!" > "$DISK_STAGE/host_seed.txt"
tar --format=ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null || tar --format ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null
truncate -s 1M "$DISK_IMG" 2>/dev/null || dd if=/dev/zero of="$DISK_IMG" bs=1k count=1000 seek=24 status=none

(
    sleep 1.6
    "$PYTHON_BIN" -c '
import sys, time
commands = [
    "echo \"[TINUX_SH] Running adversarial TASK-019 UDP & socket challenge suite...\"\n",
    "/bin/adversarial_task19_challenger\n",
    "/bin/cat /proc/net/udp\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    time.sleep(0.05)
'
    sleep 3
) | "$QEMU_BIN" \
    -kernel "$KERNEL_BIN" \
    -initrd .cache/initramfs.cpio \
    -nographic \
    -no-reboot \
    -serial stdio \
    -monitor none \
    -m 128M \
    -drive "file=$DISK_IMG,format=raw,if=none,id=drv0" -device "virtio-blk-pci,drive=drv0,disable-legacy=off" \
    -netdev "user,id=net0" -device "virtio-net-pci,netdev=net0,disable-legacy=off" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    2>&1 | tee "$LOG_FILE" || true

echo "[CHALLENGER19_HARNESS] Validating log assertions..."
grep -q "s1 bind to 5678: expected=0 actual=0 \[OK\]" "$LOG_FILE" || { echo "Failed: s1 bind"; exit 1; }
grep -q "s2 collision on 5678 returns -EADDRINUSE: expected=-98 actual=-98 \[OK\]" "$LOG_FILE" || { echo "Failed: s2 collision"; exit 1; }
grep -q "unconnected sendto with NULL dest returns -EDESTADDRREQ: expected=-89 actual=-89 \[OK\]" "$LOG_FILE" || { echo "Failed: EDESTADDRREQ sendto"; exit 1; }
grep -q "unconnected write returns -EDESTADDRREQ: expected=-89 actual=-89 \[OK\]" "$LOG_FILE" || { echo "Failed: EDESTADDRREQ write"; exit 1; }
grep -q "SOCK_NONBLOCK recvfrom on empty queue returns -EAGAIN: expected=-11 actual=-11 \[OK\]" "$LOG_FILE" || { echo "Failed: SOCK_NONBLOCK recvfrom"; exit 1; }
grep -q "fcntl O_NONBLOCK recvfrom on empty queue returns -EAGAIN: expected=-11 actual=-11 \[OK\]" "$LOG_FILE" || { echo "Failed: fcntl recvfrom"; exit 1; }
grep -q "recvfrom with small buffer truncates to len: expected=8 actual=8 \[OK\]" "$LOG_FILE" || { echo "Failed: small buffer truncate"; exit 1; }
grep -q "datagram boundary preserved: remainder discarded -> -EAGAIN: expected=-11 actual=-11 \[OK\]" "$LOG_FILE" || { echo "Failed: datagram boundary preservation"; exit 1; }
grep -q "write on connected UDP socket: expected=17 actual=17 \[OK\]" "$LOG_FILE" || { echo "Failed: connected write"; exit 1; }
grep -q "\[CHALLENGER_M19\] All empirical adversarial challenges PASSED!" "$LOG_FILE" || { echo "Failed: final pass marker"; exit 1; }

echo "[CHALLENGER19_HARNESS] SUCCESS: All empirical adversarial challenges PASSED cleanly!"
