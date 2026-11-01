// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Clean-room Adversarial IPC Pipe Semantics and Concurrency Verifier

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

fn print(msg: []const u8) void {
    _ = sys3(1, 1, @intFromPtr(msg.ptr), msg.len);
}

fn printInt(val: isize) void {
    var buf: [32]u8 = undefined;
    var v = val;
    var idx: usize = buf.len;
    var neg = false;
    if (v < 0) {
        neg = true;
        v = -v;
    } else if (v == 0) {
        idx -= 1;
        buf[idx] = '0';
        print(buf[idx..]);
        return;
    }
    while (v > 0) {
        idx -= 1;
        buf[idx] = '0' + @as(u8, @intCast(@as(usize, @intCast(v)) % 10));
        v = @divTrunc(v, 10);
    }
    if (neg) {
        idx -= 1;
        buf[idx] = '-';
    }
    print(buf[idx..]);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("[ADVERSARIAL_FAIL] ");
    print(msg);
    print("\n");
    _ = sys1(60, code);
    unreachable;
}

const LinuxTimespec = struct {
    tv_sec: i64,
    tv_nsec: i64,
};

fn sleepMs(ms: u64) void {
    const ts = LinuxTimespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = sys2(35, @intFromPtr(&ts), 0);
}

var test_buf: [4096]u8 = undefined;
var small_buf: [256]u8 = undefined;

pub export fn testMain() callconv(.C) noreturn {
    print("\n[ADVERSARIAL_TEST] START: IPC Pipe Semantics & Concurrency Suite\n");

    for (&test_buf, 0..) |*b, i| {
        b.* = @as(u8, @truncate(i & 0xFF));
    }

    // Close any inherited file descriptors > 2 (e.g. script fd from /bin/sh)
    var clean_fd: usize = 3;
    while (clean_fd < 32) : (clean_fd += 1) {
        _ = sys1(3, clean_fd);
    }

    // =========================================================================
    // Challenge 1: Buffer Capacity Boundary (4096 bytes) and Blocking
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 1: Testing Pipe Ring Buffer Capacity (4096 bytes)...\n");
    var pfd1: [2]i32 = .{ -1, -1 };
    if (sys2(293, @intFromPtr(&pfd1), 0) != 0) fail(101, "Challenge 1: pipe2 failed");

    // Write full 4096 bytes
    const written1 = sys3(1, @intCast(pfd1[1]), @intFromPtr(&test_buf), 4096);
    if (written1 != 4096) fail(102, "Challenge 1: Failed to write exactly 4096 bytes into empty pipe");
    print("[ADVERSARIAL_TEST] Successfully filled 4096 bytes in pipe.\n");

    // Test writing beyond capacity: child process attempts to write 1 more byte and must block
    const child1 = sys0(57); // sys_fork
    if (child1 < 0) fail(103, "Challenge 1: fork failed");

    if (child1 == 0) {
        // Child: write 1 byte to full pipe (should block)
        const b: u8 = 0xAA;
        const w = sys3(1, @intCast(pfd1[1]), @intFromPtr(&b), 1);
        if (w != 1) {
            _ = sys1(60, 99);
        } else {
            _ = sys1(60, 42); // Woken and written successfully
        }
        unreachable;
    }

    // Parent: verify child is blocked in WAITING_PIPE_WRITE
    sleepMs(50);
    var status1: i32 = 0;
    const check1 = sys4(61, @intCast(child1), @intFromPtr(&status1), 1, 0); // WNOHANG
    if (check1 != 0) fail(104, "Challenge 1: Child did not block on full pipe write!");
    print("[ADVERSARIAL_TEST] Confirmed: Writer child blocked on full 4096-byte pipe.\n");

    // Read 512 bytes to create space and wake blocked writer child
    const read1 = sys3(0, @intCast(pfd1[0]), @intFromPtr(&small_buf), 256);
    if (read1 != 256) fail(105, "Challenge 1: Parent read failed");
    const read2 = sys3(0, @intCast(pfd1[0]), @intFromPtr(&small_buf), 256);
    if (read2 != 256) fail(106, "Challenge 1: Parent read 2 failed");

    // Child should now be unblocked and exit with status 42
    const reaped1 = sys4(61, @intCast(child1), @intFromPtr(&status1), 0, 0);
    if (reaped1 != child1) fail(107, "Challenge 1: wait4 failed to reap child");
    if ((status1 >> 8) != 42) fail(108, "Challenge 1: Child did not complete write after wake");

    _ = sys1(3, @intCast(pfd1[0]));
    _ = sys1(3, @intCast(pfd1[1]));
    print("[ADVERSARIAL_TEST] PASS: Challenge 1 (4096 capacity & writer blocking) verified.\n");

    // =========================================================================
    // Challenge 2: Broken Pipe (-EPIPE / -32)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 2: Testing Broken Pipe (-EPIPE)...\n");
    var pfd2: [2]i32 = .{ -1, -1 };
    if (sys2(293, @intFromPtr(&pfd2), 0) != 0) fail(201, "Challenge 2: pipe2 failed");

    // Close reader immediately
    _ = sys1(3, @intCast(pfd2[0]));

    // Writing to pipe with readers == 0 must return -EPIPE (-32)
    const broken_res = sys3(1, @intCast(pfd2[1]), @intFromPtr(&test_buf), 10);
    if (broken_res != -32) {
        print("[ADVERSARIAL_FAIL] Expected -32 (EPIPE), got: ");
        printInt(broken_res);
        print("\n");
        fail(202, "Challenge 2: write on broken pipe did not return -EPIPE (-32)");
    }
    _ = sys1(3, @intCast(pfd2[1]));
    print("[ADVERSARIAL_TEST] PASS: Challenge 2 (broken pipe returns -32) verified.\n");

    // =========================================================================
    // Challenge 3: EOF Condition (returns 0 when all writers closed)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 3: Testing Pipe EOF on Closed Writers...\n");
    var pfd3: [2]i32 = .{ -1, -1 };
    if (sys2(293, @intFromPtr(&pfd3), 0) != 0) fail(301, "Challenge 3: pipe2 failed");

    // Write 16 bytes
    _ = sys3(1, @intCast(pfd3[1]), @intFromPtr("0123456789ABCDEF"), 16);

    // Close write end
    _ = sys1(3, @intCast(pfd3[1]));

    // First read gets all 16 bytes
    const eof_r1 = sys3(0, @intCast(pfd3[0]), @intFromPtr(&small_buf), 16);
    if (eof_r1 != 16) fail(302, "Challenge 3: Failed to drain pipe before EOF");

    // Subsequent read on empty pipe with writers == 0 must return 0 (EOF) immediately
    const eof_r2 = sys3(0, @intCast(pfd3[0]), @intFromPtr(&small_buf), 16);
    if (eof_r2 != 0) {
        print("[ADVERSARIAL_FAIL] Expected 0 (EOF), got: ");
        printInt(eof_r2);
        print("\n");
        fail(303, "Challenge 3: read on closed pipe did not return 0 (EOF)");
    }
    _ = sys1(3, @intCast(pfd3[0]));
    print("[ADVERSARIAL_TEST] PASS: Challenge 3 (empty pipe with closed writers returns 0) verified.\n");

    // =========================================================================
    // Challenge 4: Non-blocking Semantics (O_NONBLOCK 0x800)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 4: Challenging O_NONBLOCK (0x800) on pipe read...\n");
    // Allocate pipe with O_NONBLOCK (0x800 = 2048)
    var pfd4: [2]i32 = .{ -1, -1 };
    const pipe2_ret = sys2(293, @intFromPtr(&pfd4), 0x800);
    if (pipe2_ret != 0) fail(401, "Challenge 4: pipe2(pfd, O_NONBLOCK) failed");

    // Challenge: In Linux ABI, read on empty pipe with writers > 0 must return -EAGAIN (-11).
    // In Tinux, does it return -EAGAIN or does it block?
    const child4 = sys0(57);
    if (child4 < 0) fail(402, "Challenge 4: fork failed");

    if (child4 == 0) {
        // Child reads from empty non-blocking pipe
        const r4 = sys3(0, @intCast(pfd4[0]), @intFromPtr(&small_buf), 10);
        if (r4 == -11) {
            // Returned -EAGAIN as expected by Linux ABI!
            _ = sys1(60, 11);
        } else {
            // Returned unexpected value
            _ = sys1(60, 99);
        }
        unreachable;
    }

    // Parent inspects child state after 50ms
    sleepMs(50);
    var status4: i32 = 0;
    const check4 = sys4(61, @intCast(child4), @intFromPtr(&status4), 1, 0); // WNOHANG

    if (check4 == child4 and (status4 >> 8) == 11) {
        print("[ADVERSARIAL_OBSERVATION] O_NONBLOCK read returned -EAGAIN (-11).\n");
    } else {
        print("[ADVERSARIAL_DEFECT_DISCOVERED] O_NONBLOCK read did NOT return -EAGAIN (-11)!\n");
        print("[ADVERSARIAL_DEFECT_DISCOVERED] Child process blocked in WAITING_PIPE_READ despite O_NONBLOCK flag!\n");
        // Wake / kill the stuck child
        _ = sys2(62, @intCast(child4), 9); // sys_kill(SIGKILL)
        _ = sys4(61, @intCast(child4), @intFromPtr(&status4), 0, 0);
    }

    // Now challenge write on full non-blocking pipe
    print("[ADVERSARIAL_TEST] Challenging O_NONBLOCK (0x800) on pipe write when full...\n");
    _ = sys3(1, @intCast(pfd4[1]), @intFromPtr(&test_buf), 4096);

    const child4_w = sys0(57);
    if (child4_w < 0) fail(403, "Challenge 4: fork write child failed");

    if (child4_w == 0) {
        // Child writes 1 byte to full non-blocking pipe
        const b: u8 = 0x55;
        const w4 = sys3(1, @intCast(pfd4[1]), @intFromPtr(&b), 1);
        if (w4 == -11) {
            _ = sys1(60, 11);
        } else {
            _ = sys1(60, 99);
        }
        unreachable;
    }

    sleepMs(50);
    var status4_w: i32 = 0;
    const check4_w = sys4(61, @intCast(child4_w), @intFromPtr(&status4_w), 1, 0); // WNOHANG
    if (check4_w == child4_w and (status4_w >> 8) == 11) {
        print("[ADVERSARIAL_OBSERVATION] O_NONBLOCK write returned -EAGAIN (-11).\n");
    } else {
        print("[ADVERSARIAL_DEFECT_DISCOVERED] O_NONBLOCK write did NOT return -EAGAIN (-11)!\n");
        print("[ADVERSARIAL_DEFECT_DISCOVERED] Writer child blocked in WAITING_PIPE_WRITE despite O_NONBLOCK flag!\n");
        _ = sys2(62, @intCast(child4_w), 9); // sys_kill(SIGKILL)
        _ = sys4(61, @intCast(child4_w), @intFromPtr(&status4_w), 0, 0);
    }

    _ = sys1(3, @intCast(pfd4[0]));
    _ = sys1(3, @intCast(pfd4[1]));

    // =========================================================================
    // Challenge 4b: Testing O_CLOEXEC across execve
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 4b: Testing O_CLOEXEC closure across execve...\n");
    var cloexec_pfd1: [2]i32 = .{ -1, -1 };
    // Allocate pipe with O_CLOEXEC (0x80000) -> gets fds 3, 4
    if (sys2(293, @intFromPtr(&cloexec_pfd1), 0x80000) != 0) fail(451, "pipe2 cloexec failed");

    var regular_pfd: [2]i32 = .{ -1, -1 };
    // Allocate pipe without O_CLOEXEC -> gets fds 5, 6
    if (sys2(293, @intFromPtr(&regular_pfd), 0) != 0) fail(452, "pipe2 regular failed");

    // dup3 regular_pfd[0] (fd 5) to fd 10 with O_CLOEXEC (0x80000)
    if (sys3(292, @intCast(regular_pfd[0]), 10, 0x80000) != 10) fail(453, "dup3 cloexec failed");

    // dup3 regular_pfd[1] (fd 6) to fd 11 without O_CLOEXEC (0)
    if (sys3(292, @intCast(regular_pfd[1]), 11, 0) != 11) fail(454, "dup3 regular failed");

    var arg_clo_r: [16]u8 = undefined;
    var arg_clo_w: [16]u8 = undefined;
    var arg_clo_dup: [16]u8 = undefined;
    var arg_noclo_w: [16]u8 = undefined;
    var arg_noclo_dup: [16]u8 = undefined;

    const s_clo_r = std.fmt.bufPrintZ(&arg_clo_r, "{d}", .{cloexec_pfd1[0]}) catch "";
    const s_clo_w = std.fmt.bufPrintZ(&arg_clo_w, "{d}", .{cloexec_pfd1[1]}) catch "";
    const s_clo_dup = std.fmt.bufPrintZ(&arg_clo_dup, "{d}", .{@as(usize, 10)}) catch "";
    const s_noclo_w = std.fmt.bufPrintZ(&arg_noclo_w, "{d}", .{regular_pfd[1]}) catch "";
    const s_noclo_dup = std.fmt.bufPrintZ(&arg_noclo_dup, "{d}", .{@as(usize, 11)}) catch "";

    const child_exec = sys0(57);
    if (child_exec == 0) {
        // Child calls execve("/bin/cloexec_child", argv, envp)
        const prog: [*:0]const u8 = "/bin/cloexec_child";
        const argv = [_:null]?[*:0]const u8{
            prog,
            s_clo_r.ptr,
            s_clo_w.ptr,
            s_clo_dup.ptr,
            s_noclo_w.ptr,
            s_noclo_dup.ptr,
            null,
        };
        const envp = [_:null]?[*:0]const u8{null};
        _ = sys3(59, @intFromPtr(prog), @intFromPtr(&argv), @intFromPtr(&envp));
        _ = sys1(60, 99);
        unreachable;
    }

    var status_exec: i32 = 0;
    const reaped_exec = sys4(61, @intCast(child_exec), @intFromPtr(&status_exec), 0, 0);
    if (reaped_exec != child_exec or (status_exec >> 8) != 0) {
        fail(455, "Challenge 4b: cloexec child failed!");
    }
    print("[ADVERSARIAL_TEST] PASS: Challenge 4b (O_CLOEXEC across execve) verified.\n");

    _ = sys1(3, @intCast(cloexec_pfd1[0]));
    _ = sys1(3, @intCast(cloexec_pfd1[1]));
    _ = sys1(3, @intCast(regular_pfd[0]));
    _ = sys1(3, @intCast(regular_pfd[1]));
    _ = sys1(3, 10);
    _ = sys1(3, 11);

    // =========================================================================
    // Challenge 5: Pipe Exhaustion (MAX_PIPES = 16)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 5: Testing Pipe Exhaustion (MAX_PIPES = 16)...\n");

    // Process 1 allocates 8 pipes (takes 16 descriptors: fds 3..18)
    var p1_pipes: [8][2]i32 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (sys2(293, @intFromPtr(&p1_pipes[i]), 0) != 0) {
            fail(501, "Challenge 5: Process 1 failed to allocate 8 pipes");
        }
    }
    print("[ADVERSARIAL_TEST] Process 1 successfully allocated 8 pipes (slots 0..7).\n");

    // Fork Process 2 to allocate the remaining 8 pipes
    const child5 = sys0(57);
    if (child5 < 0) fail(502, "Challenge 5: fork failed");

    if (child5 == 0) {
        // Child closes inherited file descriptors to free its fd table slots
        var c_idx: usize = 0;
        while (c_idx < 8) : (c_idx += 1) {
            _ = sys1(3, @intCast(p1_pipes[c_idx][0]));
            _ = sys1(3, @intCast(p1_pipes[c_idx][1]));
        }

        // Child allocates 8 more pipes (slots 8..15)
        var p2_pipes: [8][2]i32 = undefined;
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            if (sys2(293, @intFromPtr(&p2_pipes[j]), 0) != 0) {
                _ = sys1(60, 51); // allocation failed prematurely
                unreachable;
            }
        }

        // System pipe table is now completely full (16 pipes in use).
        // Attempting to allocate the 17th pipe MUST fail with -ENFILE (-23).
        var overflow_pfd: [2]i32 = .{ -1, -1 };
        const over_ret = sys2(293, @intFromPtr(&overflow_pfd), 0);
        if (over_ret != -23) {
            // Failed: did not return -ENFILE (-23)
            _ = sys1(60, 52);
            unreachable;
        }

        // Close one pipe (slot 15)
        _ = sys1(3, @intCast(p2_pipes[7][0]));
        _ = sys1(3, @intCast(p2_pipes[7][1]));

        // Now allocation should succeed again
        const retry_ret = sys2(293, @intFromPtr(&overflow_pfd), 0);
        if (retry_ret != 0) {
            _ = sys1(60, 53);
            unreachable;
        }

        _ = sys1(3, @intCast(overflow_pfd[0]));
        _ = sys1(3, @intCast(overflow_pfd[1]));

        // Close remaining child pipes
        j = 0;
        while (j < 7) : (j += 1) {
            _ = sys1(3, @intCast(p2_pipes[j][0]));
            _ = sys1(3, @intCast(p2_pipes[j][1]));
        }

        _ = sys1(60, 0); // Success
        unreachable;
    }

    var status5: i32 = 0;
    const reaped5 = sys4(61, @intCast(child5), @intFromPtr(&status5), 0, 0);
    if (reaped5 != child5) fail(503, "Challenge 5: wait4 failed to reap child");
    const exit_code5 = (status5 >> 8);
    if (exit_code5 != 0) {
        print("[ADVERSARIAL_FAIL] Child 5 exited with code: ");
        printInt(exit_code5);
        print("\n");
        fail(504, "Challenge 5: Pipe exhaustion test failed in child");
    }

    // Clean up process 1 pipes
    i = 0;
    while (i < 8) : (i += 1) {
        _ = sys1(3, @intCast(p1_pipes[i][0]));
        _ = sys1(3, @intCast(p1_pipes[i][1]));
    }
    print("[ADVERSARIAL_TEST] PASS: Challenge 5 (MAX_PIPES 16 exhaustion & ENFILE -23) verified.\n");

    print("\n[ADVERSARIAL_SUMMARY] ADVERSARIAL CHALLENGE EXECUTION COMPLETED!\n");
    _ = sys1(60, 0);
    unreachable;
}
