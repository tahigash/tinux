# Tinux System Call ABI Specification

> **Purpose:**
> Documents the Linux System V AMD64 system call interface, register calling conventions, dispatch structures, and supported syscall table for Tinux.

---

## 1. Clean-Room Architectural Principles

Tinux provides binary compatibility with the standard Linux x86_64 system call ABI. The kernel implements these functional interfaces independently in Zig and assembly without copying code from the Linux kernel source tree.

Because system call numbers, register conventions, and structure layouts represent non-copyrightable functional specifications, Tinux is distributed under a permissive dual license (MIT OR Apache-2.0).

All default userland tools, shells, and test harnesses are clean-room implementations (including the in-tree Zig micro-userland), without requiring or bundling external GPL-licensed BusyBox or GNU coreutils binaries. Unmodified static and dynamic Linux binaries compiled with standard toolchains (Zig, GCC/musl, Clang, Rust) execute directly on Tinux.

---

## 2. Register Calling Conventions (x86_64)

Tinux follows the System V AMD64 ABI system call convention:

| Register | Role in Syscall Entry | Role in Syscall Exit |
| :---: | :--- | :--- |
| `RAX` | System call number | Return value (success >= 0, or negative errno) |
| `RDI` | Argument 0 | Callee scratch (restored or ignored) |
| `RSI` | Argument 1 | Callee scratch (restored or ignored) |
| `RDX` | Argument 2 | Callee scratch (restored or ignored) |
| `R10` | Argument 3 (replaces `RCX`) | Callee scratch (restored or ignored) |
| `R8` | Argument 4 | Callee scratch (restored or ignored) |
| `R9` | Argument 5 | Callee scratch (restored or ignored) |
| `RCX` | Clobbered by CPU (saves user `RIP`) | Restored from saved frame |
| `R11` | Clobbered by CPU (saves user `RFLAGS`) | Restored from saved frame |
| `RBX`, `RBP`, `R12..R15`, `RSP` | Preserved across calls | Preserved across calls |

### Note on `R10`
In standard user space C function calls, the fourth parameter is passed in `RCX`. When invoking the `SYSCALL` instruction, the hardware overwrites `RCX` with the return address (`RIP`). Therefore, userland system call wrappers move the fourth argument from `RCX` into `R10` prior to executing `syscall`.

---

## 3. Syscall Frame Layout (`src/arch/x86_64/syscall.zig`)

When a system call enters `syscallEntry`, the low-level assembly stub allocates a 128-byte `SyscallFrame` on the kernel stack:

```zig
pub const SyscallFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r9: u64,
    r8: u64,
    r10: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rax: u64,
    user_rflags: u64,
    user_rip: u64,
    user_rsp: u64,

    comptime {
        std.debug.assert(@sizeOf(SyscallFrame) == 128);
        std.debug.assert(@offsetOf(SyscallFrame, "rax") == 96);
        std.debug.assert(@offsetOf(SyscallFrame, "user_rip") == 112);
        std.debug.assert(@offsetOf(SyscallFrame, "user_rsp") == 120);
    }
};
```

---

## 4. Return Values and Error Code Convention

System call return values are returned in register `RAX`:
* **Success:** `RAX` contains zero or a positive integer (e.g. byte count read/written, new file descriptor index, or allocated memory address).
* **Failure:** `RAX` contains a negative integer corresponding to the negated Linux error code (`-errno`) in the range `-4095` to `-1`. Standard C runtimes (such as musl or glibc) detect values in this range, store `-RAX` in the thread-local `errno` variable, and return `-1` to the caller.

Common error codes returned by Tinux:
* `-EPERM` (1): Operation not permitted.
* `-ENOENT` (2): No such file or directory.
* `-ESRCH` (3): No such process.
* `-EBADF` (9): Bad file descriptor.
* `-ENOMEM` (12): Out of memory.
* `-EACCES` (13): Permission denied.
* `-EFAULT` (14): Bad address (pointer violates user canonical space).
* `-EINVAL` (22): Invalid argument.
* `-ENOSYS` (38): Function not implemented.

---

## 5. Supported System Call Table

Tinux defines and dispatches 70 Linux system calls in `src/syscall/dispatch.zig`, with additional subsystem routines for synchronization and event multiplexing:

### Process Management and Execution
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 39 | `sys_getpid` | `void` | Returns current process ID |
| 56 | `sys_clone` | `flags: u64, stack: usize, ptid: *i32, ctid: *i32, tls: usize` | Thread and process creation |
| 57 | `sys_fork` | `void` | Duplicates calling process |
| 58 | `sys_vfork` | `void` | Lightweight child process spawn |
| 59 | `sys_execve` | `path: [*:0]const u8, argv: [*][*:0]const u8, envp: [*][*:0]const u8` | Replaces image with new ELF binary |
| 60 | `sys_exit` | `status: i32` | Terminates calling thread |
| 61 | `sys_wait4` | `pid: i32, status: ?*i32, options: i32, rusage: ?*Rusage` | Waits for child state change |
| 63 | `sys_uname` | `buf: *LinuxUtsname` | Returns kernel version and release |
| 186| `sys_gettid` | `void` | Returns caller thread ID |
| 218| `sys_set_tid_address` | `tidptr: *i32` | Sets clear_child_tid pointer |
| 231| `sys_exit_group` | `status: i32` | Terminates all threads in process |

### Process Credentials and Group Identity
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 102| `sys_getuid` | `void` | Returns real user ID |
| 104| `sys_getgid` | `void` | Returns real group ID |
| 107| `sys_geteuid` | `void` | Returns effective user ID |
| 108| `sys_getegid` | `void` | Returns effective group ID |
| 110| `sys_getppid` | `void` | Returns parent process ID |
| 111| `sys_getpgrp` | `void` | Returns process group ID |
| 121| `sys_getpgid` | `pid: i32` | Returns process group ID of process |

### Signals and Process Control
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 13 | `sys_rt_sigaction` | `signum: i32, act: ?*const KernelSigAction, oldact: ?*KernelSigAction, sigsetsize: usize` | Examines and changes signal action |
| 14 | `sys_rt_sigprocmask` | `how: i32, set: ?*const SigSet, oldset: ?*SigSet, sigsetsize: usize` | Examines and changes blocked signals |
| 15 | `sys_rt_sigreturn` | `void` | Restores thread state from signal stack |
| 62 | `sys_kill` | `pid: i32, sig: i32` | Delivers signal to process |

### File and I/O Operations
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 0 | `sys_read` | `fd: i32, buf: [*]u8, count: usize` | Reads bytes from file descriptor |
| 1 | `sys_write` | `fd: i32, buf: [*]const u8, count: usize` | Writes bytes to file descriptor |
| 2 | `sys_open` | `path: [*:0]const u8, flags: u32, mode: u32` | Opens or creates a file node |
| 3 | `sys_close` | `fd: i32` | Releases open file descriptor |
| 4 | `sys_stat` | `path: [*:0]const u8, statbuf: *LinuxStat` | Queries file metadata by path |
| 5 | `sys_fstat` | `fd: i32, statbuf: *LinuxStat` | Queries metadata by descriptor |
| 16 | `sys_ioctl` | `fd: i32, request: u64, arg: usize` | Device-specific control requests |
| 17 | `sys_pread64` | `fd: i32, buf: [*]u8, count: usize, offset: i64` | Reads bytes at offset without seek |
| 19 | `sys_readv` | `fd: i32, iov: [*]const LinuxIovec, iovcnt: i32` | Scatter-read into multiple buffers |
| 20 | `sys_writev` | `fd: i32, iov: [*]const LinuxIovec, iovcnt: i32` | Gather-write from multiple buffers |
| 22 | `sys_pipe` | `pipefd: *[2]i32` | Creates unidirectional IPC pipe |
| 32 | `sys_dup` | `oldfd: i32` | Duplicates file descriptor |
| 33 | `sys_dup2` | `oldfd: i32, newfd: i32` | Duplicates file descriptor to index |
| 72 | `sys_fcntl` | `fd: i32, cmd: i32, arg: u64` | File descriptor control operations |
| 83 | `sys_mkdir` | `path: [*:0]const u8, mode: u32` | Creates new directory node |
| 84 | `sys_rmdir` | `path: [*:0]const u8` | Removes empty directory |
| 87 | `sys_unlink` | `path: [*:0]const u8` | Unlinks filesystem path entry |
| 89 | `sys_readlink` | `path: [*:0]const u8, buf: [*]u8, bufsiz: usize` | Reads value of symbolic link |
| 217| `sys_getdents64` | `fd: i32, dirp: [*]u8, count: usize` | Reads directory entries |
| 257| `sys_openat` | `dfd: i32, path: [*:0]const u8, flags: u32, mode: u32` | Opens file relative to directory fd |
| 258| `sys_mkdirat` | `dfd: i32, path: [*:0]const u8, mode: u32` | Creates directory relative to dir fd |
| 262| `sys_newfstatat` | `dfd: i32, path: [*:0]const u8, statbuf: *LinuxStat, flags: i32` | Queries file status relative to dir fd |
| 263| `sys_unlinkat` | `dfd: i32, path: [*:0]const u8, flags: i32` | Unlinks file relative to directory fd |
| 267| `sys_readlinkat` | `dfd: i32, path: [*:0]const u8, buf: [*]u8, bufsiz: usize` | Reads symlink relative to dir fd |
| 292| `sys_dup3` | `oldfd: i32, newfd: i32, flags: i32` | Duplicates file descriptor with flags |
| 293| `sys_pipe2` | `pipefd: *[2]i32, flags: i32` | Creates IPC pipe with flags (O_CLOEXEC) |

### Virtual Memory
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 9 | `sys_mmap` | `addr: usize, len: usize, prot: i32, flags: i32, fd: i32, off: i64` | Maps pages into user virtual space |
| 10 | `sys_mprotect`| `addr: usize, len: usize, prot: i32` | Sets access protection on page range |
| 11 | `sys_munmap` | `addr: usize, len: usize` | Unmaps pages from virtual space |
| 12 | `sys_brk` | `brk: usize` | Changes process data segment break |

### Architecture and Machine State
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 158| `sys_arch_prctl` | `code: i32, addr: usize` | Configures FS/GS base register (TLS) |

### Clocks and Timers
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 35 | `sys_nanosleep` | `req: *const LinuxTimespec, rem: ?*LinuxTimespec` | High-resolution task sleep |
| 228| `sys_clock_gettime`| `clock_id: i32, tp: *LinuxTimespec` | Retrieves monotonic or real time |
| 230| `sys_clock_nanosleep`| `clock_id: i32, flags: i32, req: *const LinuxTimespec, rem: ?*LinuxTimespec` | High-resolution clock sleep |

### Sockets and Networking
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 41 | `sys_socket` | `domain: i32, type: i32, protocol: i32` | Creates communication endpoint |
| 42 | `sys_connect`| `fd: i32, addr: *const SockAddrIn, len: u32` | Connects socket to remote address |
| 43 | `sys_accept` | `fd: i32, addr: ?*SockAddrIn, len: ?*u32` | Accepts incoming socket connection |
| 44 | `sys_sendto` | `fd: i32, buf: [*]const u8, len: usize, flags: i32, dest: ?*const SockAddrIn, dlen: u32` | Sends packet or data stream |
| 45 | `sys_recvfrom`| `fd: i32, buf: [*]u8, len: usize, flags: i32, src: ?*SockAddrIn, slen: ?*u32` | Receives packet or stream |
| 48 | `sys_shutdown` | `fd: i32, how: i32` | Shuts down part of full-duplex socket |
| 49 | `sys_bind` | `fd: i32, addr: *const SockAddrIn, len: u32` | Binds socket to local address and port |
| 50 | `sys_listen` | `fd: i32, backlog: i32` | Sets socket into listening state |
| 51 | `sys_getsockname` | `fd: i32, addr: *SockAddrIn, addrlen: *u32` | Retrieves local socket address |
| 52 | `sys_getpeername` | `fd: i32, addr: *SockAddrIn, addrlen: *u32` | Retrieves peer socket address |
| 53 | `sys_socketpair` | `domain: i32, type: i32, protocol: i32, sv: *[2]i32` | Creates pair of connected sockets |
| 54 | `sys_setsockopt` | `fd: i32, level: i32, optname: i32, optval: ?*const anyopaque, optlen: u32` | Sets socket options |
| 55 | `sys_getsockopt` | `fd: i32, level: i32, optname: i32, optval: ?*anyopaque, optlen: *u32` | Retrieves socket options |
| 288| `sys_accept4` | `fd: i32, addr: ?*SockAddrIn, len: ?*u32, flags: i32` | Accepts connection with flags |

### Extended and Milestone Subsystem Syscalls
| Syscall Number | Name | Function Signature | Description |
| :---: | :--- | :--- | :--- |
| 202| `sys_futex` | `uaddr: *i32, op: i32, val: i32, timeout: ?*LinuxTimespec, uaddr2: ?*i32, val3: i32` | Fast userspace locking primitive |
| 232| `sys_epoll_wait` | `epfd: i32, events: [*]LinuxEpollEvent, maxevents: i32, timeout: i32` | Waits for events on epoll set |
| 233| `sys_epoll_ctl` | `epfd: i32, op: i32, fd: i32, event: ?*const LinuxEpollEvent` | Controls epoll watch list |
| 291| `sys_epoll_create1`| `flags: i32` | Allocates epoll instance with flags |

---

## 6. User Address Space Pointer Validation

All user-supplied pointers are validated before dereferencing:
1. **Canonical Address Check:** The pointer must be less than or equal to `0x0000_7FFF_FFFF_FFFF`. Any address in the non-canonical hole or kernel space returns `-EFAULT`.
2. **Buffer Span Check:** The entire range `[ptr, ptr + len)` must not overflow 64-bit integer limits and must remain within valid user space.
3. **Alignment Verification:** Where required by architecture, pointers are checked for alignment before access.
