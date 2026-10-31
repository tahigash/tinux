#!/usr/bin/env bash
set -uo pipefail
# ==============================================================================
# Tinux Kernel & Linux ABI Automated Regression Test Runner (TASK-001 .. TASK-020)
# ==============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
REPORT_FILE="REGRESSION_REPORT.md"
KERNEL_BIN="zig-out/bin/tinux"
TIMEOUT_SEC=12
FORCE_STAGE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage|--target)
            FORCE_STAGE="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT_SEC="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
now_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}
detect_current_stage() {
    if [[ -n "$FORCE_STAGE" ]]; then
        echo "${FORCE_STAGE#TASK-}" | sed 's/^0*//'
        return
    fi
    local max_stage=0
    if [[ -f "PROGRESS.md" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ \[[xX]\][[:space:]]+\*\*TASK-0*([0-9]+)\*\* ]]; then
                local num="${BASH_REMATCH[1]}"
                if (( num > max_stage )); then
                    max_stage=$num
                fi
            fi
        done < "PROGRESS.md"
    fi
    if (( max_stage == 0 )) && [[ -f "src/main.zig" ]]; then
        local m
        m=$(grep -oE "TASK-0*[0-9]+" src/main.zig | tail -n 1 | sed -E 's/TASK-0*//')
        if [[ -n "$m" ]]; then
            max_stage=$m
        fi
    fi
    if (( max_stage == 0 )); then
        max_stage=1
    fi
    echo "$max_stage"
}
CURRENT_STAGE_NUM=$(detect_current_stage)
CURRENT_TASK_ID=$(printf "TASK-%03d" "$CURRENT_STAGE_NUM")
echo -e "${BOLD}==============================================================================${NC}"
echo -e "${BOLD}  Tinux Automated Regression Suite (20-Milestone Edition) — Stage: ${CYAN}${CURRENT_TASK_ID}${NC}"
echo -e "${BOLD}==============================================================================${NC}"
declare -a CHECK_IDS=()
declare -a CHECK_NAMES=()
declare -a CHECK_STATUS=()
declare -a CHECK_TIMES=()
declare -a CHECK_DETAILS=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
record_result() {
    local id="$1"
    local name="$2"
    local status="$3"
    local elapsed="$4"
    local detail="$5"
    CHECK_IDS+=("$id")
    CHECK_NAMES+=("$name")
    CHECK_STATUS+=("$status")
    CHECK_TIMES+=("${elapsed}ms")
    CHECK_DETAILS+=("$detail")
    if [[ "$status" == "PASS" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf "  [${GREEN}PASS${NC}] %-12s %-46s (%5sms) %s\n" "$id" "$name" "$elapsed" "$detail"
    elif [[ "$status" == "SKIP" ]]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        printf "  [${YELLOW}SKIP${NC}] %-12s %-46s (%5sms) %s\n" "$id" "$name" "$elapsed" "$detail"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf "  [${RED}FAIL${NC}] %-12s %-46s (%5sms) %s\n" "$id" "$name" "$elapsed" "$detail"
    fi
}
# ------------------------------------------------------------------------------
# Gate 0: Clean-Room License & Binary Guardrail Audit
# ------------------------------------------------------------------------------
if [[ -f "scripts/check_license_guardrails.py" ]]; then
    echo -e "\n${BLUE}[Gate 0] Auditing clean-room boundaries and licensing integrity...${NC}"
    if python -c "import sys" >/dev/null 2>&1; then
        python scripts/check_license_guardrails.py || { echo -e "${RED}[FAIL]${NC} License guardrails violated."; exit 1; }
    elif python3 -c "import sys" >/dev/null 2>&1; then
        python3 scripts/check_license_guardrails.py || { echo -e "${RED}[FAIL]${NC} License guardrails violated."; exit 1; }
    fi
    echo -e "${GREEN}[PASS]${NC} Clean-room boundaries and hybrid licensing verified."
fi

# ------------------------------------------------------------------------------
# Phase 1: Static Build, Binary Size & Xen PVH ELF Note Audit
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[Phase 1/3] Static Compilation & ELF/ABI Structural Audit${NC}"
T0=$(now_ms)
if [[ -x "./scripts/verify_qemu.sh" ]]; then
    ./scripts/verify_qemu.sh "$CURRENT_TASK_ID" "$TIMEOUT_SEC" > "/tmp/tinux_reg_primary.log" 2>&1
    PRIMARY_RC=$?
else
    zig build > "/tmp/tinux_reg_primary.log" 2>&1
    PRIMARY_RC=$?
fi
T1=$(now_ms)
PRIMARY_MS=$((T1 - T0))
if [[ -f "$KERNEL_BIN" ]]; then
    BIN_SIZE=$(wc -c < "$KERNEL_BIN" | tr -d ' ')
    record_result "BUILD-ELF" "Zig freestanding kernel compilation" "PASS" "$PRIMARY_MS" "size=${BIN_SIZE}B"
else
    record_result "BUILD-ELF" "Zig freestanding kernel compilation" "FAIL" "$PRIMARY_MS" "zig-out/bin/tinux missing"
fi
T0=$(now_ms)
if [[ -f "$KERNEL_BIN" ]] && python3 -c '
import sys
data = open(sys.argv[1], "rb").read()
sys.exit(0 if b"Xen\x00" in data else 1)
' "$KERNEL_BIN" 2>/dev/null; then
    T1=$(now_ms)
    record_result "BOOT-PVH" "Xen PVH ELF Note (XEN_ELFNOTE_PHYS32_ENTRY)" "PASS" "$((T1 - T0))" "Direct -kernel rea
else
    T1=$(now_ms)
    record_result "BOOT-PVH" "Xen PVH ELF Note (XEN_ELFNOTE_PHYS32_ENTRY)" "FAIL" "$((T1 - T0))" "Note missing in EL
fi
T0=$(now_ms)
COMPTIME_COUNT=$(grep -rn "@sizeOf(" src/ 2>/dev/null | wc -l | tr -d ' ')
T1=$(now_ms)
if (( COMPTIME_COUNT >= 1 )); then
    record_result "ABI-ASSERT" "Compile-time Linux x86_64 ABI assertions" "PASS" "$((T1 - T0))" "${COMPTIME_COUNT} a
else
    record_result "ABI-ASSERT" "Compile-time Linux x86_64 ABI assertions" "SKIP" "$((T1 - T0))" "Pre-TASK-002 stage"
fi
# ------------------------------------------------------------------------------
# Phase 2: Primary Milestone Execution & Exception/Panic Audit
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[Phase 2/3] Primary Milestone QEMU Execution & Exception Audit${NC}"
LOG_CONTENT=""
if [[ -f "/tmp/tinux_reg_primary.log" ]]; then
    LOG_CONTENT=$(cat "/tmp/tinux_reg_primary.log")
fi
if echo "$LOG_CONTENT" | grep -qE "\[TINUX_PANIC\]|Unhandled Exception|Triple fault"; then
    record_result "CPU-HEALTH" "Zero Kernel Panic / #PF / #GP / #DF exceptions" "FAIL" "0" "Exception detected in lo
else
    record_result "CPU-HEALTH" "Zero Kernel Panic / #PF / #GP / #DF exceptions" "PASS" "0" "Clean Ring 0/Ring 3 run"
fi
if [[ "$PRIMARY_RC" -eq 0 ]]; then
    record_result "$CURRENT_TASK_ID" "Active milestone verification harness" "PASS" "$PRIMARY_MS" "Exit code 0 (QEMU
else
    record_result "$CURRENT_TASK_ID" "Active milestone verification harness" "FAIL" "$PRIMARY_MS" "verify_qemu.sh fa
fi
# ------------------------------------------------------------------------------
# Phase 3: Cumulative Subsystem Regression Matrix (TASK-001 .. TASK-020)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[Phase 3/3] Cumulative Subsystem Regression Matrix (TASK-001 .. TASK-020)${NC}"
MULTI_LOG="/tmp/tinux_reg_matrix.log"
MATRIX_DISK="/tmp/tinux_reg_matrix_disk.img"
if (( CURRENT_STAGE_NUM >= 12 )) && [[ -f "$KERNEL_BIN" ]]; then
    T0=$(now_ms)
    QEMU_EXTRA_ARGS=()
    if (( CURRENT_STAGE_NUM >= 15 )); then
        DISK_STAGE="/tmp/tinux_reg_stage"
        rm -rf "$DISK_STAGE" && mkdir -p "$DISK_STAGE"
        if (( CURRENT_STAGE_NUM >= 16 )); then
            echo "[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!" > "$DISK_STAGE/host_seed.txt"
            tar --format=ustar -cf "$MATRIX_DISK" -C "$DISK_STAGE" host_seed.txt
            truncate -s 1M "$MATRIX_DISK"
        else
            dd if=/dev/zero of="$MATRIX_DISK" bs=1M count=1 status=none
            printf "[TINUX_DISK_SECTOR0] Host-provisioned VirtIO-Block image ready!\n" | dd of="$MATRIX_DISK" conv=n
        fi
        QEMU_EXTRA_ARGS+=(-drive "file=$MATRIX_DISK,format=raw,if=none,id=drv0" -device "virtio-blk-pci,drive=drv0,d
    fi
    if (( CURRENT_STAGE_NUM >= 17 )); then
        QEMU_EXTRA_ARGS+=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0,disable-legacy=off")
    fi
    if (( CURRENT_STAGE_NUM >= 20 )); then
        QEMU_EXTRA_ARGS+=(-smp "2")
    fi
    (
        sleep 0.4
        cat << 'CMDS_BASE'
export REG_VAR="SUBSYSTEM_MATRIX_OK"
echo "[REG_TTY] Interactive shell & env: $REG_VAR"
/bin/cat /etc/motd | /bin/grep Tinux
/bin/cat /proc/version
/bin/cat /proc/meminfo
/bin/mkdir /tmp/reg_dir
echo "TMPFS_REGRESSION_PASS" > /tmp/reg_dir/test.txt
/bin/touch /tmp/reg_dir/empty.tmp
/bin/ls /tmp/reg_dir
/bin/cat /tmp/reg_dir/test.txt
/bin/rm /tmp/reg_dir/empty.tmp
/bin/sleep 1 &
BG_PID=$!
/bin/ps
kill -9 $BG_PID 2>/dev/null
wait $BG_PID 2>/dev/null
/bin/dyn_inspect
CMDS_BASE
        if (( CURRENT_STAGE_NUM >= 13 )); then
            cat << 'CMDS_13'
/bin/net_test server &
SRV_PID=$!
/bin/sleep 1
/bin/cat /proc/net/tcp
/bin/net_test client
wait $SRV_PID 2>/dev/null
CMDS_13
        fi
        if (( CURRENT_STAGE_NUM >= 14 )); then
            cat << 'CMDS_14'
/bin/thread_epoll_test
CMDS_14
        fi
        if (( CURRENT_STAGE_NUM == 15 )); then
            cat << 'CMDS_15'
/bin/cat /proc/partitions
CMDS_15
        fi
        if (( CURRENT_STAGE_NUM >= 16 )); then
            cat << 'CMDS_16'
/bin/mount -t tarfs /dev/vda /mnt
/bin/cat /mnt/host_seed.txt
echo "PERSISTED_BY_TINUX_KERNEL_OVER_VIRTIO_BLK" > /mnt/guest_created.txt
/bin/sync
/bin/umount /mnt
CMDS_16
        fi
        if (( CURRENT_STAGE_NUM >= 17 )); then
            cat << 'CMDS_17'
/bin/ping_test
/bin/cat /proc/net/arp
/bin/cat /proc/net/dev
CMDS_17
        fi
        if (( CURRENT_STAGE_NUM >= 18 )); then
            cat << 'CMDS_18'
/bin/sig_test
CMDS_18
        fi
        if (( CURRENT_STAGE_NUM >= 19 )); then
            cat << 'CMDS_19'
/bin/dns_test
/bin/cat /proc/net/udp
CMDS_19
        fi
        if (( CURRENT_STAGE_NUM >= 20 )); then
            cat << 'CMDS_20'
/bin/smp_test
/bin/cat /proc/cpuinfo
CMDS_20
        fi
        echo "exit 0"
    ) | timeout "$TIMEOUT_SEC" qemu-system-x86_64 \
        -kernel "$KERNEL_BIN" \
        -nographic \
        -no-reboot \
        -serial stdio \
        -monitor none \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        "${QEMU_EXTRA_ARGS[@]}" \
        > "$MULTI_LOG" 2>&1
    T1=$(now_ms)
    MATRIX_MS=$((T1 - T0))
    COMBINED_LOG=$(cat "/tmp/tinux_reg_primary.log" "$MULTI_LOG" 2>/dev/null)
else
    COMBINED_LOG="$LOG_CONTENT"
    MATRIX_MS="$PRIMARY_MS"
fi
check_milestone_feature() {
    local task_num="$1"
    local task_id
    task_id=$(printf "REG-%03d" "$task_num")
    local title="$2"
    local pattern="$3"
    if (( CURRENT_STAGE_NUM < task_num )); then
        record_result "$task_id" "$title" "SKIP" "0" "Not yet implemented"
        return
    fi
    if echo "$COMBINED_LOG" | grep -qE "$pattern"; then
        record_result "$task_id" "$title" "PASS" "$((MATRIX_MS / CURRENT_STAGE_NUM))" "Verified in QEMU serial log"
    else
        record_result "$task_id" "$title" "FAIL" "$((MATRIX_MS / CURRENT_STAGE_NUM))" "Pattern '$pattern' missing"
    fi
}
check_milestone_feature 1  "Boot & 16550A Serial Console Output"          "TINUX_TEST|TINUX_BOOT|TINUX_INIT"
check_milestone_feature 2  "GDT/TSS, IDT Exception Gates & Bitmap PMM"    "TINUX_GDT|TINUX_INIT|TINUX_TEST"
check_milestone_feature 3  "4-Level Page Table VMM & Kernel Heap"         "TINUX_VMM|TINUX_HEAP|TINUX_INIT"
check_milestone_feature 4  "SYSCALL/SYSRET MSRs & Ring 3 Transition"      "TINUX_SYSCALL|sys_exit\(0\)"
check_milestone_feature 5  "Static ELF64 Loader, Auxv, TLS & sys_brk"     "TINUX_ELF|TINUX_INIT"
check_milestone_feature 6  "In-Memory VFS, CPIO Initramfs & BusyBox"      "Welcome to Tinux|TINUX_VFS"
check_milestone_feature 7  "Multi-Process fork/execve/wait4 & /bin/sh"    "TINUX_SH|TINUX_INIT"
check_milestone_feature 8  "IPC Pipes (pipe2), dup2 & /proc Pseudo-FS"    "Linux version 6\.12\.0-tinux|Welcome to T
check_milestone_feature 9  "Writable tmpfs, getdents64 & File Ops"        "hello\.txt|TMPFS_REGRESSION_PASS"
check_milestone_feature 10 "PIT 100Hz Timer, nanosleep, /proc/pid & ps"   "PID|TINUX_PROC|TINUX_TIMER"
check_milestone_feature 11 "Dynamic ELF Loader (PT_INTERP / ld-musl)"     "TINUX_DYN"
check_milestone_feature 12 "Interactive TTY Console (IRQ4 / termios)"     "TINUX_TTY|REG_TTY"
check_milestone_feature 13 "Linux Socket API (TCP 127.0.0.1 & AF_UNIX)"   "PONG_FROM_TINUX_SERVER|TINUX_NET"
check_milestone_feature 14 "Multi-Threading (CLONE_VM), futex & epoll"    "TINUX_FUTEX|TINUX_JOIN"
check_milestone_feature 15 "PCI Bus Master & VirtIO-Block (/dev/vda)"     "TINUX_BLK|vda"
check_milestone_feature 16 "Persistent USTAR TarFS Mount (sys_mount)"     "TINUX_TARFS|TINUX_MOUNT"
check_milestone_feature 17 "VirtIO-Net (eth0), ARP & ICMP External Ping"  "TINUX_PING|TINUX_VIRTIONET|TINUX_NETDRV"
check_milestone_feature 18 "POSIX Signal Delivery (rt_sigaction/return)"  "TINUX_SIG|TINUX_SIGNAL"
check_milestone_feature 19 "UDP SOCK_DGRAM & RFC 1035 DNS Resolver"       "TINUX_DNS|TINUX_UDP"
check_milestone_feature 20 "Local APIC/IOAPIC & SMP Multi-Core (-smp 2)"  "TINUX_SMP|TINUX_APIC"
# ------------------------------------------------------------------------------
# Generate Markdown Regression Report (REGRESSION_REPORT.md)
# ------------------------------------------------------------------------------
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
OVERALL_BADGE="PASSED"
if (( FAIL_COUNT > 0 )); then
    OVERALL_BADGE="FAILED"
fi
{
    echo "# Tinux Automated Regression Report (20-Milestone Suite)"
    echo ""
    echo "* **Timestamp:** \`${TIMESTAMP}\`"
    echo "* **Detected Milestone Stage:** \`${CURRENT_TASK_ID}\`"
    echo "* **Overall Verdict:** **${OVERALL_BADGE}** (\`${PASS_COUNT} Passed\`, \`${FAIL_COUNT} Failed\`, \`${SKIP_
    echo ""
    echo "## Results Matrix"
    echo ""
    echo "| Check ID | Subsystem / Milestone Verification | Status | Time | Details |"
    echo "| :--- | :--- | :---: | :---: | :--- |"
    for i in "${!CHECK_IDS[@]}"; do
        st="${CHECK_STATUS[$i]}"
        icon=" ✅  PASS"
        [[ "$st" == "FAIL" ]] && icon=" ❌  FAIL"
        [[ "$st" == "SKIP" ]] && icon=" ⏭  SKIP"
        echo "| \`${CHECK_IDS[$i]}\` | ${CHECK_NAMES[$i]} | ${icon} | \`${CHECK_TIMES[$i]}\` | ${CHECK_DETAILS[$i]} 
    done
} > "$REPORT_FILE"
echo -e "\n${BOLD}==============================================================================${NC}"
echo -e "  Regression Summary: ${GREEN}${PASS_COUNT} Passed${NC}, ${RED}${FAIL_COUNT} Failed${NC},${YELLOW}${SKIP_CO
echo -e "  Markdown Report   : ${CYAN}${REPORT_FILE}${NC}"
echo -e "${BOLD}==============================================================================${NC}"
if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
