#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# Tinux QEMU GDB Stub Launcher & Interactive Debugger
# Usage:
#   ./scripts/debug_gdb.sh                 # Build, start QEMU (-s -S), attach GDB
#   ./scripts/debug_gdb.sh --server-only   # Start QEMU (-s -S) on :1234 for IDE (F5)
#   ./scripts/debug_gdb.sh --port 1234     # Specify custom GDB stub TCP port
# ==============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'
GDB_PORT=1234
SERVER_ONLY=0
SKIP_BUILD=0
KERNEL_BIN="zig-out/bin/tinux"
GDBINIT_FILE=".cache/tinux.gdbinit"
DISK_IMG="/tmp/tinux_debug_disk.img"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-only|--wait)
            SERVER_ONLY=1
            shift
            ;;
        --no-build)
            SKIP_BUILD=1
            shift
            ;;
        --port|-p)
            GDB_PORT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
mkdir -p .cache
# ------------------------------------------------------------------------------
# 1. Build Kernel with Debug Symbols
# ------------------------------------------------------------------------------
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo -e "${CYAN}[DEBUG]${NC} Building Tinux kernel (with DWARF debug symbols)..."
    zig build
fi
if [[ ! -f "$KERNEL_BIN" ]]; then
    echo -e "${RED}[ERROR]${NC} Kernel binary '$KERNEL_BIN' not found. Run 'zig build' first."
    exit 1
fi
# ------------------------------------------------------------------------------
# 2. Prepare VirtIO-Block Debug Disk Image (for TASK-015 / TASK-016)
# ------------------------------------------------------------------------------
if [[ ! -f "$DISK_IMG" ]]; then
    STAGE_DIR="/tmp/tinux_debug_stage"
    rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
    echo "[TINUX_TARFS] Debug disk image mounted via /dev/vda!" > "$STAGE_DIR/host_seed.txt"
    tar --format=ustar -cf "$DISK_IMG" -C "$STAGE_DIR" host_seed.txt 2>/dev/null || true
    truncate -s 1M "$DISK_IMG" 2>/dev/null || dd if=/dev/zero of="$DISK_IMG" bs=1M count=1 status=none
fi
QEMU_ARGS=(
    -kernel "$KERNEL_BIN"
    -nographic
    -no-reboot
    -monitor none
    -serial stdio
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
    -drive "file=$DISK_IMG,format=raw,if=none,id=drv0"
    -device "virtio-blk-pci,drive=drv0,disable-legacy=off"
    -gdb "tcp::${GDB_PORT}"
    -S
)
# ------------------------------------------------------------------------------
# 3. Mode A: Server-Only Mode (For VS Code / Google Antigravity F5 Attach)
# ------------------------------------------------------------------------------
if [[ "$SERVER_ONLY" -eq 1 ]]; then
    # Kill any stale QEMU listening on GDB_PORT
    pkill -f "qemu-system-x86_64.*tcp::${GDB_PORT}" 2>/dev/null || true
    echo -e "${GREEN}[DEBUG]${NC} Starting QEMU GDB server on ${CYAN}localhost:${GDB_PORT}${NC} (CPU paused with -S)..."
    echo -e "${YELLOW}[DEBUG]${NC} Press F5 in VS Code / Google Antigravity to attach, or Ctrl+C to stop."
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
fi
# ------------------------------------------------------------------------------
# 4. Mode B: Interactive CLI Mode (Auto-Generate .gdbinit & Attach GDB)
# ------------------------------------------------------------------------------
GDB_BIN=""
for candidate in gdb gdb-multiarch x86_64-elf-gdb x86_64-linux-gnu-gdb; do
    if command -v "$candidate" >/dev/null 2>&1; then
        GDB_BIN="$candidate"
        break
    fi
done
if [[ -z "$GDB_BIN" ]]; then
    echo -e "${RED}[ERROR]${NC} No GDB binary found (tried: gdb, gdb-multiarch, x86_64-elf-gdb)."
    echo -e "        Run './scripts/debug_gdb.sh --server-only' and attach from your IDE instead."
    exit 1
fi
cat << EOF > "$GDBINIT_FILE"
set confirm off
set pagination off
set print pretty on
set disassembly-flavor att
set architecture i386:x86-64
file $KERNEL_BIN
target remote localhost:${GDB_PORT}
# Use hardware breakpoints so 32->64 bit mode transition and CR3 switches work cleanly
hbreak kmain
hbreak syscallDispatch
hbreak isrDispatch
define tinux-regs
    printf "=== CPU Control & Segment Registers (QEMU Monitor) ===\n"
    monitor info registers
end
document tinux-regs
Dump full x86_64 CPU registers including CR0, CR2, CR3, CR4, EFER, GDT, and IDT via QEMU Monitor.
end
define tinux-mmap
    printf "=== Active Page Table Virtual Memory Map (CR3) ===\n"
    monitor info mem
end
document tinux-mmap
Display currently mapped virtual address ranges and permission flags from CR3.
end
define tinux-tlb
    printf "=== Virtual-to-Physical Page Table Walk ===\n"
    monitor info tlb
end
document tinux-tlb
Display full virtual-to-physical page translations in current CR3.
end
define tinux-syscall
    printf "=== Current SyscallFrame (arg0=%rdi) ===\n"
    print *(syscall.SyscallFrame *)\$rdi
end
document tinux-syscall
Pretty-print the 128-byte SyscallFrame when stopped at syscallDispatch.
end
define tinux-trap
    printf "=== Current TrapFrame (arg0=%rdi) ===\n"
    print *(idt.TrapFrame *)\$rdi
end
document tinux-trap
Pretty-print the 176-byte TrapFrame when stopped at isrDispatch.
end
printf "\n"
printf "======================================================================\n"
printf "  Tinux GDB Session Connected (localhost:${GDB_PORT})\n"
printf "  Hardware Breakpoints Set : kmain, syscallDispatch, isrDispatch\n"
printf "  Custom Helper Commands   : tinux-regs | tinux-mmap | tinux-syscall | tinux-trap\n"
printf "======================================================================\n\n"
# Automatically run from 32-bit PVH entry until 64-bit kmain()
continue
EOF
echo -e "${GREEN}[DEBUG]${NC} Launching QEMU in background on port ${GDB_PORT}..."
qemu-system-x86_64 "${QEMU_ARGS[@]}" > /tmp/tinux_gdb_serial.log 2>&1 &
QEMU_PID=$!
cleanup() {
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM
sleep 0.2
echo -e "${GREEN}[DEBUG]${NC} Attaching ${CYAN}${GDB_BIN}${NC} (serial output logged to /tmp/tinux_gdb_serial.log)..."
"$GDB_BIN" -q -x "$GDBINIT_FILE"
