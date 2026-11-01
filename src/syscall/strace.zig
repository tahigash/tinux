const std = @import("std");
const serial = @import("../drivers/serial.zig");
const task = @import("../proc/task.zig");
const syscall_arch = @import("../arch/x86_64/syscall.zig");
const SyscallFrame = syscall_arch.SyscallFrame;
const dispatch = @import("dispatch.zig");
const errno_mod = @import("../uapi/errno.zig");

pub const TraceLevel = enum(u8) {
    off = 0,
    enosys_only = 1,
    errors_only = 2,
    full = 3,
};

var global_trace_level: u8 = 0; // Default 0 (OFF) so automated tests remain clean
var total_syscalls: u64 = 0;
var total_enosys: u64 = 0;
var last_enosys_num: u64 = 0;
var last_enosys_pid: usize = 0;

pub fn getTraceLevel() TraceLevel {
    return @enumFromInt(@atomicLoad(u8, &global_trace_level, .seq_cst));
}

pub fn setTraceLevel(level: TraceLevel) void {
    @atomicStore(u8, &global_trace_level, @intFromEnum(level), .seq_cst);
}

pub fn parseAndSetConfig(input: []const u8) void {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return;
    if (std.mem.eql(u8, trimmed, "0") or std.mem.eql(u8, trimmed, "off")) {
        setTraceLevel(.off);
    } else if (std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "enosys")) {
        setTraceLevel(.enosys_only);
    } else if (std.mem.eql(u8, trimmed, "2") or std.mem.eql(u8, trimmed, "errors")) {
        setTraceLevel(.errors_only);
    } else if (std.mem.eql(u8, trimmed, "3") or std.mem.eql(u8, trimmed, "full") or std.mem.eql(u8, trimmed, "all")) {
        setTraceLevel(.full);
    }
}

pub fn formatStatus(buf: []u8) []const u8 {
    const lvl = getTraceLevel();
    const lvl_name = switch (lvl) {
        .off => "0 (OFF)",
        .enosys_only => "1 (ENOSYS_ONLY)",
        .errors_only => "2 (ERRORS_ONLY)",
        .full => "3 (FULL_STRACE)",
    };
    return std.fmt.bufPrint(
        buf,
        "trace_level    : {s}\ntotal_syscalls : {d}\nunimplemented  : {d}\nlast_enosys_num : {d} ({s}) by pid {d}\n",
        .{
            lvl_name,
            @atomicLoad(u64, &total_syscalls, .seq_cst),
            @atomicLoad(u64, &total_enosys, .seq_cst),
            last_enosys_num,
            syscallName(last_enosys_num),
            last_enosys_pid,
        },
    ) catch "trace_level: error\n";
}

/// Safely reads a NUL-terminated string from user space for strace display
fn previewUserString(user_ptr: usize, out_buf: *[64]u8) []const u8 {
    if (user_ptr < 0x1000 or user_ptr >= 0x0000_8000_0000_0000) return "<bad-ptr>";
    var len: usize = 0;
    while (len < out_buf.len) : (len += 1) {
        if (!dispatch.validateUserBuffer(user_ptr + len, 1)) break;
        const b = @as(*const u8, @ptrFromInt(user_ptr + len)).*;
        if (b == 0) break;
        out_buf[len] = if (b >= 0x20 and b < 0x7F) b else '.';
    }
    return out_buf[0..len];
}

/// Converts a negative kernel return value (-1 .. -4095) to its POSIX errno name
pub fn errnoSymbol(ret: isize) []const u8 {
    if (ret >= 0 or ret < -4095) return "";
    const pos: u16 = @intCast(-ret);
    return switch (pos) {
        1 => "EPERM",
        2 => "ENOENT",
        3 => "ESRCH",
        4 => "EINTR",
        5 => "EIO",
        6 => "ENXIO",
        7 => "E2BIG",
        8 => "ENOEXEC",
        9 => "EBADF",
        10 => "ECHILD",
        11 => "EAGAIN",
        12 => "ENOMEM",
        13 => "EACCES",
        14 => "EFAULT",
        16 => "EBUSY",
        17 => "EEXIST",
        18 => "EXDEV",
        19 => "ENODEV",
        20 => "ENOTDIR",
        21 => "EISDIR",
        22 => "EINVAL",
        24 => "EMFILE",
        25 => "ENOTTY",
        28 => "ENOSPC",
        29 => "ESPIPE",
        32 => "EPIPE",
        34 => "ERANGE",
        38 => "ENOSYS",
        39 => "ENOTEMPTY",
        95 => "EOPNOTSUPP",
        97 => "EAFNOSUPPORT",
        98 => "EADDRINUSE",
        104 => "ECONNRESET",
        111 => "ECONNREFUSED",
        else => "EUNKNOWN",
    };
}

/// Maps Linux x86_64 syscall numbers to their standard names
pub fn syscallName(num: u64) []const u8 {
    return switch (num) {
        0 => "read",
        1 => "write",
        2 => "open",
        3 => "close",
        4 => "stat",
        5 => "fstat",
        6 => "lstat",
        7 => "poll",
        8 => "lseek",
        9 => "mmap",
        10 => "mprotect",
        11 => "munmap",
        12 => "brk",
        13 => "rt_sigaction",
        14 => "rt_sigprocmask",
        15 => "rt_sigreturn",
        16 => "ioctl",
        17 => "pread64",
        18 => "pwrite64",
        19 => "readv",
        20 => "writev",
        21 => "access",
        22 => "pipe",
        23 => "select",
        24 => "sched_yield",
        28 => "madvise",
        32 => "dup",
        33 => "dup2",
        34 => "pause",
        35 => "nanosleep",
        37 => "alarm",
        38 => "setitimer",
        39 => "getpid",
        41 => "socket",
        42 => "connect",
        43 => "accept",
        44 => "sendto",
        45 => "recvfrom",
        48 => "shutdown",
        49 => "bind",
        50 => "listen",
        51 => "getsockname",
        52 => "getpeername",
        53 => "socketpair",
        54 => "setsockopt",
        55 => "getsockopt",
        56 => "clone",
        57 => "fork",
        58 => "vfork",
        59 => "execve",
        60 => "exit",
        61 => "wait4",
        62 => "kill",
        63 => "uname",
        72 => "fcntl",
        74 => "fsync",
        75 => "fdatasync",
        79 => "getcwd",
        80 => "chdir",
        83 => "mkdir",
        84 => "rmdir",
        85 => "creat",
        87 => "unlink",
        89 => "readlink",
        96 => "gettimeofday",
        102 => "getuid",
        104 => "getgid",
        107 => "geteuid",
        108 => "getegid",
        109 => "setpgid",
        110 => "getppid",
        111 => "getpgrp",
        112 => "setsid",
        121 => "getpgid",
        131 => "sigaltstack",
        157 => "prctl",
        158 => "arch_prctl",
        162 => "sync",
        165 => "mount",
        166 => "umount2",
        186 => "gettid",
        200 => "tkill",
        202 => "futex",
        203 => "sched_setaffinity",
        204 => "sched_getaffinity",
        213 => "epoll_create",
        217 => "getdents64",
        218 => "set_tid_address",
        228 => "clock_gettime",
        229 => "clock_getres",
        230 => "clock_nanosleep",
        231 => "exit_group",
        232 => "epoll_wait",
        233 => "epoll_ctl",
        234 => "tgkill",
        257 => "openat",
        258 => "mkdirat",
        262 => "newfstatat",
        263 => "unlinkat",
        267 => "readlinkat",
        269 => "faccessat",
        271 => "ppoll",
        273 => "set_robust_list",
        280 => "utimensat",
        281 => "epoll_pwait",
        288 => "accept4",
        291 => "epoll_create1",
        292 => "dup3",
        293 => "pipe2",
        302 => "prlimit64",
        309 => "getcpu",
        318 => "getrandom",
        332 => "statx",
        334 => "rseq",
        435 => "clone3",
        436 => "close_range",
        439 => "faccessat2",
        441 => "epoll_pwait2",
        else => "unknown_syscall",
    };
}

/// Logs the completed (or unimplemented) system call according to active TraceLevel
pub fn traceSyscall(
    orig_num: u64,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    user_rip: usize,
    ret: isize,
) void {
    _ = @atomicRmw(u64, &total_syscalls, .Add, 1, .seq_cst);
    const cur = task.currentTask();
    const is_enosys = (ret == -38);
    if (is_enosys) {
        _ = @atomicRmw(u64, &total_enosys, .Add, 1, .seq_cst);
        last_enosys_num = orig_num;
        last_enosys_pid = cur.pid;
    }

    const lvl = getTraceLevel();
    const task_traced = cur.strace_enabled;

    if (!task_traced) {
        switch (lvl) {
            .off => return,
            .enosys_only => if (!is_enosys) return,
            .errors_only => if (ret >= 0) return,
            .full => {
                // Skip noisy console stdout/stderr writes in full global trace to avoid visual clutter
                if ((orig_num == 1 or orig_num == 20) and (arg1 == 1 or arg1 == 2) and ret >= 0) return;
            },
        }
    } else {
        // Even in per-task STRACE=1 mode, skip successful stdout/stderr writes so app output stays readable
        if ((orig_num == 1 or orig_num == 20) and (arg1 == 1 or arg1 == 2) and ret >= 0) return;
    }

    const name = syscallName(orig_num);
    var path_buf: [64]u8 = undefined;

    if (is_enosys) {
        serial.print(
            "[STRACE:ENOSYS] pid={d} ({s}) UNIMPLEMENTED syscall={d} ({s}) args=(0x{X}, 0x{X}, 0x{X}, 0x{X}) rip=0x{X}\n",
            .{ cur.pid, cur.comm(), orig_num, name, arg1, arg2, arg3, arg4, user_rip },
        );
        return;
    }

    // Format path-taking syscalls with human-readable string preview
    const has_arg1_path = (orig_num == 2 or orig_num == 4 or orig_num == 6 or orig_num == 21 or
        orig_num == 59 or orig_num == 80 or orig_num == 83 or orig_num == 84 or orig_num == 87 or orig_num == 89);
    const has_arg2_path = (orig_num == 257 or orig_num == 258 or orig_num == 262 or orig_num == 263 or
        orig_num == 267 or orig_num == 269 or orig_num == 439);

    if (has_arg1_path) {
        const s = previewUserString(arg1, &path_buf);
        if (ret < 0) {
            serial.print("[STRACE] pid={d} ({s}) {s}(\"{s}\", 0x{X}, 0x{X}) = {d} ({s})\n", .{
                cur.pid, cur.comm(), name, s, arg2, arg3, ret, errnoSymbol(ret),
            });
        } else {
            serial.print("[STRACE] pid={d} ({s}) {s}(\"{s}\", 0x{X}, 0x{X}) = {d}\n", .{
                cur.pid, cur.comm(), name, s, arg2, arg3, ret,
            });
        }
    } else if (has_arg2_path) {
        const s = previewUserString(arg2, &path_buf);
        if (ret < 0) {
            serial.print("[STRACE] pid={d} ({s}) {s}({d}, \"{s}\", 0x{X}) = {d} ({s})\n", .{
                cur.pid, cur.comm(), name, @as(isize, @bitCast(arg1)), s, arg3, ret, errnoSymbol(ret),
            });
        } else {
            serial.print("[STRACE] pid={d} ({s}) {s}({d}, \"{s}\", 0x{X}) = {d}\n", .{
                cur.pid, cur.comm(), name, @as(isize, @bitCast(arg1)), s, arg3, ret,
            });
        }
    } else {
        if (ret < 0) {
            serial.print("[STRACE] pid={d} ({s}) {s}(0x{X}, 0x{X}, 0x{X}) = {d} ({s})\n", .{
                cur.pid, cur.comm(), name, arg1, arg2, arg3, ret, errnoSymbol(ret),
            });
        } else {
            serial.print("[STRACE] pid={d} ({s}) {s}(0x{X}, 0x{X}, 0x{X}) = 0x{X} ({d})\n", .{
                cur.pid, cur.comm(), name, arg1, arg2, arg3, @as(usize, @bitCast(ret)), ret,
            });
        }
    }
}
