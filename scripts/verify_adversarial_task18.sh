#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Dedicated Empirical Challenge Verification Script for Challenger (TASK-018)

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_task18.log"
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

echo "[CHALLENGER18_HARNESS] Running license guardrail check..."
"$PYTHON_BIN" scripts/check_license_guardrails.py

echo "[CHALLENGER18_HARNESS] Building userland test ELFs..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/proc" "$INITRAMFS_ROOT/tmp"

# 1. Build post-exec helper binary
"$ZIG_BIN" build-exe src/user/adversarial_task18_post_exec.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task18_post_exec"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task18_post_exec.o"

# 2. Build challenger adversarial test binary
"$ZIG_BIN" build-exe src/user/adversarial_task18_challenger.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task18_challenger"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task18_challenger.o"

# 3. Build busybox / sh if needed
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

echo "[CHALLENGER18_HARNESS] Packaging initramfs.cpio..."
"$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[CHALLENGER18_HARNESS] Building Tinux kernel for TASK-018..."
"$ZIG_BIN" build -Dtask=TASK-018

echo "[CHALLENGER18_HARNESS] Launching QEMU with interactive feeder..."
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
    echo "[CHALLENGER18_HARNESS] Error: qemu-system-x86_64 not found!"
    exit 1
fi
QEMU_BIN="qemu-system-x86_64"

DISK_IMG="/tmp/tinux_disk_TASK-018.img"
DISK_STAGE="/tmp/tinux_disk_stage_TASK-018"
rm -rf "$DISK_STAGE" "$DISK_IMG" && mkdir -p "$DISK_STAGE"
echo "[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!" > "$DISK_STAGE/host_seed.txt"
tar --format=ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null || tar --format ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null
truncate -s 1M "$DISK_IMG" 2>/dev/null || dd if=/dev/zero of="$DISK_IMG" bs=1k count=1000 seek=24 status=none

(
    sleep 1.6
    "$PYTHON_BIN" -c '
import sys, time
commands = [
    "echo \"[TINUX_SH] Running adversarial TASK-018 lifecycle & signal suite...\"\n",
    "/bin/adversarial_task18_challenger\n",
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

echo "[CHALLENGER18_HARNESS] Validating log assertions..."
grep -q "\[CHALLENGER_M18\] Unmaskable signal protections: PASS" "$LOG_FILE" || { echo "Failed: Unmaskable signal protections"; exit 1; }
grep -q "\[CHALLENGER_M18\] Boundary validation: PASS" "$LOG_FILE" || { echo "Failed: Boundary validation"; exit 1; }
grep -q "\[CHALLENGER_M18\] sys_pause return value (-EINTR): PASS" "$LOG_FILE" || { echo "Failed: sys_pause return value"; exit 1; }
grep -q "\[CHALLENGER_M18\] Lifecycle (fork inheritance + SIGCHLD delivery): PASS" "$LOG_FILE" || { echo "Failed: Lifecycle inheritance"; exit 1; }
grep -q "\[POST_EXEC_PASS\] Post-execve signal state verified" "$LOG_FILE" || { echo "Failed: Post-execve signal state"; exit 1; }
grep -q "\[CHALLENGER_M18\] Execve handler reset & mask preservation: PASS" "$LOG_FILE" || { echo "Failed: Execve reset & mask"; exit 1; }
grep -q "\[CHALLENGER_M18\] All empirical adversarial challenges PASSED!" "$LOG_FILE" || { echo "Failed: All adversarial challenges"; exit 1; }
grep -q "\[TINUX_TEST\] PASS: TASK-018" "$LOG_FILE" || { echo "Failed: PASS TASK-018"; exit 1; }

echo "[CHALLENGER18_HARNESS] SUCCESS: All empirical adversarial challenges PASSED cleanly!"
