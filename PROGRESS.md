# Tinux Autonomous Implementation Progress
> **Instructions for Builder Agent (Gemini 3.8 Flash High):**
> 1. Find the first task below marked `[ ]`.
> 2. Read its corresponding specification in `docs/specs/SPEC_TASK_0XX.md`.
> 3. Implement the code and run `./scripts/verify_qemu.sh TASK-0XX`.
> 4. When and only when `verify_qemu.sh` exits with `0` (`PASS`), update `[ ]` to `[x]`, commit all changes, and pro
> 5. If verification fails 3 consecutive times, stop immediately and write `ESCALATION_REPORT.md`.
## Milestone Checklist
- [ ] **TASK-001**: `docs/specs/SPEC_TASK_001.md` — x86_64 Minimal Boot (Xen PVH), COM1 Serial Console & QEMU Auto-V
- [ ] **TASK-002**: `docs/specs/SPEC_TASK_002.md` — GDT/TSS Reconstruction, IDT Exception Handlers (176B TrapFrame) 
- [ ] **TASK-003**: `docs/specs/SPEC_TASK_003.md` — 4-Level Page Table Manager (VMM) & `std.mem.Allocator` Kernel He
- [ ] **TASK-004**: `docs/specs/SPEC_TASK_004.md` — `SYSCALL`/`SYSRET` MSR Setup, Ring 3 Transition & Minimal Syscal
- [ ] **TASK-005**: `docs/specs/SPEC_TASK_005.md` — Static ELF64 Loader, System V AMD64 Stack (`auxv`), TLS (`arch_p
- [ ] **TASK-006**: `docs/specs/SPEC_TASK_006.md` — In-Memory VFS, CPIO (`newc`) Initramfs Unpacker, File I/O Syscal
- [ ] **TASK-007**: `docs/specs/SPEC_TASK_007.md` — Multi-Process Management (`Task` Table, `cloneUserPml4`), `fork`
- [ ] **TASK-008**: `docs/specs/SPEC_TASK_008.md` — IPC Pipes (`pipe2`), I/O Redirection (`dup2`/`O_CLOEXEC`), `/pro
- [ ] **TASK-009**: `docs/specs/SPEC_TASK_009.md` — Writable `tmpfs` (Create/Write/Truncate/Unlink/Mkdir), `getdents
- [ ] **TASK-010**: `docs/specs/SPEC_TASK_010.md` — Hardware Timer (8259A PIC + 8254 PIT 100Hz), `nanosleep`, `/proc
- [ ] **TASK-011**: `docs/specs/SPEC_TASK_011.md` — Dynamic ELF Loader (`PT_INTERP` / `ld-musl-x86_64.so.1` Co-Loadi
- [ ] **TASK-012**: `docs/specs/SPEC_TASK_012.md` — Bidirectional TTY Console (IRQ4 RX + Line Discipline + `termios`
- [ ] **TASK-013**: `docs/specs/SPEC_TASK_013.md` — Linux Socket API (`AF_INET` 127.0.0.1 Loopback & `AF_UNIX` IPC) 
- [ ] **TASK-014**: `docs/specs/SPEC_TASK_014.md` — Multi-Threading (`CLONE_VM | CLONE_THREAD | CLONE_SETTLS`), `sys
- [ ] **TASK-015**: `docs/specs/SPEC_TASK_015.md` — PCI Bus Enumeration, VirtIO-Block DMA Driver (`/dev/vda`) & Host
- [ ] **TASK-016**: `docs/specs/SPEC_TASK_016.md` — Persistent USTAR Filesystem (`tarfs`), `sys_mount`/`sys_umount2`
