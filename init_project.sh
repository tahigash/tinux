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
