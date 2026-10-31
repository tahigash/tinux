# Tinux 🦎🐧
**A Clean-Room, Linux ABI-Compatible x86_64 Kernel Written in Zig — Built via Multi-Model Agentic Engineering**
[![Architecture: x86_64](https://img.shields.io/badge/arch-x86__64-blue.svg)](#architecture-overview)
[![Language: Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![ABI: Linux x86_64](https://img.shields.io/badge/ABI-Linux%20x86__64-success.svg)](#supported-linux-system-calls)
[![Engineered with: Google Antigravity](https://img.shields.io/badge/IDE-Google%20Antigravity-4285F4.svg)](#the-arch
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-blue.svg)](#license)
---
## What's in a Name?
**Tinux** is a portmanteau of **Linux**, **Transformer**, and its creator's first name (**Takashi**).
However, in strict observance of the precedent established by Gregory Kurtzer's [**Ginux**](https://github.com/gmkur
> *"Disclaimer: Tinux is an independent, clean-room implementation compatible with the Linux ABI. It is not an official project of Linus Torvalds or the Linux Foundation, and contains no source code from the Linux kernel."*
---

## Overview
Can an AI-directed engineering workflow build a working, POSIX/Linux-compatible operating system kernel in **Zig** c
**Yes.** Tinux demonstrates that by combining Zig's low-level ergonomics with a disciplined **Architect-Builder Agen
### Key Capabilities
* **Unmodified Linux Binary Execution:** Boots unmodified static and dynamically linked (`PT_INTERP` / `/lib/ld-musl
* **Full Multi-Process & Multi-Thread Lifecycle:** Supports `fork`, `vfork`, `clone` (both isolated address spaces a
* **Interactive TTY & Shell Pipelines:** Features an interrupt-driven (IRQ4) + timer-polled 16550A UART console with
* **Hybrid Virtual Filesystem (VFS):** Unifies SVR4 `newc` CPIO `initramfs`, writable in-memory `tmpfs`, dynamic `/p
* **Hardware Virtualization & DMA:** Direct QEMU `-kernel` boot via Xen PVH ELF Note (zero external bootloader depen
---
## Architecture Overview
```text
+-----------------------------------------------------------------------------------+
|                           USER SPACE (Ring 3 / x86_64)                            |
|                                                                                   |
|  +-----------------------+  +------------------------+  +----------------------+  |
|  |  Unmodified BusyBox   |  | Alpine Dynamic Binaries|  | Multi-Threaded Apps  |  |
|  |  (/bin/sh, ls, ps,    |  | (PT_INTERP ->          |  | (CLONE_VM, TLS %fs,  |  |
|  |   cat | grep, mount)  |  |  ld-musl-x86_64.so.1)  |  |  futex, epoll, TCP)  |  |
|  +-----------+-----------+  +------------+-----------+  +----------+-----------+  |
+--------------|---------------------------|-------------------------|--------------+
               |                           |                         |
===============|===========================|=========================|===============
               v        Linux x86_64 Syscall ABI (MSR_LSTAR)         v
===============|===========================|=========================|===============
               |                           |                         |
+--------------|---------------------------|-------------------------|--------------+
|              v            KERNEL SPACE (Ring 0 / Zig)              v              |
|  +-----------------------------------------------------------------------------+  |
|  |                 System Call Dispatcher (src/syscall/dispatch.zig)           |  |
|  |        Context-Switching SyscallFrame (128B) & User Pointer Validator       |  |
|  +------+--------------------+--------------------+---------------------+------+  |
|         |                    |                    |                     |         |
|         v                    v                    v                     v         |
|  +--------------+   +-----------------+   +---------------+   +----------------+  |
|  | Process &    |   | Memory Manager  |   | Virtual FS &  |   | IPC & Network  |  |
|  | Thread Sched |   | (src/mm/*)      |   | Storage       |   | Subsystems     |  |
|  | (src/proc/*) |   |                 |   | (src/fs/*)    |   | (src/net/*)    |  |
|  | - Task Table |   | - Bitmap PMM    |   | - CPIO Rootfs |   | - Ring Pipes   |  |
|  | - ELF Loader |   | - 4-Level VMM   |   | - R/W tmpfs   |   | - Epoll Engine |  |
|  | - clone/fork |   | - cloneUserPml4 |   | - /proc & PID |   | - AF_INET TCP  |  |
|  | - Futex Hash |   | - Zig Allocator |   | - USTAR tarfs |   | - AF_UNIX IPC  |  |
|  +------+-------+   +--------+--------+   +-------+-------+   +--------+-------+  |
|         |                    |                    |                    |          |
|  +------+--------------------+--------------------+--------------------+-------+  |
|  |                Hardware Abstraction & Device Drivers (src/drivers/*)        |  |
|  |  [PVH 32->64 Boot] [GDT/TSS/IDT] [8259A PIC & 8254 PIT 100Hz]               |  |
|  |  [16550A UART TTY (IRQ4)]        [PCI Bus Scanner & VirtIO-Block DMA]       |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```
---
## The Architect-Builder HDAE Methodology
Tinux was developed using an **Architect-Builder Human-Directed Agentic Engineering (HDAE)** workflow on **Google An
1. **System Architect (`Gemini 4 Argon`):** Designs the global kernel subsystem boundaries, virtual memory layout, a
2. **Low-Level & ABI Auditor (`Claude Opus 5.5`):** Audits every specification for x86_64 register clobbers, 16-byte
3. **High-Speed Autonomous Builder (`Gemini 3.8 Flash High`):** Executes each micro-specification (`TASK-001` throug
### 16-Stage Verification Roadmap
| Task ID | Subsystem | Milestone Description | Verification Gate |
| :--- | :--- | :--- | :--- |
| **`TASK-001`** | `arch/boot` | Xen PVH direct 64-bit boot, COM1 UART driver, `isa-debug-exit` harness | `< 0.2s` Q
| **`TASK-002`** | `arch/mm` | Zig GDT/TSS reconstruction, 176B `TrapFrame` IDT, Bitmap PMM (128 MiB) | `#BP` (`int3
| **`TASK-003`** | `mm` | 4-level page table manager (VMM) & `std.mem.Allocator` kernel heap | Dynamic map/unmap & c
| **`TASK-004`** | `syscall` | `SYSCALL`/`SYSRET` MSR setup, Ring 3 transition, `sys_write` & `sys_exit` | Ring 3 `-
| **`TASK-005`** | `proc/elf` | Static ELF64 loader, System V AMD64 stack (`auxv`), TLS (`%fs`), `sys_brk` | Standal
| **`TASK-006`** | `fs/cpio` | In-memory VFS, SVR4 `newc` CPIO initramfs unpacker, file I/O syscalls | Unmodified `/
| **`TASK-007`** | `proc/task` | Multi-process table, `cloneUserPml4`, `fork`/`execve`/`wait4` | `/bin/sh /etc/rc.sh

| **`TASK-008`** | `fs/pipe` | Ring-buffer IPC pipes (`pipe2`), `dup2`/`fcntl`, `/proc` pseudo-FS | `cat /etc/motd \
| **`TASK-009`** | `fs/tmpfs` | Writable `tmpfs`, `getdents64` directory listing, `mkdir`/`unlink` | `mkdir`, `>`, `
| **`TASK-010`** | `drivers/timer`| 8259A PIC + 8254 PIT (100Hz), `nanosleep`, `/proc/[pid]/stat`, `kill` | Backgrou
| **`TASK-011`** | `proc/dyn` | Dynamic ELF loader (`PT_INTERP`), `ld-musl` co-loading, `pread64` | Dynamic ELF + `.
| **`TASK-012`** | `drivers/tty` | UART IRQ4 RX + POSIX line discipline (`termios`/`pgrp` ioctls) | Interactive `/bi
| **`TASK-013`** | `net/socket` | BSD/Linux Socket API (`AF_INET` 127.0.0.1 loopback & `AF_UNIX`) | Multi-process TC
| **`TASK-014`** | `proc/futex` | Shared-VM threads (`CLONE_VM\|CLONE_THREAD`), `futex`, 12B `epoll` | Thread sync, 
| **`TASK-015`** | `drivers/blk` | PCI Bus Master enumeration & VirtIO-Block DMA driver (`/dev/vda`) | Sector R/W & 
| **`TASK-016`** | `fs/tarfs` | Persistent USTAR `tarfs` (`sys_mount` / `sys_umount2` / `sys_sync`) | Host `tar` ext
---
## Supported Linux System Calls
Tinux implements over **65 core Linux x86_64 system calls**, covering the essential surface required by `musl` libc,
| Category | Supported System Calls (`rax` number) |
| :--- | :--- |
| **Process & Threading** | `clone` (56), `fork` (57), `vfork` (58), `execve` (59), `exit` (60), `wait4` (61), `kill
| **Memory Management** | ` mmap` (9), `mprotect` (10), `munmap` (11), `brk` (12) |
| **File & VFS I/O** | `read` (0), `write` (1), `open` (2), `close` (3), `stat` (4), `fstat` (5), `lstat` (6), `lsee
| **Directories & Mounts** | `getcwd` (79), `chdir` (80), `mkdir` (83), `rmdir` (84), `unlink` (87), `sync` (162), `
| **IPC, Synchronization & Multiplexing** | `poll` (7), `ioctl` (16), `pipe` (22), `futex` (202), `epoll_create` (21
| **Networking & Sockets** | `socket` (41), `connect` (42), `accept` (43), `sendto` (44), `recvfrom` (45), `shutdown
| **Time, Signals & Credentials** | `rt_sigaction` (13), `rt_sigprocmask` (14), `rt_sigreturn` (15), `pause` (34), `
---
## Getting Started
### Prerequisites
* **Zig** (`0.13.0`, `0.14.0`, or `0.15.0+` — zero external cross-compilers needed)
* **QEMU** (`qemu-system-x86_64`)
* Standard POSIX archiving tools (`cpio`, `tar`)
### 1. Run the Automated Verification Suite
Every milestone (`TASK-001` to `TASK-016`) is verified end-to-end by `scripts/verify_qemu.sh`, which packages the us
```bash
chmod +x scripts/verify_qemu.sh
./scripts/verify_qemu.sh TASK-016 10
```
Expected output:
```text
[TINUX_TEST] START: TASK-016
[TINUX_BLK] VirtIO-Block PCI device (/dev/vda) initialized
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Mounting /dev/vda onto /mnt...
[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!
[TINUX_MOUNT] Persistent filesystem mount, read, writeback, and umount verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-016
[HARNESS] Host tar successfully extracted guest_created.txt from /dev/vda!
[HARNESS] SUCCESS: TASK-016 verified cleanly!
```
### 2. Boot into an Interactive Shell
To launch Tinux interactively in your terminal and run standard Linux commands directly:
```bash
zig build
qemu-system-x86_64 \
    -kernel zig-out/bin/tinux \
    -nographic \
    -no-reboot \
    -serial mon:stdio
```
Inside the interactive `/bin/sh` prompt, try:
```sh
uname -a
cat /proc/version
cat /proc/meminfo

mkdir -p /tmp/demo && echo "Hello from Tinux!" > /tmp/demo/msg.txt
cat /tmp/demo/msg.txt | grep Tinux
ps
```
---

## Summary

Tinux is a clean-room, Linux ABI-compatible x86_64 kernel written from scratch in Zig.

### Background

The name is a blend of **Linux**, **Transformer**, and the author's first name (**Takashi**). Like Ginux before it, Tinux contains no Linux source code and is not an official Linux project.

### Design Principles

* **Binary compatibility:** Standard Linux user-space binaries run without modification because Tinux implements the expected syscall interfaces, data structures, and memory layouts.
* **Architect-Builder model:**
  * **System architecture & test harnesses:** Gemini 4 Argon
  * **Low-level verification & ABI auditing:** Claude Opus 5.5
  * **Implementation & testing loops:** Gemini 3.8 Flash High (with a 3-strike escalation circuit breaker to stop and report unresolvable failures)

---

## License

Tinux is distributed under the terms of both the **MIT License** and the **Apache License (Version 2.0)**.

You may choose to use, copy, modify, and distribute this software under the terms of either license at your option:

* **Apache License, Version 2.0**: [LICENSE-APACHE](LICENSE-APACHE) or <http://www.apache.org/licenses/LICENSE-2.0>
* **MIT License**: [LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

### Hybrid Licensing Note

This dual licensing approach gives developers and organizations flexibility:
* Projects requiring a minimal, frictionless permissive license (such as integration with GPL v2 codebases or typical Zig tools) can choose the **MIT License**.
* Enterprise environments seeking explicit patent grants and patent retaliation defenses can choose **Apache License 2.0**.
