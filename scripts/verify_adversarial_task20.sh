#!/usr/bin/env bash
# Copyright (c) 2026 Tinux Project Developers
# Dual-licensed under MIT or Apache-2.0
# Dedicated Empirical Challenge Verification Script for Challenger (TASK-020)

set -euo pipefail

INITRAMFS_ROOT=".cache/initramfs_root"
LOG_FILE="/tmp/tinux_adversarial_task20.log"
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

echo "[CHALLENGER20_HARNESS] Running license guardrail check..."
"$PYTHON_BIN" scripts/check_license_guardrails.py

echo "[CHALLENGER20_HARNESS] Building userland test ELFs..."
mkdir -p .cache "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" "$INITRAMFS_ROOT/proc" "$INITRAMFS_ROOT/tmp"

# 1. Build challenger adversarial test binary
"$ZIG_BIN" build-exe src/user/adversarial_task20_challenger.zig \
    -target x86_64-freestanding \
    -O ReleaseSmall \
    -fno-PIE \
    "-femit-bin=$INITRAMFS_ROOT/bin/adversarial_task20_challenger"
rm -f "$INITRAMFS_ROOT/bin/adversarial_task20_challenger.o"

# 2. Build smp_test if needed
if [[ -f src/user/smp_test.zig ]]; then
    "$ZIG_BIN" build-exe src/user/smp_test.zig \
        -target x86_64-freestanding \
        -O ReleaseSmall \
        -fno-PIE \
        "-femit-bin=$INITRAMFS_ROOT/bin/smp_test"
    rm -f "$INITRAMFS_ROOT/bin/smp_test.o"
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

# Ensure no /etc/rc.sh interferes with interactive test
rm -f "${INITRAMFS_ROOT}/etc/rc.sh"

echo "[CHALLENGER20_HARNESS] Packaging initramfs.cpio..."
"$PYTHON_BIN" tools/cpio_writer.py "$INITRAMFS_ROOT" .cache/initramfs.cpio

echo "[CHALLENGER20_HARNESS] Building Tinux kernel for TASK-020..."
"$ZIG_BIN" build -Dtask=TASK-020

echo "[CHALLENGER20_HARNESS] Launching QEMU with SMP 2 cores and interactive feeder..."
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
    echo "[CHALLENGER20_HARNESS] Error: qemu-system-x86_64 not found!"
    exit 1
fi
QEMU_BIN="qemu-system-x86_64"

DISK_IMG="/tmp/tinux_disk_TASK-020.img"
DISK_STAGE="/tmp/tinux_disk_stage_TASK-020"
rm -rf "$DISK_STAGE" "$DISK_IMG" && mkdir -p "$DISK_STAGE"
echo "[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!" > "$DISK_STAGE/host_seed.txt"
tar --format=ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null || tar --format ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null
truncate -s 1M "$DISK_IMG" 2>/dev/null || dd if=/dev/zero of="$DISK_IMG" bs=1k count=1000 seek=24 status=none

(
    sleep 1.6
    "$PYTHON_BIN" -c '
import sys, time
commands = [
    "echo \"[TINUX_SH] Running adversarial TASK-020 SMP challenge suite...\"\n",
    "/bin/adversarial_task20_challenger\n",
    "echo \"[TINUX_SH] Running baseline smp_test verification...\"\n",
    "/bin/smp_test\n",
    "echo \"[TINUX_SH] Inspecting multi-core /proc/cpuinfo:\"\n",
    "/bin/cat /proc/cpuinfo\n",
    "echo \"[TINUX_SMP_DONE] Adversarial SMP suite verified!\"\n",
    "exit 0\n"
]
for cmd in commands:
    for ch in cmd:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(0.001)
    if cmd.startswith("/bin/adversarial"):
        time.sleep(1.8)
    else:
        time.sleep(0.2)
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
    -smp 2 \
    -drive "file=$DISK_IMG,format=raw,if=none,id=drv0" -device "virtio-blk-pci,drive=drv0,disable-legacy=off" \
    -netdev "user,id=net0" -device "virtio-net-pci,netdev=net0,disable-legacy=off" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    2>&1 | tee "$LOG_FILE" || true

echo "[CHALLENGER20_HARNESS] Validating log assertions..."
grep -q "sched_getaffinity(cpusetsize=0): expected=-22 actual=-22 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 1 cpusetsize=0"; exit 1; }
grep -q "sched_getaffinity(cpusetsize=1): expected=-22 actual=-22 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 1 cpusetsize=1"; exit 1; }
grep -q "sched_getaffinity(cpusetsize=4): expected=-22 actual=-22 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 1 cpusetsize=4"; exit 1; }
grep -q "sched_getaffinity(cpusetsize=7): expected=-22 actual=-22 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 1 cpusetsize=7"; exit 1; }
grep -q "sched_getaffinity(cpusetsize=0, mask_ptr=NULL): expected=-22 actual=-22 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 1 cpusetsize=0 NULL"; exit 1; }
grep -q "sched_getaffinity canary untampered on -EINVAL: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 1 canary integrity"; exit 1; }
grep -q "sched_getaffinity(cpusetsize=8, mask_ptr=NULL): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 2 NULL mask"; exit 1; }
grep -q "sched_getaffinity(mask_ptr=0xFFFF800000000000): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 3 kernel address"; exit 1; }
grep -q "sched_getaffinity(mask_ptr=0x2000 unmapped): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 3 unmapped"; exit 1; }
grep -q "sched_getaffinity(cpusetsize=16) rc: expected=8 actual=8 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 4 rc 16"; exit 1; }
grep -q "sched_getaffinity(16) mask=0x03: expected=3 actual=3 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 4 mask 16"; exit 1; }
grep -q "sched_getaffinity(16) trailing bytes zeroed: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 4 zeroed 16"; exit 1; }
grep -q "sched_getaffinity(cpusetsize=128) rc: expected=8 actual=8 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 4 rc 128"; exit 1; }
grep -q "sched_getaffinity(128) mask=0x03: expected=3 actual=3 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 4 mask 128"; exit 1; }
grep -q "sched_getaffinity(128) trailing 120 bytes zeroed: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 4 zeroed 128"; exit 1; }
grep -q "getcpu(cpu_ptr=NULL, &node) rc: expected=0 actual=0 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 5 getcpu null cpu"; exit 1; }
grep -q "getcpu(cpu_ptr=NULL, &node) node value: expected=0 actual=0 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 5 node value"; exit 1; }
grep -q "getcpu(bad cpu_ptr) rc: expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 6 bad cpu"; exit 1; }
grep -q "getcpu(bad node_ptr) rc: expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 6 bad node"; exit 1; }
grep -q "sched_setaffinity(mask_ptr=NULL): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 7 null mask"; exit 1; }
grep -q "sched_setaffinity(mask_ptr=kernel_addr): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 7 kernel mask"; exit 1; }
grep -q "sched_setaffinity(valid_mask=0x03): expected=0 actual=0 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 7 valid mask"; exit 1; }
grep -q "sched_yield 100 iterations return 0: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 8 sched_yield"; exit 1; }

# Vector 9: Paging Integrity & Ring 3 MMIO Protection
grep -q "sched_getaffinity(mask_ptr=LAPIC_BASE 0xFEE00000): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 LAPIC getaffinity"; exit 1; }
grep -q "sched_setaffinity(mask_ptr=LAPIC_BASE 0xFEE00000): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 LAPIC setaffinity"; exit 1; }
grep -q "getcpu(cpu_ptr=LAPIC_BASE 0xFEE00000): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 LAPIC getcpu"; exit 1; }
grep -q "getcpu(node_ptr=LAPIC_BASE 0xFEE00000): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 LAPIC getnode"; exit 1; }
grep -q "write(stdout, LAPIC_BASE 0xFEE00000, 4): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 LAPIC write"; exit 1; }
grep -q "read(stdin, LAPIC_BASE 0xFEE00000, 4): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 LAPIC read"; exit 1; }
grep -q "write(stdout, IOAPIC_BASE 0xFEC00000, 4): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 IOAPIC write"; exit 1; }
grep -q "read(stdin, IOAPIC_BASE 0xFEC00000, 4): expected=-14 actual=-14 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 IOAPIC read"; exit 1; }
grep -q "Ring 0 MMIO access via getcpu succeeds: expected=0 actual=0 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 9 Ring 0 MMIO"; exit 1; }

# Vector 10: Multi-Core /proc/cpuinfo Parsing
grep -q "open(/proc/cpuinfo): expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 open cpuinfo"; exit 1; }
grep -q "cpuinfo contains 'processor : 0': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 processor 0"; exit 1; }
grep -q "cpuinfo contains 'vendor_id : TinuxZig': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 vendor_id"; exit 1; }
grep -q "cpuinfo contains 'model name : Tinux Virtual SMP x86_64 CPU': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 model name"; exit 1; }
grep -q "cpuinfo contains 'cpu MHz : 3000.000': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 cpu MHz"; exit 1; }
grep -q "cpuinfo contains 'apicid : 0': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 apicid 0"; exit 1; }
grep -q "cpuinfo contains 'processor : 1': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 processor 1"; exit 1; }
grep -q "cpuinfo contains 'apicid : 1': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 apicid 1"; exit 1; }
grep -q "cpuinfo topology ordering: Core 0 precedes Core 1: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 10 ordering"; exit 1; }

# Vector 11: Multi-Core /proc/stat Parsing
grep -q "open(/proc/stat): expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 11 open stat"; exit 1; }
grep -q "stat contains aggregate 'cpu  200 0 200 2000...': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 11 aggregate line"; exit 1; }
grep -q "stat contains per-core 'cpu0 100 0 100 1000...': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 11 cpu0 line"; exit 1; }
grep -q "stat contains per-core 'cpu1 100 0 100 1000...': expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 11 cpu1 line"; exit 1; }
grep -q "stat line ordering: aggregate precedes cpu0 precedes cpu1: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 11 stat ordering"; exit 1; }

# Vector 12: Rapid Repeated Reading Stress & VFS Integrity
grep -q "100 rapid /proc/cpuinfo and /proc/stat reads without VFS corruption: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 12 100 reads"; exit 1; }
grep -q "VFS write probe open after procfs stress: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 12 probe write open"; exit 1; }
grep -q "VFS read probe content matches exactly: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 12 probe match"; exit 1; }
grep -q "VFS unlink probe file succeeds: expected=0 actual=0 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 12 unlink"; exit 1; }

# Vector 13: 500 Interleaved SMP Syscalls
grep -q "500 rapid interleaved SMP syscalls completed cleanly: expected=1 actual=1 \[OK\]" "$LOG_FILE" || { echo "Failed: Vector 13 stress"; exit 1; }

grep -q "\[CHALLENGER_M20\] All 13 empirical adversarial challenges & stress tests PASSED!" "$LOG_FILE" || { echo "Failed: Final pass marker"; exit 1; }
grep -q "\[TINUX_SMP\] sched_getaffinity mask=0x03 (2 CPUs online)" "$LOG_FILE" || { echo "Failed: Baseline smp_test"; exit 1; }
grep -q "processor : 1" "$LOG_FILE" || { echo "Failed: Multi-core cpuinfo core 1"; exit 1; }
grep -q "\[TINUX_TEST\] PASS: TASK-020" "$LOG_FILE" || { echo "Failed: Kernel test PASS"; exit 1; }

echo "[CHALLENGER20_HARNESS] SUCCESS: All 13 empirical adversarial challenges PASSED cleanly!"
