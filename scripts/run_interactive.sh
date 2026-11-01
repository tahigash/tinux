#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Tinux Interactive Workstation & User App Packer
# Usage:
#   ./scripts/run_interactive.sh
# ==============================================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

USER_APPS_DIR="user_apps"
DISK_STAGE=".cache/user_disk_stage"
DISK_IMG="tinux_user_disk.img"
INITRAMFS_ROOT=".cache/initramfs_root"
KERNEL_BIN="zig-out/bin/tinux"

PYTHON_BIN=""
for cand in python python3 py; do
    if "$cand" -c 'import sys' >/dev/null 2>&1; then
        PYTHON_BIN="$cand"
        break
    fi
done

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    for cand_dir in "/c/Users/takashi/bin/qemu" "/c/Program Files/qemu" "$HOME/bin/qemu" "/c/qemu"; do
        if [[ -f "$cand_dir/qemu-system-x86_64.exe" ]] || [[ -f "$cand_dir/qemu-system-x86_64" ]]; then
            export PATH="$cand_dir:$PATH"
            break
        fi
    done
fi

mkdir -p "$USER_APPS_DIR" "$DISK_STAGE" "$INITRAMFS_ROOT/bin"

echo -e "${CYAN}[PACKER]${NC} Scanning ${USER_APPS_DIR}/ for C and Zig applications..."

# 1. Auto-compile any .c files in user_apps/ using `zig cc`
for c_file in "$USER_APPS_DIR"/*.c; do
    [[ -e "$c_file" ]] || continue
    base_name=$(basename "$c_file" .c)
    echo -e "  -> Compiling C app   : ${c_file} -> /mnt/${base_name} & /bin/${base_name}"
    zig cc -target x86_64-linux-musl -Os -static -fno-pie "$c_file" -o "${DISK_STAGE}/${base_name}"
    chmod +x "${DISK_STAGE}/${base_name}"
    cp "${DISK_STAGE}/${base_name}" "${INITRAMFS_ROOT}/bin/${base_name}"
done

# 2. Auto-compile any .zig files in user_apps/ using `zig build-exe`
for z_file in "$USER_APPS_DIR"/*.zig; do
    [[ -e "$z_file" ]] || continue
    base_name=$(basename "$z_file" .zig)
    echo -e "  -> Compiling Zig app : ${z_file} -> /mnt/${base_name} & /bin/${base_name}"
    zig build-exe "$z_file" \
        -target x86_64-linux-musl \
        -O ReleaseSmall \
        -fno-pie \
        "-femit-bin=${DISK_STAGE}/${base_name}"
    chmod +x "${DISK_STAGE}/${base_name}"
    cp "${DISK_STAGE}/${base_name}" "${INITRAMFS_ROOT}/bin/${base_name}"
done

# 3. Copy any pre-built ELF binaries in user_apps/
for bin_file in "$USER_APPS_DIR"/*; do
    [[ -f "$bin_file" && -x "$bin_file" ]] || continue
    case "$bin_file" in
        *.c|*.zig|*.rs|*.md) continue ;;
    esac
    base_name=$(basename "$bin_file")
    cp "$bin_file" "${DISK_STAGE}/${base_name}"
    cp "$bin_file" "${INITRAMFS_ROOT}/bin/${base_name}"
done

# 4. Create a README file on the persistent /dev/vda disk
cat << 'EOF' > "${DISK_STAGE}/README_DISK.txt"
Welcome to Tinux Persistent VirtIO-Block Disk (/dev/vda)!
Any files created or modified inside /mnt will be persisted back to tinux_user_disk.img on the host.
EOF

# 5. Pack DISK_STAGE into USTAR disk image (tinux_user_disk.img)
echo -e "${CYAN}[PACKER]${NC} Building 2 MiB USTAR persistent disk image (${DISK_IMG})..."
tar --format=ustar -cf "$DISK_IMG" -C "$DISK_STAGE" . 2>/dev/null || tar --format ustar -cf "$DISK_IMG" -C "$DISK_STAGE" . 2>/dev/null
truncate -s 2M "$DISK_IMG" 2>/dev/null || dd if=/dev/zero of="$DISK_IMG" bs=1k count=2000 seek=48 status=none

# 6. Repack initramfs.cpio and rebuild kernel
echo -e "${CYAN}[PACKER]${NC} Updating initramfs.cpio and building Tinux kernel..."
"$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio
zig build

echo ""
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}       Launching Interactive Tinux Session (SMP 2-Core + VirtIO-Blk/Net)${NC}"
echo -e "${YELLOW}  Useful commands inside Tinux /bin/sh:${NC}"
echo -e "    mount -t tarfs /dev/vda /mnt       # Mount persistent disk"
echo -e "    ls /mnt                            # List custom apps & files"
echo -e "    /mnt/hello_c /mnt/out.txt          # Run custom C app & write to disk"
echo -e "    sync && umount /mnt                # Flush changes to host disk image"
echo -e "    exit 0                             # Cleanly power off QEMU"
echo -e "${GREEN}======================================================================${NC}"
echo ""

qemu-system-x86_64 \
    -kernel "$KERNEL_BIN" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -serial mon:stdio \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -drive "file=$DISK_IMG,format=raw,if=none,id=drv0" \
    -device "virtio-blk-pci,drive=drv0,disable-legacy=off" \
    -netdev "user,id=net0" \
    -device "virtio-net-pci,netdev=net0,disable-legacy=off" || true

echo ""
echo -e "${CYAN}[HOST]${NC} Tinux session ended. Files currently stored in ${DISK_IMG}:"
tar -tvf "$DISK_IMG" 2>/dev/null || true
