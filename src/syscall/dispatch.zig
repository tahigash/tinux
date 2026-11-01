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
const futex = @import("../proc/futex.zig");
const epoll = @import("../fs/epoll.zig");
const elf = @import("../proc/elf.zig");
const strace = @import("strace.zig");
const profiler = @import("profiler.zig");
const virtio_blk = @import("../drivers/virtio_blk.zig");
const tarfs = @import("../fs/tarfs.zig");
const virtio_net = @import("../drivers/virtio_net.zig");
const netstack = @import("../net/netstack.zig");
const signal = @import("../proc/signal.zig");

pub const SYS_READ: u64 = 0;
pub const SYS_WRITE: u64 = 1;
pub const SYS_OPEN: u64 = 2;
pub const SYS_CLOSE: u64 = 3;
pub const SYS_STAT: u64 = 4;
pub const SYS_FSTAT: u64 = 5;
pub const SYS_LSTAT: u64 = 6;
pub const SYS_POLL: u64 = 7;
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
pub const SYS_ACCESS: u64 = 21;
pub const SYS_PIPE: u64 = 22;
pub const SYS_DUP: u64 = 32;
pub const SYS_DUP2: u64 = 33;
pub const SYS_PAUSE: u64 = 34;
pub const SYS_NANOSLEEP: u64 = 35;
pub const SYS_ALARM: u64 = 37;
pub const SYS_SETITIMER: u64 = 38;
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
pub const SYS_FSYNC: u64 = 74;
pub const SYS_GETCWD: u64 = 79;
pub const SYS_CHDIR: u64 = 80;
pub const SYS_MKDIR: u64 = 83;
pub const SYS_RMDIR: u64 = 84;
pub const SYS_CREAT: u64 = 85;
pub const SYS_UNLINK: u64 = 87;
pub const SYS_READLINK: u64 = 89;
pub const SYS_GETTIMEOFDAY: u64 = 96;
pub const SYS_GETUID: u64 = 102;
pub const SYS_GETGID: u64 = 104;
pub const SYS_GETEUID: u64 = 107;
pub const SYS_GETEGID: u64 = 108;
pub const SYS_SETPGID: u64 = 109;
pub const SYS_GETPPID: u64 = 110;
pub const SYS_GETPGRP: u64 = 111;
pub const SYS_SETSID: u64 = 112;
pub const SYS_GETPGID: u64 = 121;
pub const SYS_ARCH_PRCTL: u64 = 158;
pub const SYS_SYNC: u64 = 162;
pub const SYS_MOUNT: u64 = 165;
pub const SYS_UMOUNT2: u64 = 166;
pub const SYS_GETTID: u64 = 186;
pub const SYS_FUTEX: u64 = 202;
pub const SYS_EPOLL_CREATE: u64 = 213;
pub const SYS_GETDENTS64: u64 = 217;
pub const SYS_SET_TID_ADDRESS: u64 = 218;
pub const SYS_CLOCK_GETTIME: u64 = 228;
pub const SYS_CLOCK_GETRES: u64 = 229;
pub const SYS_CLOCK_NANOSLEEP: u64 = 230;
pub const SYS_EXIT_GROUP: u64 = 231;
pub const SYS_EPOLL_WAIT: u64 = 232;
pub const SYS_EPOLL_CTL: u64 = 233;
pub const SYS_OPENAT: u64 = 257;
pub const SYS_MKDIRAT: u64 = 258;
pub const SYS_NEWFSTATAT: u64 = 262;
pub const SYS_UNLINKAT: u64 = 263;
pub const SYS_READLINKAT: u64 = 267;
pub const SYS_FACCESSAT: u64 = 269;
pub const SYS_PPOLL: u64 = 271;
pub const SYS_SET_ROBUST_LIST: u64 = 273;
pub const SYS_UTIMENSAT: u64 = 280;
pub const SYS_EPOLL_PWAIT: u64 = 281;
pub const SYS_ACCEPT4: u64 = 288;
pub const SYS_EPOLL_CREATE1: u64 = 291;
pub const SYS_DUP3: u64 = 292;
pub const SYS_PIPE2: u64 = 293;
pub const SYS_PRLIMIT64: u64 = 302;
pub const SYS_GETRANDOM: u64 = 318;
pub const SYS_STATX: u64 = 332;
pub const SYS_FACCESSAT2: u64 = 439;

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

pub const LinuxTimeval = extern struct {
    tv_sec: i64 align(1) = 0,
    tv_usec: i64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxTimeval) == 16);
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

fn sysExit(status: usize) *SyscallFrame {
    const cur = task.currentTask();
    if (cur.is_thread) {
        if (cur.clear_child_tid != 0) {
            if (vmm.translate(cur.pml4_phys, cur.clear_child_tid)) |pa| {
                std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(pa)), 0, .little);
                _ = futex.wakeByPaddr(pa, 1);
            }
            cur.clear_child_tid = 0;
        }
        cur.closeAllFds();
        cur.state = .UNUSED;
        cur.pid = 0;
        const next_idx = task.scheduleNextOrWait();
        task.activateTask(next_idx);
        return signal.deliverPendingSignals(task.tasks[next_idx].saved_frame);
    } else {
        if (cur.clear_child_tid != 0) {
            if (vmm.translate(cur.pml4_phys, cur.clear_child_tid)) |pa| {
                std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(pa)), 0, .little);
                _ = futex.wakeByPaddr(pa, 1);
            }
            cur.clear_child_tid = 0;
        }
        serial.print("[TINUX_SYSCALL] sys_exit({d}) received from Ring 3\n", .{status});
        if (cur.pid == 1) {
            if (status == 0) {
                serial.print("[TINUX_TEST] PASS: {s}\n", .{current_test_name});
                io.qemuExitSuccess();
            } else {
                serial.print("[TINUX_TEST] FAIL: {s} (exit status {d})\n", .{ current_test_name, status });
                io.qemuExitFailure();
            }
        }
        return task.exitCurrentTask(@intCast(status));
    }
}

fn sysExitGroup(status: usize) *SyscallFrame {
    const cur = task.currentTask();
    const tgid = if (cur.tgid != 0) cur.tgid else cur.pid;
    for (&task.tasks) |*t| {
        if (t.state != .UNUSED and (t.tgid == tgid or t.pid == tgid)) {
            if (t.clear_child_tid != 0) {
                if (vmm.translate(t.pml4_phys, t.clear_child_tid)) |pa| {
                    std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(pa)), 0, .little);
                    _ = futex.wakeByPaddr(pa, 1);
                }
                t.clear_child_tid = 0;
            }
            t.closeAllFds();
            if (t.pid != tgid) {
                t.state = .UNUSED;
                t.pid = 0;
            }
        }
    }
    serial.print("[TINUX_SYSCALL] sys_exit({d}) received from Ring 3\n", .{status});
    if (cur.pid == 1 or tgid == 1) {
        if (status == 0) {
            serial.print("[TINUX_TEST] PASS: {s}\n", .{current_test_name});
            io.qemuExitSuccess();
        } else {
            serial.print("[TINUX_TEST] FAIL: {s} (exit status {d})\n", .{ current_test_name, status });
            io.qemuExitFailure();
        }
    }
    return task.exitCurrentTask(@intCast(status));
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

pub fn sysPread64(fd: usize, buf_ptr: usize, count: usize, pos: usize) isize {
    if (count == 0) return 0;
    const cur_task = task.currentTask();
    if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
        return errno_mod.toReturn(.EBADF);
    }
    if (!validateUserBuffer(buf_ptr, count)) {
        return errno_mod.toReturn(.EFAULT);
    }
    const entry = &cur_task.fd_table[fd];
    switch (entry.kind) {
        .BLKDEV => {
            const dst = @as([*]u8, @ptrFromInt(buf_ptr))[0..count];
            const n = virtio_blk.readBytes(pos, dst);
            return @intCast(n);
        },
        .VFS_FILE => {
            const node = vfs.getNode(entry.node_idx);
            const file_data = node.slice();
            if (pos >= file_data.len) return 0;
            const avail = file_data.len - pos;
            const to_read = @min(count, avail);
            @memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..to_read], file_data[pos .. pos + to_read]);
            return @intCast(to_read);
        },
        else => return errno_mod.toReturn(.EBADF),
    }
}

pub fn sysReadlinkat(dirfd: isize, path_ptr: usize, buf_ptr: usize, bufsiz: usize) isize {
    _ = dirfd;
    const path_str = getUserString(path_ptr, 256) orelse {
        return errno_mod.toReturn(.EFAULT);
    };
    if (!validateUserBuffer(buf_ptr, bufsiz)) {
        return errno_mod.toReturn(.EFAULT);
    }
    const cur_task = task.currentTask();
    if (std.mem.eql(u8, path_str, "/proc/self/exe")) {
        const exe = cur_task.exePath();
        const copy_len = @min(exe.len, bufsiz);
        @memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..copy_len], exe[0..copy_len]);
        return @intCast(copy_len);
    }
    if (vfs.lookup(path_str)) |n_idx| {
        const node = vfs.getNode(n_idx);
        if ((node.mode & vfs.S_IFMT) == vfs.S_IFLNK) {
            const target = node.slice();
            const copy_len = @min(target.len, bufsiz);
            @memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..copy_len], target[0..copy_len]);
            return @intCast(copy_len);
        }
        return errno_mod.toReturn(.EINVAL);
    }
    return errno_mod.toReturn(.ENOENT);
}

pub fn sysSetTidAddress(tidptr: usize) usize {
    const cur_task = task.currentTask();
    cur_task.clear_child_tid = tidptr;
    return if (cur_task.pid != 0) cur_task.pid else 1;
}

fn sysMount(source_ptr: usize, target_ptr: usize, fstype_ptr: usize, flags: usize, data_ptr: usize) isize {
    _ = flags;
    _ = data_ptr;

    // 1. Validate & copy source device string from userspace (-EFAULT on invalid pointer)
    var source_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
    const source_str = readUserCString(source_ptr, &source_buf) catch |err| return errno_mod.toReturn(err);
    _ = source_str;

    // 2. Validate & copy target mount point path from userspace (-EFAULT on invalid pointer)
    var target_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
    const target_str = readUserCString(target_ptr, &target_buf) catch |err| return errno_mod.toReturn(err);
    if (target_str.len == 0) return errno_mod.toReturn(.ENOENT);

    // 3. Validate & copy filesystem type string from userspace (-EFAULT on invalid pointer)
    var fstype_buf: [64]u8 = undefined;
    const fstype_str = readUserCString(fstype_ptr, &fstype_buf) catch |err| return errno_mod.toReturn(err);

    // 4. Validate filesystem type (Tinux supports "tarfs" for block device mounts)
    if (!std.mem.eql(u8, fstype_str, "tarfs")) {
        return errno_mod.toReturn(.ENODEV);
    }

    // 5. Canonicalize target path and reject root / empty mount points
    const target_canonical = vfs.normalizePath(target_str);
    if (target_canonical.len == 0) return errno_mod.toReturn(.EINVAL);

    // 6. Verify mount point exists in VFS and is a directory (-ENOENT / -ENOTDIR)
    const target_idx = vfs.lookupExact(target_canonical) orelse return errno_mod.toReturn(.ENOENT);
    const node = vfs.getNode(target_idx);
    if (!node.isDir()) {
        return errno_mod.toReturn(.ENOTDIR);
    }

    // 7. Verify not already mounted (-EBUSY)
    if (tarfs.isMounted()) {
        return errno_mod.toReturn(.EBUSY);
    }

    // 8. Mount USTAR filesystem from block device and update dynamic /proc/mounts
    _ = tarfs.mountFromDisk(target_canonical) catch |err| return errno_mod.toReturn(err);
    procfs.refreshMounts();
    return 0;
}

fn sysUmount2(target_ptr: usize, flags: usize) isize {
    _ = flags;
    var target_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
    const target_str = readUserCString(target_ptr, &target_buf) catch |err| return errno_mod.toReturn(err);
    const target_canonical = vfs.normalizePath(target_str);
    if (!tarfs.isMounted() or !std.mem.eql(u8, target_canonical, tarfs.mountPrefix())) {
        return errno_mod.toReturn(.EINVAL);
    }
    tarfs.syncToDisk() catch |err| return errno_mod.toReturn(err);
    vfs.unmountChildNodes(tarfs.mountPrefix());
    tarfs.setMounted(false);
    procfs.refreshMounts();
    return 0;
}

fn resolveAtBaseDir(dirfd: isize, path_str: []const u8) Errno![]const u8 {
    const cur_task = task.currentTask();
    if (path_str.len > 0 and path_str[0] == '/') {
        return "";
    }
    if (dirfd == vfs.AT_FDCWD) {
        return cur_task.cwd();
    }
    if (dirfd >= 0 and dirfd < vfs.MAX_OPEN_FILES) {
        const ufd: usize = @intCast(dirfd);
        if (cur_task.fd_table[ufd].kind == .UNUSED) return Errno.EBADF;
        if (cur_task.fd_table[ufd].kind != .VFS_FILE) return Errno.ENOTDIR;
        const dnode = vfs.getNode(cur_task.fd_table[ufd].node_idx);
        if (!dnode.isDir()) return Errno.ENOTDIR;
        return dnode.name();
    }
    return Errno.EBADF;
}

fn handleUnlinkat(dirfd: isize, path_str: []const u8, flags: usize) isize {
    const base_dir = resolveAtBaseDir(dirfd, path_str) catch |err| {
        return errno_mod.toReturn(err);
    };
    var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
    const resolved = vfs.resolveTaskPath(base_dir, path_str, &path_buf);
    vfs.unlinkNode(resolved, (flags & vfs.AT_REMOVEDIR) != 0) catch |err| {
        return errno_mod.toReturn(err);
    };
    return 0;
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
    const a5 = frame.r8;
    const a6 = frame.r9;

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
                        switch (r) {
                            .bytes => |n| res = @intCast(n),
                            .eof => res = 0,
                            .would_block => {
                                if ((entry.flags & vfs.O_NONBLOCK) != 0) {
                                    res = errno_mod.toReturn(.EAGAIN);
                                } else {
                                    cur_task.state = .WAITING_TTY;
                                    do_block = true;
                                }
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
                                if ((entry.flags & 0x800) != 0) {
                                    res = errno_mod.toReturn(.EAGAIN);
                                } else {
                                    cur_task.state = .WAITING_PIPE_READ;
                                    cur_task.wait_pipe_idx = entry.node_idx;
                                    do_block = true;
                                }
                            },
                        }
                    },
                    .SOCKET => {
                        const s_idx = if (entry.sock_idx != 0) entry.sock_idx else entry.node_idx;
                        if (socket.sockets[s_idx].sock_type == socket.SOCK_DGRAM and socket.sockets[s_idx].proto != 1) {
                            virtio_net.pollRx();
                        }
                        const r = socket.read(s_idx, dst);
                        switch (r) {
                            .bytes => |n| res = @intCast(n),
                            .eof => res = 0,
                            .would_block => {
                                if ((entry.flags & vfs.O_NONBLOCK) != 0 or socket.sockets[s_idx].nonblock) {
                                    res = errno_mod.toReturn(.EAGAIN);
                                } else {
                                    cur_task.state = .WAITING_SOCK_READ;
                                    cur_task.wait_sock_idx = s_idx;
                                    do_block = true;
                                }
                            },
                        }
                    },
                    .BLKDEV => {
                        const n = virtio_blk.readBytes(entry.offset, dst);
                        entry.offset += n;
                        res = @intCast(n);
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
                    .CONSOLE_IN, .CONSOLE_OUT, .CONSOLE_ERR => {
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
                                if ((entry.flags & 0x800) != 0) {
                                    res = errno_mod.toReturn(.EAGAIN);
                                } else {
                                    cur_task.state = .WAITING_PIPE_WRITE;
                                    cur_task.wait_pipe_idx = entry.node_idx;
                                    do_block = true;
                                }
                            },
                        }
                    },
                    .SOCKET => {
                        const s_idx = if (entry.sock_idx != 0) entry.sock_idx else entry.node_idx;
                        if (socket.sockets[s_idx].sock_type == socket.SOCK_DGRAM and socket.sockets[s_idx].proto != 1) {
                            const local_port = socket.ensureBoundPort(s_idx);
                            if (socket.sockets[s_idx].state != .CONNECTED or socket.sockets[s_idx].peer_port == 0) {
                                res = errno_mod.toReturn(.EDESTADDRREQ);
                                break :blk;
                            }
                            const dst_ip = socket.sockets[s_idx].peer_ip;
                            const dst_port = socket.sockets[s_idx].peer_port;

                            if (dst_ip[0] == 127 or std.mem.eql(u8, &dst_ip, &netstack.OUR_IP)) {
                                _ = socket.deliverUdpDatagram(dst_ip, local_port, dst_port, src);
                            } else {
                                _ = netstack.sendUdpPacket(local_port, dst_ip, dst_port, src);
                            }
                            res = @intCast(src.len);
                        } else {
                            const w = socket.write(s_idx, src) catch |err| {
                                res = errno_mod.toReturn(err);
                                break :blk;
                            };
                            if (socket.sockets[s_idx].peer_idx) |p_idx| {
                                task.wakeSocketReadWaiters(p_idx);
                            }
                            res = @intCast(w);
                        }
                    },
                    .BLKDEV => {
                        const n = virtio_blk.writeBytes(entry.offset, src);
                        entry.offset += n;
                        res = @intCast(n);
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
                    .SOCKET => {
                        const s_idx = if (entry.sock_idx != 0) entry.sock_idx else entry.node_idx;
                        if (socket.close(s_idx)) |peer_idx| {
                            task.wakeSocketReadWaiters(peer_idx);
                        }
                    },
                    .EPOLL => epoll.close(entry.node_idx),
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

        SYS_POLL, SYS_PPOLL => {
            res = handlePoll(a1, a2);
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
                    .BLKDEV => {
                        const dev_size: i64 = @intCast(virtio_blk.getCapacityBytes());
                        const curr_off: i64 = @intCast(entry.offset);
                        var new_off: i64 = 0;
                        switch (whence) {
                            SEEK_SET => new_off = offset,
                            SEEK_CUR => new_off = curr_off + offset,
                            SEEK_END => new_off = dev_size + offset,
                            else => {
                                res = errno_mod.toReturn(.EINVAL);
                                break :blk;
                            },
                        }
                        if (new_off < 0 or new_off > dev_size) {
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

            if (len == 0) {
                res = errno_mod.toReturn(.EINVAL);
            } else {
                const MAP_FIXED: usize = 0x10;
                const MAP_ANONYMOUS: usize = 0x20;
                const aligned_len = std.mem.alignForward(usize, len, vmm.PAGE_SIZE);
                const is_fixed = (flags & MAP_FIXED) != 0;
                const is_anon = (flags & MAP_ANONYMOUS) != 0;
                const is_fixed_effective = is_fixed and addr != 0;
                const base_vaddr = if (is_fixed_effective) (addr & ~@as(usize, 0xFFF)) else cur_task.next_mmap_vaddr;

                var v = base_vaddr;
                const top = base_vaddr + aligned_len;
                while (v < top) : (v += vmm.PAGE_SIZE) {
                    if (is_fixed_effective) {
                        const p = pmm.allocZeroedPage() orelse {
                            res = errno_mod.toReturn(.ENOMEM);
                            break :blk;
                        };
                        _ = vmm.mapPage(cur_task.pml4_phys, v, p, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
                    } else {
                        if (vmm.translate(cur_task.pml4_phys, v) == null) {
                            const p = pmm.allocZeroedPage() orelse {
                                res = errno_mod.toReturn(.ENOMEM);
                                break :blk;
                            };
                            _ = vmm.mapPage(cur_task.pml4_phys, v, p, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
                        }
                    }
                }

                if (!is_anon and fd < vfs.MAX_OPEN_FILES and cur_task.fd_table[fd].kind == .VFS_FILE) {
                    const node = vfs.getNode(cur_task.fd_table[fd].node_idx);
                    const file_slice = node.slice();
                    if (offset < file_slice.len) {
                        const avail = file_slice.len - offset;
                        const copy_len = @min(avail, len);
                        @memcpy(@as([*]u8, @ptrFromInt(base_vaddr))[0..copy_len], file_slice[offset .. offset + copy_len]);
                    }
                }

                if (!is_fixed_effective) {
                    cur_task.next_mmap_vaddr = top;
                }
                res = @intCast(base_vaddr);
            }
        },

        SYS_MPROTECT => res = 0,
        SYS_MUNMAP => res = 0,

        SYS_RT_SIGACTION => {
            const sig = a1;
            const act_ptr = a2;
            const oact_ptr = a3;
            const sigsetsize = a4;

            if (sig == 0 or sig > 64 or sig == signal.SIGKILL or sig == signal.SIGSTOP) {
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }
            if (sigsetsize != 8) {
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }
            if (oact_ptr != 0) {
                if (!validateUserBuffer(oact_ptr, @sizeOf(signal.KernelSigAction))) {
                    res = errno_mod.toReturn(.EFAULT);
                    break :blk;
                }
                const oact = @as(*signal.KernelSigAction, @ptrFromInt(oact_ptr));
                oact.* = cur_task.sigactions[sig];
            }
            if (act_ptr != 0) {
                if (!validateUserBuffer(act_ptr, @sizeOf(signal.KernelSigAction))) {
                    res = errno_mod.toReturn(.EFAULT);
                    break :blk;
                }
                const act = @as(*const signal.KernelSigAction, @ptrFromInt(act_ptr));
                cur_task.sigactions[sig] = act.*;
                cur_task.sigactions[sig].sa_mask &= ~signal.UNMASKABLE_SIGNALS;
            }
            res = 0;
        },

        SYS_RT_SIGPROCMASK => {
            const how = a1;
            const set_ptr = a2;
            const oset_ptr = a3;
            const sigsetsize = a4;

            if (sigsetsize != 8) {
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }
            if (oset_ptr != 0) {
                if (!validateUserBuffer(oset_ptr, 8)) {
                    res = errno_mod.toReturn(.EFAULT);
                    break :blk;
                }
                std.mem.writeInt(u64, @as(*[8]u8, @ptrFromInt(oset_ptr)), cur_task.sig_mask, .little);
            }
            if (set_ptr != 0) {
                if (!validateUserBuffer(set_ptr, 8)) {
                    res = errno_mod.toReturn(.EFAULT);
                    break :blk;
                }
                const set_val = std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(set_ptr)), .little);
                switch (how) {
                    signal.SIG_BLOCK => cur_task.sig_mask |= set_val,
                    signal.SIG_UNBLOCK => cur_task.sig_mask &= ~set_val,
                    signal.SIG_SETMASK => cur_task.sig_mask = set_val,
                    else => {
                        res = errno_mod.toReturn(.EINVAL);
                        break :blk;
                    },
                }
                cur_task.sig_mask &= ~signal.UNMASKABLE_SIGNALS;
            }
            res = 0;
        },

        SYS_RT_SIGRETURN => return signal.restoreSignalFrame(frame),

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
                    res = tty.handleIoctl(req, arg, &validateUserBuffer) catch |err| errno_mod.toReturn(err);
                }
            }
        },

        SYS_PREAD64 => {
            res = sysPread64(a1, a2, a3, a4);
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
            const flags: u32 = if (num == SYS_PIPE) 0 else @truncate(a2);
            if (num == SYS_PIPE2) {
                if ((flags & ~@as(u32, 0x80000 | 0x800)) != 0) {
                    res = errno_mod.toReturn(.EINVAL);
                    break :blk;
                }
            }
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
                    const cloexec = (flags & 0x80000) != 0;
                    cur_task.fd_table[r_fd.?] = .{
                        .kind = .PIPE_READ,
                        .node_idx = p_idx,
                        .flags = (flags & 0x800),
                        .cloexec = cloexec,
                    };
                    cur_task.fd_table[w_fd.?] = .{
                        .kind = .PIPE_WRITE,
                        .node_idx = p_idx,
                        .flags = (flags & 0x800),
                        .cloexec = cloexec,
                    };

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
            if (num == SYS_DUP3) {
                if (oldfd == newfd) {
                    res = errno_mod.toReturn(.EINVAL);
                    break :blk;
                }
                if (a3 != 0 and a3 != 0x80000) {
                    res = errno_mod.toReturn(.EINVAL);
                    break :blk;
                }
            }
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
                if (ts.tv_sec < 0 or ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) {
                    res = errno_mod.toReturn(.EINVAL);
                } else {
                    const sec_u: u64 = @intCast(ts.tv_sec);
                    const nsec_u: u64 = @intCast(ts.tv_nsec);
                    const duration_ticks = sec_u * timer.HZ + (nsec_u + 9_999_999) / 10_000_000;
                    const wait_ticks = @max(duration_ticks, 1);

                    cur_task.wake_tick = timer.getTicks() + wait_ticks;
                    cur_task.sleep_wake_tick = cur_task.wake_tick;
                    cur_task.state = .WAITING_SLEEP;

                    frame.rax = 0; // Return 0 upon wake
                    cur_task.saved_frame = frame;

                    const next_idx = task.scheduleNextOrWait();
                    task.activateTask(next_idx);
                    return signal.deliverPendingSignals(task.tasks[next_idx].saved_frame);
                }
            }
        },

        SYS_GETPID => res = @intCast(if (cur_task.tgid != 0) cur_task.tgid else (if (cur_task.pid != 0) cur_task.pid else 1)),
        SYS_GETPPID => res = @intCast(cur_task.parent_pid),
        SYS_GETUID, SYS_GETGID, SYS_GETEUID, SYS_GETEGID => res = 0,
        SYS_GETTID => res = @intCast(if (cur_task.pid != 0) cur_task.pid else 1),
        SYS_SET_ROBUST_LIST, SYS_PRLIMIT64 => res = 0,
        SYS_SET_TID_ADDRESS => {
            cur_task.clear_child_tid = a1;
            res = @intCast(if (cur_task.pid != 0) cur_task.pid else 1);
        },

        SYS_GETTIMEOFDAY => {
            const tv_ptr = a1;
            const tz_ptr = a2;
            _ = tz_ptr;
            if (tv_ptr != 0) {
                if (!validateUserBuffer(tv_ptr, @sizeOf(LinuxTimeval))) {
                    res = errno_mod.toReturn(.EFAULT);
                } else {
                    const tv = @as(*LinuxTimeval, @ptrFromInt(tv_ptr));
                    const current_ticks = timer.getTicks();
                    tv.tv_sec = @intCast(current_ticks / timer.HZ);
                    tv.tv_usec = @intCast((current_ticks % timer.HZ) * 10_000);
                    res = 0;
                }
            } else {
                res = 0;
            }
        },

        SYS_SOCKET => {
            const domain: u16 = @truncate(a1);
            const base_type: u32 = @truncate(a2 & 0xFF);
            const flags: u32 = @truncate(a2 & ~@as(u64, 0xFF));
            const proto: u32 = @truncate(a3);
            const is_nonblock = (flags & socket.SOCK_NONBLOCK) != 0;
            const is_cloexec = (flags & socket.SOCK_CLOEXEC) != 0;
            if (domain != socket.AF_UNIX and domain != socket.AF_INET) {
                res = errno_mod.toReturn(.EAFNOSUPPORT);
            } else if (base_type != socket.SOCK_STREAM and base_type != socket.SOCK_DGRAM and base_type != socket.SOCK_RAW) {
                res = errno_mod.toReturn(.EINVAL);
            } else {
                const s_idx = socket.alloc(domain, base_type, is_nonblock) orelse {
                    res = errno_mod.toReturn(.ENOBUFS);
                    break :blk;
                };
                socket.sockets[s_idx].proto = proto;
                if (vfs.allocFd(&cur_task.fd_table, 0)) |fd| {
                    cur_task.fd_table[fd] = .{
                        .kind = .SOCKET,
                        .node_idx = s_idx,
                        .sock_idx = s_idx,
                        .cloexec = is_cloexec,
                        .flags = if (is_nonblock) vfs.O_NONBLOCK else 0,
                    };
                    res = @intCast(fd);
                } else {
                    _ = socket.close(s_idx);
                    res = errno_mod.toReturn(.EMFILE);
                }
            }
        },

        SYS_BIND => {
            const fd = a1;
            const addr_ptr = a2;
            const addr_len = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else {
                const s_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                const dom = socket.sockets[s_idx].domain;
                if (dom == socket.AF_INET) {
                    if (!validateUserBuffer(addr_ptr, @sizeOf(socket.SockAddrIn)) or addr_len < @sizeOf(socket.SockAddrIn)) {
                        res = errno_mod.toReturn(.EFAULT);
                    } else {
                        const sin = @as(*align(1) const socket.SockAddrIn, @ptrFromInt(addr_ptr)).*;
                        const host_port = std.mem.bigToNative(u16, sin.sin_port);
                        socket.bindInet(s_idx, host_port) catch |err| {
                            res = errno_mod.toReturn(err);
                            break :blk;
                        };
                        if (socket.sockets[s_idx].sock_type == socket.SOCK_DGRAM and socket.sockets[s_idx].proto != 1) {
                            procfs.recordUdpHistory(host_port);
                        }
                        res = 0;

                    }
                } else if (dom == socket.AF_UNIX) {
                    if (!validateUserBuffer(addr_ptr, 2) or addr_len < 2) {
                        res = errno_mod.toReturn(.EFAULT);
                    } else {
                        const sun = @as(*align(1) const socket.SockAddrUn, @ptrFromInt(addr_ptr)).*;
                        const max_p = @min(addr_len - 2, 108);
                        var p_len: usize = 0;
                        while (p_len < max_p and sun.sun_path[p_len] != 0) : (p_len += 1) {}
                        socket.bindUnix(s_idx, sun.sun_path[0..p_len]) catch |err| {
                            res = errno_mod.toReturn(err);
                            break :blk;
                        };
                        res = 0;
                    }
                } else {
                    res = errno_mod.toReturn(.EINVAL);
                }
            }
        },

        SYS_LISTEN => {
            const fd = a1;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else {
                const s_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                socket.listen(s_idx) catch |err| {
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
            const flags: u32 = if (num == SYS_ACCEPT4) @truncate(a4) else 0;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else {
                const l_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                if (socket.sockets[l_idx].state != .LISTENING) {
                    res = errno_mod.toReturn(.EINVAL);
                    break :blk;
                }
                const is_nonblock = (flags & socket.SOCK_NONBLOCK) != 0 or socket.sockets[l_idx].nonblock or (cur_task.fd_table[fd].flags & vfs.O_NONBLOCK) != 0;
                const is_cloexec = (flags & socket.SOCK_CLOEXEC) != 0;

                if (socket.popAccept(l_idx)) |conn_idx| {
                    if (vfs.allocFd(&cur_task.fd_table, 0)) |new_fd| {
                        cur_task.fd_table[new_fd] = .{
                            .kind = .SOCKET,
                            .node_idx = conn_idx,
                            .sock_idx = conn_idx,
                            .cloexec = is_cloexec,
                            .flags = if (is_nonblock) vfs.O_NONBLOCK else 0,
                        };
                        if (is_nonblock) {
                            socket.sockets[conn_idx].nonblock = true;
                        }

                        if (addr_ptr != 0 and addr_len_ptr != 0) {
                            if (socket.sockets[conn_idx].domain == socket.AF_INET) {
                                if (validateUserBuffer(addr_ptr, @sizeOf(socket.SockAddrIn)) and validateUserBuffer(addr_len_ptr, 4)) {
                                    const peer_port = if (socket.sockets[conn_idx].peer_idx) |p| socket.sockets[p].bound_port else 0;
                                    const sin_out = socket.SockAddrIn{
                                        .sin_family = socket.AF_INET,
                                        .sin_port = std.mem.nativeToBig(u16, peer_port),
                                        .sin_addr = 0x0100007F,
                                    };
                                    @as(*socket.SockAddrIn, @ptrFromInt(addr_ptr)).* = sin_out;
                                    @as(*u32, @ptrFromInt(addr_len_ptr)).* = @sizeOf(socket.SockAddrIn);
                                }
                            } else if (socket.sockets[conn_idx].domain == socket.AF_UNIX) {
                                if (validateUserBuffer(addr_ptr, @sizeOf(socket.SockAddrUn)) and validateUserBuffer(addr_len_ptr, 4)) {
                                    var sun_out = socket.SockAddrUn{ .sun_family = socket.AF_UNIX };
                                    if (socket.sockets[conn_idx].peer_idx) |p| {
                                        const p_len = socket.sockets[p].bound_path_len;
                                        @memcpy(sun_out.sun_path[0..p_len], socket.sockets[p].bound_path[0..p_len]);
                                    }
                                    @as(*socket.SockAddrUn, @ptrFromInt(addr_ptr)).* = sun_out;
                                    @as(*u32, @ptrFromInt(addr_len_ptr)).* = @sizeOf(socket.SockAddrUn);
                                }
                            }
                        }
                        res = @intCast(new_fd);
                    } else {
                        _ = socket.close(conn_idx);
                        res = errno_mod.toReturn(.EMFILE);
                    }
                } else {
                    if (is_nonblock) {
                        res = errno_mod.toReturn(.EAGAIN);
                    } else {
                        cur_task.state = .WAITING_SOCK_ACCEPT;
                        cur_task.wait_sock_idx = l_idx;
                        do_block = true;
                    }
                }
            }
        },

        SYS_CONNECT => {
            const fd = a1;
            const addr_ptr = a2;
            const addr_len = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else {
                const s_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                const dom = socket.sockets[s_idx].domain;
                if (socket.sockets[s_idx].sock_type == socket.SOCK_DGRAM and socket.sockets[s_idx].proto != 1) {
                    if (!validateUserBuffer(addr_ptr, @sizeOf(socket.SockAddrIn)) or addr_len < @sizeOf(socket.SockAddrIn)) {
                        res = errno_mod.toReturn(.EFAULT);
                    } else {
                        const sin = @as(*align(1) const socket.SockAddrIn, @ptrFromInt(addr_ptr)).*;
                        const target_port = std.mem.bigToNative(u16, sin.sin_port);
                        const target_ip = @as(*const [4]u8, @ptrFromInt(addr_ptr + 4)).*;
                        _ = socket.ensureBoundPort(s_idx);
                        socket.sockets[s_idx].peer_ip = target_ip;
                        socket.sockets[s_idx].peer_port = target_port;
                        socket.sockets[s_idx].state = .CONNECTED;
                        res = 0;
                    }
                    break :blk;
                }
                if (dom == socket.AF_INET) {
                    if (!validateUserBuffer(addr_ptr, @sizeOf(socket.SockAddrIn)) or addr_len < @sizeOf(socket.SockAddrIn)) {
                        res = errno_mod.toReturn(.EFAULT);
                    } else {
                        const sin = @as(*align(1) const socket.SockAddrIn, @ptrFromInt(addr_ptr)).*;
                        const target_port = std.mem.bigToNative(u16, sin.sin_port);
                        const l_idx = socket.connectInet(s_idx, target_port) catch |err| {
                            res = errno_mod.toReturn(err);
                            break :blk;
                        };
                        task.wakeSocketAcceptWaiters(l_idx);
                        res = 0;
                    }
                } else if (dom == socket.AF_UNIX) {
                    if (!validateUserBuffer(addr_ptr, 2) or addr_len < 2) {
                        res = errno_mod.toReturn(.EFAULT);
                    } else {
                        const sun = @as(*align(1) const socket.SockAddrUn, @ptrFromInt(addr_ptr)).*;
                        const max_p = @min(addr_len - 2, 108);
                        var p_len: usize = 0;
                        while (p_len < max_p and sun.sun_path[p_len] != 0) : (p_len += 1) {}
                        const l_idx = socket.connectUnix(s_idx, sun.sun_path[0..p_len]) catch |err| {
                            res = errno_mod.toReturn(err);
                            break :blk;
                        };
                        task.wakeSocketAcceptWaiters(l_idx);
                        res = 0;
                    }
                } else {
                    res = errno_mod.toReturn(.EINVAL);
                }
            }
        },

        SYS_SENDTO => {
            const fd = a1;
            const buf_ptr = a2;
            const len = a3;
            const dest_addr_ptr = a5;
            const dest_addr_len = a6;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else if (len == 0) {
                res = 0;
            } else if (!validateUserBuffer(buf_ptr, len)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const s_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                const src = @as([*]const u8, @ptrFromInt(buf_ptr))[0..len];
                if (socket.sockets[s_idx].sock_type == socket.SOCK_DGRAM and socket.sockets[s_idx].proto != 1) {
                    const local_port = socket.ensureBoundPort(s_idx);
                    var dst_ip: [4]u8 = undefined;
                    var dst_port: u16 = 0;
                    if (dest_addr_ptr != 0) {
                        if (dest_addr_len < 16 or !validateUserBuffer(dest_addr_ptr, 16)) {
                            res = errno_mod.toReturn(.EINVAL);
                            break :blk;
                        }
                        const sin = @as(*align(1) const socket.SockAddrIn, @ptrFromInt(dest_addr_ptr)).*;
                        dst_port = std.mem.bigToNative(u16, sin.sin_port);
                        dst_ip = @as(*const [4]u8, @ptrFromInt(dest_addr_ptr + 4)).*;
                    } else {
                        if (socket.sockets[s_idx].state != .CONNECTED or socket.sockets[s_idx].peer_port == 0) {
                            res = errno_mod.toReturn(.EDESTADDRREQ);
                            break :blk;
                        }
                        dst_ip = socket.sockets[s_idx].peer_ip;
                        dst_port = socket.sockets[s_idx].peer_port;
                    }

                    if (dst_ip[0] == 127 or std.mem.eql(u8, &dst_ip, &netstack.OUR_IP)) {
                        _ = socket.deliverUdpDatagram(dst_ip, local_port, dst_port, src);
                    } else {
                        _ = netstack.sendUdpPacket(local_port, dst_ip, dst_port, src);
                    }
                    res = @intCast(src.len);
                    break :blk;
                }

                if (socket.sockets[s_idx].domain == socket.AF_INET and (socket.sockets[s_idx].proto == 1 or socket.sockets[s_idx].sock_type == socket.SOCK_RAW)) {
                    if (dest_addr_ptr == 0 or dest_addr_len < 16 or !validateUserBuffer(dest_addr_ptr, 16)) {
                        res = errno_mod.toReturn(.EINVAL);
                        break :blk;
                    }
                    if (len < 8) {
                        res = errno_mod.toReturn(.EINVAL);
                        break :blk;
                    }
                    const dest_ip = @as(*const [4]u8, @ptrFromInt(dest_addr_ptr + 4)).*;
                    const id_be = std.mem.readInt(u16, src[4..6], .little);
                    const seq_be = std.mem.readInt(u16, src[6..8], .little);
                    const payload = src[8..];
                    if (netstack.sendIcmpEchoRequest(dest_ip, id_be, seq_be, payload)) {
                        res = @intCast(len);
                    } else {
                        res = errno_mod.toReturn(.EIO);
                    }
                    break :blk;
                }

                const w = socket.write(s_idx, src) catch |err| {
                    res = errno_mod.toReturn(err);
                    break :blk;
                };
                if (socket.sockets[s_idx].peer_idx) |p_idx| {
                    task.wakeSocketReadWaiters(p_idx);
                }
                res = @intCast(w);
            }
        },

        SYS_RECVFROM => {
            const fd = a1;
            const buf_ptr = a2;
            const len = a3;
            const src_addr_ptr = a5;
            const addrlen_ptr = a6;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else if (len == 0) {
                res = 0;
            } else if (!validateUserBuffer(buf_ptr, len)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const s_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                const dst = @as([*]u8, @ptrFromInt(buf_ptr))[0..len];

                if (socket.sockets[s_idx].sock_type == socket.SOCK_DGRAM and socket.sockets[s_idx].proto != 1) {
                    virtio_net.pollRx();
                    var s = &socket.sockets[s_idx];
                    if (s.dgram_ready) {
                        const n = @min(len, s.dgram_len);
                        @memcpy(dst[0..n], s.rx_buf[0..n]);
                        s.dgram_ready = false;
                        s.rx_count = 0;
                        if (src_addr_ptr != 0 and addrlen_ptr != 0) {
                            if (validateUserBuffer(src_addr_ptr, @sizeOf(socket.SockAddrIn)) and validateUserBuffer(addrlen_ptr, 4)) {
                                const sin_out = socket.SockAddrIn{
                                    .sin_family = socket.AF_INET,
                                    .sin_port = std.mem.nativeToBig(u16, s.last_rx_port),
                                    .sin_addr = std.mem.readInt(u32, &s.last_rx_ip, .little),
                                };
                                @as(*socket.SockAddrIn, @ptrFromInt(src_addr_ptr)).* = sin_out;
                                @as(*u32, @ptrFromInt(addrlen_ptr)).* = @sizeOf(socket.SockAddrIn);
                            }
                        }
                        res = @intCast(n);
                        break :blk;
                    } else {
                        if (s.nonblock or (cur_task.fd_table[fd].flags & vfs.O_NONBLOCK) != 0) {
                            res = errno_mod.toReturn(.EAGAIN);
                        } else {
                            cur_task.state = .WAITING_SOCK_READ;
                            cur_task.wait_sock_idx = s_idx;
                            do_block = true;
                        }
                        break :blk;
                    }
                }

                if (socket.sockets[s_idx].domain == socket.AF_INET and (socket.sockets[s_idx].proto == 1 or socket.sockets[s_idx].sock_type == socket.SOCK_RAW)) {
                    var timeout: usize = 1_000_000;
                    while (!netstack.hasIcmpReply() and timeout > 0) : (timeout -= 1) {
                        virtio_net.pollRx();
                        asm volatile ("pause");
                    }
                    var reply_src_ip: [4]u8 = undefined;
                    const n = netstack.getIcmpReply(dst, &reply_src_ip) orelse {
                        if (socket.sockets[s_idx].nonblock or (cur_task.fd_table[fd].flags & vfs.O_NONBLOCK) != 0) {
                            res = errno_mod.toReturn(.EAGAIN);
                        } else {
                            res = errno_mod.toReturn(.ETIMEDOUT);
                        }
                        break :blk;
                    };
                    if (src_addr_ptr != 0 and addrlen_ptr != 0) {
                        if (validateUserBuffer(src_addr_ptr, @sizeOf(socket.SockAddrIn)) and validateUserBuffer(addrlen_ptr, 4)) {
                            const sin_out = socket.SockAddrIn{
                                .sin_family = socket.AF_INET,
                                .sin_port = 0,
                                .sin_addr = std.mem.readInt(u32, &reply_src_ip, .little),
                            };
                            @as(*socket.SockAddrIn, @ptrFromInt(src_addr_ptr)).* = sin_out;
                            @as(*u32, @ptrFromInt(addrlen_ptr)).* = @sizeOf(socket.SockAddrIn);
                        }
                    }
                    res = @intCast(n);
                    break :blk;
                }

                const r = socket.read(s_idx, dst);
                switch (r) {
                    .bytes => |n| {
                        if (src_addr_ptr != 0 and addrlen_ptr != 0) {
                            if (socket.sockets[s_idx].domain == socket.AF_INET) {
                                if (validateUserBuffer(src_addr_ptr, @sizeOf(socket.SockAddrIn)) and validateUserBuffer(addrlen_ptr, 4)) {
                                    const peer_port = if (socket.sockets[s_idx].peer_idx) |p| socket.sockets[p].bound_port else 0;
                                    const sin_out = socket.SockAddrIn{
                                        .sin_family = socket.AF_INET,
                                        .sin_port = std.mem.nativeToBig(u16, peer_port),
                                        .sin_addr = 0x0100007F,
                                    };
                                    @as(*socket.SockAddrIn, @ptrFromInt(src_addr_ptr)).* = sin_out;
                                    @as(*u32, @ptrFromInt(addrlen_ptr)).* = @sizeOf(socket.SockAddrIn);
                                }
                            }
                        }
                        res = @intCast(n);
                    },
                    .eof => res = 0,
                    .would_block => {
                        if (socket.sockets[s_idx].nonblock or (cur_task.fd_table[fd].flags & vfs.O_NONBLOCK) != 0) {
                            res = errno_mod.toReturn(.EAGAIN);
                        } else {
                            cur_task.state = .WAITING_SOCK_READ;
                            cur_task.wait_sock_idx = s_idx;
                            do_block = true;
                        }
                    },
                }
            }
        },

        SYS_SHUTDOWN => {
            const fd = a1;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else {
                const s_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                if (socket.sockets[s_idx].state != .CONNECTED or socket.sockets[s_idx].peer_idx == null) {
                    res = errno_mod.toReturn(.ENOTCONN);
                } else {
                    const p_idx = socket.sockets[s_idx].peer_idx.?;
                    if (p_idx < socket.MAX_SOCKETS and socket.sockets[p_idx].in_use) {
                        socket.sockets[p_idx].peer_closed = true;
                        task.wakeSocketReadWaiters(p_idx);
                    }
                    res = 0;
                }
            }
        },

        SYS_GETSOCKNAME => {
            const fd = a1;
            const addr_ptr = a2;
            const addr_len_ptr = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else if (!validateUserBuffer(addr_ptr, 16) or !validateUserBuffer(addr_len_ptr, 4)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const s_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                const dom = socket.sockets[s_idx].domain;
                if (dom == socket.AF_INET) {
                    const sin = socket.SockAddrIn{
                        .sin_family = socket.AF_INET,
                        .sin_port = std.mem.nativeToBig(u16, socket.sockets[s_idx].bound_port),
                        .sin_addr = 0x0100007F,
                    };
                    @as(*socket.SockAddrIn, @ptrFromInt(addr_ptr)).* = sin;
                    @as(*u32, @ptrFromInt(addr_len_ptr)).* = @sizeOf(socket.SockAddrIn);
                    res = 0;
                } else if (dom == socket.AF_UNIX) {
                    var sun = socket.SockAddrUn{ .sun_family = socket.AF_UNIX };
                    const p_len = socket.sockets[s_idx].bound_path_len;
                    @memcpy(sun.sun_path[0..p_len], socket.sockets[s_idx].bound_path[0..p_len]);
                    @as(*socket.SockAddrUn, @ptrFromInt(addr_ptr)).* = sun;
                    @as(*u32, @ptrFromInt(addr_len_ptr)).* = @sizeOf(socket.SockAddrUn);
                    res = 0;
                } else {
                    res = errno_mod.toReturn(.EINVAL);
                }
            }
        },

        SYS_GETPEERNAME => {
            const fd = a1;
            const addr_ptr = a2;
            const addr_len_ptr = a3;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else {
                const s_idx = if (cur_task.fd_table[fd].sock_idx != 0) cur_task.fd_table[fd].sock_idx else cur_task.fd_table[fd].node_idx;
                if (socket.sockets[s_idx].state != .CONNECTED or socket.sockets[s_idx].peer_idx == null) {
                    res = errno_mod.toReturn(.ENOTCONN);
                } else if (!validateUserBuffer(addr_ptr, 16) or !validateUserBuffer(addr_len_ptr, 4)) {
                    res = errno_mod.toReturn(.EFAULT);
                } else {
                    const p_idx = socket.sockets[s_idx].peer_idx.?;
                    const dom = socket.sockets[s_idx].domain;
                    if (dom == socket.AF_INET) {
                        const sin = socket.SockAddrIn{
                            .sin_family = socket.AF_INET,
                            .sin_port = std.mem.nativeToBig(u16, socket.sockets[p_idx].bound_port),
                            .sin_addr = 0x0100007F,
                        };
                        @as(*socket.SockAddrIn, @ptrFromInt(addr_ptr)).* = sin;
                        @as(*u32, @ptrFromInt(addr_len_ptr)).* = @sizeOf(socket.SockAddrIn);
                        res = 0;
                    } else if (dom == socket.AF_UNIX) {
                        var sun = socket.SockAddrUn{ .sun_family = socket.AF_UNIX };
                        const p_len = socket.sockets[p_idx].bound_path_len;
                        @memcpy(sun.sun_path[0..p_len], socket.sockets[p_idx].bound_path[0..p_len]);
                        @as(*socket.SockAddrUn, @ptrFromInt(addr_ptr)).* = sun;
                        @as(*u32, @ptrFromInt(addr_len_ptr)).* = @sizeOf(socket.SockAddrUn);
                        res = 0;
                    } else {
                        res = errno_mod.toReturn(.EINVAL);
                    }
                }
            }
        },

        SYS_SOCKETPAIR => {
            const domain: u16 = @truncate(a1);
            const base_type: u32 = @truncate(a2 & 0xFF);
            const flags: u32 = @truncate(a2 & ~@as(u64, 0xFF));
            const sv_ptr = a4;
            const is_nonblock = (flags & socket.SOCK_NONBLOCK) != 0;
            const is_cloexec = (flags & socket.SOCK_CLOEXEC) != 0;

            if (domain != socket.AF_UNIX) {
                res = errno_mod.toReturn(.EOPNOTSUPP);
            } else if (!validateUserBuffer(sv_ptr, 8)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const pair = socket.socketpair(domain, base_type, is_nonblock) catch |err| {
                    res = errno_mod.toReturn(err);
                    break :blk;
                };
                const fd0 = vfs.allocFd(&cur_task.fd_table, 0) orelse {
                    _ = socket.close(pair[0]);
                    _ = socket.close(pair[1]);
                    res = errno_mod.toReturn(.EMFILE);
                    break :blk;
                };
                cur_task.fd_table[fd0] = .{
                    .kind = .SOCKET,
                    .node_idx = pair[0],
                    .sock_idx = pair[0],
                    .cloexec = is_cloexec,
                    .flags = if (is_nonblock) vfs.O_NONBLOCK else 0,
                };
                const fd1 = vfs.allocFd(&cur_task.fd_table, fd0 + 1) orelse {
                    cur_task.fd_table[fd0] = .{};
                    _ = socket.close(pair[0]);
                    _ = socket.close(pair[1]);
                    res = errno_mod.toReturn(.EMFILE);
                    break :blk;
                };
                cur_task.fd_table[fd1] = .{
                    .kind = .SOCKET,
                    .node_idx = pair[1],
                    .sock_idx = pair[1],
                    .cloexec = is_cloexec,
                    .flags = if (is_nonblock) vfs.O_NONBLOCK else 0,
                };
                @as(*[2]i32, @ptrFromInt(sv_ptr)).* = [2]i32{ @intCast(fd0), @intCast(fd1) };
                res = 0;
            }
        },

        SYS_SETSOCKOPT, SYS_GETSOCKOPT => {
            const fd = a1;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else if (cur_task.fd_table[fd].kind != .SOCKET) {
                res = errno_mod.toReturn(.ENOTSOCK);
            } else {
                res = 0;
            }
        },

        SYS_FORK, SYS_VFORK => {
            if (task.forkCurrentTask(frame)) |child_idx| {
                res = @intCast(task.tasks[child_idx].pid);
            } else {
                res = errno_mod.toReturn(.EAGAIN);
            }
        },

        SYS_CLONE => {
            const flags = a1;
            const child_stack = a2;
            const ptid_ptr = a3;
            const ctid_ptr = a4;
            const newtls = a5;
            if (task.cloneCurrentTask(frame, flags, child_stack, ptid_ptr, ctid_ptr, newtls)) |child_idx| {
                res = @intCast(task.tasks[child_idx].pid);
            } else {
                res = errno_mod.toReturn(.EAGAIN);
            }
        },

        SYS_EXECVE => {
            const initial_path_str = getUserString(a1, 256) orelse {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            };

            var raw_argv_buf: [16][]const u8 = undefined;
            var raw_envp_buf: [16][]const u8 = undefined;
            const argv_slice = collectUserStringList(a2, &raw_argv_buf);
            const envp_slice = collectUserStringList(a3, &raw_envp_buf);

            var current_path_str = initial_path_str;
            var interp_argv_storage: [18][]const u8 = undefined;
            var current_argv: []const []const u8 = argv_slice;
            var target_node_idx: ?usize = null;
            var final_resolved_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            var final_path_len: usize = 0;

            var depth: usize = 0;
            while (depth < 4) : (depth += 1) {
                var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
                const resolved = vfs.resolveTaskPath(cur_task.cwd(), current_path_str, &path_buf);
                const n_idx = vfs.lookup(resolved) orelse {
                    res = errno_mod.toReturn(.ENOENT);
                    break :blk;
                };

                const data = vfs.getNode(n_idx).slice();
                if (data.len >= 2 and data[0] == '#' and data[1] == '!') {
                    var end_line: usize = 2;
                    while (end_line < data.len and data[end_line] != '\n' and data[end_line] != '\r') : (end_line += 1) {}
                    const line = std.mem.trim(u8, data[2..end_line], " \t");
                    if (line.len == 0) {
                        res = errno_mod.toReturn(.ENOEXEC);
                        break :blk;
                    }

                    var interp_path: []const u8 = line;
                    var opt_arg: ?[]const u8 = null;
                    if (std.mem.indexOfAny(u8, line, " \t")) |space_pos| {
                        interp_path = line[0..space_pos];
                        opt_arg = std.mem.trim(u8, line[space_pos + 1 ..], " \t");
                    }

                    interp_argv_storage[0] = interp_path;
                    var new_argc: usize = 1;
                    if (opt_arg) |arg| {
                        if (arg.len > 0) {
                            interp_argv_storage[new_argc] = arg;
                            new_argc += 1;
                        }
                    }
                    interp_argv_storage[new_argc] = current_path_str;
                    new_argc += 1;
                    if (current_argv.len > 1) {
                        for (current_argv[1..]) |arg| {
                            if (new_argc < interp_argv_storage.len) {
                                interp_argv_storage[new_argc] = arg;
                                new_argc += 1;
                            }
                        }
                    }

                    current_argv = interp_argv_storage[0..new_argc];
                    current_path_str = interp_path;
                    continue;
                }

                target_node_idx = n_idx;
                @memcpy(final_resolved_path[0..resolved.len], resolved);
                final_path_len = resolved.len;
                break;
            }

            const exec_node_idx = target_node_idx orelse {
                res = errno_mod.toReturn(.ENOEXEC);
                break :blk;
            };

            const elf_data = vfs.getNode(exec_node_idx).slice();
            cur_task.setCmdline(current_argv);
            const new_pml4 = vmm.createFreshUserPml4() orelse {
                res = errno_mod.toReturn(.ENOMEM);
                break :blk;
            };

            const loaded = elf.loadStaticElfWithArgs(new_pml4, elf_data, current_argv, envp_slice) catch {
                res = errno_mod.toReturn(.ENOEXEC);
                break :blk;
            };

            cur_task.pml4_phys = new_pml4;
            cur_task.initial_brk = loaded.initial_brk;
            cur_task.current_brk = loaded.initial_brk;
            cur_task.next_mmap_vaddr = task.DEFAULT_MMAP_BASE;
            cur_task.fs_base = 0;
            syscall_arch.wrmsr(syscall_arch.MSR_FS_BASE, 0);
            vmm.loadCr3(new_pml4);
            cur_task.setComm(final_resolved_path[0..final_path_len]);
            cur_task.setExePath(final_resolved_path[0..final_path_len]);
            cur_task.closeCloexecFds();

            frame.r15 = 0;
            frame.r14 = 0;
            frame.r13 = 0;
            frame.r12 = 0;
            frame.rbp = 0;
            frame.rbx = 0;
            frame.r9 = 0;
            frame.r8 = 0;
            frame.r10 = 0;
            frame.rdx = 0;
            frame.rsi = 0;
            frame.rdi = 0;
            frame.rax = 0;
            frame.user_rflags = 0x202;
            frame.user_rip = loaded.entry_rip;
            frame.user_rsp = loaded.user_rsp;

            for (&cur_task.sigactions) |*act| {
                if (act.sa_handler > 1) {
                    act.sa_handler = signal.SIG_DFL;
                    act.sa_restorer = 0;
                    act.sa_flags = 0;
                    act.sa_mask = 0;
                }
            }
            cur_task.in_signal_handler = false;
            cur_task.last_sigframe_vaddr = 0;
            cur_task.alarm_wake_tick = 0;
            cur_task.itimer_interval_ticks = 0;

            return signal.deliverPendingSignals(frame);
        },

        SYS_EXIT => return sysExit(a1),
        SYS_EXIT_GROUP => return sysExitGroup(a1),

        SYS_WAIT4 => {
            const target_pid: isize = @bitCast(a1);
            const status_ptr = a2;
            const options: u32 = @truncate(a3);
            const wnohang = (options & 1) != 0;

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
                z.pid = 0;
                z.pml4_phys = 0;
                res = @intCast(reaped_pid);
            } else if (!has_children) {
                res = errno_mod.toReturn(.ECHILD);
            } else if (wnohang) {
                res = 0;
            } else {
                cur_task.state = .WAITING_CHILD;
                cur_task.wait_target_pid = target_pid;
                do_block = true;
            }
        },

        SYS_KILL => {
            const target_pid: isize = @bitCast(a1);
            const sig = a2;

            if (sig > 64) {
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }

            if (target_pid > 0) {
                const utarget: usize = @intCast(target_pid);
                if (task.getTaskByPid(utarget)) |t| {
                    if (sig == 0) {
                        res = 0;
                    } else {
                        signal.sendSignalToTask(t, sig);
                        res = 0;
                    }
                } else {
                    res = errno_mod.toReturn(.ESRCH);
                }
            } else if (target_pid == 0) {
                var found = false;
                for (&task.tasks) |*t| {
                    if (t.state != .UNUSED and t.pgid == cur_task.pgid) {
                        found = true;
                        if (sig != 0) signal.sendSignalToTask(t, sig);
                    }
                }
                res = if (found) 0 else errno_mod.toReturn(.ESRCH);
            } else if (target_pid == -1) {
                for (&task.tasks) |*t| {
                    if (t.state != .UNUSED and t.pid > 1) {
                        if (sig != 0) signal.sendSignalToTask(t, sig);
                    }
                }
                res = 0;
            } else {
                const target_pgid: usize = @intCast(-target_pid);
                var found = false;
                for (&task.tasks) |*t| {
                    if (t.state != .UNUSED and t.pgid == target_pgid) {
                        found = true;
                        if (sig != 0) signal.sendSignalToTask(t, sig);
                    }
                }
                res = if (found) 0 else errno_mod.toReturn(.ESRCH);
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
                        if (arg >= vfs.MAX_OPEN_FILES) {
                            res = errno_mod.toReturn(.EINVAL);
                            break :blk;
                        }
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
            const dirfd: isize = if (num == SYS_MKDIRAT) @bitCast(a1) else vfs.AT_FDCWD;
            const path_ptr = if (num == SYS_MKDIRAT) a2 else a1;
            const mode: u32 = @truncate(if (num == SYS_MKDIRAT) a3 else a2);
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(path_ptr, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            const base_dir = resolveAtBaseDir(dirfd, path_str) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
            const resolved = vfs.resolveTaskPath(base_dir, path_str, &path_buf);
            _ = vfs.createNode(resolved, vfs.S_IFDIR | (mode & 0o777)) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            res = 0;
        },

        SYS_CREAT => {
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(a1, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            const mode: u32 = @truncate(a2);
            res = handleOpenat(vfs.AT_FDCWD, path_str, vfs.O_CREAT | vfs.O_WRONLY | vfs.O_TRUNC, mode);
        },

        SYS_RMDIR => {
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(a1, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            res = handleUnlinkat(vfs.AT_FDCWD, path_str, vfs.AT_REMOVEDIR);
        },

        SYS_UNLINK, SYS_UNLINKAT => {
            const dirfd: isize = if (num == SYS_UNLINKAT) @bitCast(a1) else vfs.AT_FDCWD;
            const path_ptr = if (num == SYS_UNLINKAT) a2 else a1;
            const flags: usize = if (num == SYS_UNLINKAT) a3 else 0;
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(path_ptr, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            res = handleUnlinkat(dirfd, path_str, flags);
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
                const entry = &cur_task.fd_table[fd];
                const node = vfs.getNode(entry.node_idx);
                if (!node.isDir()) {
                    res = errno_mod.toReturn(.ENOTDIR);
                    break :blk;
                }
                procfs.syncProcessNodes();
                const dst = @as([*]u8, @ptrFromInt(dirp_ptr))[0..count];
                const written = vfs.readDirEntries64(entry.node_idx, &entry.offset, dst) catch |err| {
                    res = errno_mod.toReturn(err);
                    break :blk;
                };
                res = @intCast(written);
            }
        },

        SYS_ARCH_PRCTL => {
            res = sysArchPrctl(a1, a2);
        },

        SYS_SYNC => {
            if (tarfs.isMounted()) {
                tarfs.syncToDisk() catch {};
            }
            res = 0;
        },

        SYS_FSYNC => {
            const fd = a1;
            if (fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
            } else {
                if (tarfs.isMounted()) {
                    tarfs.syncToDisk() catch {};
                }
                res = 0;
            }
        },

        SYS_MOUNT => {
            res = sysMount(a1, a2, a3, a4, a5);
        },

        SYS_UMOUNT2 => {
            res = sysUmount2(a1, a2);
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

        SYS_READLINK => {
            res = sysReadlinkat(-100, a1, a2, a3);
        },
        SYS_READLINKAT => {
            res = sysReadlinkat(@bitCast(a1), a2, a3, a4);
        },

        SYS_GETCWD => {
            const buf_ptr = a1;
            const size = a2;
            if (size == 0) {
                res = errno_mod.toReturn(.EINVAL);
            } else if (!validateUserBuffer(buf_ptr, size)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const c = cur_task.cwd();
                const path_str = if (c.len == 0) "/" else c;
                if (size < path_str.len + 1) {
                    res = errno_mod.toReturn(.ERANGE);
                } else {
                    const dst = @as([*]u8, @ptrFromInt(buf_ptr));
                    @memcpy(dst[0..path_str.len], path_str);
                    dst[path_str.len] = 0;
                    res = @intCast(path_str.len + 1);
                }
            }
        },

        SYS_ACCESS, SYS_FACCESSAT, SYS_FACCESSAT2 => {
            const path_ptr = if (num == SYS_ACCESS) a1 else a2;
            const path_str = getUserString(path_ptr, 256) orelse {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            };
            var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
            const resolved = vfs.resolveTaskPath(cur_task.cwd(), path_str, &path_buf);
            if (vfs.lookup(resolved) != null) {
                res = 0;
            } else {
                res = errno_mod.toReturn(.ENOENT);
            }
        },

        SYS_PAUSE => {
            cur_task.state = .WAITING_SIGNAL;
            frame.rax = @bitCast(@as(isize, -4)); // -EINTR
            cur_task.saved_frame = frame;
            const next_idx = task.scheduleNextOrWait();
            task.activateTask(next_idx);
            return signal.deliverPendingSignals(task.tasks[next_idx].saved_frame);
        },

        SYS_ALARM => {
            const seconds = a1;
            const now = timer.getTicks();
            var remaining: usize = 0;
            if (cur_task.alarm_wake_tick > now) {
                remaining = @intCast((cur_task.alarm_wake_tick - now) / timer.HZ);
                if (remaining == 0 and cur_task.alarm_wake_tick > now) {
                    remaining = 1;
                }
            }
            if (seconds == 0) {
                cur_task.alarm_wake_tick = 0;
                cur_task.itimer_interval_ticks = 0;
            } else {
                cur_task.alarm_wake_tick = now + seconds * timer.HZ;
                cur_task.itimer_interval_ticks = 0;
            }
            res = @intCast(remaining);
        },

        SYS_SETITIMER => {
            const which = a1;
            const new_val_ptr = a2;
            const old_val_ptr = a3;

            if (which != 0) { // ITIMER_REAL only
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }
            if (new_val_ptr == 0 or !validateUserBuffer(new_val_ptr, @sizeOf(signal.LinuxItimerval))) {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            }
            if (old_val_ptr != 0 and !validateUserBuffer(old_val_ptr, @sizeOf(signal.LinuxItimerval))) {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            }

            const now = timer.getTicks();
            if (old_val_ptr != 0) {
                var old_it = @as(*signal.LinuxItimerval, @ptrFromInt(old_val_ptr));
                old_it.* = .{};
                if (cur_task.alarm_wake_tick > now) {
                    const rem_ticks = cur_task.alarm_wake_tick - now;
                    old_it.it_value_sec = @intCast(rem_ticks / timer.HZ);
                    old_it.it_value_usec = @intCast((rem_ticks % timer.HZ) * 10_000);
                }
                if (cur_task.itimer_interval_ticks > 0) {
                    old_it.it_interval_sec = @intCast(cur_task.itimer_interval_ticks / timer.HZ);
                    old_it.it_interval_usec = @intCast((cur_task.itimer_interval_ticks % timer.HZ) * 10_000);
                }
            }

            const new_it = @as(*const signal.LinuxItimerval, @ptrFromInt(new_val_ptr));
            if (new_it.it_value_sec < 0 or new_it.it_value_usec < 0 or new_it.it_value_usec >= 1_000_000 or
                new_it.it_interval_sec < 0 or new_it.it_interval_usec < 0 or new_it.it_interval_usec >= 1_000_000)
            {
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }

            if (new_it.it_value_sec == 0 and new_it.it_value_usec == 0) {
                cur_task.alarm_wake_tick = 0;
                cur_task.itimer_interval_ticks = 0;
            } else {
                const val_ticks: u64 = @as(u64, @intCast(new_it.it_value_sec * timer.HZ)) +
                    @as(u64, @intCast(@divTrunc(new_it.it_value_usec + 9999, 10000)));
                cur_task.alarm_wake_tick = now + @max(val_ticks, 1);

                const int_ticks: u64 = @as(u64, @intCast(new_it.it_interval_sec * timer.HZ)) +
                    @as(u64, @intCast(@divTrunc(new_it.it_interval_usec + 9999, 10000)));
                cur_task.itimer_interval_ticks = int_ticks;
            }
            res = 0;
        },

        SYS_CHDIR => {
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(a1, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
            const resolved = vfs.resolveTaskPath(cur_task.cwd(), path_str, &path_buf);
            if (vfs.lookup(resolved)) |n_idx| {
                const node = vfs.getNode(n_idx);
                if (!node.isDir()) {
                    res = errno_mod.toReturn(.ENOTDIR);
                } else {
                    cur_task.cwd_buf[0] = '/';
                    if (resolved.len == 0) {
                        cur_task.cwd_len = 1;
                    } else {
                        const n = @min(resolved.len, cur_task.cwd_buf.len - 2);
                        @memcpy(cur_task.cwd_buf[1 .. 1 + n], resolved[0..n]);
                        cur_task.cwd_len = 1 + n;
                    }
                    res = 0;
                }
            } else {
                res = errno_mod.toReturn(.ENOENT);
            }
        },

        SYS_UTIMENSAT => {
            const dirfd: isize = @bitCast(a1);
            const path_ptr = a2;
            const times_ptr = a3;
            const flags: u32 = @truncate(a4);
            if (times_ptr != 0 and !validateUserBuffer(times_ptr, 2 * @sizeOf(LinuxTimespec))) {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            }
            if (path_ptr == 0) {
                if ((flags & AT_EMPTY_PATH) != 0) {
                    if (dirfd == vfs.AT_FDCWD or (dirfd >= 0 and dirfd < vfs.MAX_OPEN_FILES and cur_task.fd_table[@intCast(dirfd)].kind != .UNUSED)) {
                        res = 0;
                    } else {
                        res = errno_mod.toReturn(.EBADF);
                    }
                } else {
                    res = errno_mod.toReturn(.EINVAL);
                }
                break :blk;
            }
            var raw_path: [vfs.MAX_PATH_LEN]u8 = undefined;
            const path_str = readUserCString(path_ptr, &raw_path) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            const base_dir = resolveAtBaseDir(dirfd, path_str) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
            const resolved = vfs.resolveTaskPath(base_dir, path_str, &path_buf);
            if (vfs.lookup(resolved) == null) {
                res = errno_mod.toReturn(.ENOENT);
            } else {
                res = 0;
            }
        },

        SYS_STATX => {
            res = errno_mod.toReturn(.ENOSYS);
        },

        SYS_SETPGID => {
            const target_pid = if (a1 == 0) cur_task.pid else a1;
            const new_pgid = if (a2 == 0) target_pid else a2;
            var found = false;
            for (&task.tasks) |*t| {
                if (t.state != .UNUSED and t.pid == target_pid) {
                    t.pgid = new_pgid;
                    found = true;
                    break;
                }
            }
            if (found) {
                res = 0;
            } else {
                res = errno_mod.toReturn(.ESRCH);
            }
        },

        SYS_GETPGRP => {
            res = @intCast(cur_task.pgid);
        },

        SYS_SETSID => {
            cur_task.pgid = cur_task.pid;
            res = @intCast(cur_task.pid);
        },

        SYS_GETPGID => {
            const target_pid = if (a1 == 0) cur_task.pid else a1;
            var found_pgid: ?usize = null;
            for (&task.tasks) |*t| {
                if (t.state != .UNUSED and t.pid == target_pid) {
                    found_pgid = t.pgid;
                    break;
                }
            }
            if (found_pgid) |pg| {
                res = @intCast(pg);
            } else {
                res = errno_mod.toReturn(.ESRCH);
            }
        },

        SYS_CLOCK_GETRES => {
            const tp_ptr = a2;
            if (tp_ptr != 0 and validateUserBuffer(tp_ptr, @sizeOf(LinuxTimespec))) {
                const ts = @as(*LinuxTimespec, @ptrFromInt(tp_ptr));
                ts.tv_sec = 0;
                ts.tv_nsec = 10_000_000;
            }
            res = 0;
        },

        SYS_GETRANDOM => {
            const buf_ptr = a1;
            const len = a2;
            if (!validateUserBuffer(buf_ptr, len)) {
                res = errno_mod.toReturn(.EFAULT);
            } else {
                const dst = @as([*]u8, @ptrFromInt(buf_ptr));
                for (0..len) |i| {
                    dst[i] = @as(u8, @truncate((i *% 37 +% 13)));
                }
                res = @intCast(len);
            }
        },

        SYS_FUTEX => {
            const uaddr = a1;
            const futex_op = a2;
            const val: u32 = @truncate(a3);
            const cmd = futex_op & futex.FUTEX_CMD_MASK;

            if ((uaddr & 3) != 0) {
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }
            if (!validateUserBuffer(uaddr, 4)) {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            }
            const paddr = vmm.translate(cur_task.pml4_phys, uaddr) orelse {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            };

            switch (cmd) {
                futex.FUTEX_WAIT, futex.FUTEX_WAIT_BITSET => {
                    const cur_val = std.mem.readInt(i32, @as(*const [4]u8, @ptrFromInt(paddr)), .little);
                    if (cur_val != @as(i32, @bitCast(val))) {
                        res = errno_mod.toReturn(.EAGAIN);
                    } else {
                        cur_task.state = .WAITING_FUTEX;
                        cur_task.wait_futex_paddr = paddr;
                        frame.rax = 0; // Return 0 upon wake
                        cur_task.saved_frame = frame;
                        const next_idx = task.scheduleNextOrWait();
                        task.activateTask(next_idx);
                        return signal.deliverPendingSignals(task.tasks[next_idx].saved_frame);
                    }
                },
                futex.FUTEX_WAKE, futex.FUTEX_WAKE_BITSET => {
                    const max_wake: usize = @truncate(a3);
                    const woken = futex.wakeByPaddr(paddr, max_wake);
                    res = @intCast(woken);
                },
                else => res = errno_mod.toReturn(.ENOSYS),
            }
        },

        SYS_EPOLL_CREATE, SYS_EPOLL_CREATE1 => {
            const is_cloexec = (num == SYS_EPOLL_CREATE1) and ((a1 & 0x80000) != 0);
            if (num == SYS_EPOLL_CREATE1) {
                if ((a1 & ~@as(u64, 0x80000)) != 0) {
                    res = errno_mod.toReturn(.EINVAL);
                    break :blk;
                }
            } else {
                const size: isize = @bitCast(a1);
                if (size <= 0) {
                    res = errno_mod.toReturn(.EINVAL);
                    break :blk;
                }
            }
            const ep_idx = epoll.alloc() orelse {
                res = errno_mod.toReturn(.EMFILE);
                break :blk;
            };
            if (vfs.allocFd(&cur_task.fd_table, 0)) |fd| {
                cur_task.fd_table[fd] = .{
                    .kind = .EPOLL,
                    .node_idx = ep_idx,
                    .cloexec = is_cloexec,
                };
                res = @intCast(fd);
            } else {
                epoll.close(ep_idx);
                res = errno_mod.toReturn(.EMFILE);
            }
        },

        SYS_EPOLL_CTL => {
            const epfd = a1;
            const op = a2;
            const target_fd = a3;
            const event_ptr = a4;
            if (epfd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[epfd].kind != .EPOLL) {
                res = errno_mod.toReturn(.EBADF);
                break :blk;
            }
            if (target_fd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[target_fd].kind == .UNUSED) {
                res = errno_mod.toReturn(.EBADF);
                break :blk;
            }
            if (epfd == target_fd) {
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }
            var ev = epoll.LinuxEpollEvent{};
            if (op != epoll.EPOLL_CTL_DEL) {
                if (!validateUserBuffer(event_ptr, @sizeOf(epoll.LinuxEpollEvent))) {
                    res = errno_mod.toReturn(.EFAULT);
                    break :blk;
                }
                ev = @as(*const align(1) epoll.LinuxEpollEvent, @ptrFromInt(event_ptr)).*;
            }
            epoll.ctl(cur_task.fd_table[epfd].node_idx, op, target_fd, ev) catch |err| {
                res = errno_mod.toReturn(err);
                break :blk;
            };
            res = 0;
        },

        SYS_EPOLL_WAIT, SYS_EPOLL_PWAIT => {
            const epfd = a1;
            const events_ptr = a2;
            const maxevents: isize = @bitCast(a3);
            const timeout_val: isize = @bitCast(a4);

            if (epfd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[epfd].kind != .EPOLL) {
                res = errno_mod.toReturn(.EBADF);
                break :blk;
            }
            if (maxevents <= 0) {
                res = errno_mod.toReturn(.EINVAL);
                break :blk;
            }
            const max_ev_u: usize = @intCast(maxevents);
            const bytes_needed = max_ev_u * @sizeOf(epoll.LinuxEpollEvent);
            if (!validateUserBuffer(events_ptr, bytes_needed)) {
                res = errno_mod.toReturn(.EFAULT);
                break :blk;
            }
            const out_events = @as([*]epoll.LinuxEpollEvent, @ptrFromInt(events_ptr))[0..max_ev_u];
            const ep_idx = cur_task.fd_table[epfd].node_idx;
            const ready_count = epoll.collectReadyEvents(ep_idx, &cur_task.fd_table, out_events);
            if (ready_count > 0) {
                res = @intCast(ready_count);
            } else if (timeout_val == 0) {
                res = 0;
            } else {
                cur_task.state = .WAITING_EPOLL;
                cur_task.wait_epoll_idx = ep_idx;
                do_block = true;
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
        return signal.deliverPendingSignals(task.tasks[next_idx].saved_frame);
    }

    frame.rax = @bitCast(res);

    // Profiler & strace logging
    if (task.currentTask().pid == orig_pid and frame.user_rip == orig_rip) {
        const elapsed = profiler.readTsc() -% start_tsc;
        profiler.recordSample(num, elapsed, res);
        strace.traceSyscall(num, a1, a2, a3, a4, orig_rip, res);
    }

    return signal.deliverPendingSignals(frame);
}

fn handleOpenat(dirfd: isize, path_str: []const u8, flags: u32, mode: u32) isize {
    const cur_task = task.currentTask();
    if (path_str.len == 0) return errno_mod.toReturn(.ENOENT);

    const base_dir = resolveAtBaseDir(dirfd, path_str) catch |err| {
        return errno_mod.toReturn(err);
    };

    var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
    const resolved = vfs.resolveTaskPath(base_dir, path_str, &path_buf);
    if (std.mem.startsWith(u8, resolved, "proc")) {
        procfs.refreshDynamicNodes();
    }

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
        const target_node = vfs.getNode(node_idx.?);
        var kind: vfs.FdKind = .VFS_FILE;
        if (target_node.isCharDev()) {
            const n_path = target_node.name();
            if (std.mem.endsWith(u8, n_path, "tty") or std.mem.endsWith(u8, n_path, "console")) {
                const acc_mode = flags & 0x03;
                kind = if (acc_mode == vfs.O_WRONLY) .CONSOLE_OUT else .CONSOLE_IN;
            }
        } else if ((target_node.mode & vfs.S_IFMT) == vfs.S_IFBLK) {
            kind = .BLKDEV;
        }
        cur_task.fd_table[fd] = .{
            .kind = kind,
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
        .BLKDEV => {
            st.* = .{
                .st_dev = 1,
                .st_ino = entry.node_idx + 1,
                .st_nlink = 1,
                .st_mode = vfs.S_IFBLK | 0o660,
                .st_uid = 0,
                .st_gid = 0,
                .st_rdev = (254 << 8) | 0,
                .st_size = @as(i64, @intCast(virtio_blk.getCapacityBytes())),
                .st_blksize = 512,
                .st_blocks = @as(i64, @intCast(virtio_blk.getCapacityBytes() / 512)),
                .st_atime = 0,
                .st_mtime = 0,
                .st_ctime = 0,
            };
            return 0;
        },
        else => return errno_mod.toReturn(.EBADF),
    }
}

pub const LinuxPollFd = extern struct {
    fd: i32,
    events: i16,
    revents: i16 = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxPollFd) == 8);
    }
};

fn handlePoll(fds_ptr: usize, nfds: usize) isize {
    if (nfds == 0) return 0;
    if (!validateUserBuffer(fds_ptr, nfds * @sizeOf(LinuxPollFd))) {
        return errno_mod.toReturn(.EFAULT);
    }
    const cur_task = task.currentTask();
    const fds = @as([*]LinuxPollFd, @ptrFromInt(fds_ptr))[0..nfds];
    var ready_count: isize = 0;

    for (fds) |*pfd| {
        pfd.revents = 0;
        if (pfd.fd < 0) continue;
        const ufd: usize = @intCast(pfd.fd);
        if (ufd >= vfs.MAX_OPEN_FILES or cur_task.fd_table[ufd].kind == .UNUSED) {
            pfd.revents = 0x0020; // POLLNVAL
            ready_count += 1;
            continue;
        }

        const entry = &cur_task.fd_table[ufd];
        var rev: i16 = 0;
        switch (entry.kind) {
            .CONSOLE_IN => {
                if ((pfd.events & 0x0001) != 0 and tty.hasReadableData()) {
                    rev |= 0x0001; // POLLIN
                }
                if ((pfd.events & 0x0004) != 0) {
                    rev |= 0x0004; // POLLOUT
                }
            },
            .CONSOLE_OUT, .CONSOLE_ERR => {
                if ((pfd.events & 0x0004) != 0) {
                    rev |= 0x0004; // POLLOUT
                }
            },
            .VFS_FILE => {
                if ((pfd.events & 0x0001) != 0) rev |= 0x0001;
                if ((pfd.events & 0x0004) != 0) rev |= 0x0004;
            },
            else => {
                if ((pfd.events & 0x0001) != 0) rev |= 0x0001;
                if ((pfd.events & 0x0004) != 0) rev |= 0x0004;
            },
        }
        pfd.revents = rev;
        if (rev != 0) {
            ready_count += 1;
        }
    }

    return ready_count;
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

    var path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
    const resolved = vfs.resolveTaskPath(base_dir, path_str, &path_buf);
    if (std.mem.startsWith(u8, resolved, "proc")) {
        procfs.refreshDynamicNodes();
    }
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
            return switch (r) {
                .bytes => |n| @intCast(n),
                .eof => 0,
                .would_block => -11,
            };
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
            const s_idx = if (entry.sock_idx != 0) entry.sock_idx else entry.node_idx;
            const r = socket.read(s_idx, dst);
            return switch (r) {
                .bytes => |n| @intCast(n),
                .eof => 0,
                .would_block => -11,
            };
        },
        .BLKDEV => {
            const n = virtio_blk.readBytes(entry.offset, dst);
            entry.offset += n;
            return @intCast(n);
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
            const s_idx = if (entry.sock_idx != 0) entry.sock_idx else entry.node_idx;
            const w = socket.write(s_idx, src) catch |err| return errno_mod.toReturn(err);
            if (socket.sockets[s_idx].peer_idx) |p_idx| {
                task.wakeSocketReadWaiters(p_idx);
            }
            return @intCast(w);
        },
        .BLKDEV => {
            const n = virtio_blk.writeBytes(entry.offset, src);
            entry.offset += n;
            return @intCast(n);
        },
        else => return errno_mod.toReturn(.EBADF),
    }
}

fn retainFd(entry: vfs.FdEntry) void {
    switch (entry.kind) {
        .PIPE_READ => pipe_mod.retainReader(entry.node_idx),
        .PIPE_WRITE => pipe_mod.retainWriter(entry.node_idx),
        .SOCKET => {
            const s_idx = if (entry.sock_idx != 0) entry.sock_idx else entry.node_idx;
            socket.retain(s_idx);
        },
        .EPOLL => epoll.retain(entry.node_idx),
        else => {},
    }
}

fn closeFdEntry(entry: *vfs.FdEntry) void {
    switch (entry.kind) {
        .PIPE_READ => pipe_mod.closeReader(entry.node_idx),
        .PIPE_WRITE => pipe_mod.closeWriter(entry.node_idx),
        .SOCKET => {
            const s_idx = if (entry.sock_idx != 0) entry.sock_idx else entry.node_idx;
            if (socket.close(s_idx)) |peer_idx| {
                task.wakeSocketReadWaiters(peer_idx);
            }
        },
        .EPOLL => epoll.close(entry.node_idx),
        else => {},
    }
    entry.* = .{};
}

fn copyFixed(dst: []u8, src: []const u8) void {
    const n = @min(dst.len - 1, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

fn collectUserStringList(array_ptr: usize, out_slice: [][]const u8) []const []const u8 {
    if (array_ptr == 0) return out_slice[0..0];
    const ptrs = @as([*]const usize, @ptrFromInt(array_ptr));
    var cnt: usize = 0;
    while (cnt < out_slice.len) : (cnt += 1) {
        const str_p = ptrs[cnt];
        if (str_p == 0) break;
        if (getUserString(str_p, 256)) |s| {
            out_slice[cnt] = s;
        } else break;
    }
    return out_slice[0..cnt];
}
