const std = @import("std");
const SIGUSR1: usize = 10;
const SIGALRM: usize = 14;
const SIGCHLD: usize = 17;
const SIG_BLOCK: usize = 0;
const SIG_UNBLOCK: usize = 1;
const SA_RESTORER: u64 = 0x0400_0000;
const KernelSigAction = extern struct {
    sa_handler: usize align(1) = 0,
    sa_flags: u64 align(1) = 0,
    sa_restorer: usize align(1) = 0,
    sa_mask: u64 align(1) = 0,
};
const LinuxItimerval = extern struct {
    it_interval_sec: i64 align(1) = 0,
    it_interval_usec: i64 align(1) = 0,
    it_value_sec: i64 align(1) = 0,
    it_value_usec: i64 align(1) = 30_000, // 30ms timer
};
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call sigTestMain
    );
}
export fn sigRestorer() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq $15, %rax
        \\ syscall
    );
}
inline fn syscall0(num: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
        : "rcx", "r11", "memory"
    );
}
inline fn syscall1(num: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
        : "rcx", "r11", "memory"
    );
}


162 ---
inline fn syscall2(num: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
        : "rcx", "r11", "memory"
    );
}
inline fn syscall3(num: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}
inline fn syscall4(num: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
        : "rcx", "r11", "memory"
    );
}
fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}
fn failExit(code: usize) noreturn {
    _ = syscall1(231, code);
    unreachable;
}
var usr1_count: usize = 0;
var alrm_count: usize = 0;
var chld_count: usize = 0;
export fn signalHandler(signum: usize) callconv(.C) void {
    // Verify 16-byte stack alignment inside C signal handler
    var local_aligned: [16]u8 align(16) = [_]u8{0} ** 16;
    local_aligned[0] = @truncate(signum);
    if ((@intFromPtr(&local_aligned) & 0xF) != 0) failExit(99);
    if (signum == SIGUSR1) {
        usr1_count += 1;
        writeStdout("[TINUX_SIG] Custom SIGUSR1 handler invoked in Ring 3!\n");
    } else if (signum == SIGALRM) {
        alrm_count += 1;
        writeStdout("[TINUX_SIG] Custom SIGALRM timer handler invoked & waking pause()!\n");
    } else if (signum == SIGCHLD) {
        chld_count += 1;
        writeStdout("[TINUX_SIG] Custom SIGCHLD handler invoked on child exit!\n");
    }
}
export fn sigTestMain() callconv(.C) noreturn {
    const act = KernelSigAction{
        .sa_handler = @intFromPtr(&signalHandler),
        .sa_flags = SA_RESTORER,
        .sa_restorer = @intFromPtr(&sigRestorer),
        .sa_mask = 0,
    };
    // 1. Register handlers for SIGUSR1 (10), SIGALRM (14), SIGCHLD (17)
    if (syscall4(13, SIGUSR1, @intFromPtr(&act), 0, 8) != 0) failExit(10);
    if (syscall4(13, SIGALRM, @intFromPtr(&act), 0, 8) != 0) failExit(11);
    if (syscall4(13, SIGCHLD, @intFromPtr(&act), 0, 8) != 0) failExit(12);
    // 2. Test sigprocmask (SIG_BLOCK -> kill -> verify blocked -> SIG_UNBLOCK -> delivered!)


163 ---
    var mask: u64 = (@as(u64, 1) << (SIGUSR1 - 1));
    if (syscall4(14, SIG_BLOCK, @intFromPtr(&mask), 0, 8) != 0) failExit(13);
    const pid = syscall0(39); // getpid
    if (syscall2(62, @intCast(pid), SIGUSR1) != 0) failExit(14);
    if (@atomicLoad(usize, &usr1_count, .seq_cst) != 0) failExit(15); // Must still be blocked!
    if (syscall4(14, SIG_UNBLOCK, @intFromPtr(&mask), 0, 8) != 0) failExit(16);
    if (@atomicLoad(usize, &usr1_count, .seq_cst) != 1) failExit(17); // Must have fired on unblock!
    // 3. Test setitimer(ITIMER_REAL) + pause() -> SIGALRM delivery -> rt_sigreturn -> -EINTR
    var itimer = LinuxItimerval{};
    if (syscall3(38, 0, @intFromPtr(&itimer), 0) != 0) failExit(18);
    const pause_rc = syscall0(34); // sys_pause()
    if (pause_rc != -4) failExit(19); // Expect -EINTR (-4)
    if (@atomicLoad(usize, &alrm_count, .seq_cst) != 1) failExit(20);
    // 4. Test SIGCHLD delivery on child process exit
    const child_pid = syscall0(57); // sys_fork()
    if (child_pid == 0) {
        _ = syscall1(60, 0); // Child exits immediately
        unreachable;
    }
    var status: i32 = 0;
    _ = syscall4(61, @intCast(child_pid), @intFromPtr(&status), 0, 0);
    if (@atomicLoad(usize, &chld_count, .seq_cst) != 1) failExit(21);
    writeStdout("[TINUX_SIG] All signal delivery, masking, timer, and rt_sigreturn checks passed!\n");
    _ = syscall1(231, 0);
    unreachable;
}
