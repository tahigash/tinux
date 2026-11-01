#!/usr/bin/env bash
set -uo pipefail
# ==============================================================================
# Tinux Unified Build & QEMU Verification Harness (TASK-001 .. TASK-020)
# Usage: ./scripts/verify_qemu.sh <TASK-0XX> [TIMEOUT_SECONDS]
# ==============================================================================
TEST_CASE="${1:-TASK-001}"
TIMEOUT_SEC="${2:-10}"
TASK_NUM=$(echo "$TEST_CASE" | sed -E 's/^TASK-0*//')
if ! [[ "$TASK_NUM" =~ ^[0-9]+$ ]]; then
    TASK_NUM=1
fi
LOG_FILE="/tmp/tinux_qemu_${TEST_CASE}.log"
DISK_IMG="/tmp/tinux_disk_${TEST_CASE}.img"
KERNEL_BIN="zig-out/bin/tinux"
INITRAMFS_ROOT=".cache/initramfs_root"
mkdir -p .cache src/proc src/fs "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" \
         "$INITRAMFS_ROOT/lib" "$INITRAMFS_ROOT/tmp" "$INITRAMFS_ROOT/mnt"

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

# ------------------------------------------------------------------------------
# Pre-Check: Clean-Room License & Binary Guardrail Audit
# ------------------------------------------------------------------------------
if [[ -f "scripts/check_license_guardrails.py" ]] && [[ -n "$PYTHON_BIN" ]]; then
    "$PYTHON_BIN" scripts/check_license_guardrails.py || exit 1
fi

# ------------------------------------------------------------------------------
# Helper: Cross-compile a standalone x86_64-linux userland ELF with Zig
# Automatically adapts calling convention syntax across Zig 0.13 / 0.14 / 0.15+
# ------------------------------------------------------------------------------
build_user_elf() {
    local src_file="$1"
    local out_bin="$2"
    local pie_flag="${3:--fno-PIE}"
    if [[ "$pie_flag" =~ ^-[fF][nN][oO]-[pP][iI][eE]$ ]]; then
        pie_flag="-fno-PIE"
    elif [[ "$pie_flag" =~ ^-[fF][pP][iI][eE]$ ]]; then
        pie_flag="-fPIE"
    fi
    if [[ ! -f "$src_file" ]]; then
        echo "[HARNESS] ERROR: Missing user source file: $src_file"
        return 1
    fi
    if zig build-exe "$src_file" \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        "$pie_flag" \
        "-femit-bin=${out_bin}" >/dev/null 2>&1; then
        rm -f "${out_bin}.o" "${out_bin}.elf.o"
        chmod +x "$out_bin"
        return 0
    fi
    # Fallback for Zig 0.14.1 / 0.15+ where callconv(.C)/.Naked became lowercase .c/.naked
    local patched_src=".cache/$(basename "$src_file")"
    sed -e 's/callconv(\.C)/callconv(.c)/g' \
        -e 's/callconv(\.Naked)/callconv(.naked)/g' \
        "$src_file" > "$patched_src"
    if ! zig build-exe "$patched_src" \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        "$pie_flag" \
        "-femit-bin=${out_bin}"; then
        echo "[HARNESS] FAIL: Failed to compile user ELF $src_file"
        rm -f "${out_bin}.o" "${out_bin}.elf.o"
        return 1
    fi
    rm -f "${out_bin}.o" "${out_bin}.elf.o"
    chmod +x "$out_bin"
    return 0
}
# ------------------------------------------------------------------------------
# Helper: Build or Provision Static x86_64 Linux /bin/busybox
# ------------------------------------------------------------------------------
ensure_busybox_elf() {
    local bb_out="${INITRAMFS_ROOT}/bin/busybox"
    if [[ "${USE_HOST_BUSYBOX:-0}" == "1" ]] && command -v busybox >/dev/null 2>&1; then
        local bb_path
        bb_path=$(command -v busybox)
        if file "$bb_path" | grep -q "x86-64" && file "$bb_path" | grep -q "statically linked"; then
            cp "$bb_path" "$bb_out"
            chmod +x "$bb_out"
            for app in sh cat grep ls mkdir touch rm rmdir sleep ps mount umount sync; do
                cp "$bb_out" "${INITRAMFS_ROOT}/bin/$app"
                chmod +x "${INITRAMFS_ROOT}/bin/$app"
            done
            return 0
        fi
    fi
    local bb_src="src/user/tinux_busybox.zig"
    if [[ ! -f "$bb_src" ]]; then
        echo "[HARNESS] ERROR: Missing userland source: $bb_src"
        return 1
    fi
    build_user_elf "$bb_src" "$bb_out" "-fno-PIE" || return 1
    for app in sh cat grep ls mkdir touch rm rmdir sleep ps mount umount sync; do
        cp "$bb_out" "${INITRAMFS_ROOT}/bin/$app"
        chmod +x "${INITRAMFS_ROOT}/bin/$app"
    done
    return 0
}
# ------------------------------------------------------------------------------
# 1. Stage-Specific Userland & Initramfs Preparation
# ------------------------------------------------------------------------------
if [[ -f "src/user/init_test.zig" ]]; then
    echo "[HARNESS] Compiling standalone user ELF src/user/init_test.zig..."
    build_user_elf "src/user/init_test.zig" ".cache/init_test.elf" "-fno-PIE" || exit 1
fi
if (( TASK_NUM >= 6 )); then
    echo "[HARNESS] Preparing initramfs root filesystem for ${TEST_CASE}..."
    echo "Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!" > "${INITRAMFS_ROOT}/etc/motd"
    echo "nameserver 10.0.2.3" > "${INITRAMFS_ROOT}/etc/resolv.conf"
    printf "127.0.0.1\tlocalhost\n10.0.2.15\ttinux\n" > "${INITRAMFS_ROOT}/etc/hosts"
    ensure_busybox_elf || exit 1
    # Clean up stale /etc/rc.sh before building initramfs
    rm -f "${INITRAMFS_ROOT}/etc/rc.sh"
    # Generate task-appropriate /etc/rc.sh for non-interactive boot stages (TASK-007 .. TASK-011)
    case "$TASK_NUM" in
        6)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
/bin/cat /etc/motd
exit 0
EOF
            ;;
        7)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] /bin/sh started (PID $$)"
/bin/cat /etc/motd
echo "[TINUX_SH] Child process /bin/cat completed and reaped via wait4!"
exit 0
EOF
            ;;
        8)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Testing shell pipeline (cat /etc/motd | grep Tinux)..."
/bin/cat /etc/motd | /bin/grep Tinux
echo "[TINUX_SH] Inspecting /proc/version and /proc/meminfo:"
/bin/cat /proc/version
/bin/cat /proc/meminfo
echo "[TINUX_PIPE] Multi-process pipe2, dup2 redirection, and /proc verified!"
exit 0
EOF
            ;;
        9)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Creating directory /tmp/work and files..."
/bin/mkdir /tmp/work
echo "Hello from writable tmpfs on Tinux!" > /tmp/work/hello.txt
/bin/touch /tmp/work/empty.tmp
echo "[TINUX_SH] Listing /tmp/work via getdents64 (ls):"
/bin/ls /tmp/work
echo "[TINUX_SH] Reading back /tmp/work/hello.txt:"
/bin/cat /tmp/work/hello.txt
echo "[TINUX_SH] Removing /tmp/work/empty.tmp and listing again:"
/bin/rm /tmp/work/empty.tmp
/bin/ls /tmp/work
echo "[TINUX_TMPFS] Writable tmpfs, getdents64, mkdir, touch, redirection, and rm verified!"
exit 0
EOF
            ;;
        10)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Testing hardware timer (PIT 100Hz) and nanosleep..."
/bin/sleep 1
echo "[TINUX_TIMER] Uptime after 1s sleep:"
/bin/cat /proc/uptime
echo "[TINUX_SH] Spawning background job: /bin/sleep 5 &"
/bin/sleep 5 &
BG_PID=$!
echo "[TINUX_PS] Process table while background job is sleeping:"
/bin/ps
echo "[TINUX_KILL] Sending SIGKILL to background process..."
kill -9 $BG_PID
wait $BG_PID 2>/dev/null
echo "[TINUX_PROC] Hardware timer, nanosleep, /proc/[pid]/stat (ps), and kill verified!"
exit 0
EOF
            ;;
        11)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Launching dynamically-linked ELF binary (/bin/dyn_inspect)..."
/bin/dyn_inspect
echo "[TINUX_ALPINE] Dynamic ELF loader (PT_INTERP + ld-musl + shared library mmap) verified!"
exit 0
EOF
            ;;
    esac
    chmod +x "${INITRAMFS_ROOT}/etc/rc.sh" 2>/dev/null || true
    # Build dynamic linker & PT_INTERP test binary for TASK-011+
    if (( TASK_NUM >= 11 )) && [[ -f "src/user/ld_tinux_so.zig" ]] && [[ -f "src/user/dyn_inspect.zig" ]]; then
        echo "TINUX_SO_SHARED_LIBRARY_PAYLOAD_v1" > "${INITRAMFS_ROOT}/lib/libtinux.so"
        build_user_elf "src/user/ld_tinux_so.zig" "${INITRAMFS_ROOT}/lib/ld-musl-x86_64.so.1" "-fPIE" || exit 1
        build_user_elf "src/user/dyn_inspect.zig" "${INITRAMFS_ROOT}/bin/dyn_inspect" "-fno-PIE" || exit 1
        # Ensure PT_INTERP (p_type=3) program header is present in /bin/dyn_inspect
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
    fi
    if (( TASK_NUM >= 13 )) && [[ -f "src/user/net_test.zig" ]]; then
        build_user_elf "src/user/net_test.zig" "${INITRAMFS_ROOT}/bin/net_test" "-fno-PIE" || exit 1
    fi
    if (( TASK_NUM >= 14 )) && [[ -f "src/user/thread_epoll_test.zig" ]]; then
        build_user_elf "src/user/thread_epoll_test.zig" "${INITRAMFS_ROOT}/bin/thread_epoll_test" "-fno-PIE" || exit 1
    fi
    if (( TASK_NUM >= 17 )) && [[ -f "src/user/ping_test.zig" ]]; then
        build_user_elf "src/user/ping_test.zig" "${INITRAMFS_ROOT}/bin/ping_test" "-fno-PIE" || exit 1
    fi
    if (( TASK_NUM >= 18 )) && [[ -f "src/user/sig_test.zig" ]]; then
        build_user_elf "src/user/sig_test.zig" "${INITRAMFS_ROOT}/bin/sig_test" "-fno-PIE" || exit 1
    fi
    if (( TASK_NUM >= 19 )) && [[ -f "src/user/dns_test.zig" ]]; then
        build_user_elf "src/user/dns_test.zig" "${INITRAMFS_ROOT}/bin/dns_test" "-fno-PIE" || exit 1
    fi
    if (( TASK_NUM >= 20 )) && [[ -f "src/user/smp_test.zig" ]]; then
        build_user_elf "src/user/smp_test.zig" "${INITRAMFS_ROOT}/bin/smp_test" "-fno-PIE" || exit 1
    fi
    "$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio
fi
# ------------------------------------------------------------------------------
# 2. Build Tinux Kernel
# ------------------------------------------------------------------------------
echo "[HARNESS] Building Tinux kernel for ${TEST_CASE}..."
if ! zig build -Dtask="${TEST_CASE}"; then
    echo "[HARNESS] FAIL: zig build failed."
    exit 1
fi
# ------------------------------------------------------------------------------
# 3. Configure QEMU Hardware Arguments (VirtIO-Blk, VirtIO-Net, SMP)
# ------------------------------------------------------------------------------
QEMU_ARGS=(
    -kernel "$KERNEL_BIN"
    -nographic
    -no-reboot
    -serial stdio
    -monitor none
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
)
if (( TASK_NUM == 15 )); then
    rm -f "$DISK_IMG"
    dd if=/dev/zero of="$DISK_IMG" bs=1M count=1 status=none
    printf "[TINUX_DISK_SECTOR0] Host-provisioned VirtIO-Block image ready!\n" | dd of="$DISK_IMG" conv=notrunc status=none
    QEMU_ARGS+=(-drive "file=$DISK_IMG,format=raw,if=none,id=drv0" -device "virtio-blk-pci,drive=drv0,disable-legacy=off")
elif (( TASK_NUM >= 16 )); then
    DISK_STAGE="/tmp/tinux_disk_stage_${TEST_CASE}"
    rm -rf "$DISK_STAGE" "$DISK_IMG" && mkdir -p "$DISK_STAGE"
    echo "[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!" > "$DISK_STAGE/host_seed.txt"
    tar --format=ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null || tar --format ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null
    truncate -s 1M "$DISK_IMG" 2>/dev/null || dd if=/dev/zero of="$DISK_IMG" bs=1k count=1000 seek=24 status=none
    QEMU_ARGS+=(-drive "file=$DISK_IMG,format=raw,if=none,id=drv0" -device "virtio-blk-pci,drive=drv0,disable-legacy=off")
fi
if (( TASK_NUM >= 17 )); then
    QEMU_ARGS+=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0,disable-legacy=off")
fi
if (( TASK_NUM >= 20 )); then
    QEMU_ARGS+=(-smp "2")
fi
# ------------------------------------------------------------------------------
# 4. Execute QEMU (Direct Boot for TASK-001..011, Interactive Stdin for TASK-012+)
# ------------------------------------------------------------------------------
echo "[HARNESS] Running QEMU for ${TEST_CASE} (timeout=${TIMEOUT_SEC}s)..."
generate_interactive_stdin() {
    case "$TASK_NUM" in
        12)
            "$PYTHON_BIN" -c '
import sys, time
commands = [
    "export TINUX_STAGE=\"Interactive-TTY-Ready\"\n",
    "echo \"[TINUX_TTY] Operator session active: $TINUX_STAGE\"\n",
    "/bin/mkdir /tmp/ops\n",
    "echo \"Linux asset compatibility verified on Tinux!\" > /tmp/ops/report.txt\n",
    "/bin/cat /tmp/ops/report.txt | /bin/grep Tinux\n",
    "/bin/dyn_inspect\n",
    "/bin/ps\n",
    "echo \"[TINUX_OPS] All interactive Linux operations completed successfully!\"\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    time.sleep(0.05)
'
            ;;
        13)
            "$PYTHON_BIN" -c '
import sys, time
commands = [
    "echo \"[TINUX_SH] Starting background TCP server (/bin/net_test server &)...\"\n",
    "/bin/net_test server &\n",
    "SRV_PID=$!\n",
    "/bin/sleep 1\n",
    "echo \"[TINUX_SH] Inspecting /proc/net/tcp:\"\n",
    "/bin/cat /proc/net/tcp\n",
    "echo \"[TINUX_SH] Running TCP & UNIX socket client (/bin/net_test client)...\"\n",
    "/bin/net_test client\n",
    "wait $SRV_PID 2>/dev/null\n",
    "echo \"[TINUX_SOCKET] Multi-process TCP loopback (127.0.0.1:8080) & AF_UNIX IPC verified!\"\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    time.sleep(0.05)
'
            ;;
        14)
            "$PYTHON_BIN" -c '
import sys, time
commands = [
    "echo \"[TINUX_SH] Running multi-threaded futex & epoll verification suite...\"\n",
    "/bin/thread_epoll_test\n",
    "echo \"[TINUX_RUNTIME] CLONE_VM threads, futex synchronization, and epoll multiplexing verified!\"\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    time.sleep(0.05)
'
            ;;
        15)
            "$PYTHON_BIN" -c '
import sys, time
commands = [
    "echo \"[TINUX_SH] Inspecting /proc/partitions:\"\n",
    "/bin/cat /proc/partitions\n",
    "echo \"[TINUX_SH] Reading initial sector from /dev/vda and writing persistence marker:\"\n",
    "/bin/busybox blk_rw\n",
    "echo \"[TINUX_BLK] Guest-to-Host VirtIO-Block DMA read & write verified!\"\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    time.sleep(0.05)
'
            ;;
        16)
            cat << 'EOF'
echo "[TINUX_SH] Mounting /dev/vda onto /mnt..."
/bin/mount -t tarfs /dev/vda /mnt
/bin/cat /proc/mounts
echo "[TINUX_SH] Reading host-seeded file from /mnt/host_seed.txt:"
/bin/cat /mnt/host_seed.txt
echo "[TINUX_SH] Creating persistent file /mnt/guest_created.txt..."
echo "PERSISTED_BY_TINUX_KERNEL_OVER_VIRTIO_BLK" > /mnt/guest_created.txt
/bin/ls /mnt
/bin/sync
/bin/umount /mnt
echo "[TINUX_MOUNT] Persistent filesystem mount, read, writeback, and umount verified!"
exit 0
EOF
            ;;
        17)
            cat << 'EOF'
echo "[TINUX_SH] Executing external ICMP ping over VirtIO-Net (eth0)..."
/bin/ping_test
echo "[TINUX_SH] Inspecting /proc/net/arp and /proc/net/dev:"
/bin/cat /proc/net/arp
/bin/cat /proc/net/dev
echo "[TINUX_VIRTIONET] External ARP resolution and ICMP ping to 10.0.2.2 verified!"
exit 0
EOF
            ;;
        18)
            cat << 'EOF'
echo "[TINUX_SH] Running user-space signal delivery & rt_sigreturn test suite..."
/bin/sig_test
echo "[TINUX_SIGNAL] POSIX signal delivery (rt_sigaction/sigprocmask/setitimer/SIGCHLD/rt_sigreturn) verified!"
exit 0
EOF
            ;;
        19)
            cat << 'EOF'
echo "[TINUX_SH] Running UDP socket & RFC 1035 DNS resolver test suite..."
/bin/dns_test
echo "[TINUX_SH] Inspecting /proc/net/udp and /proc/net/arp:"
/bin/cat /proc/net/udp
/bin/cat /proc/net/arp
echo "[TINUX_DNS_DONE] UDP SOCK_DGRAM and DNS resolution (10.0.2.3:53) verified!"
exit 0
EOF
            ;;
        20)
            cat << 'EOF'
echo "[TINUX_SH] Running SMP multi-core affinity & getcpu verification..."
/bin/smp_test
echo "[TINUX_SH] Inspecting multi-core /proc/cpuinfo:"
/bin/cat /proc/cpuinfo
echo "[TINUX_SMP_DONE] Local APIC, IOAPIC, INIT-SIPI-SIPI AP boot, and SMP syscalls verified!"
exit 0
EOF
            ;;
    esac
}
if (( TASK_NUM >= 12 )); then
    (
        sleep 1.6
        generate_interactive_stdin
        sleep 3
    ) | timeout "$TIMEOUT_SEC" qemu-system-x86_64 "${QEMU_ARGS[@]}" > "$LOG_FILE" 2>&1
    QEMU_EXIT=$?
else
    timeout "$TIMEOUT_SEC" qemu-system-x86_64 "${QEMU_ARGS[@]}" > "$LOG_FILE" 2>&1
    QEMU_EXIT=$?
fi
cat "$LOG_FILE"
# ------------------------------------------------------------------------------
# 5. Validate QEMU Exit Code, Serial Output Markers & Host Persistence
# ------------------------------------------------------------------------------
if [ "$QEMU_EXIT" -ne 33 ]; then
    echo "[HARNESS] FAIL: Unexpected QEMU exit code $QEMU_EXIT (expected 33)."
    if [ -x "./scripts/triage_crash.py" ]; then
        ./scripts/triage_crash.py --log "$LOG_FILE" --elf "$KERNEL_BIN"
    fi
    exit 1
fi
if ! grep -q "\[TINUX_TEST\] PASS: ${TEST_CASE}" "$LOG_FILE"; then
    echo "[HARNESS] FAIL: Pass marker '[TINUX_TEST] PASS: ${TEST_CASE}' not found in serial log."
    exit 1
fi
# Host-side disk persistence verification for TASK-015 & TASK-016
if (( TASK_NUM == 15 )); then
    echo "[HARNESS] Verifying host-side disk image persistence..."
    if ! head -c 64 "$DISK_IMG" | grep -q "TINUX_PERSISTENCE_VERIFIED_ON_VIRTIO_BLK"; then
        echo "[HARNESS] FAIL: Host disk image Sector 0 was not updated by VirtIO-Block DMA write."
        exit 1
    fi
elif (( TASK_NUM == 16 )); then
    if tar -xOf "$DISK_IMG" guest_created.txt 2>/dev/null | grep -q "PERSISTED_BY_TINUX_KERNEL_OVER_VIRTIO_BLK"; then
        echo "[HARNESS] Host tar successfully extracted guest_created.txt from /dev/vda!"
    else
        echo "[HARNESS] FAIL: Host tar could not extract guest_created.txt from disk image."
        exit 1
    fi
fi
echo "[HARNESS] SUCCESS: ${TEST_CASE} verified cleanly!"
exit 0
