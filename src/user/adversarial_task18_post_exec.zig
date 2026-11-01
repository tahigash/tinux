// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Post-execve signal state verifier for TASK-018 adversarial suite

const std = @import("std");

pub const SYS_WRITE: usize = 1;
pub const SYS_RT_SIGACTION: usize = 13;
pub const SYS_RT_SIGPROCMASK: usize = 14;
pub const SYS_EXIT_GROUP: usize = 231;

pub const SIGUSR1: usize = 10;
pub const SIGUSR2: usize = 12;
pub const SIGALRM: usize = 14;
pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;
pub const SIG_BLOCK: usize = 0;

pub const KernelSigAction = extern struct {
    sa_handler: usize align(1) = 0,
    sa_flags: u64 align(1) = 0,
    sa_restorer: usize align(1) = 0,
    sa_mask: u64 align(1) = 0,
};

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call postExecMain
    );
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1) : "rcx", "r11", "memory");
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

export fn postExecMain() callconv(.C) noreturn {
    // 1. Verify SIGUSR1 (was custom handler) is reset to SIG_DFL (0)
    var act_usr1 = KernelSigAction{};
    if (sys4(SYS_RT_SIGACTION, SIGUSR1, 0, @intFromPtr(&act_usr1), 8) != 0) {
        writeStr("[POST_EXEC_FAIL] Query SIGUSR1 failed\n");
        _ = sys1(SYS_EXIT_GROUP, 61);
    }
    if (act_usr1.sa_handler != SIG_DFL) {
        writeStr("[POST_EXEC_FAIL] SIGUSR1 was not reset to SIG_DFL across execve!\n");
        _ = sys1(SYS_EXIT_GROUP, 62);
    }

    // 2. Verify SIGUSR2 (was SIG_IGN) remained SIG_IGN (1)
    var act_usr2 = KernelSigAction{};
    if (sys4(SYS_RT_SIGACTION, SIGUSR2, 0, @intFromPtr(&act_usr2), 8) != 0) {
        writeStr("[POST_EXEC_FAIL] Query SIGUSR2 failed\n");
        _ = sys1(SYS_EXIT_GROUP, 63);
    }
    if (act_usr2.sa_handler != SIG_IGN) {
        writeStr("[POST_EXEC_FAIL] SIGUSR2 SIG_IGN was lost across execve!\n");
        _ = sys1(SYS_EXIT_GROUP, 64);
    }

    // 3. Verify sig_mask (SIGALRM was blocked) persisted across execve
    var mask: u64 = 0;
    if (sys4(SYS_RT_SIGPROCMASK, SIG_BLOCK, 0, @intFromPtr(&mask), 8) != 0) {
        writeStr("[POST_EXEC_FAIL] Query sig_mask failed\n");
        _ = sys1(SYS_EXIT_GROUP, 65);
    }
    const alrm_bit = @as(u64, 1) << (SIGALRM - 1);
    if ((mask & alrm_bit) == 0) {
        writeStr("[POST_EXEC_FAIL] Blocked SIGALRM mask was lost across execve!\n");
        _ = sys1(SYS_EXIT_GROUP, 66);
    }

    writeStr("[POST_EXEC_PASS] Post-execve signal state verified (custom reset, IGN preserved, mask preserved)!\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}
