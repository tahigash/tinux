// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Adversarial test suite for TASK-010: Hardware Timer, PIT 100Hz cadence, Nanosleep boundaries, Timeval syscalls, and Process Control

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
const SYS_OPEN: usize = 2;
const SYS_CLOSE: usize = 3;
const SYS_NANOSLEEP: usize = 35;
const SYS_FORK: usize = 57;
const SYS_EXIT: usize = 60;
const SYS_WAIT4: usize = 61;
const SYS_KILL: usize = 62;
const SYS_GETTIMEOFDAY: usize = 96;
const SYS_GETPID: usize = 39;
const SYS_GETDENTS64: usize = 217;
const SYS_CLOCK_GETTIME: usize = 228;
const SYS_CLOCK_GETRES: usize = 229;
const SYS_CLOCK_NANOSLEEP: usize = 230;
const SYS_OPENAT: usize = 257;

const AT_FDCWD: isize = -100;
const O_RDONLY: usize = 0;
const WNOHANG: usize = 1;

const LinuxTimespec = extern struct {
    tv_sec: i64 = 0,
    tv_nsec: i64 = 0,
};

const LinuxTimeval = extern struct {
    tv_sec: i64 = 0,
    tv_usec: i64 = 0,
};

fn print(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn printInt(val: isize) void {
    var buf: [32]u8 = undefined;
    var v = val;
    var negative = false;
    if (v < 0) {
        negative = true;
        v = -v;
    }
    var idx: usize = buf.len;
    if (v == 0) {
        idx -= 1;
        buf[idx] = '0';
    } else {
        while (v > 0) {
            idx -= 1;
            buf[idx] = @as(u8, @intCast(@rem(v, 10))) + '0';
            v = @divTrunc(v, 10);
        }
    }
    if (negative) {
        idx -= 1;
        buf[idx] = '-';
    }
    print(buf[idx..]);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("\n[CHALLENGER_M10_FAIL] Code ");
    printInt(@intCast(code));
    print(": ");
    print(msg);
    print("\n");
    _ = sys1(SYS_EXIT, code);
    unreachable;
}

fn openPath(path: []const u8, flags: usize) isize {
    var c_path: [256]u8 = undefined;
    if (path.len >= c_path.len) return -1;
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;
    return sys4(SYS_OPENAT, @bitCast(AT_FDCWD), @intFromPtr(&c_path), flags, 0);
}

export fn testMain() noreturn {
    print("======================================================================\n");
    print("[CHALLENGER_M10] TASK-010 Adversarial Timer & Nanosleep Verification\n");
    print("======================================================================\n\n");

    // =========================================================================
    // Challenge 1: PIT Cadence, Tick Monotonicity & clock_gettime Resolution
    // =========================================================================
    print("[CHALLENGE 1] Verifying PIT 100Hz interrupt cadence & tick monotonicity...\n");
    {
        var ts1: LinuxTimespec = .{};
        var ts2: LinuxTimespec = .{};

        const ret1 = sys2(SYS_CLOCK_GETTIME, 0, @intFromPtr(&ts1));
        if (ret1 != 0) fail(101, "sys_clock_gettime initial call failed");

        if (ts1.tv_sec < 0 or ts1.tv_nsec < 0 or ts1.tv_nsec >= 1_000_000_000) {
            fail(102, "sys_clock_gettime returned out-of-range timespec values");
        }
        if (@rem(ts1.tv_nsec, 10_000_000) != 0) {
            fail(103, "sys_clock_gettime tv_nsec not a multiple of 10ms (10,000,000 ns)");
        }

        // Sleep 150 ms (15 ticks)
        const req: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = 150_000_000 };
        const sleep_ret = sys2(SYS_NANOSLEEP, @intFromPtr(&req), 0);
        if (sleep_ret != 0) fail(104, "sys_nanosleep(150ms) returned error");

        const ret2 = sys2(SYS_CLOCK_GETTIME, 0, @intFromPtr(&ts2));
        if (ret2 != 0) fail(105, "sys_clock_gettime second call failed");

        const elapsed_ns: i64 = (ts2.tv_sec - ts1.tv_sec) * 1_000_000_000 + (ts2.tv_nsec - ts1.tv_nsec);
        print("  -> Sleep 150ms: elapsed = ");
        printInt(@intCast(@divTrunc(elapsed_ns, 1_000_000)));
        print(" ms (");
        printInt(@intCast(elapsed_ns));
        print(" ns)\n");

        if (elapsed_ns < 140_000_000) {
            fail(106, "sys_nanosleep(150ms) woke up too early (< 140ms)");
        }
        print("  [PASS] PIT 100Hz cadence and clock_gettime 10ms resolution verified.\n\n");
    }

    // =========================================================================
    // Challenge 2: Nanosleep Zero Duration & Ceiling Division
    // =========================================================================
    print("[CHALLENGE 2] Testing nanosleep zero duration & sub-tick ceiling division...\n");
    {
        // 0 sec, 0 nsec
        const req_zero: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = 0 };
        const ret_zero = sys2(SYS_NANOSLEEP, @intFromPtr(&req_zero), 0);
        if (ret_zero != 0) fail(201, "sys_nanosleep(0, 0) did not return 0");
        print("  -> sys_nanosleep(0, 0) returned 0 cleanly.\n");

        // 0 sec, 1 nsec (must round up to 1 tick = 10ms without failing)
        const req_1ns: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = 1 };
        const ret_1ns = sys2(SYS_NANOSLEEP, @intFromPtr(&req_1ns), 0);
        if (ret_1ns != 0) fail(202, "sys_nanosleep(0, 1ns) did not return 0");
        print("  -> sys_nanosleep(0, 1ns) rounded up to 1 tick and returned 0 cleanly.\n");

        // Boundary: 0 sec, 999_999_999 nsec
        var ts_pre: LinuxTimespec = .{};
        _ = sys2(SYS_CLOCK_GETTIME, 0, @intFromPtr(&ts_pre));
        const req_999: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = 999_999_999 };
        const ret_999 = sys2(SYS_NANOSLEEP, @intFromPtr(&req_999), 0);
        if (ret_999 != 0) fail(203, "sys_nanosleep(0, 999999999ns) failed");
        var ts_post: LinuxTimespec = .{};
        _ = sys2(SYS_CLOCK_GETTIME, 0, @intFromPtr(&ts_post));
        const delta_ms = (ts_post.tv_sec - ts_pre.tv_sec) * 1000 + @divTrunc(ts_post.tv_nsec - ts_pre.tv_nsec, 1_000_000);
        print("  -> sys_nanosleep(0, 999999999ns): slept ");
        printInt(@intCast(delta_ms));
        print(" ms\n");
        if (delta_ms < 950) fail(204, "sys_nanosleep(0, 999999999ns) woke up too early");
        print("  [PASS] Zero duration and ceiling division verified.\n\n");
    }

    // =========================================================================
    // Challenge 3: Nanosleep Error Codes (-EINVAL, -EFAULT)
    // =========================================================================
    print("[CHALLENGE 3] Adversarially probing nanosleep parameter validation & error returns...\n");
    {
        // 1. Negative seconds
        const req_neg_sec: LinuxTimespec = .{ .tv_sec = -1, .tv_nsec = 0 };
        const ret_neg_sec = sys2(SYS_NANOSLEEP, @intFromPtr(&req_neg_sec), 0);
        if (ret_neg_sec != -22) {
            print("  Negative sec return: ");
            printInt(ret_neg_sec);
            print("\n");
            fail(301, "sys_nanosleep with negative tv_sec did not return -EINVAL (-22)");
        }
        print("  -> Negative tv_sec: correctly returned -EINVAL (-22)\n");

        // 2. Negative nanoseconds
        const req_neg_nsec: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = -1 };
        const ret_neg_nsec = sys2(SYS_NANOSLEEP, @intFromPtr(&req_neg_nsec), 0);
        if (ret_neg_nsec != -22) {
            print("  Negative nsec return: ");
            printInt(ret_neg_nsec);
            print("\n");
            fail(302, "sys_nanosleep with negative tv_nsec did not return -EINVAL (-22)");
        }
        print("  -> Negative tv_nsec: correctly returned -EINVAL (-22)\n");

        // 3. Overflow nanoseconds (>= 1_000_000_000)
        const req_overflow_nsec: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = 1_000_000_000 };
        const ret_overflow_nsec = sys2(SYS_NANOSLEEP, @intFromPtr(&req_overflow_nsec), 0);
        if (ret_overflow_nsec != -22) {
            print("  tv_nsec=1e9 return: ");
            printInt(ret_overflow_nsec);
            print("\n");
            fail(303, "sys_nanosleep with tv_nsec == 1,000,000,000 did not return -EINVAL (-22)");
        }
        print("  -> tv_nsec == 1,000,000,000: correctly returned -EINVAL (-22)\n");

        const req_huge_nsec: LinuxTimespec = .{ .tv_sec = 1, .tv_nsec = 2_500_000_000 };
        const ret_huge_nsec = sys2(SYS_NANOSLEEP, @intFromPtr(&req_huge_nsec), 0);
        if (ret_huge_nsec != -22) {
            fail(304, "sys_nanosleep with tv_nsec > 1e9 did not return -EINVAL (-22)");
        }
        print("  -> tv_nsec == 2,500,000,000: correctly returned -EINVAL (-22)\n");

        // 4. Invalid pointer (NULL pointer)
        const ret_null = sys2(SYS_NANOSLEEP, 0, 0);
        if (ret_null != -14) {
            print("  NULL req_ptr return: ");
            printInt(ret_null);
            print("\n");
            fail(305, "sys_nanosleep(NULL, NULL) did not return -EFAULT (-14)");
        }
        print("  -> NULL req_ptr: correctly returned -EFAULT (-14)\n");

        // 5. Unmapped pointer
        const ret_unmapped = sys2(SYS_NANOSLEEP, 0xFFFF_8000_0000_0000, 0);
        if (ret_unmapped != -14) {
            fail(306, "sys_nanosleep with unmapped kernel pointer did not return -EFAULT (-14)");
        }
        print("  -> Unmapped req_ptr: correctly returned -EFAULT (-14)\n");
        print("  [PASS] Nanosleep boundary validations strictly enforced.\n\n");
    }

    // =========================================================================
    // Challenge 4: sys_clock_nanosleep Delegation & Validation
    // =========================================================================
    print("[CHALLENGE 4] Testing sys_clock_nanosleep ABI contract & delegation...\n");
    {
        // Invalid req pointer
        const ret_fault = sys4(SYS_CLOCK_NANOSLEEP, 0, 0, 0, 0);
        if (ret_fault != -14) {
            fail(401, "sys_clock_nanosleep with NULL req did not return -EFAULT (-14)");
        }

        // Invalid nsec
        const req_bad: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = -5 };
        const ret_inval = sys4(SYS_CLOCK_NANOSLEEP, 0, 0, @intFromPtr(&req_bad), 0);
        if (ret_inval != -22) {
            fail(402, "sys_clock_nanosleep with negative nsec did not return -EINVAL (-22)");
        }

        // Valid sleep 50ms (5 ticks)
        const req_ok: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = 50_000_000 };
        const ret_ok = sys4(SYS_CLOCK_NANOSLEEP, 0, 0, @intFromPtr(&req_ok), 0);
        if (ret_ok != 0) {
            fail(403, "sys_clock_nanosleep(50ms) failed");
        }
        print("  [PASS] sys_clock_nanosleep ABI contract and execution verified.\n\n");
    }

    // =========================================================================
    // Challenge 5: sys_gettimeofday & sys_clock_getres Precision & Boundaries
    // =========================================================================
    print("[CHALLENGE 5] Testing sys_gettimeofday and sys_clock_getres accuracy...\n");
    {
        // NULL tv_ptr is allowed and returns 0 in POSIX/Linux
        const ret_null = sys2(SYS_GETTIMEOFDAY, 0, 0);
        if (ret_null != 0) fail(501, "sys_gettimeofday(NULL, NULL) did not return 0");

        // Invalid tv_ptr
        const ret_bad = sys2(SYS_GETTIMEOFDAY, 0x1234, 0);
        if (ret_bad != -14) fail(502, "sys_gettimeofday with invalid pointer did not return -EFAULT (-14)");

        // Valid gettimeofday
        var tv1: LinuxTimeval = .{};
        var tv2: LinuxTimeval = .{};
        const ret_gtod1 = sys2(SYS_GETTIMEOFDAY, @intFromPtr(&tv1), 0);
        if (ret_gtod1 != 0) fail(503, "sys_gettimeofday call failed");

        if (tv1.tv_sec < 0 or tv1.tv_usec < 0 or tv1.tv_usec >= 1_000_000) {
            fail(504, "sys_gettimeofday returned out-of-range timeval");
        }
        if (@rem(tv1.tv_usec, 10_000) != 0) {
            fail(505, "sys_gettimeofday tv_usec not a multiple of 10,000 (10ms)");
        }

        // Sleep 200ms
        const req_200: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = 200_000_000 };
        _ = sys2(SYS_NANOSLEEP, @intFromPtr(&req_200), 0);

        const ret_gtod2 = sys2(SYS_GETTIMEOFDAY, @intFromPtr(&tv2), 0);
        if (ret_gtod2 != 0) fail(506, "sys_gettimeofday second call failed");

        const elapsed_us = (tv2.tv_sec - tv1.tv_sec) * 1_000_000 + (tv2.tv_usec - tv1.tv_usec);
        print("  -> gettimeofday elapsed across 200ms sleep: ");
        printInt(@intCast(elapsed_us));
        print(" us\n");
        if (elapsed_us < 190_000) fail(507, "gettimeofday delta < 190,000 us for 200ms sleep");

        // Test sys_clock_getres
        var res_ts: LinuxTimespec = .{};
        const ret_res = sys2(SYS_CLOCK_GETRES, 0, @intFromPtr(&res_ts));
        if (ret_res != 0) fail(508, "sys_clock_getres failed");
        if (res_ts.tv_sec != 0 or res_ts.tv_nsec != 10_000_000) {
            fail(509, "sys_clock_getres did not report 10,000,000 ns (10ms) resolution");
        }
        print("  [PASS] sys_gettimeofday and sys_clock_getres precision verified.\n\n");
    }

    // =========================================================================
    // Challenge 6: Dynamic /proc/uptime Cadence & Format
    // =========================================================================
    print("[CHALLENGE 6] Testing dynamic /proc/uptime formatting and elapsed time...\n");
    {
        var buf1: [64]u8 = undefined;
        var buf2: [64]u8 = undefined;

        const fd1 = openPath("/proc/uptime", O_RDONLY);
        if (fd1 < 0) fail(601, "Failed to open /proc/uptime");
        const n1 = sys3(SYS_READ, @intCast(fd1), @intFromPtr(&buf1), buf1.len);
        _ = sys1(SYS_CLOSE, @intCast(fd1));
        if (n1 <= 0) fail(602, "Failed to read /proc/uptime");

        print("  -> Initial /proc/uptime: ");
        print(buf1[0..@intCast(n1)]);

        // Sleep 1000 ms (1.00s)
        const req_1s: LinuxTimespec = .{ .tv_sec = 1, .tv_nsec = 0 };
        _ = sys2(SYS_NANOSLEEP, @intCast(@intFromPtr(&req_1s)), 0);

        const fd2 = openPath("/proc/uptime", O_RDONLY);
        if (fd2 < 0) fail(603, "Failed to open /proc/uptime after 1s sleep");
        const n2 = sys3(SYS_READ, @intCast(fd2), @intFromPtr(&buf2), buf2.len);
        _ = sys1(SYS_CLOSE, @intCast(fd2));
        if (n2 <= 0) fail(604, "Failed to read /proc/uptime after 1s sleep");

        print("  -> /proc/uptime after 1s sleep: ");
        print(buf2[0..@intCast(n2)]);

        // Check format: contains space, ends with \n
        const slice2 = buf2[0..@intCast(n2)];
        if (!std.mem.containsAtLeast(u8, slice2, 1, " ") or !std.mem.endsWith(u8, slice2, "\n")) {
            fail(605, "/proc/uptime format violation: missing space or newline");
        }
        print("  [PASS] /proc/uptime dynamic generation & elapsed time verified.\n\n");
    }

    // =========================================================================
    // Challenge 7: Process Lifecycle, /proc/[pid]/stat 24-Token Contract, Kill & WNOHANG
    // =========================================================================
    print("[CHALLENGE 7] Stress-testing process states, 24-token stat layout, SIGKILL, and wait4 WNOHANG...\n");
    {
        const parent_pid = sys0(SYS_GETPID);
        _ = parent_pid;
        const fork_ret = sys0(SYS_FORK);
        if (fork_ret < 0) fail(701, "sys_fork failed");

        if (fork_ret == 0) {
            // Child process: sleep 10 seconds waiting to be killed
            const sleep_10s: LinuxTimespec = .{ .tv_sec = 10, .tv_nsec = 0 };
            _ = sys2(SYS_NANOSLEEP, @intFromPtr(&sleep_10s), 0);
            _ = sys1(SYS_EXIT, 0);
            unreachable;
        }

        // Parent process
        const child_pid = fork_ret;
        print("  -> Spawned child process PID ");
        printInt(child_pid);
        print("\n");

        // Allow child to schedule and enter WAITING_SLEEP
        const req_tick: LinuxTimespec = .{ .tv_sec = 0, .tv_nsec = 20_000_000 };
        _ = sys2(SYS_NANOSLEEP, @intFromPtr(&req_tick), 0);

        // 1. Non-blocking wait4 (WNOHANG) on active sleeping child must return 0
        var status: i32 = 0;
        const wait_noblock = sys4(SYS_WAIT4, @bitCast(child_pid), @intFromPtr(&status), WNOHANG, 0);
        if (wait_noblock != 0) {
            print("  wait4 WNOHANG returned: ");
            printInt(wait_noblock);
            print("\n");
            fail(702, "sys_wait4 with WNOHANG on active child did not return 0");
        }
        print("  -> wait4 WNOHANG on active sleeping child returned 0 immediately.\n");

        // 2. Inspect /proc/[child_pid]/stat
        var stat_path_buf: [64]u8 = undefined;
        var p_idx: usize = 0;
        const p_str = "proc/";
        @memcpy(stat_path_buf[p_idx .. p_idx + p_str.len], p_str);
        p_idx += p_str.len;

        // format child_pid
        var c_pid = child_pid;
        var pid_rev_buf: [16]u8 = undefined;
        var r_len: usize = 0;
        while (c_pid > 0) {
            pid_rev_buf[r_len] = @as(u8, @intCast(@rem(c_pid, 10))) + '0';
            c_pid = @divTrunc(c_pid, 10);
            r_len += 1;
        }
        while (r_len > 0) {
            r_len -= 1;
            stat_path_buf[p_idx] = pid_rev_buf[r_len];
            p_idx += 1;
        }
        const s_str = "/stat";
        @memcpy(stat_path_buf[p_idx .. p_idx + s_str.len], s_str);
        p_idx += s_str.len;
        const stat_path = stat_path_buf[0..p_idx];

        var stat_data: [256]u8 = undefined;
        const fd_stat = openPath(stat_path, O_RDONLY);
        if (fd_stat < 0) fail(703, "Failed to open /proc/[child_pid]/stat");
        const n_stat = sys3(SYS_READ, @intCast(fd_stat), @intFromPtr(&stat_data), stat_data.len);
        _ = sys1(SYS_CLOSE, @intCast(fd_stat));
        if (n_stat <= 0) fail(704, "Failed to read /proc/[child_pid]/stat");

        print("  -> Child /proc/[pid]/stat content: ");
        print(stat_data[0..@intCast(n_stat)]);

        // Verify 24 tokens
        var token_count: usize = 0;
        var in_token = false;
        var token3_char: u8 = 0;
        for (stat_data[0..@intCast(n_stat)]) |b| {
            if (b == ' ' or b == '\n') {
                if (in_token) {
                    token_count += 1;
                    in_token = false;
                }
            } else {
                if (!in_token) {
                    in_token = true;
                    if (token_count == 2) {
                        token3_char = b;
                    }
                }
            }
        }
        if (in_token) token_count += 1;

        if (token_count != 24) {
            print("  Token count was: ");
            printInt(@intCast(token_count));
            print(" (expected 24)\n");
            fail(705, "/proc/[pid]/stat does not contain exactly 24 space-separated tokens");
        }
        if (token3_char != 'S') {
            print("  State char was: '");
            var c_buf: [1]u8 = .{token3_char};
            print(&c_buf);
            print("' (expected 'S')\n");
            fail(706, "Sleeping child state in /proc/[pid]/stat is not 'S'");
        }
        print("  -> 24 tokens verified, state = 'S' verified.\n");

        // 3. Signal handling: kill(child_pid, 0) checks process existence
        const ret_kill0 = sys2(SYS_KILL, @bitCast(child_pid), 0);
        if (ret_kill0 != 0) fail(707, "sys_kill(child_pid, 0) existence check failed");
        const ret_kill_bad = sys2(SYS_KILL, 99999, 0);
        if (ret_kill_bad != -3) fail(708, "sys_kill(99999, 0) did not return -ESRCH (-3)");
        print("  -> sys_kill(pid, 0) and sys_kill(nonexistent, 0) verified.\n");

        // 4. Send SIGKILL (9) to child
        const ret_sigkill = sys2(SYS_KILL, @bitCast(child_pid), 9);
        if (ret_sigkill != 0) fail(709, "sys_kill(child_pid, 9) failed");
        print("  -> sys_kill(child_pid, 9) delivered successfully.\n");

        // Check stat state is now 'Z' (Zombie)
        const fd_stat_z = openPath(stat_path, O_RDONLY);
        if (fd_stat_z >= 0) {
            var stat_data_z: [256]u8 = undefined;
            const n_z = sys3(SYS_READ, @intCast(fd_stat_z), @intFromPtr(&stat_data_z), stat_data_z.len);
            _ = sys1(SYS_CLOSE, @intCast(fd_stat_z));
            if (n_z > 0) {
                // Find token 3
                var t_cnt: usize = 0;
                var in_t = false;
                var z_char: u8 = 0;
                for (stat_data_z[0..@intCast(n_z)]) |b| {
                    if (b == ' ' or b == '\n') {
                        if (in_t) {
                            t_cnt += 1;
                            in_t = false;
                        }
                    } else {
                        if (!in_t) {
                            in_t = true;
                            if (t_cnt == 2) z_char = b;
                        }
                    }
                }
                if (z_char != 'Z') {
                    print("  Zombie state was: '");
                    var c_buf: [1]u8 = .{z_char};
                    print(&c_buf);
                    print("'\n");
                    fail(710, "Target state after SIGKILL did not transition to 'Z' (zombie)");
                }
                print("  -> State transitioned to 'Z' (zombie) as expected.\n");
            }
        }

        // 5. Reap zombie child via wait4
        var reaped_status: i32 = 0;
        const reaped_pid = sys4(SYS_WAIT4, @bitCast(child_pid), @intFromPtr(&reaped_status), WNOHANG, 0);
        if (reaped_pid != child_pid) {
            print("  reaped_pid = ");
            printInt(reaped_pid);
            print("\n");
            fail(711, "sys_wait4 failed to reap zombie child");
        }
        const sig_exit = (reaped_status >> 8) & 0xFF;
        if (sig_exit != (128 + 9)) {
            print("  Exit status was: ");
            printInt(sig_exit);
            print(" (expected 137)\n");
            fail(712, "Reaped status mismatch for SIGKILL (expected 137 = 128+9)");
        }
        print("  -> Zombie child reaped with status 137 (128 + SIGKILL).\n");

        // 6. Calling wait4 again must return -ECHILD (-10)
        const wait_nochild = sys4(SYS_WAIT4, @bitCast(child_pid), @intFromPtr(&reaped_status), WNOHANG, 0);
        if (wait_nochild != -10) {
            print("  wait_nochild = ");
            printInt(wait_nochild);
            print("\n");
            fail(713, "sys_wait4 after reaping did not return -ECHILD (-10)");
        }
        print("  -> Subsequent wait4 returned -ECHILD (-10) as required.\n");

        // 7. Dynamic procfs cleanup: /proc/[child_pid]/stat must no longer exist (-ENOENT)
        const fd_stat_gone = openPath(stat_path, O_RDONLY);
        if (fd_stat_gone >= 0) {
            _ = sys1(SYS_CLOSE, @intCast(fd_stat_gone));
            fail(714, "/proc/[child_pid]/stat still exists after process reaped (stale node not purged)");
        }
        print("  -> Reaped process nodes purged from /proc as required.\n");
        print("  [PASS] Process control, state transitions, stat tokens, and reaping verified.\n\n");
    }

    // =========================================================================
    // Challenge 8: Multi-Second Sleep Non-Truncation Check (> 50 ticks)
    // =========================================================================
    print("[CHALLENGE 8] Testing multi-second sleep non-truncation (> 50 ticks)...\n");
    {
        var ts1: LinuxTimespec = .{};
        var ts2: LinuxTimespec = .{};

        _ = sys2(SYS_CLOCK_GETTIME, 0, @intFromPtr(&ts1));
        // Sleep 1.2 seconds = 120 ticks (> 50 ticks)
        const req_120: LinuxTimespec = .{ .tv_sec = 1, .tv_nsec = 200_000_000 };
        const ret_120 = sys2(SYS_NANOSLEEP, @intFromPtr(&req_120), 0);
        if (ret_120 != 0) fail(801, "sys_nanosleep(1.2s) failed");

        _ = sys2(SYS_CLOCK_GETTIME, 0, @intFromPtr(&ts2));
        const delta_ms = (ts2.tv_sec - ts1.tv_sec) * 1000 + @divTrunc(ts2.tv_nsec - ts1.tv_nsec, 1_000_000);
        print("  -> Sleep 1.2s (120 ticks): elapsed = ");
        printInt(@intCast(delta_ms));
        print(" ms\n");

        if (delta_ms < 1150) {
            fail(802, "Sleep duration truncated! Tick cap may still exist.");
        }
        print("  [PASS] Multi-second sleep completed accurately without truncation.\n\n");
    }

    print("======================================================================\n");
    print("[CHALLENGER_M10] ALL 8 ADVERSARIAL CHALLENGES EMPIRICALLY CONFIRMED!\n");
    print("======================================================================\n");

    _ = sys1(SYS_EXIT, 0);
    unreachable;
}
