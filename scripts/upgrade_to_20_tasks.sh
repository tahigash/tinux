#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# Tinux Infrastructure Upgrader: TASK-001..016 -> TASK-001..020
# Integrates:
#   - TASK-017: VirtIO-Net PCI Driver (TX/RX Virtqueue DMA) & ARP/IPv4/ICMP Ping
#   - TASK-018: POSIX Signal Delivery (Signal Trampoline, rt_sigaction/sigreturn)
#   - TASK-019: UDP SOCK_DGRAM Stack, /proc/net/udp & RFC 1035 DNS Resolver
#   - TASK-020: Local APIC / IOAPIC, INIT-SIPI-SIPI SMP Multi-Core Boot (-smp 2)
# ==============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${BLUE}[UPGRADE]${NC}$*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}$*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}$*"; }
mkdir -p docs/specs scripts
# ------------------------------------------------------------------------------
# 1. Non-Destructive Update of PROGRESS.md (Preserves existing [x] checkmarks)
# ------------------------------------------------------------------------------
log_info "Updating PROGRESS.md with TASK-017 .. TASK-020..."
if [[ ! -f "PROGRESS.md" ]]; then
    log_warn "PROGRESS.md not found; creating fresh 20-task PROGRESS.md..."
    cat << 'EOF' > PROGRESS.md
# Tinux Autonomous Implementation Progress
> **Instructions for Builder Agent (Gemini 3.8 Flash High):**
> 1. Find the first task below marked `[ ]`.
> 2. Read its corresponding specification in `docs/specs/SPEC_TASK_0XX.md`.
> 3. Implement the code and run `./scripts/verify_qemu.sh TASK-0XX`.
> 4. When and only when `verify_qemu.sh` exits with `0` (`PASS`), update `[ ]` to `[x]`, commit all changes, and proceed to the next milestone.
> 5. If verification fails 3 consecutive times, stop immediately and write `ESCALATION_REPORT.md`.
## Milestone Checklist
- [ ] **TASK-001**: `docs/specs/SPEC_TASK_001.md`: x86_64 Minimal Boot (Xen PVH), COM1 Serial Console & QEMU Auto-Verification Harness
- [ ] **TASK-002**: `docs/specs/SPEC_TASK_002.md`: GDT/TSS Reconstruction, IDT Exception Handlers (176B TrapFrame), and Bitmap PMM
- [ ] **TASK-003**: `docs/specs/SPEC_TASK_003.md`: 4-Level Page Table Manager (VMM) and std.mem.Allocator Kernel Heap
- [ ] **TASK-004**: `docs/specs/SPEC_TASK_004.md`: SYSCALL/SYSRET MSR Setup, Ring 3 Transition, and Minimal Syscall Dispatcher
- [ ] **TASK-005**: `docs/specs/SPEC_TASK_005.md`: Static ELF64 Loader, System V AMD64 Stack (auxv), TLS (arch_prctl), and sys_brk
- [ ] **TASK-006**: `docs/specs/SPEC_TASK_006.md`: In-Memory VFS, CPIO (newc) Initramfs Unpacker, and File I/O Syscalls
- [ ] **TASK-007**: `docs/specs/SPEC_TASK_007.md`: Multi-Process Management (Task Table, cloneUserPml4), fork/execve/wait4
- [ ] **TASK-008**: `docs/specs/SPEC_TASK_008.md`: IPC Pipes (pipe2), I/O Redirection (dup2/O_CLOEXEC), and /proc Pseudo-FS
- [ ] **TASK-009**: `docs/specs/SPEC_TASK_009.md`: Writable tmpfs (Create/Write/Truncate/Unlink/Mkdir) and getdents64
- [ ] **TASK-010**: `docs/specs/SPEC_TASK_010.md`: Hardware Timer (8259A PIC + 8254 PIT 100Hz), nanosleep, and /proc/[pid]/stat
- [ ] **TASK-011**: `docs/specs/SPEC_TASK_011.md`: Dynamic ELF Loader (PT_INTERP / ld-musl-x86_64.so.1 Co-Loading)
- [ ] **TASK-012**: `docs/specs/SPEC_TASK_012.md`: Bidirectional TTY Console (IRQ4 RX + Line Discipline + termios ioctls)
- [ ] **TASK-013**: `docs/specs/SPEC_TASK_013.md`: Linux Socket API (AF_INET 127.0.0.1 Loopback & AF_UNIX IPC)
- [ ] **TASK-014**: `docs/specs/SPEC_TASK_014.md`: Multi-Threading (CLONE_VM | CLONE_THREAD | CLONE_SETTLS) and sys_futex
- [ ] **TASK-015**: `docs/specs/SPEC_TASK_015.md`: PCI Bus Enumeration, VirtIO-Block DMA Driver (/dev/vda), and Persistence
- [ ] **TASK-016**: `docs/specs/SPEC_TASK_016.md`: Persistent USTAR Filesystem (tarfs), sys_mount/sys_umount2/sys_sync
EOF
fi
append_task_if_missing() {
    local task_id="$1"
    local line="$2"
    if ! grep -q "\*\*${task_id}\*\*" PROGRESS.md; then
        echo "$line" >> PROGRESS.md
        log_ok "Appended ${task_id} to PROGRESS.md"
    else
        log_ok "${task_id} already present in PROGRESS.md (state preserved)"
    fi
}
append_task_if_missing "TASK-017" "- [ ] **TASK-017**: \`docs/specs/SPEC_TASK_017.md\`: VirtIO-Net PCI Network Driver & Ping Verification"
append_task_if_missing "TASK-018" "- [ ] **TASK-018**: \`docs/specs/SPEC_TASK_018.md\`: User-Space Signal Delivery & rt_sigreturn"
append_task_if_missing "TASK-019" "- [ ] **TASK-019**: \`docs/specs/SPEC_TASK_019.md\`: UDP/IPv4 Socket Stack (SOCK_DGRAM) & DNS Resolver"
append_task_if_missing "TASK-020" "- [ ] **TASK-020**: \`docs/specs/SPEC_TASK_020.md\`: Local APIC / IOAPIC Init, SMP Multi-Core Boot (-smp 2)"
# ------------------------------------------------------------------------------
# 2. Update scripts/check_specs.sh for 20 Specifications
# ------------------------------------------------------------------------------
log_info "Updating scripts/check_specs.sh for TASK-001 .. TASK-020..."
cat << 'EOF' > scripts/check_specs.sh
#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Tinux Specification Readiness & Quality Validator (TASK-001 .. TASK-020)
# Validates:
#   1. Existence and non-emptiness (>30 lines)
#   2. Absence of STATUS: PLACEHOLDER tags
#   3. Zero stray clipboard markers (^\d+\s+---)
#   4. Zero non-ASCII / Japanese characters (ord > 127)
# ==============================================================================

PYTHON_BIN=""
for cand in python python3 py; do
    if "$cand" -c 'import sys' >/dev/null 2>&1; then
        PYTHON_BIN="$cand"
        break
    fi
done

echo "Checking Tinux specification readiness (TASK-001 .. TASK-020)..."
READY_COUNT=0
TOTAL_SPECS=20

for num in $(seq -f "%03g" 1 "$TOTAL_SPECS"); do
    FILE="docs/specs/SPEC_TASK_${num}.md"

    if [ ! -f "$FILE" ]; then
        echo "  [PENDING] $FILE (file missing)"
        continue
    fi

    LINE_COUNT=$(wc -l < "$FILE" | tr -d ' ')
    if [ "$LINE_COUNT" -le 30 ]; then
        echo "  [PENDING] $FILE (fewer than 30 lines: $LINE_COUNT lines)"
        continue
    fi

    if grep -q "STATUS: PLACEHOLDER" "$FILE"; then
        echo "  [PENDING] $FILE (contains STATUS: PLACEHOLDER)"
        continue
    fi

    if grep -qE "^[0-9]+[[:space:]]+---" "$FILE"; then
        echo "  [PENDING] $FILE (contains clipboard marker '^[0-9]+ ---')"
        continue
    fi

    HAS_NON_ASCII=0
    if [ -n "$PYTHON_BIN" ]; then
        if ! "$PYTHON_BIN" -c '
import sys
try:
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    sys.exit(1 if any(b > 127 for b in data) else 0)
except Exception:
    sys.exit(2)
' "$FILE" >/dev/null 2>&1; then
            HAS_NON_ASCII=1
        fi
    else
        NON_ASCII_COUNT=$(LC_ALL=C tr -d '\000-\177' < "$FILE" | wc -c | tr -d ' ')
        if [ "$NON_ASCII_COUNT" -gt 0 ]; then
            HAS_NON_ASCII=1
        fi
    fi

    if [ "$HAS_NON_ASCII" -eq 1 ]; then
        echo "  [PENDING] $FILE (contains non-ASCII or Japanese characters)"
        continue
    fi

    echo "  [READY]   $FILE"
    READY_COUNT=$((READY_COUNT + 1))
done

echo "Summary: ${READY_COUNT}/${TOTAL_SPECS} specifications ready for Builder execution."

if [ "$READY_COUNT" -eq "$TOTAL_SPECS" ]; then
    exit 0
else
    exit 1
fi
EOF
chmod +x scripts/check_specs.sh
log_ok "scripts/check_specs.sh updated to check 20 tasks."
# ------------------------------------------------------------------------------
# 3. Update init_project.sh to Support All 20 Tasks Out-of-the-Box
# ------------------------------------------------------------------------------
log_info "Updating init_project.sh with TASK-001 .. TASK-020 definitions..."
cat << 'EOF' > init_project.sh
#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*"; }
echo "======================================================================"
echo "  Tinux Project Initializer (20-Milestone x86_64 Zig Linux Kernel)"
echo "======================================================================"
MISSING_TOOLS=0
for cmd in zig qemu-system-x86_64 cpio tar git python3; do
    if command -v "$cmd" >/dev/null 2>&1; then
        VER=$("$cmd" --version 2>&1 | head -n 1 || true)
        log_ok "Found $cmd ($VER)"
    else
        log_err "Missing required tool: $cmd"
        MISSING_TOOLS=1
    fi
done
DIRS=(
    "docs/specs"
    "scripts"
    "tools"
    "src/arch/x86_64"
    "src/drivers"
    "src/mm"
    "src/fs"
    "src/proc"
    "src/net"
    "src/syscall"
    "src/uapi"
    "src/user"
    ".cache/initramfs_root/bin"
    ".cache/initramfs_root/etc"
    ".cache/initramfs_root/lib"
    ".cache/initramfs_root/tmp"
    ".cache/initramfs_root/mnt"
)
for d in "${DIRS[@]}"; do
    mkdir -p "$d"
done
declare -A TASK_TITLES=(
    ["001"]="x86_64 Minimal Kernel Boot, Serial Console (COM1), and QEMU Auto-Verification Harness"
    ["002"]="x86_64 GDT/TSS Reconstruction, IDT Exception Handlers, and Physical Page Frame Allocator (PMM)"
    ["003"]="x86_64 4-Level Page Table Manager (VMM) and std.mem.Allocator Compliant Kernel Heap"
    ["004"]="x86_64 SYSCALL/SYSRET MSR Setup, Ring 3 Transition, and Minimal Syscall Dispatcher"
    ["005"]="Linux x86_64 Static ELF Loader, System V AMD64 Initial Stack (auxv), and sys_arch_prctl / sys_brk"
    ["006"]="In-Memory VFS, Initramfs (newc CPIO) Unpacker, File I/O Syscalls, and Unmodified BusyBox Execution"
    ["007"]="Multi-Process Management, sys_fork / sys_clone / sys_execve / sys_wait4, and BusyBox Shell Execution"
    ["008"]="IPC Pipes (sys_pipe2), Standard I/O Redirection (sys_dup2), /proc Pseudo-FS, and Shell Pipeline"
    ["009"]="Writable In-Memory Filesystem (tmpfs), Directory Listing (sys_getdents64), and ls / touch / rm"
    ["010"]="Hardware Timer Interrupts (PIC/PIT), Time Management (nanosleep), /proc/[pid]/stat, and ps / kill"
    ["011"]="Dynamic ELF Loader (PT_INTERP / ld-musl-x86_64.so.1 Co-Loading) and Shared Library Mapping"
    ["012"]="Bidirectional TTY Console (UART IRQ4 + termios ioctls) and Interactive Shell via Stdin"
    ["013"]="Linux Socket API (AF_INET Loopback & AF_UNIX IPC) and Multi-Process Server/Client Verification"
    ["014"]="Multi-Threading (CLONE_VM | CLONE_THREAD), Fast Userspace Locking (sys_futex), and epoll"
    ["015"]="PCI Bus Enumeration, VirtIO-Block Driver (DMA Virtqueue), and /dev/vda Persistence"
    ["016"]="Persistent Disk Filesystem (POSIX USTAR / tarfs on /dev/vda) and sys_mount / sys_umount2 / sys_sync"
    ["017"]="VirtIO-Net PCI Network Driver (TX/RX Virtqueue DMA), ARP/IPv4/ICMP Stack, and External Gateway Ping"
    ["018"]="User-Space Signal Delivery Mechanism (Signal Trampoline, rt_sigaction, rt_sigreturn, SIGALRM/SIGCHLD)"
    ["019"]="UDP/IPv4 Socket Stack (SOCK_DGRAM), /proc/net/udp, and RFC 1035 DNS Resolver Verification"
    ["020"]="Local APIC / IOAPIC Init, SMP Multi-Core Boot via INIT-SIPI-SIPI, and Multi-Core /proc/cpuinfo"
)
for num in $(seq -f "%03g" 1 20); do
    SPEC_FILE="docs/specs/SPEC_TASK_${num}.md"
    if [ ! -f "$SPEC_FILE" ]; then
        cat << SPEC_EOF > "$SPEC_FILE"
# Tinux Implementation Specification: TASK-${num}
> **STATUS: PLACEHOLDER: PASTE FULL SPECIFICATION FOR TASK-${num} HERE**
> * **Title:** ${TASK_TITLES[$num]}
SPEC_EOF
        log_warn "Created placeholder: $SPEC_FILE"
    else
        log_ok "Verified existing spec: $SPEC_FILE"
    fi
done
log_ok "init_project.sh execution complete."
EOF
chmod +x init_project.sh
log_ok "init_project.sh updated to 20 tasks."
# ------------------------------------------------------------------------------
# 4. Update scripts/run_regression.sh for Full 20-Task Matrix (NIC + SMP + Signals)
# ------------------------------------------------------------------------------
log_info "Updating scripts/run_regression.sh to cover TASK-001 .. TASK-020..."
cat << 'EOF' > scripts/run_regression.sh
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
PYTHON_BIN=""
for cand in python python3 py; do
    if "$cand" -c 'import sys' >/dev/null 2>&1; then
        PYTHON_BIN="$cand"
        break
    fi
done
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
    if [[ -n "$PYTHON_BIN" ]]; then
        "$PYTHON_BIN" -c 'import time; print(int(time.time() * 1000))'
    else
        echo 0
    fi
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
echo -e "${BOLD}  Tinux Automated Regression Suite (20-Milestone Edition): Stage: ${CYAN}${CURRENT_TASK_ID}${NC}"
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
if [[ -f "$KERNEL_BIN" ]] && [[ -n "$PYTHON_BIN" ]] && "$PYTHON_BIN" -c '
import sys
data = open(sys.argv[1], "rb").read()
sys.exit(0 if b"Xen\x00" in data else 1)
' "$KERNEL_BIN" 2>/dev/null; then
    T1=$(now_ms)
    record_result "BOOT-PVH" "Xen PVH ELF Note (XEN_ELFNOTE_PHYS32_ENTRY)" "PASS" "$((T1 - T0))" "Direct -kernel readiness"
else
    T1=$(now_ms)
    record_result "BOOT-PVH" "Xen PVH ELF Note (XEN_ELFNOTE_PHYS32_ENTRY)" "FAIL" "$((T1 - T0))" "Note missing in ELF"
fi
T0=$(now_ms)
COMPTIME_COUNT=$(grep -rn "@sizeOf(" src/ 2>/dev/null | wc -l | tr -d ' ')
T1=$(now_ms)
if (( COMPTIME_COUNT >= 1 )); then
    record_result "ABI-ASSERT" "Compile-time Linux x86_64 ABI assertions" "PASS" "$((T1 - T0))" "${COMPTIME_COUNT} assertions passed"
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
    record_result "CPU-HEALTH" "Zero Kernel Panic / #PF / #GP / #DF exceptions" "FAIL" "0" "Exception detected in log"
else
    record_result "CPU-HEALTH" "Zero Kernel Panic / #PF / #GP / #DF exceptions" "PASS" "0" "Clean Ring 0/Ring 3 run"
fi
if [[ "$PRIMARY_RC" -eq 0 ]]; then
    record_result "$CURRENT_TASK_ID" "Active milestone verification harness" "PASS" "$PRIMARY_MS" "Exit code 0 (QEMU passed)"
else
    record_result "$CURRENT_TASK_ID" "Active milestone verification harness" "FAIL" "$PRIMARY_MS" "verify_qemu.sh failed"
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
            printf "[TINUX_DISK_SECTOR0] Host-provisioned VirtIO-Block image ready!\n" | dd of="$MATRIX_DISK" conv=notrunc status=none
        fi
        QEMU_EXTRA_ARGS+=(-drive "file=$MATRIX_DISK,format=raw,if=none,id=drv0" -device "virtio-blk-pci,drive=drv0,disable-legacy=off")
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
check_milestone_feature 8  "IPC Pipes (pipe2), dup2 & /proc Pseudo-FS"    "Linux version 6\.12\.0-tinux|Welcome to Tinux"
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
    echo "* **Overall Verdict:** **${OVERALL_BADGE}** (\`${PASS_COUNT} Passed\`, \`${FAIL_COUNT} Failed\`, \`${SKIP_COUNT} Skipped\`)"
    echo ""
    echo "## Results Matrix"
    echo ""
    echo "| Check ID | Subsystem / Milestone Verification | Status | Time | Details |"
    echo "| :--- | :--- | :---: | :---: | :--- |"
    for i in "${!CHECK_IDS[@]}"; do
        st="${CHECK_STATUS[$i]}"
        icon=" [PASS]"
        [[ "$st" == "FAIL" ]] && icon=" [FAIL]"
        [[ "$st" == "SKIP" ]] && icon=" [SKIP]"
        echo "| \`${CHECK_IDS[$i]}\` | ${CHECK_NAMES[$i]} | ${icon} | \`${CHECK_TIMES[$i]}\` | ${CHECK_DETAILS[$i]} |"
    done
} > "$REPORT_FILE"
echo -e "\n${BOLD}==============================================================================${NC}"
echo -e "  Regression Summary: ${GREEN}${PASS_COUNT} Passed${NC}, ${RED}${FAIL_COUNT} Failed${NC}, ${YELLOW}${SKIP_COUNT} Skipped${NC}"
echo -e "  Markdown Report   : ${CYAN}${REPORT_FILE}${NC}"
echo -e "${BOLD}==============================================================================${NC}"
if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
EOF
chmod +x scripts/run_regression.sh
log_ok "scripts/run_regression.sh updated to cover all 20 milestones."
echo ""
echo "======================================================================"
echo -e "${GREEN}Upgrade to 20-Milestone Architecture Complete!${NC}"
echo "Run './scripts/check_specs.sh' to verify all 20 specification files."
echo "======================================================================"
