# Tinux Developer Cheat Sheet & Project Reference

> **Quick Reference:** Essential directory structure, operational commands, and workflow guide for the Tinux kernel project on Google Antigravity.

---

## 1. Directory Tree & Architecture Map

File structure and corresponding milestone tags (`TASK-001` .. `TASK-020`):

```text
tinux/
|-- build.zig                          # [TASK-001..004] Build definition for Zig 0.13 / 0.14 / 0.15+
|-- linker.ld                          # [TASK-001..002] 1 MiB (0x100000) kernel linker script with boundary symbols
|-- init_project.sh                    # [Bootstrap] Workspace scaffolding & directory tree generator
|-- ANTIGRAVITY_MASTER_PROMPT.md       # [Orchestrator] Autonomous builder & architect execution prompt
|-- PROGRESS.md                        # [State] Task tracking checklist ([ ] -> [x])
|-- CHEATSHEET.md                      # [Reference] This developer cheat sheet
|-- README.md                          # [Docs] Project overview & architecture documentation
|-- KICKOFF_GUIDE.md                   # [Guide] 20-milestone kickoff execution steps
|-- LICENSE                            # [License] Dual-license guidance note (MIT OR Apache-2.0)
|-- LICENSE-MIT                        # [License] MIT License text
|-- LICENSE-APACHE                     # [License] Apache License 2.0 text
|-- .antigravity/
|   |-- mcp.json                       # [MCP] FastMCP server registration for tinux_abi_mcp.py
|   \-- skills/humanizer/SKILL.md      # [Skill] Humanizer text polish skill
|-- .vscode/
|   |-- tasks.json                     # [IDE] QEMU build and debug tasks
|   \-- launch.json                    # [IDE] GDB stub attach configuration
|-- docs/
|   |-- SPEC_TEMPLATE.md               # [Template] Architect-Builder specification template
|   |-- PREFLIGHT_CHECKLIST.md         # [Checklist] Toolchain & Zig version compatibility checklist
|   |-- DEBUGGING_GUIDE.md             # [Guide] GDB & QEMU interactive debugging instructions
|   |-- CRASH_TRIAGE_GUIDE.md          # [Guide] Automated crash triage & serial log parser guide
|   |-- TINUX_ABI_MCP_SETUP.md         # [Guide] FastMCP ABI inspector configuration
|   \-- specs/
|       |-- SPEC_TASK_001.md           # [TASK-001] Xen PVH direct boot, COM1 UART & QEMU harness
|       |-- SPEC_TASK_002.md           # [TASK-002] GDT/TSS, IDT exceptions (176B TrapFrame) & PMM (128 MiB)
|       |-- SPEC_TASK_003.md           # [TASK-003] 4-level VMM paging & std.mem.Allocator kernel heap
|       |-- SPEC_TASK_004.md           # [TASK-004] SYSCALL/SYSRET MSR, Ring 3 switch & sys_write/exit
|       |-- SPEC_TASK_005.md           # [TASK-005] Static ELF64 loader, System V stack (auxv), TLS & sys_brk
|       |-- SPEC_TASK_006.md           # [TASK-006] VFS, CPIO initramfs & unmodified BusyBox boot
|       |-- SPEC_TASK_007.md           # [TASK-007] Multi-process task table, CoW fork, execve & wait4
|       |-- SPEC_TASK_008.md           # [TASK-008] IPC ring pipes (pipe2), dup2 fd redirection & /proc
|       |-- SPEC_TASK_009.md           # [TASK-009] Writable tmpfs, getdents64 & mkdir/unlink
|       |-- SPEC_TASK_010.md           # [TASK-010] 8259A PIC + 8254 PIT (100Hz), nanosleep, ps & kill
|       |-- SPEC_TASK_011.md           # [TASK-011] Dynamic ELF loader (PT_INTERP / ld-musl co-loading)
|       |-- SPEC_TASK_012.md           # [TASK-012] Bidirectional TTY (IRQ4 RX, termios/pgrp ioctls)
|       |-- SPEC_TASK_013.md           # [TASK-013] Linux Socket API (TCP 127.0.0.1 & AF_UNIX)
|       |-- SPEC_TASK_014.md           # [TASK-014] Multi-threading (CLONE_VM), sys_futex & sys_epoll
|       |-- SPEC_TASK_015.md           # [TASK-015] PCI enumeration & VirtIO-Block (/dev/vda)
|       |-- SPEC_TASK_016.md           # [TASK-016] Persistent TarFS mount (sys_mount / sys_sync)
|       |-- SPEC_TASK_017.md           # [TASK-017] VirtIO-Net PCI driver & ARP/IPv4/ICMP Ping
|       |-- SPEC_TASK_018.md           # [TASK-018] POSIX signal delivery & rt_sigaction/sigreturn
|       |-- SPEC_TASK_019.md           # [TASK-019] UDP SOCK_DGRAM stack & RFC 1035 DNS resolver
|       \-- SPEC_TASK_020.md           # [TASK-020] Local APIC / IOAPIC, INIT-SIPI-SIPI SMP boot
|-- scripts/
|   |-- check_specs.sh                 # Verify specification readiness (TASK-001..020)
|   |-- verify_qemu.sh                 # [Core Gate] Task build, QEMU boot, and automated test pass/fail
|   |-- triage_crash.py                # Crash diagnostics, symbol lookup, and #PF error code parser
|   |-- run_regression.sh              # Full cumulative regression test runner & report generator
|   |-- debug_gdb.sh                   # QEMU GDB stub launcher and CLI debug runner
|   |-- preflight_check.sh             # Host toolchain and device validation
|   \-- upgrade_to_20_tasks.sh         # Scaffolding upgrader for 20-milestone support
|-- tools/
|   \-- tinux_abi_mcp.py               # Linux x86_64 ABI/UAPI inspector (FastMCP server & CLI)
|-- src/
|   |-- main.zig                       # Kernel entry (kmain) and subsystem initialization
|   |-- arch/x86_64/
|   |   |-- boot.S                     # Xen PVH ELF Note & 32-to-64bit trampoline
|   |   |-- ap_trampoline.S            # SMP Application Processor 16-to-64bit real-mode trampoline
|   |   |-- apic.zig                   # Local APIC / IOAPIC register mapping and IPI delivery
|   |   |-- gdt.zig                    # GDT segment selectors & 64-bit TSS (rsp0)
|   |   |-- isr.S                      # CPU exception (0..31) and hardware IRQ (32..47) stubs
|   |   |-- idt.zig                    # IDT gates registration & TrapFrame dispatch
|   |   |-- syscall_entry.S            # SYSCALL assembly entry, 128B SyscallFrame save/restore
|   |   |-- syscall.zig                # EFER, STAR, LSTAR, FMASK MSR configuration
|   |   \-- io.zig                     # Port-mapped I/O (inb, outb, inw, outw, inl, outl)
|   |-- drivers/
|   |   |-- serial.zig                 # 16550A COM1 (0x3F8) driver & IRQ4 handler
|   |   |-- timer.zig                  # 8259A PIC remap & 8254 PIT (100Hz) timer
|   |   |-- tty.zig                    # Canonical line editing, echo & termios/pgrp ioctls
|   |   |-- pci.zig                    # PCI Configuration Mechanism #1 scanner & Bus Master enabler
|   |   |-- virtio_blk.zig             # VirtIO-Block PCI driver & Virtqueue DMA
|   |   \-- virtio_net.zig             # VirtIO-Net PCI driver & packet TX/RX Virtqueues
|   |-- mm/
|   |   |-- pmm.zig                    # 128 MiB bitmap physical page frame allocator
|   |   |-- vmm.zig                    # 4-level x86_64 page table manager & user PML4 cloning
|   |   \-- heap.zig                   # Free-list kernel heap allocator (std.mem.Allocator)
|   |-- proc/
|   |   |-- elf.zig                    # Static & dynamic (PT_INTERP) ELF64 loader
|   |   |-- task.zig                   # Task table, round-robin scheduler & thread management
|   |   |-- futex.zig                  # Physical-address-keyed FUTEX_WAIT and FUTEX_WAKE queues
|   |   \-- signal.zig                 # POSIX signal delivery, signal stack frames & sigaction
|   |-- fs/
|   |   |-- vfs.zig                    # Unified FD table, tmpfs storage & getdents64
|   |   |-- cpio.zig                   # SVR4 newc (070701) initramfs parser
|   |   |-- pipe.zig                   # 4 KiB ring-buffer IPC pipes & reference counting
|   |   |-- procfs.zig                 # Dynamic /proc pseudo-filesystem (/proc/meminfo, /proc/mounts)
|   |   |-- epoll.zig                  # epoll event multiplexing table & interest lists
|   |   \-- tarfs.zig                  # VirtIO-Block backed POSIX USTAR persistent filesystem
|   |-- net/
|   |   |-- socket.zig                 # AF_INET TCP loopback, AF_UNIX domain & UDP datagrams
|   |   \-- netstack.zig               # Ethernet, ARP, IPv4, ICMP & UDP protocol stack
|   |-- syscall/
|   |   |-- dispatch.zig               # Linux x86_64 syscall dispatcher (65+ syscalls)
|   |   |-- strace.zig                 # Syscall tracing and register inspection engine
|   |   \-- profiler.zig               # Per-syscall latency and execution frequency profiler
|   \-- uapi/
|       \-- errno.zig                  # POSIX errno constants and negative return mappings
\-- src/user/
    |-- init_test.zig                  # Userland test: Initial stack, auxv, TLS & sys_brk
    |-- net_test.zig                   # Userland test: TCP 127.0.0.1 loopback & socketpair
    |-- thread_epoll_test.zig          # Userland test: CLONE_VM threads, futex & epoll
    |-- ping_test.zig                  # Userland test: VirtIO-Net raw ICMP Ping response
    |-- sig_test.zig                   # Userland test: POSIX signal handling & sigreturn
    |-- dns_test.zig                   # Userland test: UDP sockets & /etc/resolv.conf DNS resolver
    \-- smp_test.zig                   # Userland test: Multi-core SMP affinity & sched_getaffinity
```

---

## 2. Script & Tool Reference Matrix

| Script / Tool | Example Command | Purpose & Usage Timing |
| :--- | :--- | :--- |
| **`init_project.sh`** | `./init_project.sh` | **[Once at setup]** Initializes directory hierarchy, Git repo, and progress tracker |
| **`scripts/check_specs.sh`** | `./scripts/check_specs.sh` | **[Before building]** Validates that all specifications are populated |
| **`scripts/verify_qemu.sh`** | `./scripts/verify_qemu.sh TASK-006 5` | **[Core test gate]** Compiles userland binaries, boots QEMU, and evaluates pass criteria |
| **`scripts/verify_qemu.sh`** | `./scripts/verify_qemu.sh TASK-012 --interactive` | **[Manual testing]** Boots into interactive serial console with keyboard input |
| **`scripts/debug_gdb.sh`** | `./scripts/debug_gdb.sh` | **[GDB debugging]** Launches QEMU with `-s -S` and automatically attaches GDB |
| **`scripts/triage_crash.py`** | `./scripts/triage_crash.py` | **[Crash triage]** Analyzes the latest `/tmp/tinux_qemu_*.log` and resolves symbols |
| **`scripts/run_regression.sh`** | `./scripts/run_regression.sh` | **[Milestone verification]** Runs full regression suite across all completed stages |
| **`tools/tinux_abi_mcp.py`** | `./tools/tinux_abi_mcp.py syscall epoll`<br>`./tools/tinux_abi_mcp.py struct stat` | **[ABI ground truth]** Queries Linux syscall numbers, struct layouts, and constants |

---

## 3. End-to-End Operational Workflow

### Phase 1: Workspace Scaffolding

```bash
# 1. Run bootstrap initializer
./init_project.sh

# 2. Verify all 20 specifications are present
./scripts/check_specs.sh
```

### Phase 2: FastMCP Server Integration (Optional)

Configure `.antigravity/mcp.json` to allow autonomous agents to query struct layouts and ABI constants without hallucinations.

### Phase 3: Autonomous Builder Loop

1. Select **`Gemini 3.8 Flash High`** in the model picker.
2. Submit the kickoff prompt from `ANTIGRAVITY_MASTER_PROMPT.md` (Section 2).
3. The agent autonomously cycles through:
   * Finding the first incomplete task in `PROGRESS.md`.
   * Reading `docs/specs/SPEC_TASK_0XX.md` and implementing code.
   * Executing `./scripts/verify_qemu.sh TASK-0XX` to verify pass criteria.
   * Updating `PROGRESS.md` to `[x]`, committing with Git, and advancing to the next milestone.

### Phase 4: Escalation Protocol on Consecutive Failures

If the Builder fails three consecutive attempts on a milestone:
1. Run `./scripts/triage_crash.py --out ESCALATION_REPORT.md` to diagnose the failure.
2. Switch models to **`Gemini 4 Argon`** (architecture / paging issues) or **`Claude Opus 5.5`** (ABI / assembly / lock bugs).
3. Submit the Section 3 prompt from `ANTIGRAVITY_MASTER_PROMPT.md` to review the failure and apply targeted corrections.
4. Return to **`Gemini 3.8 Flash High`** to resume autonomous implementation.

### Phase 5: Full Regression Testing & Interactive Shell

```bash
# Run comprehensive regression suite across all milestones
./scripts/run_regression.sh

# Boot directly into an interactive /bin/sh shell
./scripts/verify_qemu.sh TASK-012 --interactive
```

---

## 4. Kernel Virtual Memory Map Reference

Virtual memory layout maintained across all kernel subsystems:

| Virtual Address Range | Size | Access Flags | Subsystem / Purpose |
| :--- | :--- | :--- | :--- |
| `0x0000_0000 .. 0x0000_0FFF` | `4 KiB` | **Unmapped** | Page 0 NULL pointer dereference guard |
| `0x0000_1000 .. 0x07FF_FFFF` | `~128 MiB` | `PRESENT \| WRITABLE` (Ring 0) | Identity-mapped kernel code (`.text`), data (`.data`), BSS, and PMM bitmap |
| `0x0040_0000 .. 0x007F_FFFF` | `4 MiB+` | `PRESENT \| WRITABLE \| USER` | Main executable load area (`ET_EXEC` / `ET_DYN`) |
| `0x0080_0000 .. 0x0080_7FFF` | `32 KiB` | `PRESENT \| WRITABLE \| USER` | User-space initial stack (`USER_STACK_BOTTOM` = `0x0080_8000`) |
| `0x1000_0000 .. 0x1003_FFFF` | `256 KiB` | `PRESENT \| WRITABLE` (Ring 0) | Kernel heap region (`KERNEL_HEAP_START`, expandable) |
| `0x1800_0000 .. 0x1FFF_FFFF` | `128 MiB` | `PRESENT \| WRITABLE \| USER` | Dynamic linker base mapping area (`INTERP_LOAD_BASE`) |
| `0x2000_0000 .. 0x3FFF_FFFF` | `512 MiB` | `PRESENT \| WRITABLE \| USER` | Dynamic `sys_mmap` memory allocation arena |
| `0x4000_0000 .. 0x47FF_FFFF` | `128 MiB` | `PRESENT \| WRITABLE` (Ring 0) | PCI MMIO bar mapping space |
