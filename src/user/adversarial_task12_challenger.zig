// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Adversarial test suite for TASK-012: Bidirectional TTY, line discipline, and process group management

const std = @import("std");

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call testMain
    );
}

inline fn sys0(n: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
        : "rcx", "r11", "memory"
    );
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
        : "rcx", "r11", "memory"
    );
}

inline fn sys2(n: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
        : "rcx", "r11", "memory"
    );
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}

inline fn sys4(n: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
          [d] "{r10}" (a4),
        : "rcx", "r11", "memory"
    );
}

const SYS_READ: usize = 0;
const SYS_WRITE: usize = 1;
const SYS_CLOSE: usize = 3;
const SYS_IOCTL: usize = 16;
const SYS_PIPE: usize = 22;
const SYS_GETPID: usize = 39;
const SYS_FORK: usize = 57;
const SYS_EXIT: usize = 60;
const SYS_WAIT4: usize = 61;
const SYS_FCNTL: usize = 72;
const SYS_SETPGID: usize = 109;
const SYS_GETPGRP: usize = 111;
const SYS_SETSID: usize = 112;
const SYS_GETPGID: usize = 121;
const SYS_EXIT_GROUP: usize = 231;

const TCGETS: usize = 0x5401;
const TCSETS: usize = 0x5402;
const TIOCGPGRP: usize = 0x540F;
const TIOCSPGRP: usize = 0x5410;
const TIOCGWINSZ: usize = 0x5413;
const TIOCSWINSZ: usize = 0x5414;

const F_GETFL: usize = 3;
const F_SETFL: usize = 4;
const O_NONBLOCK: usize = 0o4000;

pub const KernelTermios = extern struct {
    c_iflag: u32 = 0,
    c_oflag: u32 = 0,
    c_cflag: u32 = 0,
    c_lflag: u32 = 0,
    c_line: u8 = 0,
    c_cc: [19]u8 = [_]u8{0} ** 19,
    comptime {
        std.debug.assert(@sizeOf(KernelTermios) == 36);
    }
};

pub const Winsize = extern struct {
    ws_row: u16 = 0,
    ws_col: u16 = 0,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
    comptime {
        std.debug.assert(@sizeOf(Winsize) == 8);
    }
};

fn print(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("\n[CHALLENGER12_FAIL] Code ");
    var num_buf: [16]u8 = undefined;
    var val = code;
    var idx: usize = num_buf.len;
    if (val == 0) {
        idx -= 1;
        num_buf[idx] = '0';
    } else {
        while (val > 0) {
            idx -= 1;
            num_buf[idx] = '0' + @as(u8, @intCast(val % 10));
            val /= 10;
        }
    }
    print(num_buf[idx..]);
    print(": ");
    print(msg);
    print("\n");
    _ = sys1(SYS_EXIT_GROUP, code);
    unreachable;
}

pub export fn testMain() callconv(.C) noreturn {
    print("\n[CHALLENGER12] Starting empirical verification suite for TASK-012...\n");

    // =========================================================================
    // 1. Process Group Syscalls (sys_getpgrp, sys_getpgid, sys_setpgid, sys_setsid)
    // =========================================================================
    print("[CHALLENGER12] Step 1: Testing process group syscalls...\n");
    const my_pid: usize = @intCast(sys0(SYS_GETPID));
    if (my_pid == 0) fail(1, "sys_getpid returned 0");

    const pgrp1 = sys0(SYS_GETPGRP);
    if (pgrp1 <= 0) fail(2, "sys_getpgrp returned non-positive value");

    const pgid_self = sys1(SYS_GETPGID, 0);
    if (pgid_self != pgrp1) fail(3, "sys_getpgid(0) does not match sys_getpgrp()");

    const pgid_my_pid = sys1(SYS_GETPGID, my_pid);
    if (pgid_my_pid != pgrp1) fail(4, "sys_getpgid(my_pid) does not match sys_getpgrp()");

    const pgid_invalid = sys1(SYS_GETPGID, 9999);
    if (pgid_invalid != -3) fail(5, "sys_getpgid(9999) did not return -ESRCH (-3)");

    const setpgid_self = sys2(SYS_SETPGID, 0, 0);
    if (setpgid_self != 0) fail(6, "sys_setpgid(0, 0) failed");
    if (sys0(SYS_GETPGRP) != @as(isize, @intCast(my_pid))) fail(7, "sys_setpgid(0, 0) did not set pgrp to pid");

    const setpgid_custom = sys2(SYS_SETPGID, 0, 555);
    if (setpgid_custom != 0) fail(8, "sys_setpgid(0, 555) failed");
    if (sys0(SYS_GETPGRP) != 555) fail(9, "sys_setpgid(0, 555) did not update pgrp");

    const setpgid_invalid = sys2(SYS_SETPGID, 9999, 555);
    if (setpgid_invalid != -3) fail(10, "sys_setpgid(9999, 555) did not return -ESRCH");

    const sid_res = sys0(SYS_SETSID);
    if (sid_res != @as(isize, @intCast(my_pid))) fail(11, "sys_setsid did not return calling pid");
    if (sys0(SYS_GETPGRP) != @as(isize, @intCast(my_pid))) fail(12, "sys_setsid did not set pgid to pid");

    // Test fork inheritance
    const child_pid = sys0(SYS_FORK);
    if (child_pid < 0) fail(13, "fork failed");
    if (child_pid == 0) {
        // In child: verify inherited pgid
        if (sys0(SYS_GETPGRP) != @as(isize, @intCast(my_pid))) {
            _ = sys1(SYS_EXIT, 81);
        }
        const c_pid: usize = @intCast(sys0(SYS_GETPID));
        if (sys2(SYS_SETPGID, 0, 0) != 0) {
            _ = sys1(SYS_EXIT, 82);
        }
        if (sys0(SYS_GETPGRP) != @as(isize, @intCast(c_pid))) {
            _ = sys1(SYS_EXIT, 83);
        }
        _ = sys1(SYS_EXIT, 42);
        unreachable;
    }

    var wait_status: i32 = 0;
    const reaped = sys4(SYS_WAIT4, @intCast(child_pid), @intFromPtr(&wait_status), 0, 0);
    if (reaped != child_pid) fail(14, "wait4 failed to reap child");
    const exit_code = (wait_status >> 8) & 0xFF;
    if (exit_code != 42) fail(15, "child process failed process group fork test");

    // =========================================================================
    // 2. TTY ioctl ABI (TIOCGPGRP, TIOCSPGRP, TIOCGWINSZ, TIOCSWINSZ, TCGETS, TCSETS)
    // =========================================================================
    print("[CHALLENGER12] Step 2: Testing TTY ioctl ABI contract...\n");
    var fg_grp: i32 = 0;
    if (sys3(SYS_IOCTL, 0, TIOCGPGRP, @intFromPtr(&fg_grp)) != 0) fail(20, "ioctl(0, TIOCGPGRP) failed");
    if (fg_grp <= 0) fail(21, "TIOCGPGRP returned non-positive process group");

    const orig_fg = fg_grp;
    var new_fg: i32 = 777;
    if (sys3(SYS_IOCTL, 0, TIOCSPGRP, @intFromPtr(&new_fg)) != 0) fail(22, "ioctl(0, TIOCSPGRP) failed");
    var check_fg: i32 = 0;
    _ = sys3(SYS_IOCTL, 0, TIOCGPGRP, @intFromPtr(&check_fg));
    if (check_fg != 777) fail(23, "TIOCSPGRP did not update foreground pgrp");
    _ = sys3(SYS_IOCTL, 0, TIOCSPGRP, @intFromPtr(&orig_fg));

    // Fault check: invalid user pointer must return -EFAULT (-14)
    if (sys3(SYS_IOCTL, 0, TIOCGPGRP, 0) != -14) fail(24, "ioctl(0, TIOCGPGRP, NULL) did not return -EFAULT");

    // ENOTTY check on non-tty fd (pipe)
    var p_fds: [2]i32 = undefined;
    if (sys1(SYS_PIPE, @intFromPtr(&p_fds)) == 0) {
        const pipe_ioctl = sys3(SYS_IOCTL, @intCast(p_fds[0]), TIOCGPGRP, @intFromPtr(&fg_grp));
        if (pipe_ioctl != -25) fail(25, "ioctl on pipe did not return -ENOTTY (-25)");
        _ = sys1(SYS_CLOSE, @intCast(p_fds[0]));
        _ = sys1(SYS_CLOSE, @intCast(p_fds[1]));
    }

    // Winsize check
    var ws: Winsize = .{};
    if (sys3(SYS_IOCTL, 0, TIOCGWINSZ, @intFromPtr(&ws)) != 0) fail(26, "ioctl(0, TIOCGWINSZ) failed");
    if (ws.ws_row != 24 or ws.ws_col != 80) fail(27, "TIOCGWINSZ default is not 24x80");

    var update_ws: Winsize = .{ .ws_row = 35, .ws_col = 110 };
    if (sys3(SYS_IOCTL, 0, TIOCSWINSZ, @intFromPtr(&update_ws)) != 0) fail(28, "ioctl(0, TIOCSWINSZ) failed");
    var verify_ws: Winsize = .{};
    _ = sys3(SYS_IOCTL, 0, TIOCGWINSZ, @intFromPtr(&verify_ws));
    if (verify_ws.ws_row != 35 or verify_ws.ws_col != 110) fail(29, "TIOCSWINSZ did not update winsize");
    _ = sys3(SYS_IOCTL, 0, TIOCSWINSZ, @intFromPtr(&ws)); // restore

    // Termios check
    var term: KernelTermios = .{};
    if (sys3(SYS_IOCTL, 0, TCGETS, @intFromPtr(&term)) != 0) fail(30, "ioctl(0, TCGETS) failed");
    if ((term.c_iflag & 0x0100) == 0) fail(31, "TCGETS ICRNL bit not set");
    if ((term.c_lflag & 0x0002) == 0) fail(32, "TCGETS ICANON bit not set");
    if ((term.c_lflag & 0x0008) == 0) fail(33, "TCGETS ECHO bit not set");

    // =========================================================================
    // 3. Non-blocking Console Read (O_NONBLOCK -> -EAGAIN)
    // =========================================================================
    print("[CHALLENGER12] Step 3: Testing non-blocking console read (O_NONBLOCK)...\n");
    const orig_flags = sys2(SYS_FCNTL, 0, F_GETFL);
    if (orig_flags < 0) fail(40, "fcntl(0, F_GETFL) failed");

    if (sys3(SYS_FCNTL, 0, F_SETFL, @as(usize, @intCast(orig_flags)) | O_NONBLOCK) != 0) {
        fail(41, "fcntl(0, F_SETFL, O_NONBLOCK) failed");
    }

    var nb_buf: [32]u8 = undefined;
    const nb_res = sys3(SYS_READ, 0, @intFromPtr(&nb_buf), nb_buf.len);
    if (nb_res != -11) fail(42, "non-blocking read did not return -EAGAIN (-11)");

    // Restore blocking flags
    _ = sys3(SYS_FCNTL, 0, F_SETFL, @as(usize, @intCast(orig_flags)));

    // =========================================================================
    // 4. Instruction Pointer Rewinding (user_rip -= 2) under Blocking Read
    // =========================================================================
    print("[CHALLENGER12] Step 4: Testing instruction rewind on blocking read...\n");
    print("[CHALLENGER12_HOOK] READY_READ_STREAM_1\n");

    var stream_buf1: [32]u8 = undefined;
    const n1 = sys3(SYS_READ, 0, @intFromPtr(&stream_buf1), stream_buf1.len);
    if (n1 <= 0) fail(50, "blocking read stream 1 returned <= 0");
    const s1 = stream_buf1[0..@intCast(n1)];
    if (!std.mem.eql(u8, s1, "CHALLENGE_LINE1\n")) fail(51, "stream 1 payload mismatch");

    // =========================================================================
    // 5. Line Discipline Backspace Erase (\x08 / \x7F)
    // =========================================================================
    print("[CHALLENGER12] Step 5: Testing canonical backspace erase...\n");
    print("[CHALLENGER12_HOOK] READY_READ_STREAM_2\n");

    var stream_buf2: [32]u8 = undefined;
    const n2 = sys3(SYS_READ, 0, @intFromPtr(&stream_buf2), stream_buf2.len);
    if (n2 <= 0) fail(60, "blocking read stream 2 returned <= 0");
    const s2 = stream_buf2[0..@intCast(n2)];
    if (!std.mem.eql(u8, s2, "ac\n")) fail(61, "backspace did not erase character");

    // =========================================================================
    // 6. Canonical Line Reading Verification
    // =========================================================================
    print("[CHALLENGER12] Step 6: Testing canonical line discipline...\n");
    print("[CHALLENGER12_HOOK] READY_READ_STREAM_3\n");

    var stream_buf3: [32]u8 = undefined;
    const n3 = sys3(SYS_READ, 0, @intFromPtr(&stream_buf3), stream_buf3.len);
    if (n3 <= 0) fail(70, "blocking read stream 3 returned <= 0");
    const s3 = stream_buf3[0..@intCast(n3)];
    if (!std.mem.eql(u8, s3, "tinux_canonical\n")) fail(71, "canonical line discipline mismatch");

    // =========================================================================
    // 7. Line Discipline Ctrl+D EOF Handling
    // =========================================================================
    print("[CHALLENGER12] Step 7: Testing Ctrl+D EOF handling...\n");
    print("[CHALLENGER12_HOOK] READY_READ_STREAM_4\n");

    var stream_buf4: [32]u8 = undefined;
    const n4 = sys3(SYS_READ, 0, @intFromPtr(&stream_buf4), stream_buf4.len);
    if (n4 != 0) fail(80, "Ctrl+D did not return 0 (EOF)");

    print("\n[CHALLENGER12_PASS] ALL_ADVERSARIAL_CHALLENGES_CONFIRMED\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}
