# Tinux Automated Regression Report (20-Milestone Suite)

* **Timestamp:** `2026-11-01 15:09:22 UTC`
* **Detected Milestone Stage:** `TASK-014`
* **Overall Verdict:** **FAILED** (`15 Passed`, `4 Failed`, `6 Skipped`)

## Results Matrix

| Check ID | Subsystem / Milestone Verification | Status | Time | Details |
| :--- | :--- | :---: | :---: | :--- |
| `BUILD-ELF` | Zig freestanding kernel compilation |  [PASS] | `11348ms` | size=2121016B |
| `BOOT-PVH` | Xen PVH ELF Note (XEN_ELFNOTE_PHYS32_ENTRY) |  [PASS] | `184ms` | Direct -kernel readiness |
| `ABI-ASSERT` | Compile-time Linux x86_64 ABI assertions |  [PASS] | `196ms` | 99 assertions passed |
| `CPU-HEALTH` | Zero Kernel Panic / #PF / #GP / #DF exceptions |  [PASS] | `0ms` | Clean Ring 0/Ring 3 run |
| `TASK-014` | Active milestone verification harness |  [PASS] | `11348ms` | Exit code 0 (QEMU passed) |
| `REG-001` | Boot & 16550A Serial Console Output |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-002` | GDT/TSS, IDT Exception Gates & Bitmap PMM |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-003` | 4-Level Page Table VMM & Kernel Heap |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-004` | SYSCALL/SYSRET MSRs & Ring 3 Transition |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-005` | Static ELF64 Loader, Auxv, TLS & sys_brk |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-006` | In-Memory VFS, CPIO Initramfs & BusyBox |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-007` | Multi-Process fork/execve/wait4 & /bin/sh |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-008` | IPC Pipes (pipe2), dup2 & /proc Pseudo-FS |  [FAIL] | `54ms` | Pattern 'Linux version 6\.12\.0-tinux|Welcome to Tinux' missing |
| `REG-009` | Writable tmpfs, getdents64 & File Ops |  [FAIL] | `54ms` | Pattern 'hello\.txt|TMPFS_REGRESSION_PASS' missing |
| `REG-010` | PIT 100Hz Timer, nanosleep, /proc/pid & ps |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-011` | Dynamic ELF Loader (PT_INTERP / ld-musl) |  [FAIL] | `54ms` | Pattern 'TINUX_DYN' missing |
| `REG-012` | Interactive TTY Console (IRQ4 / termios) |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-013` | Linux Socket API (TCP 127.0.0.1 & AF_UNIX) |  [FAIL] | `54ms` | Pattern 'PONG_FROM_TINUX_SERVER|TINUX_NET' missing |
| `REG-014` | Multi-Threading (CLONE_VM), futex & epoll |  [PASS] | `54ms` | Verified in QEMU serial log |
| `REG-015` | PCI Bus Master & VirtIO-Block (/dev/vda) |  [SKIP] | `0ms` | Not yet implemented |
| `REG-016` | Persistent USTAR TarFS Mount (sys_mount) |  [SKIP] | `0ms` | Not yet implemented |
| `REG-017` | VirtIO-Net (eth0), ARP & ICMP External Ping |  [SKIP] | `0ms` | Not yet implemented |
| `REG-018` | POSIX Signal Delivery (rt_sigaction/return) |  [SKIP] | `0ms` | Not yet implemented |
| `REG-019` | UDP SOCK_DGRAM & RFC 1035 DNS Resolver |  [SKIP] | `0ms` | Not yet implemented |
| `REG-020` | Local APIC/IOAPIC & SMP Multi-Core (-smp 2) |  [SKIP] | `0ms` | Not yet implemented |
