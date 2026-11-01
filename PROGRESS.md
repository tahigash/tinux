# Tinux Autonomous Implementation Progress

> **Instructions for Builder Agent (Gemini 3.8 Flash High):**
> 1. Find the first task below marked `[ ]`.
> 2. Read its corresponding specification in `docs/specs/SPEC_TASK_0XX.md`.
> 3. Implement the code and run `./scripts/verify_qemu.sh TASK-0XX`.
> 4. When and only when `verify_qemu.sh` exits with `0` (`PASS`), update `[ ]` to `[x]`, commit all changes, and proceed to the next milestone.
> 5. If verification fails 3 consecutive times, stop immediately and write `ESCALATION_REPORT.md`.

## Milestone Checklist

- [x] **TASK-001**: `docs/specs/SPEC_TASK_001.md`: x86_64 Minimal Boot (Xen PVH), COM1 Serial Console & QEMU Auto-Verification Harness
- [x] **TASK-002**: `docs/specs/SPEC_TASK_002.md`: GDT/TSS Reconstruction, IDT Exception Handlers (176B TrapFrame), and Bitmap PMM
- [x] **TASK-003**: `docs/specs/SPEC_TASK_003.md`: 4-Level Page Table Manager (VMM) and `std.mem.Allocator` Kernel Heap
- [ ] **TASK-004**: `docs/specs/SPEC_TASK_004.md`: `SYSCALL`/`SYSRET` MSR Setup, Ring 3 Transition, and Minimal Syscall Dispatcher
- [ ] **TASK-005**: `docs/specs/SPEC_TASK_005.md`: Static ELF64 Loader, System V AMD64 Stack (`auxv`), TLS (`arch_prctl`), and `sys_brk`
- [ ] **TASK-006**: `docs/specs/SPEC_TASK_006.md`: In-Memory VFS, CPIO (`newc`) Initramfs Unpacker, and File I/O Syscalls
- [ ] **TASK-007**: `docs/specs/SPEC_TASK_007.md`: Multi-Process Management (`Task` Table, `cloneUserPml4`), `fork`/`execve`/`wait4`
- [ ] **TASK-008**: `docs/specs/SPEC_TASK_008.md`: IPC Pipes (`pipe2`), I/O Redirection (`dup2`/`O_CLOEXEC`), and `/proc` Pseudo-FS
- [ ] **TASK-009**: `docs/specs/SPEC_TASK_009.md`: Writable `tmpfs` (Create/Write/Truncate/Unlink/Mkdir), and `getdents64`
- [ ] **TASK-010**: `docs/specs/SPEC_TASK_010.md`: Hardware Timer (8259A PIC + 8254 PIT 100Hz), `nanosleep`, and `/proc/[pid]/stat`
- [ ] **TASK-011**: `docs/specs/SPEC_TASK_011.md`: Dynamic ELF Loader (`PT_INTERP` / `ld-musl-x86_64.so.1` Co-Loading)
- [ ] **TASK-012**: `docs/specs/SPEC_TASK_012.md`: Bidirectional TTY Console (IRQ4 RX + Line Discipline + `termios` ioctls)
- [ ] **TASK-013**: `docs/specs/SPEC_TASK_013.md`: Linux Socket API (`AF_INET` 127.0.0.1 Loopback & `AF_UNIX` IPC)
- [ ] **TASK-014**: `docs/specs/SPEC_TASK_014.md`: Multi-Threading (`CLONE_VM | CLONE_THREAD | CLONE_SETTLS`) and `sys_futex`
- [ ] **TASK-015**: `docs/specs/SPEC_TASK_015.md`: PCI Bus Enumeration, VirtIO-Block DMA Driver (`/dev/vda`), and Persistence
- [ ] **TASK-016**: `docs/specs/SPEC_TASK_016.md`: Persistent USTAR Filesystem (`tarfs`), `sys_mount`/`sys_umount2`/`sys_sync`
- [ ] **TASK-017**: `docs/specs/SPEC_TASK_017.md`: VirtIO-Net PCI Network Driver (TX/RX Virtqueues) and Ping Verification
- [ ] **TASK-018**: `docs/specs/SPEC_TASK_018.md`: User-Space Signal Delivery, Signal Trampoline, and `rt_sigreturn`
- [ ] **TASK-019**: `docs/specs/SPEC_TASK_019.md`: UDP/IPv4 Socket Stack (`SOCK_DGRAM`), `/proc/net/udp`, and DNS Resolver
- [ ] **TASK-020**: `docs/specs/SPEC_TASK_020.md`: Local APIC / IOAPIC Initialization, SMP Multi-Core Boot (`-smp 2`)
