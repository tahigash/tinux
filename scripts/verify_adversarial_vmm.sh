#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Adversarial Virtual Memory & Fork Stress Verification Harness

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_vmm.log"
KERNEL_BIN="zig-out/bin/tinux"

echo "[ADVERSARIAL_HARNESS] Building userland test ELF src/user/adversarial_fork_test.zig..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc"

# Compile standalone userland adversarial ELF
zig build-exe src/user/adversarial_fork_test.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=.cache/adversarial_fork_test.elf"

cp .cache/adversarial_fork_test.elf "$INITRAMFS_ROOT/bin/adversarial_fork_test"
chmod +x "$INITRAMFS_ROOT/bin/adversarial_fork_test"

# Ensure busybox/sh exists in initramfs
if [[ ! -f "$INITRAMFS_ROOT/bin/sh" ]]; then
    zig build-exe src/user/tinux_busybox.zig \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/busybox"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/sh"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/cat"
    chmod +x "$INITRAMFS_ROOT/bin/sh" "$INITRAMFS_ROOT/bin/cat"
fi

echo "Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!" > "${INITRAMFS_ROOT}/etc/motd"

# Configure /etc/rc.sh to execute adversarial suite
cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Spawning /bin/adversarial_fork_test via spawnExternal..."
/bin/adversarial_fork_test
echo "[TINUX_SH] Adversarial fork test reaped cleanly!"
exit 0
EOF
chmod +x "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[ADVERSARIAL_HARNESS] Packaging initramfs.cpio..."
python tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[ADVERSARIAL_HARNESS] Building Tinux kernel for TASK-007..."
zig build -Dtask=TASK-007

echo "[ADVERSARIAL_HARNESS] Executing QEMU (timeout=10s)..."
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    for cand_dir in "/c/Users/takashi/bin/qemu" "/c/Program Files/qemu" "$HOME/bin/qemu" "/c/qemu"; do
        if [[ -f "$cand_dir/qemu-system-x86_64.exe" ]] || [[ -f "$cand_dir/qemu-system-x86_64" ]]; then
            export PATH="$cand_dir:$PATH"
            break
        fi
    done
fi

timeout 10 qemu-system-x86_64 \
    -kernel "$KERNEL_BIN" \
    -nographic \
    -no-reboot \
    -serial stdio \
    -monitor none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 > "$LOG_FILE" 2>&1 || QEMU_EXIT=$?

QEMU_EXIT="${QEMU_EXIT:-0}"
cat "$LOG_FILE"

echo "[ADVERSARIAL_HARNESS] QEMU Exit Code: $QEMU_EXIT (expected 33)"
if [ "$QEMU_EXIT" -ne 33 ]; then
    echo "[ADVERSARIAL_HARNESS] FAIL: Unexpected exit code."
    exit 1
fi

if grep -q "MUTATION LEAK" "$LOG_FILE"; then
    echo "[ADVERSARIAL_HARNESS] FAIL: Memory mutation leak detected!"
    exit 1
fi

if grep -q "PAGE TABLE LEAK" "$LOG_FILE"; then
    echo "[ADVERSARIAL_HARNESS] FAIL: Page table leak detected!"
    exit 1
fi

if grep -q "HEAP CORRUPTION" "$LOG_FILE" || grep -q "HEAP DATA LEAK" "$LOG_FILE"; then
    echo "[ADVERSARIAL_HARNESS] FAIL: Heap independence failure detected!"
    exit 1
fi

if ! grep -q "ALL 5 ADVERSARIAL CHALLENGES CONFIRMED AND PASSED!" "$LOG_FILE"; then
    echo "[ADVERSARIAL_HARNESS] FAIL: Adversarial suite did not reach completion marker!"
    exit 1
fi

echo "[ADVERSARIAL_HARNESS] SUCCESS: All 5 adversarial challenges passed cleanly under QEMU!"
exit 0
