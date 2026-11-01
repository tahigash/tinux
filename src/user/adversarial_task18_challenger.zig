// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Comprehensive empirical adversarial challenge suite for TASK-018:
// Signal lifecycles, unmaskable signal protections, rt_sigaction/procmask validation,
// sys_pause return value (-EINTR), and signal stack alignment.

const std = @import("std");

pub const SYS_READ: usize = 0;
pub const SYS_WRITE: usize = 1;
pub const SYS_RT_SIGACTION: usize = 13;
pub const SYS_RT_SIGPROCMASK: usize = 14;
pub const SYS_RT_SIGRETURN: usize = 15;
pub const SYS_PAUSE: usize = 34;
pub const SYS_SETITIMER: usize = 38;
pub const SYS_GETPID: usize = 39;
pub const SYS_FORK: usize = 57;
pub const SYS_EXECVE: usize = 59;
pub const SYS_EXIT: usize = 60;
pub const SYS_WAIT4: usize = 61;
pub const SYS_KILL: usize = 62;
pub const SYS_EXIT_GROUP: usize = 231;

pub const SIGHUP: usize = 1;
pub const SIGINT: usize = 2;
pub const SIGQUIT: usize = 3;
pub const SIGKILL: usize = 9;
pub const SIGUSR1: usize = 10;
pub const SIGUSR2: usize = 12;
pub const SIGALRM: usize = 14;
pub const SIGTERM: usize = 15;
pub const SIGCHLD: usize = 17;
pub const SIGSTOP: usize = 19;

pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;

pub const SA_RESTORER: u64 = 0x0400_0000;
pub const SA_NODEFER: u64 = 0x4000_0000;

pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;

pub const EINVAL: isize = -22;
pub const EFAULT: isize = -14;
pub const ESRCH: isize = -3;
pub const EINTR: isize = -4;

pub const KernelSigAction = extern struct {
    sa_handler: usize align(1) = 0,
    sa_flags: u64 align(1) = 0,
    sa_restorer: usize align(1) = 0,
    sa_mask: u64 align(1) = 0,
};

pub const LinuxItimerval = extern struct {
    it_interval_sec: i64 align(1) = 0,
    it_interval_usec: i64 align(1) = 0,
    it_value_sec: i64 align(1) = 0,
    it_value_usec: i64 align(1) = 20_000, // 20ms
};

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

pub export fn sigRestorer() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq $15, %rax
        \\ syscall
    );
}

inline fn sys0(n: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n) : "rcx", "r11", "memory");
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1) : "rcx", "r11", "memory");
}

inline fn sys2(n: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2) : "rcx", "r11", "memory");
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3) : "rcx", "r11", "memory");
}

inline fn sys4(n: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3), [d] "{r10}" (a4) : "rcx", "r11", "memory");
}

fn writeStr(s: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(s.ptr), s.len);
}

fn assertEqual(actual: isize, expected: isize, msg: []const u8) void {
    if (actual != expected) {
        writeStr("[CHALLENGER_FAIL] ");
        writeStr(msg);
        writeStr(": expected ");
        printDec(expected);
        writeStr(", got ");
        printDec(actual);
        writeStr("\n");
        _ = sys1(SYS_EXIT_GROUP, 99);
        unreachable;
    }
}

fn assertTrue(cond: bool, msg: []const u8) void {
    if (!cond) {
        writeStr("[CHALLENGER_FAIL] Assertion failed: ");
        writeStr(msg);
        writeStr("\n");
        _ = sys1(SYS_EXIT_GROUP, 98);
        unreachable;
    }
}

fn printDec(val: isize) void {
    var buf: [24]u8 = undefined;
    var v = val;
    var idx: usize = buf.len;
    var neg = false;
    if (v < 0) {
        neg = true;
        v = -v;
    } else if (v == 0) {
        writeStr("0");
        return;
    }
    while (v > 0) {
        idx -= 1;
        buf[idx] = '0' + @as(u8, @intCast(@rem(v, 10)));
        v = @divTrunc(v, 10);
    }
    if (neg) {
        idx -= 1;
        buf[idx] = '-';
    }
    writeStr(buf[idx..]);
}

var g_handler_sig: usize = 0;
var g_usr1_count: usize = 0;
var g_usr2_count: usize = 0;
var g_alrm_count: usize = 0;
var g_chld_count: usize = 0;

export fn testSignalHandler(signum: usize) callconv(.C) void {
    // Check 16-byte stack alignment: (%rsp & 0xF) should be 0 inside function body
    var local: [16]u8 align(16) = [_]u8{0} ** 16;
    local[0] = @truncate(signum);
    if ((@intFromPtr(&local) & 0xF) != 0) {
        writeStr("[CHALLENGER_FATAL] Stack misaligned inside signal handler!\n");
        _ = sys1(SYS_EXIT_GROUP, 97);
    }

    g_handler_sig = signum;
    if (signum == SIGUSR1) {
        g_usr1_count += 1;
    } else if (signum == SIGUSR2) {
        g_usr2_count += 1;
    } else if (signum == SIGALRM) {
        g_alrm_count += 1;
    } else if (signum == SIGCHLD) {
        g_chld_count += 1;
    }
}

export fn challengerMain() callconv(.C) noreturn {
    writeStr("[CHALLENGER_M18] Starting adversarial tests for Milestone M18...\n");

    const default_act = KernelSigAction{
        .sa_handler = @intFromPtr(&testSignalHandler),
        .sa_flags = SA_RESTORER,
        .sa_restorer = @intFromPtr(&sigRestorer),
        .sa_mask = 0,
    };

    // =========================================================================
    // SECTION 1: Unmaskable Signal Protection (SIGKILL=9, SIGSTOP=19)
    // =========================================================================
    writeStr("[CHALLENGER_M18] Testing unmaskable signal protections...\n");

    // 1.1 rt_sigaction with SIGKILL must return -EINVAL
    assertEqual(sys4(SYS_RT_SIGACTION, SIGKILL, @intFromPtr(&default_act), 0, 8), EINVAL, "rt_sigaction(SIGKILL, act) != -EINVAL");
    // 1.2 rt_sigaction with SIGSTOP must return -EINVAL
    assertEqual(sys4(SYS_RT_SIGACTION, SIGSTOP, @intFromPtr(&default_act), 0, 8), EINVAL, "rt_sigaction(SIGSTOP, act) != -EINVAL");
    // 1.3 Setting SIG_IGN on SIGKILL/SIGSTOP must return -EINVAL
    const ign_act = KernelSigAction{ .sa_handler = SIG_IGN };
    assertEqual(sys4(SYS_RT_SIGACTION, SIGKILL, @intFromPtr(&ign_act), 0, 8), EINVAL, "rt_sigaction(SIGKILL, SIG_IGN) != -EINVAL");
    assertEqual(sys4(SYS_RT_SIGACTION, SIGSTOP, @intFromPtr(&ign_act), 0, 8), EINVAL, "rt_sigaction(SIGSTOP, SIG_IGN) != -EINVAL");

    // 1.4 Setting sa_mask with SIGKILL and SIGSTOP bits must strip them
    var poison_act = default_act;
    const kill_bit = @as(u64, 1) << (SIGKILL - 1); // bit 8
    const stop_bit = @as(u64, 1) << (SIGSTOP - 1); // bit 18
    poison_act.sa_mask = kill_bit | stop_bit | (@as(u64, 1) << (SIGINT - 1));
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR1, @intFromPtr(&poison_act), 0, 8), 0, "rt_sigaction(SIGUSR1, poison_act) failed");

    var read_oact = KernelSigAction{};
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR1, 0, @intFromPtr(&read_oact), 8), 0, "rt_sigaction(SIGUSR1, read_oact) failed");
    assertTrue((read_oact.sa_mask & kill_bit) == 0, "SIGKILL bit present in stored sa_mask!");
    assertTrue((read_oact.sa_mask & stop_bit) == 0, "SIGSTOP bit present in stored sa_mask!");
    assertTrue((read_oact.sa_mask & (@as(u64, 1) << (SIGINT - 1))) != 0, "SIGINT bit missing from stored sa_mask!");

    // 1.5 rt_sigprocmask must never allow blocking SIGKILL or SIGSTOP
    var block_unmaskable: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    assertEqual(sys4(SYS_RT_SIGPROCMASK, SIG_SETMASK, @intFromPtr(&block_unmaskable), 0, 8), 0, "rt_sigprocmask(SETMASK) failed");
    var cur_mask: u64 = 0;
    assertEqual(sys4(SYS_RT_SIGPROCMASK, SIG_BLOCK, 0, @intFromPtr(&cur_mask), 8), 0, "rt_sigprocmask read current failed");
    assertTrue((cur_mask & kill_bit) == 0, "SIGKILL bit was successfully set in proc sig_mask!");
    assertTrue((cur_mask & stop_bit) == 0, "SIGSTOP bit was successfully set in proc sig_mask!");

    // Unblock all signals again for clean slate
    var zero_mask: u64 = 0;
    assertEqual(sys4(SYS_RT_SIGPROCMASK, SIG_SETMASK, @intFromPtr(&zero_mask), 0, 8), 0, "rt_sigprocmask clear failed");
    writeStr("[CHALLENGER_M18] Unmaskable signal protections: PASS\n");

    // =========================================================================
    // SECTION 2: Syscall Argument Boundaries & Error Returns
    // =========================================================================
    writeStr("[CHALLENGER_M18] Testing boundary validation on rt_sigaction/procmask...\n");

    // 2.1 Invalid signal numbers
    assertEqual(sys4(SYS_RT_SIGACTION, 0, @intFromPtr(&default_act), 0, 8), EINVAL, "rt_sigaction(sig=0) != -EINVAL");
    assertEqual(sys4(SYS_RT_SIGACTION, 65, @intFromPtr(&default_act), 0, 8), EINVAL, "rt_sigaction(sig=65) != -EINVAL");
    assertEqual(sys4(SYS_RT_SIGACTION, 128, @intFromPtr(&default_act), 0, 8), EINVAL, "rt_sigaction(sig=128) != -EINVAL");

    // 2.2 Invalid sigsetsize (must be 8)
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR1, @intFromPtr(&default_act), 0, 4), EINVAL, "rt_sigaction(sigsetsize=4) != -EINVAL");
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR1, @intFromPtr(&default_act), 0, 16), EINVAL, "rt_sigaction(sigsetsize=16) != -EINVAL");
    assertEqual(sys4(SYS_RT_SIGPROCMASK, SIG_BLOCK, @intFromPtr(&zero_mask), 0, 4), EINVAL, "rt_sigprocmask(sigsetsize=4) != -EINVAL");

    // 2.3 Invalid pointers (non-canonical address)
    const bad_ptr: usize = 0xFFFF_8000_1234_0000;
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR1, bad_ptr, 0, 8), EFAULT, "rt_sigaction(bad act) != -EFAULT");
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR1, 0, bad_ptr, 8), EFAULT, "rt_sigaction(bad oact) != -EFAULT");
    assertEqual(sys4(SYS_RT_SIGPROCMASK, SIG_BLOCK, bad_ptr, 0, 8), EFAULT, "rt_sigprocmask(bad set) != -EFAULT");
    assertEqual(sys4(SYS_RT_SIGPROCMASK, SIG_BLOCK, 0, bad_ptr, 8), EFAULT, "rt_sigprocmask(bad oset) != -EFAULT");

    // 2.4 Invalid 'how' in rt_sigprocmask
    assertEqual(sys4(SYS_RT_SIGPROCMASK, 99, @intFromPtr(&zero_mask), 0, 8), EINVAL, "rt_sigprocmask(how=99) != -EINVAL");

    // 2.5 Invalid kill arguments
    assertEqual(sys2(SYS_KILL, 99999, 0), ESRCH, "kill(nonexistent_pid, 0) != -ESRCH");
    assertEqual(sys2(SYS_KILL, @intCast(sys0(SYS_GETPID)), 999), EINVAL, "kill(pid, 999) != -EINVAL");

    writeStr("[CHALLENGER_M18] Boundary validation: PASS\n");

    // =========================================================================
    // SECTION 3: Syscall sys_pause Return Value & Timing (-EINTR = -4)
    // =========================================================================
    writeStr("[CHALLENGER_M18] Testing sys_pause waking and -EINTR return value...\n");

    // Register handler for SIGALRM
    assertEqual(sys4(SYS_RT_SIGACTION, SIGALRM, @intFromPtr(&default_act), 0, 8), 0, "rt_sigaction(SIGALRM) failed");

    // Set 20ms itimer
    var itimer = LinuxItimerval{ .it_value_usec = 20_000 };
    assertEqual(sys3(SYS_SETITIMER, 0, @intFromPtr(&itimer), 0), 0, "sys_setitimer failed");

    // Call sys_pause()
    const pause_res = sys0(SYS_PAUSE);
    assertEqual(pause_res, EINTR, "sys_pause() did not return -EINTR (-4)!");
    assertTrue(g_alrm_count >= 1, "SIGALRM handler was not invoked upon pause wake!");

    writeStr("[CHALLENGER_M18] sys_pause return value (-EINTR): PASS\n");

    // =========================================================================
    // SECTION 4: Process Lifecycle (fork/clone, SIGCHLD, inheritance, execve)
    // =========================================================================
    writeStr("[CHALLENGER_M18] Testing process lifecycle: fork, SIGCHLD, and execve...\n");

    // Register handlers for SIGUSR2 and SIGCHLD
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR2, @intFromPtr(&default_act), 0, 8), 0, "rt_sigaction(SIGUSR2) failed");
    assertEqual(sys4(SYS_RT_SIGACTION, SIGCHLD, @intFromPtr(&default_act), 0, 8), 0, "rt_sigaction(SIGCHLD) failed");

    // Block SIGUSR1 in parent before fork
    var block_usr1 = (@as(u64, 1) << (SIGUSR1 - 1));
    assertEqual(sys4(SYS_RT_SIGPROCMASK, SIG_BLOCK, @intFromPtr(&block_usr1), 0, 8), 0, "rt_sigprocmask block USR1 failed");

    // Fork child
    const fork_pid = sys0(SYS_FORK);
    assertTrue(fork_pid >= 0, "sys_fork failed");

    if (fork_pid == 0) {
        // In Child Process:
        // 1. Verify child inherited blocked SIGUSR1
        var child_mask: u64 = 0;
        _ = sys4(SYS_RT_SIGPROCMASK, SIG_BLOCK, 0, @intFromPtr(&child_mask), 8);
        if ((child_mask & block_usr1) == 0) {
            _ = sys1(SYS_EXIT, 51);
        }

        // 2. Verify child inherited SIGUSR2 action
        var child_act = KernelSigAction{};
        _ = sys4(SYS_RT_SIGACTION, SIGUSR2, 0, @intFromPtr(&child_act), 8);
        if (child_act.sa_handler != @intFromPtr(&testSignalHandler)) {
            _ = sys1(SYS_EXIT, 52);
        }

        // 3. Child exits with status 42
        _ = sys1(SYS_EXIT, 42);
        unreachable;
    }

    // In Parent Process:
    var child_status: i32 = 0;
    const wait_pid = sys4(SYS_WAIT4, @intCast(fork_pid), @intFromPtr(&child_status), 0, 0);
    assertEqual(wait_pid, fork_pid, "wait4 did not return child pid");
    const exit_code = (child_status >> 8) & 0xFF;
    assertEqual(exit_code, 42, "child exit code mismatch (check 51/52 error codes)");

    // Verify parent's SIGCHLD handler was triggered
    assertTrue(g_chld_count >= 1, "Parent did not receive SIGCHLD upon child termination!");

    // Unblock SIGUSR1 in parent
    _ = sys4(SYS_RT_SIGPROCMASK, SIG_UNBLOCK, @intFromPtr(&block_usr1), 0, 8);

    writeStr("[CHALLENGER_M18] Lifecycle (fork inheritance + SIGCHLD delivery): PASS\n");

    // 4.3 Test handler reset on SYS_EXECVE:
    // We register custom handler on SIGUSR1, set SIG_IGN on SIGUSR2, block SIGALRM, and execve post_exec verifier.
    // In our kernel, sysExecve resets sa_handler > 1 to SIG_DFL, while preserving SIG_IGN and sig_mask.
    writeStr("[CHALLENGER_M18] Testing execve handler reset...\n");
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR1, @intFromPtr(&default_act), 0, 8), 0, "sigaction USR1");
    assertEqual(sys4(SYS_RT_SIGACTION, SIGUSR2, @intFromPtr(&ign_act), 0, 8), 0, "sigaction USR2 IGN");
    var block_alrm = (@as(u64, 1) << (SIGALRM - 1));
    assertEqual(sys4(SYS_RT_SIGPROCMASK, SIG_BLOCK, @intFromPtr(&block_alrm), 0, 8), 0, "sigprocmask block ALRM");

    // Check we can fork a child that calls execve, then checks actions:
    const exec_child_pid = sys0(SYS_FORK);
    assertTrue(exec_child_pid >= 0, "sys_fork for execve failed");
    if (exec_child_pid == 0) {
        const post_exec_path = "/bin/adversarial_task18_post_exec\x00";
        const arg0 = "post_exec\x00";
        const argv = [_:null]?[*:0]const u8{ arg0.ptr, null };
        const envp = [_:null]?[*:0]const u8{null};

        _ = sys3(SYS_EXECVE, @intFromPtr(post_exec_path.ptr), @intFromPtr(&argv), @intFromPtr(&envp));
        // If execve failed:
        _ = sys1(SYS_EXIT, 88);
        unreachable;
    }

    var exec_status: i32 = 0;
    const wait_exec = sys4(SYS_WAIT4, @intCast(exec_child_pid), @intFromPtr(&exec_status), 0, 0);
    assertEqual(wait_exec, exec_child_pid, "wait4 exec child failed");
    const exec_code = (exec_status >> 8) & 0xFF;
    assertEqual(exec_code, 0, "exec child did not exit 0 (check 61..66 or 88)");

    writeStr("[CHALLENGER_M18] Execve handler reset & mask preservation: PASS\n");

    writeStr("[CHALLENGER_M18] All empirical adversarial challenges PASSED!\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}
