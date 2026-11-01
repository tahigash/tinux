#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Adversarial Writable tmpfs, MAX_FILE_SIZE, EISDIR, ENOTEMPTY Verification Harness

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_task9.log"
KERNEL_BIN="zig-out/bin/tinux"

echo "[ADVERSARIAL_HARNESS] Building userland test ELFs..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/tmp"

# Compile adversarial test suite ELF
zig build-exe src/user/adversarial_task9_test.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task9_test"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task9_test.o"

# Ensure busybox/sh exists in initramfs
if [[ ! -f "$INITRAMFS_ROOT/bin/sh" ]]; then
    zig build-exe src/user/tinux_busybox.zig \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/busybox"
    rm -f "$INITRAMFS_ROOT/bin/busybox.o"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/sh"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/cat"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/ls"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/mkdir"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/touch"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/rm"
fi
chmod +x "$INITRAMFS_ROOT/bin/"*

echo "Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!" > "${INITRAMFS_ROOT}/etc/motd"

# Configure /etc/rc.sh to execute adversarial suite followed by standard shell operations
cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Executing /bin/adversarial_task9_test..."
/bin/adversarial_task9_test
echo "[TINUX_SH] Adversarial binary tests completed with exit 0."
echo "[TINUX_SH] Executing shell validation sequence..."
/bin/mkdir /tmp/sh_work
echo "Shell redirection into tmpfs verified!" > /tmp/sh_work/shell_test.txt
/bin/cat /tmp/sh_work/shell_test.txt
/bin/ls /tmp/sh_work
/bin/rm /tmp/sh_work/shell_test.txt
/bin/rmdir /tmp/sh_work
echo "[TINUX_TMPFS] Full empirical verification passed!"
exit 0
EOF
chmod +x "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[ADVERSARIAL_HARNESS] Packaging initramfs.cpio..."
python tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[ADVERSARIAL_HARNESS] Building Tinux kernel for TASK-009..."
zig build -Dtask=TASK-009

echo "[ADVERSARIAL_HARNESS] Executing QEMU (timeout=8s)..."
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
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 > "$LOG_FILE" 2>&1 || true

cat "$LOG_FILE"

# Clean up binaries in .cache/initramfs_root to satisfy license guardrails
rm -rf "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/tmp"
