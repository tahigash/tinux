const std = @import("std");
const serial = @import("../drivers/serial.zig");
const io = @import("../arch/x86_64/io.zig");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const heap = @import("../mm/heap.zig");
const syscall_arch = @import("../arch/x86_64/syscall.zig");
const SyscallFrame = syscall_arch.SyscallFrame;
const errno_mod = @import("../uapi/errno.zig");
const Errno = errno_mod.Errno;
const vfs = @import("../fs/vfs.zig");
const task = @import("../proc/task.zig");
const pipe_mod = @import("../fs/pipe.zig");
const procfs = @import("../fs/procfs.zig");
const timer = @import("../drivers/timer.zig");
const tty = @import("../drivers/tty.zig");
const socket = @import("../net/socket.zig");
const elf = @import("../proc/elf.zig");
const strace = @import("strace.zig");
const profiler = @import("profiler.zig");

pub const SYS_READ: u64 = 0;
pub const SYS_WRITE: u64 = 1;
pub const SYS_OPEN: u64 = 2;
pub const SYS_CLOSE: u64 = 3;
pub const SYS_STAT: u64 = 4;
pub const SYS_FSTAT: u64 = 5;
pub const SYS_LSTAT: u64 = 6;
pub const SYS_LSEEK: u64 = 8;
pub const SYS_MMAP: u64 = 9;
pub const SYS_MPROTECT: u64 = 10;
pub const SYS_MUNMAP: u64 = 11;
pub const SYS_BRK: u64 = 12;
pub const SYS_RT_SIGACTION: u64 = 13;
pub const SYS_RT_SIGPROCMASK: u64 = 14;
pub const SYS_RT_SIGRETURN: u64 = 15;
pub const SYS_IOCTL: u64 = 16;
pub const SYS_PREAD64: u64 = 17;
pub const SYS_READV: u64 = 19;
pub const SYS_WRITEV: u64 = 20;
pub const SYS_PIPE: u64 = 22;
pub const SYS_DUP: u64 = 32;
pub const SYS_DUP2: u64 = 33;
pub const SYS_NANOSLEEP: u64 = 35;
pub const SYS_GETPID: u64 = 39;
pub const SYS_SOCKET: u64 = 41;
pub const SYS_CONNECT: u64 = 42;
pub const SYS_ACCEPT: u64 = 43;
pub const SYS_SENDTO: u64 = 44;
pub const SYS_RECVFROM: u64 = 45;
pub const SYS_SHUTDOWN: u64 = 48;
pub const SYS_BIND: u64 = 49;
pub const SYS_LISTEN: u64 = 50;
pub const SYS_GETSOCKNAME: u64 = 51;
pub const SYS_GETPEERNAME: u64 = 52;
pub const SYS_SOCKETPAIR: u64 = 53;
pub const SYS_SETSOCKOPT: u64 = 54;
pub const SYS_GETSOCKOPT: u64 = 55;
pub const SYS_CLONE: u64 = 56;
pub const SYS_FORK: u64 = 57;
pub const SYS_VFORK: u64 = 58;
pub const SYS_EXECVE: u64 = 59;
pub const SYS_EXIT: u64 = 60;
pub const SYS_WAIT4: u64 = 61;
pub const SYS_KILL: u64 = 62;
pub const SYS_UNAME: u64 = 63;
pub const SYS_FCNTL: u64 = 72;
pub const SYS_MKDIR: u64 = 83;
pub const SYS_RMDIR: u64 = 84;
pub const SYS_UNLINK: u64 = 87;
pub const SYS_READLINK: u64 = 89;
pub const SYS_GETUID: u64 = 102;
pub const SYS_GETGID: u64 = 104;
pub const SYS_GETEUID: u64 = 107;
pub const SYS_GETEGID: u64 = 108;
pub const SYS_GETPPID: u64 = 110;
pub const SYS_GETPGRP: u64 = 111;
pub const SYS_GETPGID: u64 = 121;
pub const SYS_ARCH_PRCTL: u64 = 158;
pub const SYS_GETTID: u64 = 186;
pub const SYS_GETDENTS64: u64 = 217;
pub const SYS_SET_TID_ADDRESS: u64 = 218;
pub const SYS_CLOCK_GETTIME: u64 = 228;
pub const SYS_CLOCK_NANOSLEEP: u64 = 230;
pub const SYS_EXIT_GROUP: u64 = 231;
pub const SYS_OPENAT: u64 = 257;
pub const SYS_MKDIRAT: u64 = 258;
pub const SYS_NEWFSTATAT: u64 = 262;
pub const SYS_UNLINKAT: u64 = 263;
pub const SYS_READLINKAT: u64 = 267;
pub const SYS_ACCEPT4: u64 = 288;
pub const SYS_DUP3: u64 = 292;
pub const SYS_PIPE2: u64 = 293;
pub const SYS_SET_ROBUST_LIST: u64 = 273;
pub const SYS_PRLIMIT64: u64 = 302;

// Whence modes for sys_lseek
pub const SEEK_SET: u32 = 0;
pub const SEEK_CUR: u32 = 1;
pub const SEEK_END: u32 = 2;

// Flags for sys_newfstatat
pub const AT_EMPTY_PATH: u32 = 0x1000;
pub const AT_SYMLINK_NOFOLLOW: u32 = 0x100;

pub const LinuxUtsname = extern struct {
    sysname: [65]u8 = [_]u8{0} ** 65,
    nodename: [65]u8 = [_]u8{0} ** 65,
    release: [65]u8 = [_]u8{0} ** 65,
    version: [65]u8 = [_]u8{0} ** 65,
    machine: [65]u8 = [_]u8{0} ** 65,
    domainname: [65]u8 = [_]u8{0} ** 65,
    comptime {
        std.debug.assert(@sizeOf(LinuxUtsname) == 390);
    }
};

pub const LinuxTimespec = extern struct {
    tv_sec: i64 align(1) = 0,
    tv_nsec: i64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxTimespec) == 16);
    }
};

pub const ARCH_SET_FS: usize = 0x1002;
pub const ARCH_GET_FS: usize = 0x1003;
pub const MSR_FS_BASE: u32 = syscall_arch.MSR_FS_BASE; // 0xC000_0100
pub const USER_ADDR_MAX: usize = 0x0000_8000_0000_0000;
pub const MAX_BRK_GROWTH: usize = 16 * 1024 * 1024; // 16 MiB max heap growth

pub var current_brk: usize = 0;
pub var initial_brk: usize = 0;
pub var current_fs_base: usize = 0;

var current_test_name: []const u8 = "TASK-004";

pub fn setCurrentTestName(name: []const u8) void {
    current_test_name = name;
}

pub fn validateUserBuffer(buf_ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (buf_ptr < 0x1000 or buf_ptr >= 0x0000_8000_0000_0000) return false;
    const end_addr = std.math.add(usize, buf_ptr, len - 1) catch return false;
    if (end_addr >= 0x0000_8000_0000_0000) return false;
    const pml4 = vmm.readCr3();
    var page = buf_ptr & ~@as(usize, 0xFFF);
    const last_page = end_addr & ~@as(usize, 0xFFF);
    while (true) {
        const flags = vmm.getPteFlags(pml4, page) orelse return false;
        if ((flags & vmm.PTE_USER) == 0) return false;
        if (page == last_page) break;
        page += vmm.PAGE_SIZE;
    }
    return true;
}

pub fn readUserCString(ptr: usize, out_buf: []u8) error{EFAULT, ENAMETOOLONG}![]const u8 {
    if (ptr < 0x1000 or ptr >= USER_ADDR_MAX) return error.EFAULT;
    const p = @as([*]const u8, @ptrFromInt(ptr));
    var len: usize = 0;
    while (len < out_buf.len) : (len += 1) {
        const curr_addr = ptr + len;
        if (curr_addr >= USER_ADDR_MAX) return error.EFAULT;
        if (len == 0 or (curr_addr & 0xFFF) == 0) {
            if (!validateUserBuffer(curr_addr, 1)) return error.EFAULT;
        }
        const ch = p[len];
        if (ch == 0) {
            return out_buf[0..len];
        }
        out_buf[len] = ch;
    }
    return error.ENAMETOOLONG;
}

fn getUserString(ptr: usize, max_len: usize) ?[]const u8 {
    if (ptr < 0x1000 or ptr >= USER_ADDR_MAX) return null;
    if (!validateUserBuffer(ptr, 1)) return null;
    const p = @as([*]const u8, @ptrFromInt(ptr));
    var len: usize = 0;
    while (len < max_len) : (len += 1) {
        const curr_addr = ptr + len;
        if (curr_addr >= USER_ADDR_MAX) return null;
        if ((curr_addr & 0xFFF) == 0) {
            if (!validateUserBuffer(curr_addr, 1)) return null;
        }
        if (p[len] == 0) {
            return p[0..len];
        }
    }
    return null;
}

fn sysExit(status: usize) noreturn {
    serial.print("[TINUX_SYSCALL] sys_exit({d}) received from Ring 3\n", .{status});
    const cur = task.currentTask();
    if (cur.pid == 1) {
        if (status == 0) {
            serial.print("[TINUX_TEST] PASS: {s}\n", .{current_test_name});
            io.qemuExitSuccess();
        } else {
            serial.print("[TINUX_TEST] FAIL: {s} (exit status {d})\n", .{ current_test_name, status });
            io.qemuExitFailure();
        }
    } else {
        cur.state = .ZOMBIE;
        cur.exit_status = @intCast(status);
        cur.closeAllFds();
        task.wakeParentIfWaiting(cur.parent_pid);
        const next_idx = task.scheduleNextOrWait();
        task.activateTask(next_idx);
        unreachable;
    }
}

pub fn initBrk(base: usize) void {
    initial_brk = base;
    current_brk = base;
    const cur = task.currentTask();
    cur.initial_brk = base;
    cur.current_brk = base;
}

pub fn sysBrk(new_brk: usize) usize {
    const cur_task = task.currentTask();
    const init_b = if (cur_task.initial_brk != 0) cur_task.initial_brk else initial_brk;
    const cur_b = if (cur_task.current_brk != 0) cur_task.current_brk else current_brk;

    if (new_brk == 0 or new_brk < init_b) {
        return cur_b;
    }
    if (new_brk >= USER_ADDR_MAX or new_brk > init_b + MAX_BRK_GROWTH) {
        return cur_b;
    }

    if (new_brk > cur_b) {
        const old_top = std.mem.alignForward(usize, cur_b, vmm.PAGE_SIZE);
        const new_top = std.mem.alignForward(usize, new_brk, vmm.PAGE_SIZE);
        if (new_top > old_top) {
            const pml4 = if (cur_task.pml4_phys != 0) cur_task.pml4_phys else vmm.getKernelPml4Phys();
            var v = old_top;
            while (v < new_top) : (v += vmm.PAGE_SIZE) {
                const flags = vmm.getPteFlags(pml4, v);
                if (flags == null or (flags.? & vmm.PTE_USER) == 0) {
                    const p = pmm.allocZeroedPage() orelse {
                        return cur_b;
                    };
                    if (!vmm.mapPage(pml4, v, p, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER)) {
                        pmm.freePage(p);
                        return cur_b;
                    }
                }
            }
        }
    }

    current_brk = new_brk;
    cur_task.current_brk = new_brk;
    return new_brk;
}

pub fn sysArchPrctl(code: usize, addr: usize) isize {
    const cur_task = task.currentTask();
    if (code == ARCH_SET_FS) {
        if (addr >= USER_ADDR_MAX) {
            return errno_mod.toReturn(.EINVAL);
        }
        current_fs_base = addr;
        cur_task.fs_base = addr;
        syscall_arch.wrmsr(MSR_FS_BASE, addr);
        return 0;
    } else if (code == ARCH_GET_FS) {
        if (!validateUserBuffer(addr, 8)) {
            return errno_mod.toReturn(.EFAULT);
        }
        const fs_val = if (cur_task.fs_base != 0) cur_task.fs_base else current_fs_base;
        std.mem.writeInt(u64, @as(*[8]u8, @ptrFromInt(addr)), fs_val, .little);
        return 0;
    } else {
        return errno_mod.toReturn(.EINVAL);
    }
}

pub fn sysSetTidAddress(tidptr: usize) usize {
    const cur_task = task.currentTask();
    cur_task.clear_child_tid = tidptr;
    return if (cur_task.pid != 0) cur_task.pid else 1;
}

export fn syscallDispatch(frame: *SyscallFrame) callconv(.C) *SyscallFrame {
    const start_tsc = profiler.readTsc();
    const cur_task = task.currentTask();
    const orig_pid = cur_task.pid;
    const num = frame.rax;
    const orig_rip = frame.user_rip;
    const a1 = frame.rdi;
    const a2 = frame.rsi;
    const a3 = frame.rdx;
    const a4 = frame.r10;

    var res: isize = 0;
    var do_block: bool = false;

    blk: {
    switch (num) {
        SYS_READ => {
            const fd = a1;
            const buf_ptr = a2;
            const count = a3;
            if (fd >= vfs.MAX_OPEN_FILES) {
                res = errno_mod.toReturn(.EBADF);
            } else if (count == 0) {
                res = 0;
            } else if (!validateUserBuffer(buf_ptr, count)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const entry = &cur_task.fd_table[fd];
                const dst = @as([*]u8, @ptrFromInt(buf_ptr))[0..count];
                switch (entry.kind) {
                    .CONSOLE_IN => {
                        const r = tty.read(dst);
                        switch (r.status) {
                            .bytes => res = @intCast(r.n),
                            .eof => res = 0,
                            .would_block => {
                                cur_task.state = .WAITING_TTY;
                                do_block = true;
                            },
                        }
                    },
                    .VFS_FILE => {
                        const node = vfs.getNode(entry.node_idx);
                        const file_data = node.slice();
                        if (entry.offset >= file_data.len) {
                            res = 0;
                        } else {
                            const avail = file_data.len - entry.offset;
                            const to_read = @min(count, avail);
                            @memcpy(dst[0..to_read], file_data[entry.offset .. entry.offset + to_read]);
                            entry.offset += to_read;
                            res = @intCast(to_read);
                        }
                    },
                    .PIPE_READ => {
                        const r = pipe_mod.read(entry.node_idx, dst);
                        switch (r.status) {
                            .bytes => res = @intCast(r.n),
                            .eof => res = 0,
                            .would_block => {
                                cur_task.state = .WAITING_PIPE_READ;
                                cur_task.wait_pipe_idx = entry.node_idx;
                                do_block = true;
                            },
                        }
                    },
                    .SOCKET => {
                        const r = socket.readStream(entry.node_idx, dst);
                        switch (r.status) {
                            .bytes => res = @intCast(r.n),
                            .eof => res = 0,
                            .would_block => {
                                cur_task.state = .WAITING_SOCK_READ;
                                cur_task.wait_sock_idx = entry.node_idx;
                                do_block = true;
                            },
                        }
                    },
                    else => res = errno_mod.toReturn(.EBADF),
                }
            }
        },

        SYS_WRITE => {
            const fd = a1;
            const buf_ptr = a2;
            const count = a3;
            if (fd >= vfs.MAX_OPEN_FILES) {
                res = errno_mod.toReturn(.EBADF);
            } else if (count == 0) {
                res = 0;
            } else if (!validateUserBuffer(buf_ptr, count)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const entry = &cur_task.fd_table[fd];
                const src = @as([*]const u8, @ptrFromInt(buf_ptr))[0..count];
                switch (entry.kind) {
                    .CONSOLE_OUT, .CONSOLE_ERR => {
                        serial.writeString(src);
                        res = @intCast(count);
                    },
                    .VFS_FILE => {
                        const write_off = if ((entry.flags & vfs.O_APPEND) != 0) vfs.getNode(entry.node_idx).size else entry.offset;
                        const written = vfs.writeNode(entry.node_idx, write_off, src) catch |err| {
                            res = errno_mod.toReturn(err);
                            break :blk;
                        };
                        entry.offset = write_off + written;
                        res = @intCast(written);
                    },
                    .PIPE_WRITE => {
                        const r = pipe_mod.write(entry.node_idx, src);
                        switch (r.status) {
                            .bytes => res = @intCast(r.n),
                            .broken_pipe => res = errno_mod.toReturn(.EPIPE),
                            .would_block => {
                                cur_task.state = .WAITING_PIPE_WRITE;
                                cur_task.wait_pipe_idx = entry.node_idx;
                                do_block = true;
                            },
                        }
                    },
                    .SOCKET => {
                        const w = socket.writeStream(entry.node_idx, src) catch |err| {
                            res = errno_mod.toReturn(err);
                            break :blk;
                        };
                        res = @intCast(w);
                    },
                    else => res = errno_mod.toReturn(.EBADF),
                }
            }
        },

        SYS_OPEN => {
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(a1, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            const flags: u32 = @truncate(a2);
            const mode: u32 = @truncate(a3);
            res = handleOpenat(vfs.AT_FDCWD, path_str, flags, mode);
        },

        SYS_OPENAT => {
            const dirfd: isize = @bitCast(a1);
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(a2, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            const flags: u32 = @truncate(a3);
            const mode: u32 = @truncate(a4);
            res = handleOpenat(dirfd, path_str, flags, mode);
        },

        SYS_CLOSE => {
            const fd = a1;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else {
                const entry = &cur_task.fd_table[fd];
                switch (entry.kind) {
                    .PIPE_READ => pipe_mod.closeReader(entry.node_idx),
                    .PIPE_WRITE => pipe_mod.closeWriter(entry.node_idx),
                    .SOCKET => socket.close(entry.node_idx),
                    else => {},
                }
                entry.* = .{};
                res = 0;
            }
        },

        SYS_STAT, SYS_LSTAT => {
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(a1, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            res = handleStatPath(vfs.AT_FDCWD, path_str, a2, 0);
        },

        SYS_FSTAT => {
            res = handleFstat(a1, a2);
        },

        SYS_LSEEK => {
            const fd = a1;
            const offset: i64 = @bitCast(a2);
            const whence: u32 = @truncate(a3);
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else {
                const entry = &cur_task.fd_table[fd];
                switch (entry.kind) {
                    .VFS_FILE => {
                        const node = vfs.getNode(entry.node_idx);
                        const file_size: i64 = @intCast(node.size);
                        const curr_off: i64 = @intCast(entry.offset);
                        var new_off: i64 = 0;
                        switch (whence) {
                            SEEK_SET => new_off = offset,
                            SEEK_CUR => new_off = curr_off + offset,
                            SEEK_END => new_off = file_size + offset,
                            else => {
                                res = errno_mod.toReturn(.EINVAL);
                                break :blk;
                            },
                        }
                        if (new_off < 0) {
                            res = errno_mod.toReturn(.EINVAL);
                        } else {
                            entry.offset = @intCast(new_off);
                            res = @intCast(new_off);
                        }
                    },
                    .CONSOLE_IN, .CONSOLE_OUT, .CONSOLE_ERR, .PIPE_READ, .PIPE_WRITE, .SOCKET => {
                        res = errno_mod.toReturn(.ESPIPE);
                    },
                    else => res = errno_mod.toReturn(.EBADF),
                }
            }
        },

        SYS_NEWFSTATAT => {
            const dirfd: isize = @bitCast(a1);
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(a2, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            const stat_ptr = a3;
            const flags: u32 = @truncate(a4);
            res = handleStatPath(dirfd, path_str, stat_ptr, flags);
        },

        SYS_BRK => {
            res = @intCast(sysBrk(a1));
        },

        SYS_MMAP => {
            const addr = a1;
            const len = a2;
            const prot = a3;
            const flags = a4;
            const fd = frame.r8;
            const offset = frame.r9;
            _ = prot;
            _ = offset;

            if (len == 0) {
                res = errno_mod.toReturn(.EINVAL);
            } else {
                const aligned_len = std.mem.alignForward(usize, len, vmm.PAGE_SIZE);
                const is_fixed = (flags & 0x10) != 0;
                const base_vaddr = if (is_fixed and addr != 0) addr else cur_task.next_mmap_vaddr;

                var v = base_vaddr;
                const top = base_vaddr + aligned_len;
                while (v < top) : (v += vmm.PAGE_SIZE) {
                    const p = pmm.allocZeroedPage() orelse {
                        res = errno_mod.toReturn(.ENOMEM);
                        break :blk;
                    };
                    _ = vmm.mapPage(cur_task.pml4_phys, v, p, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
                }

                if (fd < vfs.MAX_OPEN_FILES and cur_task.fd_table[fd].kind == .VFS_FILE) {
                    const node = vfs.getNode(cur_task.fd_table[fd].node_idx);
                    const file_slice = node.slice();
                    const copy_len = @min(file_slice.len, len);
                    @memcpy(@as([*]u8, @ptrFromInt(base_vaddr))[0..copy_len], file_slice[0..copy_len]);
                }

                if (!is_fixed) {
                    cur_task.next_mmap_vaddr = top;
                }
                res = @intCast(base_vaddr);
            }
        },

        SYS_MPROTECT => res = 0,
        SYS_MUNMAP => res = 0,

        SYS_IOCTL => {
            const fd = a1;
            const req = a2;
            const arg = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else {
                const entry = &cur_task.fd_table[fd];
                if (entry.kind != .CONSOLE_IN and entry.kind != .CONSOLE_OUT and entry.kind != .CONSOLE_ERR) {
                    res = errno_mod.toReturn(.ENOTTY);
                } else {
                    switch (req) {
                    tty.TCGETS => {
                        if (!validateUserBuffer(arg, @sizeOf(tty.LinuxTermios))) {
                            res = errno_mod.toReturn(.EFAULT);
                        } else {
                            const p = @as(*tty.LinuxTermios, @ptrFromInt(arg));
                            p.* = tty.getTermios();
                            res = 0;
                        }
                    },
                    tty.TCSETS, tty.TCSETSW, tty.TCSETSF => {
                        if (!validateUserBuffer(arg, @sizeOf(tty.LinuxTermios))) {
                            res = errno_mod.toReturn(.EFAULT);
                        } else {
                            const p = @as(*const tty.LinuxTermios, @ptrFromInt(arg));
                            tty.setTermios(p.*);
                            res = 0;
                        }
                    },
                    tty.TIOCGPGRP => {
                        if (!validateUserBuffer(arg, @sizeOf(i32))) {
                            res = errno_mod.toReturn(.EFAULT);
                        } else {
                            const p = @as(*i32, @ptrFromInt(arg));
                            p.* = tty.getForegroundPgrp();
                            res = 0;
                        }
                    },
                    tty.TIOCSPGRP => {
                        if (!validateUserBuffer(arg, @sizeOf(i32))) {
                            res = errno_mod.toReturn(.EFAULT);
                        } else {
                            const p = @as(*const i32, @ptrFromInt(arg));
                            tty.setForegroundPgrp(p.*);
                            res = 0;
                        }
                    },
                    tty.TIOCGWINSZ => {
                        if (!validateUserBuffer(arg, @sizeOf(tty.LinuxWinsize))) {
                            res = errno_mod.toReturn(.EFAULT);
                        } else {
                            const p = @as(*tty.LinuxWinsize, @ptrFromInt(arg));
                            p.* = .{ .ws_row = 25, .ws_col = 80 };
                            res = 0;
                        }
                    },
                    tty.TIOCSWINSZ => res = 0,
                    else => res = errno_mod.toReturn(.ENOTTY),
                }
            }
        }
        },

        SYS_PREAD64 => {
            const fd = a1;
            const buf_ptr = a2;
            const count = a3;
            const offset = a4;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind != .VFS_FILE) {
                res = errno_mod.toReturn(.EBADF);
            } else if (!validateUserBuffer(buf_ptr, count)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const node = vfs.getNode(cur_task.fd_table[fd].node_idx);
                const file_data = node.slice();
                if (offset >= file_data.len) {
                    res = 0;
                } else {
                    const avail = file_data.len - offset;
                    const to_read = @min(count, avail);
                    @memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..to_read], file_data[offset .. offset + to_read]);
                    res = @intCast(to_read);
                }
            }
        },

        SYS_READV => {
            const fd = a1;
            const iov_ptr = a2;
            const iov_cnt = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (iov_cnt > 1024) {
                res = errno_mod.toReturn(.EINVAL);
            } else if (!validateUserBuffer(iov_ptr, iov_cnt * @sizeOf(vfs.LinuxIovec))) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const iovs = @as([*]const vfs.LinuxIovec, @ptrFromInt(iov_ptr))[0..iov_cnt];
                var total: usize = 0;
                for (iovs) |iov| {
                    if (iov.iov_len == 0) continue;
                    if (!validateUserBuffer(iov.iov_base, iov.iov_len)) {
                        res = errno_mod.toReturn(.EFAULT);
                        break :blk;
                    }
                    const r = handleReadDirect(fd, iov.iov_base, iov.iov_len);
                    if (r < 0) {
                        res = r;
                        break :blk;
                    }
                    total += @intCast(r);
                    if (r < iov.iov_len) break;
                }
                res = @intCast(total);
            }
        },

        SYS_WRITEV => {
            const fd = a1;
            const iov_ptr = a2;
            const iov_cnt = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (iov_cnt > 1024) {
                res = errno_mod.toReturn(.EINVAL);
            } else if (!validateUserBuffer(iov_ptr, iov_cnt * @sizeOf(vfs.LinuxIovec))) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const iovs = @as([*]const vfs.LinuxIovec, @ptrFromInt(iov_ptr))[0..iov_cnt];
                var total: usize = 0;
                for (iovs) |iov| {
                    if (iov.iov_len == 0) continue;
                    if (!validateUserBuffer(iov.iov_base, iov.iov_len)) {
                        res = errno_mod.toReturn(.EFAULT);
                        break :blk;
                    }
                    const w = handleWriteDirect(fd, iov.iov_base, iov.iov_len);
                    if (w < 0) {
                        res = w;
                        break :blk;
                    }
                    total += @intCast(w);
                }
                res = @intCast(total);
            }
        },

        SYS_PIPE, SYS_PIPE2 => {
            const pipefd_ptr = a1;
            if (!validateUserBuffer(pipefd_ptr, 8)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const p_idx = pipe_mod.alloc() orelse {
                    res = errno_mod.toReturn(.ENFILE);
                    break :blk;
                };

                var r_fd: ?usize = null;
                var w_fd: ?usize = null;
                for (&cur_task.fd_table, 0..) |*e, i| {
                    if (e.kind == .UNUSED) {
                        if (r_fd == null) {
                            r_fd = i;
                        } else if (w_fd == null) {
                            w_fd = i;
                            break;
                        }
                    }
                }

                if (r_fd == null or w_fd == null) {
                    pipe_mod.closeReader(p_idx);
                    pipe_mod.closeWriter(p_idx);
                    res = errno_mod.toReturn(.EMFILE);
                } else {
                    const cloexec = (a2 & 0x80000) != 0;
                    cur_task.fd_table[r_fd.?] = .{ .kind = .PIPE_READ, .node_idx = p_idx, .cloexec = cloexec };
                    cur_task.fd_table[w_fd.?] = .{ .kind = .PIPE_WRITE, .node_idx = p_idx, .cloexec = cloexec };

                    std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(pipefd_ptr)), @intCast(r_fd.?), .little);
                    std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(pipefd_ptr + 4)), @intCast(w_fd.?), .little);
                    res = 0;
                }
            }
        },

        SYS_DUP => {
            const oldfd = a1;
            if (oldfd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[oldfd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else {
                var newfd: ?usize = null;
                for (&cur_task.fd_table, 0..) |*e, i| {
                    if (e.kind == .UNUSED) {
                        newfd = i;
                        break;
                    }
                }
                if (newfd) |nfd| {
                    cur_task.fd_table[nfd] = cur_task.fd_table[oldfd];
                    cur_task.fd_table[nfd].cloexec = false;
                    retainFd(cur_task.fd_table[nfd]);
                    res = @intCast(nfd);
                } else {
                    res = errno_mod.toReturn(.EMFILE);
                }
            }
        },

        SYS_DUP2, SYS_DUP3 => {
            const oldfd = a1;
            const newfd = a2;
            if (oldfd >= vfs.MAX_OPEN_FILES or newfd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[oldfd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (oldfd == newfd) {
                res = @intCast(newfd);
            } else {
                if (cur_task.fd_table[newfd].kind != .UNUSED) {
                    closeFdEntry(&cur_task.fd_table[newfd]);
                }
                cur_task.fd_table[newfd] = cur_task.fd_table[oldfd];
                cur_task.fd_table[newfd].cloexec = (num == SYS_DUP3 and (a3 & 0x80000) != 0);
                retainFd(cur_task.fd_table[newfd]);
                res = @intCast(newfd);
            }
        },

        SYS_NANOSLEEP, SYS_CLOCK_NANOSLEEP => {
            const req_ptr = if (num == SYS_CLOCK_NANOSLEEP) a3 else a1;
            if (!validateUserBuffer(req_ptr, @sizeOf(LinuxTimespec))) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const ts = @as(*const LinuxTimespec, @ptrFromInt(req_ptr));
                const total_ms = (@as(u64, @intCast(ts.tv_sec)) * 1000) + (@as(u64, @intCast(ts.tv_nsec)) / 1_000_000);
                const wait_ticks = @min(@max((total_ms + 9) / 10, 1), 50);

                cur_task.sleep_wake_tick = timer.getTicks() + wait_ticks;
                cur_task.state = .WAITING_SLEEP;

                frame.rax = 0; // Return 0 upon wake
                cur_task.saved_frame = frame;

                const next_idx = task.scheduleNextOrWait();
                task.activateTask(next_idx);
                return task.tasks[next_idx].saved_frame;
            }
        },

        SYS_GETPID => res = @intCast(if (cur_task.pid != 0) cur_task.pid else 1),
        SYS_GETPPID => res = @intCast(cur_task.parent_pid),
        SYS_GETPGID, SYS_GETPGRP => res = @intCast(cur_task.pgid),
        SYS_GETUID, SYS_GETGID, SYS_GETEUID, SYS_GETEGID => res = 0,
        SYS_GETTID => res = @intCast(if (cur_task.pid != 0) cur_task.pid else 1),
        SYS_SET_ROBUST_LIST, SYS_PRLIMIT64 => res = 0,
        SYS_SET_TID_ADDRESS => {
            res = @intCast(sysSetTidAddress(a1));
        },

        SYS_SOCKET => {
            const domain: u16 = @truncate(a1);
            const sock_type: u16 = @truncate(a2 & 0xFF);
            const proto: u16 = @truncate(a3);
            if (domain != socket.AF_UNIX and domain != socket.AF_INET) {
                res = errno_mod.toReturn(.EINVAL);
            } else {
                const s_idx = socket.alloc(domain, sock_type, proto) orelse {
                    res = errno_mod.toReturn(.ENFILE);
                    break :blk;
                };
                var fd_slot: ?usize = null;
                for (&cur_task.fd_table, 0..) |*e, i| {
                    if (e.kind == .UNUSED) {
                        fd_slot = i;
                        break;
                    }
                }
                if (fd_slot) |fd| {
                    cur_task.fd_table[fd] = .{ .kind = .SOCKET, .node_idx = s_idx };
                    res = @intCast(fd);
                } else {
                    socket.close(s_idx);
                    res = errno_mod.toReturn(.EMFILE);
                }
            }
        },

        SYS_BIND => {
            const fd = a1;
            const addr_ptr = a2;
            const addr_len = a3;
            _ = addr_len;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.EBADF);
            } else if (!validateUserBuffer(addr_ptr, @sizeOf(socket.SockAddrIn))) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const sin = @as(*const socket.SockAddrIn, @ptrFromInt(addr_ptr));
                const host_port = std.mem.bigToNative(u16, sin.sin_port);
                socket.bind(cur_task.fd_table[fd].node_idx, host_port) catch |err| {
                    res = errno_mod.toReturn(err);
                    break :blk;
                };
                res = 0;
            }
        },

        SYS_LISTEN => {
            const fd = a1;
            const backlog = a2;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.EBADF);
            } else {
                socket.listen(cur_task.fd_table[fd].node_idx, backlog) catch |err| {
                    res = errno_mod.toReturn(err);
                    break :blk;
                };
                res = 0;
            }
        },

        SYS_ACCEPT, SYS_ACCEPT4 => {
            const fd = a1;
            const addr_ptr = a2;
            const addr_len_ptr = a3;
            _ = addr_ptr;
            _ = addr_len_ptr;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.EBADF);
            } else {
                const l_idx = cur_task.fd_table[fd].node_idx;
                if (socket.popAcceptQueue(l_idx)) |conn_idx| {
                    var new_fd: ?usize = null;
                    for (&cur_task.fd_table, 0..) |*e, i| {
                        if (e.kind == .UNUSED) {
                            new_fd = i;
                            break;
                        }
                    }
                    if (new_fd) |nfd| {
                        cur_task.fd_table[nfd] = .{ .kind = .SOCKET, .node_idx = conn_idx };
                        res = @intCast(nfd);
                    } else {
                        socket.close(conn_idx);
                        res = errno_mod.toReturn(.EMFILE);
                    }
                } else {
                    cur_task.state = .WAITING_SOCK_ACCEPT;
                    cur_task.wait_sock_idx = l_idx;
                    do_block = true;
                }
            }
        },

        SYS_CONNECT => {
            const fd = a1;
            const addr_ptr = a2;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.EBADF);
            } else if (!validateUserBuffer(addr_ptr, @sizeOf(socket.SockAddrIn))) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const sin = @as(*const socket.SockAddrIn, @ptrFromInt(addr_ptr));
                const target_port = std.mem.bigToNative(u16, sin.sin_port);
                socket.connectLoopback(cur_task.fd_table[fd].node_idx, target_port) catch |err| {
                    res = errno_mod.toReturn(err);
                    break :blk;
                };
                res = 0;
            }
        },

        SYS_SENDTO => {
            const fd = a1;
            const buf_ptr = a2;
            const len = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.EBADF);
            } else if (!validateUserBuffer(buf_ptr, len)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const src = @as([*]const u8, @ptrFromInt(buf_ptr))[0..len];
                const w = socket.writeStream(cur_task.fd_table[fd].node_idx, src) catch |err| {
                    res = errno_mod.toReturn(err);
                    break :blk;
                };
                res = @intCast(w);
            }
        },

        SYS_RECVFROM => {
            const fd = a1;
            const buf_ptr = a2;
            const len = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.EBADF);
            } else if (!validateUserBuffer(buf_ptr, len)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const dst = @as([*]u8, @ptrFromInt(buf_ptr))[0..len];
                const r = socket.readStream(cur_task.fd_table[fd].node_idx, dst);
                switch (r.status) {
                    .bytes => res = @intCast(r.n),
                    .eof => res = 0,
                    .would_block => {
                        cur_task.state = .WAITING_SOCK_READ;
                        cur_task.wait_sock_idx = cur_task.fd_table[fd].node_idx;
                        do_block = true;
                    },
                }
            }
        },

        SYS_SHUTDOWN, SYS_SETSOCKOPT, SYS_GETSOCKOPT => res = 0,

        SYS_FORK, SYS_VFORK => {
            if (task.forkCurrentTask(frame)) |child_idx| {
                res = @intCast(task.tasks[child_idx].pid);
            } else {
                res = errno_mod.toReturn(.EAGAIN);
            }
        },

        SYS_CLONE => {
            const flags = a1;
            const newsp = a2;
            _ = newsp;
            if ((flags & 0x100) != 0) { // SIGCHLD or standard fork clone
                if (task.forkCurrentTask(frame)) |child_idx| {
                    res = @intCast(task.tasks[child_idx].pid);
                } else {
                    res = errno_mod.toReturn(.EAGAIN);
                }
            } else {
                res = errno_mod.toReturn(.EINVAL);
            }
        },

        SYS_EXECVE => {
            const path_str = getUserString(a1, 256) orelse {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            };

            var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
            const resolved = vfs.resolveTaskPath(cur_task.cwd(), path_str, &path_buf);
            const n_idx = vfs.lookup(resolved) orelse {
                res = errno_mod.toReturn(.ENOENT);
                break :blk;
            };

            const elf_data = vfs.getNode(n_idx).slice();
            const new_pml4 = vmm.createFreshUserPml4() orelse {
                res = errno_mod.toReturn(.ENOMEM);
                break :blk;
            };

            // Collect argv and envp
            const argv_slice = collectStrings(a2);
            const envp_slice = collectStrings(a3);

            const loaded = elf.loadStaticElfWithArgs(new_pml4, elf_data, argv_slice, envp_slice) catch {
                res = errno_mod.toReturn(.ENOEXEC);
                break :blk;
            };

            cur_task.pml4_phys = new_pml4;
            cur_task.initial_brk = loaded.initial_brk;
            cur_task.current_brk = loaded.initial_brk;
            cur_task.setComm(resolved);
            cur_task.closeCloexecFds();

            frame.user_rip = loaded.entry_rip;
            frame.user_rsp = loaded.user_rsp;
            frame.rax = 0;
            vmm.loadCr3(new_pml4);
            return frame;
        },

        SYS_EXIT, SYS_EXIT_GROUP => sysExit(a1),

        SYS_WAIT4 => {
            const target_pid: isize = @bitCast(a1);
            const status_ptr = a2;
            const options = a3;
            _ = options;

            var found_zombie: ?usize = null;
            var has_children = false;

            for (&task.tasks, 0..) |*t, i| {
                if (t.parent_pid == cur_task.pid and t.state != .UNUSED) {
                    if (target_pid == -1 or target_pid == @as(isize, @intCast(t.pid))) {
                        has_children = true;
                        if (t.state == .ZOMBIE) {
                            found_zombie = i;
                            break;
                        }
                    }
                }
            }

            if (found_zombie) |z_idx| {
                const z = &task.tasks[z_idx];
                const reaped_pid = z.pid;
                if (status_ptr != 0 and validateUserBuffer(status_ptr, 4)) {
                    const status_val = (z.exit_status & 0xFF) << 8;
                    std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(status_ptr)), status_val, .little);
                }
                z.state = .UNUSED;
                res = @intCast(reaped_pid);
            } else if (!has_children) {
                res = errno_mod.toReturn(.ECHILD);
            } else {
                cur_task.state = .WAITING_CHILD;
                cur_task.wait_target_pid = target_pid;
                do_block = true;
            }
        },

        SYS_KILL => {
            const target_pid: isize = @bitCast(a1);
            const sig = a2;
            var found = false;
            for (&task.tasks) |*t| {
                if (t.state != .UNUSED and target_pid == @as(isize, @intCast(t.pid))) {
                    found = true;
                    if (sig == 9 or sig == 15) {
                        t.state = .ZOMBIE;
                        t.exit_status = 128 + @as(i32, @intCast(sig));
                        t.closeAllFds();
                        task.wakeParentIfWaiting(t.parent_pid);
                    }
                    break;
                }
            }
            if (found) {
                res = 0;
            } else {
                res = errno_mod.toReturn(.ESRCH);
            }
        },

        SYS_UNAME => {
            const buf_ptr = a1;
            if (!validateUserBuffer(buf_ptr, @sizeOf(LinuxUtsname))) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                var uts = @as(*LinuxUtsname, @ptrFromInt(buf_ptr));
                uts.* = .{};
                copyFixed(&uts.sysname, "Linux");
                copyFixed(&uts.nodename, "tinux");
                copyFixed(&uts.release, "6.6.0-tinux");
                copyFixed(&uts.version, "#1 SMP PREEMPT Tinux 2026");
                copyFixed(&uts.machine, "x86_64");
                copyFixed(&uts.domainname, "(none)");
                res = 0;
            }
        },

        SYS_FCNTL => {
            const fd = a1;
            const cmd = a2;
            const arg = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else {
                switch (cmd) {
                    0, 1030 => { // F_DUPFD, F_DUPFD_CLOEXEC
                        var newfd: ?usize = null;
                        for (arg..vfs.MAX_OPEN_FILES) |i| {
                            if (cur_task.fd_table[i].kind == .UNUSED) {
                                newfd = i;
                                break;
                            }
                        }
                        if (newfd) |nfd| {
                            cur_task.fd_table[nfd] = cur_task.fd_table[fd];
                            cur_task.fd_table[nfd].cloexec = (cmd == 1030);
                            retainFd(cur_task.fd_table[nfd]);
                            res = @intCast(nfd);
                        } else {
                            res = errno_mod.toReturn(.EMFILE);
                        }
                    },
                    1 => res = if (cur_task.fd_table[fd].cloexec) 1 else 0, // F_GETFD
                    2 => { // F_SETFD
                        cur_task.fd_table[fd].cloexec = (arg & 1) != 0;
                        res = 0;
                    },
                    3 => res = @intCast(cur_task.fd_table[fd].flags), // F_GETFL
                    4 => { // F_SETFL
                        cur_task.fd_table[fd].flags = @truncate(arg);
                        res = 0;
                    },
                    else => res = 0,
                }
            }
        },

        SYS_MKDIR, SYS_MKDIRAT => {
            const path_ptr = if (num == SYS_MKDIRAT) a2 else a1;
            const mode: u32 = @truncate(if (num == SYS_MKDIRAT) a3 else a2);
            const path_str = getUserString(path_ptr, 256) orelse {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            };
            var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
            const resolved = vfs.resolveTaskPath(cur_task.cwd(), path_str, &path_buf);
            _ = vfs.createNode(resolved, vfs.S_IFDIR | (mode & 0o777)) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            res = 0;
        },

        SYS_RMDIR => {
            const path_str = getUserString(a1, 256) orelse {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            };
            var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
            const resolved = vfs.resolveTaskPath(cur_task.cwd(), path_str, &path_buf);
            vfs.unlinkNode(resolved, true) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            res = 0;
        },

        SYS_UNLINK, SYS_UNLINKAT => {
            const path_ptr = if (num == SYS_UNLINKAT) a2 else a1;
            const flags = if (num == SYS_UNLINKAT) a3 else 0;
            const path_str = getUserString(path_ptr, 256) orelse {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            };
            var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
            const resolved = vfs.resolveTaskPath(cur_task.cwd(), path_str, &path_buf);
            vfs.unlinkNode(resolved, flags == vfs.AT_REMOVEDIR) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            res = 0;
        },

        SYS_GETDENTS64 => {
            const fd = a1;
            const dirp_ptr = a2;
            const count = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind != .VFS_FILE) {
                res = errno_mod.toReturn(.EBADF);
            } else if (!validateUserBuffer(dirp_ptr, count)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                procfs.syncProcessNodes();
                const entry = &cur_task.fd_table[fd];
                const dst = @as([*]u8, @ptrFromInt(dirp_ptr))[0..count];
                const written = vfs.readDirEntries64(entry.node_idx, &entry.offset, dst);
                res = @intCast(written);
            }
        },

        SYS_ARCH_PRCTL => {
            res = sysArchPrctl(a1, a2);
        },

        SYS_CLOCK_GETTIME => {
            const clk_id = a1;
            _ = clk_id;
            const tp_ptr = a2;
            if (!validateUserBuffer(tp_ptr, @sizeOf(LinuxTimespec))) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const ts = @as(*LinuxTimespec, @ptrFromInt(tp_ptr));
                const current_ticks = timer.getTicks();
                ts.tv_sec = @intCast(current_ticks / timer.HZ);
                ts.tv_nsec = @intCast((current_ticks % timer.HZ) * 10_000_000);
                res = 0;
            }
        },

        SYS_READLINK, SYS_READLINKAT => {
            const path_ptr = if (num == SYS_READLINKAT) a2 else a1;
            const buf_ptr = if (num == SYS_READLINKAT) a3 else a2;
            const bufsiz = if (num == SYS_READLINKAT) a4 else a3;
            const path_str = getUserString(path_ptr, 256) orelse {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            };
            if (!validateUserBuffer(buf_ptr, bufsiz)) {
                res = errno_mod.toReturn(.EFAULT);
            } else if (std.mem.eql(u8, path_str, "/proc/self/exe")) {
                const exe_path = cur_task.comm();
                const copy_len = @min(exe_path.len, bufsiz);
                @memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..copy_len], exe_path[0..copy_len]);
                res = @intCast(copy_len);
            } else {
                res = errno_mod.toReturn(.ENOENT);
            }
        },

        else => res = errno_mod.toReturn(.ENOSYS),
    }
    }

    if (do_block) {
        // Rewind rip to re-execute syscall when woken
        frame.user_rip -= 2;
        cur_task.saved_frame = frame;
        const next_idx = task.scheduleNextOrWait();
        task.activateTask(next_idx);
        return task.tasks[next_idx].saved_frame;
    }

    frame.rax = @bitCast(res);

    // Profiler & strace logging
    if (task.currentTask().pid == orig_pid and frame.user_rip == orig_rip) {
        const elapsed = profiler.readTsc() -% start_tsc;
        profiler.recordSample(num, elapsed, res);
        strace.traceSyscall(num, a1, a2, a3, a4, orig_rip, res);
    }

    return frame;
}

fn handleOpenat(dirfd: isize, path_str: []const u8, flags: u32, mode: u32) isize {
    const cur_task = task.currentTask();
    if (path_str.len == 0) return errno_mod.toReturn(.ENOENT);

    var base_dir: []const u8 = "";
    if (path_str[0] == '/') {
        base_dir = "";
    } else if (dirfd == vfs.AT_FDCWD) {
        base_dir = cur_task.cwd();
    } else if (dirfd >= 0 and dirfd < vfs.MAX_OPEN_FILES) {
        const ufd: usize = @intCast(dirfd);
        if (cur_task.fd_table[ufd].kind != .VFS_FILE) return errno_mod.toReturn(.ENOTDIR);
        const dnode = vfs.getNode(cur_task.fd_table[ufd].node_idx);
        if (!dnode.isDir()) return errno_mod.toReturn(.ENOTDIR);
        base_dir = dnode.name();
    } else {
        return errno_mod.toReturn(.EBADF);
    }

    procfs.refreshDynamicNodes();
    var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
    const resolved = vfs.resolveTaskPath(base_dir, path_str, &path_buf);

    var node_idx = vfs.lookup(resolved);
    const creat = (flags & vfs.O_CREAT) != 0;
    const excl = (flags & vfs.O_EXCL) != 0;
    const trunc = (flags & vfs.O_TRUNC) != 0;
    const is_dir = (flags & vfs.O_DIRECTORY) != 0;

    if (node_idx == null) {
        if (creat) {
            node_idx = vfs.createNode(resolved, vfs.S_IFREG | (mode & 0o777)) catch |err| {
                return errno_mod.toReturn(err);
            };
        } else {
            return errno_mod.toReturn(.ENOENT);
        }
    } else {
        const target_node = vfs.getNode(node_idx.?);
        if (creat and excl) {
            return errno_mod.toReturn(.EEXIST);
        }
        if (is_dir and !target_node.isDir()) {
            return errno_mod.toReturn(.ENOTDIR);
        }
        if (target_node.isDir() and ((flags & 0x03) == vfs.O_WRONLY or (flags & 0x03) == vfs.O_RDWR)) {
            return errno_mod.toReturn(.EISDIR);
        }
        if (trunc and !target_node.isDir()) {
            vfs.truncateNode(node_idx.?);
        }
    }

    var fd_slot: ?usize = null;
    for (&cur_task.fd_table, 0..) |*e, i| {
        if (e.kind == .UNUSED) {
            fd_slot = i;
            break;
        }
    }

    if (fd_slot) |fd| {
        const cloexec = (flags & vfs.O_CLOEXEC) != 0;
        cur_task.fd_table[fd] = .{
            .kind = .VFS_FILE,
            .node_idx = node_idx.?,
            .offset = 0,
            .flags = flags,
            .cloexec = cloexec,
        };
        return @intCast(fd);
    }
    return errno_mod.toReturn(.EMFILE);
}

fn handleOpen(path_str: []const u8, flags: u32, mode: u32) isize {
    return handleOpenat(vfs.AT_FDCWD, path_str, flags, mode);
}

fn handleFstat(fd: usize, stat_ptr: usize) isize {
    const cur_task = task.currentTask();
    if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
        return errno_mod.toReturn(.EBADF);
    }
    if (!validateUserBuffer(stat_ptr, @sizeOf(vfs.LinuxStat))) {
        return errno_mod.toReturn(.EFAULT);
    }
    const entry = &cur_task.fd_table[fd];
    const st = @as(*vfs.LinuxStat, @ptrFromInt(stat_ptr));
    switch (entry.kind) {
        .CONSOLE_IN, .CONSOLE_OUT, .CONSOLE_ERR => {
            st.* = .{
                .st_mode = vfs.S_IFCHR | 0o666,
                .st_rdev = 5,
            };
            return 0;
        },
        .VFS_FILE => {
            vfs.fillStat(entry.node_idx, st);
            return 0;
        },
        .PIPE_READ, .PIPE_WRITE => {
            st.* = .{
                .st_mode = vfs.S_IFIFO | 0o600,
            };
            return 0;
        },
        .SOCKET => {
            st.* = .{
                .st_mode = vfs.S_IFSOCK | 0o666,
            };
            return 0;
        },
        else => return errno_mod.toReturn(.EBADF),
    }
}

fn handleStatPath(dirfd: isize, path_str: []const u8, stat_ptr: usize, flags: u32) isize {
    const cur_task = task.currentTask();
    if (!validateUserBuffer(stat_ptr, @sizeOf(vfs.LinuxStat))) {
        return errno_mod.toReturn(.EFAULT);
    }

    if (path_str.len == 0) {
        if ((flags & AT_EMPTY_PATH) != 0) {
            if (dirfd == vfs.AT_FDCWD) {
                var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
                const resolved = vfs.resolveTaskPath("", cur_task.cwd(), &path_buf);
                if (vfs.lookup(resolved)) |n_idx| {
                    const st = @as(*vfs.LinuxStat, @ptrFromInt(stat_ptr));
                    vfs.fillStat(n_idx, st);
                    return 0;
                }
                return errno_mod.toReturn(.ENOENT);
            } else if (dirfd >= 0 and dirfd < vfs.MAX_OPEN_FILES) {
                return handleFstat(@intCast(dirfd), stat_ptr);
            } else {
                return errno_mod.toReturn(.EBADF);
            }
        }
        return errno_mod.toReturn(.ENOENT);
    }

    var base_dir: []const u8 = "";
    if (path_str[0] == '/') {
        base_dir = "";
    } else if (dirfd == vfs.AT_FDCWD) {
        base_dir = cur_task.cwd();
    } else if (dirfd >= 0 and dirfd < vfs.MAX_OPEN_FILES) {
        const ufd: usize = @intCast(dirfd);
        if (cur_task.fd_table[ufd].kind != .VFS_FILE) return errno_mod.toReturn(.ENOTDIR);
        const dnode = vfs.getNode(cur_task.fd_table[ufd].node_idx);
        if (!dnode.isDir()) return errno_mod.toReturn(.ENOTDIR);
        base_dir = dnode.name();
    } else {
        return errno_mod.toReturn(.EBADF);
    }

    procfs.refreshDynamicNodes();
    var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
    const resolved = vfs.resolveTaskPath(base_dir, path_str, &path_buf);
    if (vfs.lookup(resolved)) |n_idx| {
        const st = @as(*vfs.LinuxStat, @ptrFromInt(stat_ptr));
        vfs.fillStat(n_idx, st);
        return 0;
    }
    return errno_mod.toReturn(.ENOENT);
}

fn handleReadDirect(fd: usize, buf_ptr: usize, count: usize) isize {
    const cur_task = task.currentTask();
    const entry = &cur_task.fd_table[fd];
    const dst = @as([*]u8, @ptrFromInt(buf_ptr))[0..count];
    switch (entry.kind) {
        .CONSOLE_IN => {
            const r = tty.read(dst);
            return @intCast(r.n);
        },
        .VFS_FILE => {
            const node = vfs.getNode(entry.node_idx);
            const file_data = node.slice();
            if (entry.offset >= file_data.len) return 0;
            const avail = file_data.len - entry.offset;
            const to_read = @min(count, avail);
            @memcpy(dst[0..to_read], file_data[entry.offset .. entry.offset + to_read]);
            entry.offset += to_read;
            return @intCast(to_read);
        },
        .PIPE_READ => {
            const r = pipe_mod.read(entry.node_idx, dst);
            return @intCast(r.n);
        },
        .SOCKET => {
            const r = socket.readStream(entry.node_idx, dst);
            return @intCast(r.n);
        },
        else => return errno_mod.toReturn(.EBADF),
    }
}

fn handleWriteDirect(fd: usize, buf_ptr: usize, count: usize) isize {
    const cur_task = task.currentTask();
    const entry = &cur_task.fd_table[fd];
    const src = @as([*]const u8, @ptrFromInt(buf_ptr))[0..count];
    switch (entry.kind) {
        .CONSOLE_OUT, .CONSOLE_ERR => {
            serial.writeString(src);
            return @intCast(count);
        },
        .VFS_FILE => {
            const write_off = if ((entry.flags & vfs.O_APPEND) != 0) vfs.getNode(entry.node_idx).size else entry.offset;
            const written = vfs.writeNode(entry.node_idx, write_off, src) catch |err| return errno_mod.toReturn(err);
            entry.offset = write_off + written;
            return @intCast(written);
        },
        .PIPE_WRITE => {
            const r = pipe_mod.write(entry.node_idx, src);
            return @intCast(r.n);
        },
        .SOCKET => {
            const w = socket.writeStream(entry.node_idx, src) catch |err| return errno_mod.toReturn(err);
            return @intCast(w);
        },
        else => return errno_mod.toReturn(.EBADF),
    }
}

fn retainFd(entry: vfs.FdEntry) void {
    switch (entry.kind) {
        .PIPE_READ => pipe_mod.retainReader(entry.node_idx),
        .PIPE_WRITE => pipe_mod.retainWriter(entry.node_idx),
        .SOCKET => socket.retain(entry.node_idx),
        else => {},
    }
}

fn closeFdEntry(entry: *vfs.FdEntry) void {
    switch (entry.kind) {
        .PIPE_READ => pipe_mod.closeReader(entry.node_idx),
        .PIPE_WRITE => pipe_mod.closeWriter(entry.node_idx),
        .SOCKET => socket.close(entry.node_idx),
        else => {},
    }
    entry.* = .{};
}

fn copyFixed(dst: []u8, src: []const u8) void {
    const n = @min(dst.len - 1, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

var temp_strings: [16][]const u8 = undefined;
fn collectStrings(array_ptr: usize) []const []const u8 {
    if (array_ptr == 0) return &[_][]const u8{};
    const ptrs = @as([*]const usize, @ptrFromInt(array_ptr));
    var cnt: usize = 0;
    while (cnt < 16) : (cnt += 1) {
        const str_p = ptrs[cnt];
        if (str_p == 0) break;
        if (getUserString(str_p, 256)) |s| {
            temp_strings[cnt] = s;
        } else break;
    }
    return temp_strings[0..cnt];
}
