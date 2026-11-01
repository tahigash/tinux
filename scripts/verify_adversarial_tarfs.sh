#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Adversarial Empirical Challenge Suite for TASK-016 (tarfs, sys_mount/umount2, /proc/mounts)

set -uo pipefail

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

KERNEL_BIN="zig-out/bin/tinux"
if [[ ! -f "$KERNEL_BIN" ]]; then
    echo "[CHALLENGER] ERROR: Kernel binary $KERNEL_BIN not found. Please build first."
    exit 1
fi

ADV_DIR=".cache/adv_tests"
mkdir -p "$ADV_DIR"

run_qemu_test() {
    local scenario_name="$1"
    local disk_img="$2"
    local py_script="$3"
    local log_file="${ADV_DIR}/tinux_adv_${scenario_name}.log"

    echo "======================================================================"
    echo "[CHALLENGER] Running Scenario: ${scenario_name}"
    echo "======================================================================"

    local qemu_args=(
        -kernel "$KERNEL_BIN"
        -nographic
        -no-reboot
        -serial stdio
        -monitor none
        -device isa-debug-exit,iobase=0xf4,iosize=0x04
        -drive "file=${disk_img},format=raw,if=none,id=drv0"
        -device "virtio-blk-pci,drive=drv0,disable-legacy=off"
    )

    (
        sleep 1.6
        "$PYTHON_BIN" "$py_script"
        sleep 3
    ) | timeout 20 qemu-system-x86_64 "${qemu_args[@]}" > "$log_file" 2>&1
    local qemu_exit=$?

    echo "[CHALLENGER] QEMU Exit Code: ${qemu_exit} (expected 33)"
    if [ "$qemu_exit" -ne 33 ]; then
        echo "[CHALLENGER] FAIL: QEMU did not exit with 33."
        cat "$log_file"
        return 1
    fi
    echo "[CHALLENGER] PASS: Scenario ${scenario_name} completed cleanly in QEMU."
    return 0
}

# -----------------------------------------------------------------------------
# Scenario 1: Empty Archive (All Zeros)
# -----------------------------------------------------------------------------
SCENARIO1_DISK="${ADV_DIR}/adv_s1_empty.img"
SCENARIO1_PY="${ADV_DIR}/adv_s1_cmds.py"
rm -f "$SCENARIO1_DISK" "$SCENARIO1_PY"
dd if=/dev/zero of="$SCENARIO1_DISK" bs=1M count=1 status=none

cat << 'EOF' > "$SCENARIO1_PY"
import sys, time
commands = [
    "/bin/mount -t tarfs /dev/vda /mnt\n",
    "/bin/cat /proc/mounts\n",
    "echo \"BOOT_AND_MOUNT_FROM_ALL_ZERO_DISK_SUCCESS\" > /mnt/from_zero.txt\n",
    "/bin/ls /mnt\n",
    "/bin/sync\n",
    "/bin/umount /mnt\n",
    "echo \"[TINUX_ZERO_TEST_DONE]\"\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    time.sleep(0.05)
EOF

run_qemu_test "s1_empty_archive" "$SCENARIO1_DISK" "$SCENARIO1_PY" || exit 1

if tar -xOf "$SCENARIO1_DISK" from_zero.txt 2>/dev/null | grep -q "BOOT_AND_MOUNT_FROM_ALL_ZERO_DISK_SUCCESS"; then
    echo "[CHALLENGER] Host GNU tar successfully verified from_zero.txt written to initially zero disk!"
else
    echo "[CHALLENGER] FAIL: Host GNU tar could not extract from_zero.txt from zero-start disk."
    exit 1
fi

# -----------------------------------------------------------------------------
# Scenario 2: Multi-Sector Files (> 512 bytes)
# -----------------------------------------------------------------------------
SCENARIO2_STAGE="${ADV_DIR}/adv_s2_stage"
SCENARIO2_DISK="${ADV_DIR}/adv_s2_multisector.img"
SCENARIO2_PY="${ADV_DIR}/adv_s2_cmds.py"
rm -rf "$SCENARIO2_STAGE" "$SCENARIO2_DISK" "$SCENARIO2_PY"
mkdir -p "$SCENARIO2_STAGE/sub"

# Create a 2400-byte multi-sector file
"$PYTHON_BIN" -c '
with open("'"$SCENARIO2_STAGE"'/host_multi.txt", "wb") as f:
    for i in range(240):
        f.write(f"MULTI_SECTOR_BLOCK_{i:04d}_LINE_DATA_CHECKSUM_OK\n".encode("ascii"))
' || exit 1

echo "TINY_SEED_FILE" > "$SCENARIO2_STAGE/host_tiny.txt"
echo "NESTED_DIR_FILE_CONTENT" > "$SCENARIO2_STAGE/sub/nested.txt"

tar --format=ustar -cf "$SCENARIO2_DISK" -C "$SCENARIO2_STAGE" host_multi.txt host_tiny.txt sub/nested.txt
truncate -s 1M "$SCENARIO2_DISK" 2>/dev/null || dd if=/dev/zero of="$SCENARIO2_DISK" bs=1k count=1000 seek=24 status=none

cat << 'EOF' > "$SCENARIO2_PY"
import sys, time
commands = [
    "/bin/mount -t tarfs /dev/vda /mnt\n",
    "/bin/cat /proc/mounts\n",
    "/bin/ls /mnt\n",
    "/bin/cat /mnt/host_tiny.txt\n",
    "/bin/cat /mnt/sub/nested.txt\n",
    "echo \"GUEST_MULTI_PERSISTENCE_CONFIRMED\" > /mnt/guest_add.txt\n",
    "/bin/ls /mnt\n",
    "/bin/sync\n",
    "/bin/umount /mnt\n",
    "echo \"[TINUX_MULTI_TEST_DONE]\"\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    time.sleep(0.05)
EOF

run_qemu_test "s2_multisector" "$SCENARIO2_DISK" "$SCENARIO2_PY" || exit 1

if tar -xOf "$SCENARIO2_DISK" guest_add.txt 2>/dev/null | grep -q "GUEST_MULTI_PERSISTENCE_CONFIRMED"; then
    echo "[CHALLENGER] Host GNU tar successfully verified guest_add.txt alongside multi-sector host files!"
else
    echo "[CHALLENGER] FAIL: Host GNU tar could not extract guest_add.txt from multi-sector disk."
    exit 1
fi

EXTRACTED_MULTI="${ADV_DIR}/adv_s2_extracted_multi.txt"
tar -xOf "$SCENARIO2_DISK" host_multi.txt > "$EXTRACTED_MULTI" 2>/dev/null
if cmp -s "$SCENARIO2_STAGE/host_multi.txt" "$EXTRACTED_MULTI"; then
    echo "[CHALLENGER] Multi-sector file host_multi.txt (2400 bytes) preserved bit-for-bit after guest syncToDisk!"
else
    echo "[CHALLENGER] FAIL: host_multi.txt data corruption detected after writeback."
    exit 1
fi

# -----------------------------------------------------------------------------
# Scenario 3: Corrupted Magic Header
# -----------------------------------------------------------------------------
SCENARIO3_DISK="${ADV_DIR}/adv_s3_corrupt.img"
SCENARIO3_PY="${ADV_DIR}/adv_s3_cmds.py"
rm -f "$SCENARIO3_DISK" "$SCENARIO3_PY"
dd if=/dev/zero of="$SCENARIO3_DISK" bs=1M count=1 status=none

# Write corrupted header to sector 0 with invalid magic "BADMGK"
"$PYTHON_BIN" -c '
with open("'"$SCENARIO3_DISK"'", "r+b") as f:
    hdr = bytearray(512)
    hdr[0:8] = b"corrupt\x00"
    hdr[257:263] = b"BADMGK"
    f.write(hdr)
' || exit 1

cat << 'EOF' > "$SCENARIO3_PY"
import sys, time
commands = [
    "/bin/mount -t tarfs /dev/vda /mnt\n",
    "/bin/cat /proc/mounts\n",
    "echo \"RECOVERED_FROM_CORRUPT_HEADER\" > /mnt/recovered.txt\n",
    "/bin/ls /mnt\n",
    "/bin/sync\n",
    "/bin/umount /mnt\n",
    "echo \"[TINUX_CORRUPT_TEST_DONE]\"\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    time.sleep(0.05)
EOF

run_qemu_test "s3_corrupt_magic" "$SCENARIO3_DISK" "$SCENARIO3_PY" || exit 1

if tar -xOf "$SCENARIO3_DISK" recovered.txt 2>/dev/null | grep -q "RECOVERED_FROM_CORRUPT_HEADER"; then
    echo "[CHALLENGER] Host GNU tar successfully verified recovered.txt after mounting corrupt-magic disk!"
else
    echo "[CHALLENGER] FAIL: Host GNU tar could not extract recovered.txt from repaired disk."
    exit 1
fi

echo ""
echo "======================================================================"
echo "[CHALLENGER] ALL ADVERSARIAL STRESS SCENARIOS PASSED 100% CLEANLY!"
echo "======================================================================"
exit 0
