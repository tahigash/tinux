#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Adversarial IPC, dup3, O_CLOEXEC, /proc, and Shell Pipeline Verification Harness

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_task8.log"
KERNEL_BIN="zig-out/bin/tinux"

echo "[ADVERSARIAL_HARNESS] Building userland test ELFs..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/tmp"

# Compile adversarial test suite ELF
zig build-exe src/user/adversarial_task8_test.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task8_test"

# Compile adversarial cloexec child helper ELF
zig build-exe src/user/adversarial_cloexec_child.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_cloexec_child"

# Ensure busybox/sh exists in initramfs
if [[ ! -f "$INITRAMFS_ROOT/bin/sh" ]]; then
    zig build-exe src/user/tinux_busybox.zig \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/busybox"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/sh"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/cat"
    cp "$INITRAMFS_ROOT/bin/busybox" "$INITRAMFS_ROOT/bin/grep"
fi
chmod +x "$INITRAMFS_ROOT/bin/"*

echo "Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!" > "${INITRAMFS_ROOT}/etc/motd"

# Configure /etc/rc.sh to execute adversarial suite and shell pipeline tests
cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Executing /bin/adversarial_task8_test..."
/bin/adversarial_task8_test
echo "[TINUX_SH] Testing shell pipeline with quoted pipe: echo \"Hello | World\" | grep Hello"
echo "Hello | World" | /bin/grep Hello
echo "[TINUX_SH] Testing 3-stage shell pipeline: /bin/cat /etc/motd | /bin/cat | /bin/grep Tinux"
/bin/cat /etc/motd | /bin/cat | /bin/grep Tinux
echo "[TINUX_SH] Testing builtin echo redirection: echo \"Redirected Output Test\" > /tmp/out.txt"
echo "Redirected Output Test" > /tmp/out.txt
/bin/cat /tmp/out.txt
echo "[TINUX_SH] Testing external binary echo redirection: /bin/echo \"External Redirection Test\" > /tmp/out_ext.txt"
/bin/echo "External Redirection Test" > /tmp/out_ext.txt
/bin/cat /tmp/out_ext.txt
echo "[TINUX_SH] Testing input redirection: /bin/cat < /etc/motd"
/bin/cat < /etc/motd
echo "[TINUX_SH] All shell tests completed."
exit 0
EOF
chmod +x "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[ADVERSARIAL_HARNESS] Packaging initramfs.cpio..."
python tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[ADVERSARIAL_HARNESS] Building Tinux kernel for TASK-008..."
zig build -Dtask=TASK-008

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
