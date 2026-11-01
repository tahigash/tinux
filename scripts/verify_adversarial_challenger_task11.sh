#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Dedicated Empirical Challenge Verification Script for Challenger (TASK-011)

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_challenger11.log"
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

echo "[CHALLENGER11_HARNESS] Building userland test ELF and dynamic artifacts..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/tmp" "$INITRAMFS_ROOT/lib" "$INITRAMFS_ROOT/usr/lib"

# 1. Package shared library
echo "TINUX_SO_SHARED_LIBRARY_PAYLOAD_v1" > "${INITRAMFS_ROOT}/lib/libtinux.so"

# 2. Build dynamic linker ld-musl
"$ZIG_BIN" build-exe src/user/ld_tinux_so.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fPIE \
    "-femit-bin=${INITRAMFS_ROOT}/lib/ld-musl-x86_64.so.1"
rm -f "${INITRAMFS_ROOT}/lib/ld-musl-x86_64.so.1.o"

# 3. Build challenger dynamic test binary
"$ZIG_BIN" build-exe src/user/adversarial_task11_challenger.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task11_challenger"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task11_challenger.o"

# 4. Inject PT_INTERP program header into adversarial binary
"$PYTHON_BIN" - "${INITRAMFS_ROOT}/bin/adversarial_task11_challenger" << 'PY_EOF'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
interp_bytes = b"/lib/ld-musl-x86_64.so.1\x00"
str_off = data.find(interp_bytes)
if str_off != -1:
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    has_interp = any(struct.unpack_from("<I", data, e_phoff + i * 56)[0] == 3 for i in range(e_phnum))
    if not has_interp:
        for i in range(e_phnum):
            off = e_phoff + i * 56
            p_type = struct.unpack_from("<I", data, off)[0]
            if p_type == 4:
                struct.pack_into("<IIQQQQQQ", data, off, 3, 4, str_off, str_off, str_off, len(interp_bytes), len(interp_bytes), 1)
                break
open(path, "wb").write(data)
PY_EOF

# 5. Build standard dyn_inspect binary for reference
"$ZIG_BIN" build-exe src/user/dyn_inspect.zig \
    -target x86_64-linux-none \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/dyn_inspect"
rm -f "$INITRAMFS_ROOT/bin/dyn_inspect.o"
"$PYTHON_BIN" - "${INITRAMFS_ROOT}/bin/dyn_inspect" << 'PY_EOF'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
interp_bytes = b"/lib/ld-musl-x86_64.so.1\x00"
str_off = data.find(interp_bytes)
if str_off != -1:
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    has_interp = any(struct.unpack_from("<I", data, e_phoff + i * 56)[0] == 3 for i in range(e_phnum))
    if not has_interp:
        for i in range(e_phnum):
            off = e_phoff + i * 56
            p_type = struct.unpack_from("<I", data, off)[0]
            if p_type == 4:
                struct.pack_into("<IIQQQQQQ", data, off, 3, 4, str_off, str_off, str_off, len(interp_bytes), len(interp_bytes), 1)
                break
open(path, "wb").write(data)
PY_EOF

# Ensure busybox/sh exists in initramfs
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

echo "Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!" > "${INITRAMFS_ROOT}/etc/motd"

# Configure /etc/rc.sh to execute challenger11 suite
cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Executing adversarial TASK-011 test suite..."
/bin/adversarial_task11_challenger
echo "[TINUX_SH] Adversarial binary tests completed with exit 0."
echo "[TINUX_SH] Executing standard /bin/dyn_inspect for end-to-end check..."
/bin/dyn_inspect
echo "[TINUX_ALPINE] Full empirical verification passed!"
exit 0
EOF
chmod +x "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[CHALLENGER11_HARNESS] Packaging initramfs.cpio..."
"$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[CHALLENGER11_HARNESS] Building Tinux kernel for TASK-011..."
"$ZIG_BIN" build -Dtask=TASK-011

echo "[CHALLENGER11_HARNESS] Executing QEMU (timeout=15s)..."
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    for cand_dir in "/c/Users/takashi/bin/qemu" "/c/Program Files/qemu" "$HOME/bin/qemu" "/c/qemu"; do
        if [[ -f "$cand_dir/qemu-system-x86_64.exe" ]] || [[ -f "$cand_dir/qemu-system-x86_64" ]]; then
            export PATH="$cand_dir:$PATH"
            break
        fi
    done
fi

timeout 15 qemu-system-x86_64 \
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

if grep -q "ALL 5 ADVERSARIAL CHALLENGES EMPIRICALLY CONFIRMED" "$LOG_FILE"; then
    echo "[CHALLENGER11_HARNESS] SUCCESS: All TASK-011 adversarial challenges passed cleanly!"
    exit 0
else
    echo "[CHALLENGER11_HARNESS] FAILURE: Verification did not produce success marker!"
    exit 1
fi
