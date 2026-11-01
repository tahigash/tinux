// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Comprehensive empirical adversarial challenge suite for TASK-014:
// Fast userspace locking (sys_futex) and Epoll multiplexing

const std = @import("std");

const CLONE_VM: usize = 0x00000100;
const CLONE_FS: usize = 0x00000200;
const CLONE_FILES: usize = 0x00000400;
const CLONE_SIGHAND: usize = 0x00000800;
const CLONE_THREAD: usize = 0x00010000;
const CLONE_SETTLS: usize = 0x00080000;
const CLONE_PARENT_SETTID: usize = 0x00100000;
const CLONE_CHILD_CLEARTID: usize = 0x00200000;

const FUTEX_WAIT: usize = 0;
const FUTEX_WAKE: usize = 1;

const EPOLL_CTL_ADD: usize = 1;
const EPOLL_CTL_DEL: usize = 2;
const EPOLL_CTL_MOD: usize = 3;

const EPOLLIN: u32 = 0x001;
const EPOLLOUT: u32 = 0x004;

const ENOENT: isize = -2;
const EBADF: isize = -9;
const EAGAIN: isize = -11;
const EEXIST: isize = -17;
const EINVAL: isize = -22;
const ENOSPC: isize = -28;

pub const LinuxEpollEvent = extern struct {
    events: u32 align(1) = 0,
    data: u64 align(1) = 0,
};

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

inline fn sys1(num: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
        : "rcx", "r11", "memory"
    );
}

inline fn sys2(num: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
        : "rcx", "r11", "memory"
    );
}

inline fn sys3(num: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}

inline fn sys4(num: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
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

inline fn sys6(num: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}" (a5),
          [a6] "{r9}" (a6),
        : "rcx", "r11", "memory"
    );
}

fn writeStdout(msg: []const u8) void {
    _ = sys3(1, 1, @intFromPtr(msg.ptr), msg.len);
}

fn exitFail(code: usize, reason: []const u8) noreturn {
    writeStdout("\n[CHALLENGER_FAIL] ");
    writeStdout(reason);
    writeStdout("\n");
    _ = sys1(231, code); // sys_exit_group
    unreachable;
}

// ----------------------------------------------------------------------------
// Challenge 1: sys_futex edge cases, misalignment, EAGAIN, and waiter counts
// ----------------------------------------------------------------------------
var futex_test_word: i32 align(8) = 12345;
var futex_multi_wait: i32 align(8) = 0;
var waiter1_stack: [8192]u8 align(16) = undefined;
var waiter2_stack: [8192]u8 align(16) = undefined;
var waiter_tls: [8]u64 align(16) = .{ 0x5555_6666_7777_8888, 0, 0, 0, 0, 0, 0, 0 };

var waiter1_woken: i32 align(4) = 0;
var waiter2_woken: i32 align(4) = 0;

export fn waiter1Entry() callconv(.C) noreturn {
    _ = sys4(202, @intFromPtr(&futex_multi_wait), FUTEX_WAIT, 0, 0);
    @atomicStore(i32, &waiter1_woken, 1, .seq_cst);
    _ = sys1(60, 0);
    unreachable;
}

export fn waiter2Entry() callconv(.C) noreturn {
    _ = sys4(202, @intFromPtr(&futex_multi_wait), FUTEX_WAIT, 0, 0);
    @atomicStore(i32, &waiter2_woken, 1, .seq_cst);
    _ = sys1(60, 0);
    unreachable;
}

fn challengeFutex() void {
    writeStdout("[CHALLENGER14] Step 1: Testing sys_futex misalignment (-EINVAL) & mismatch (-EAGAIN)...\n");

    const uaddr = @intFromPtr(&futex_test_word);

    // 1. Unaligned uaddr: uaddr & 3 != 0 MUST return -EINVAL (-22)
    const rc_off1 = sys4(202, uaddr + 1, FUTEX_WAIT, 0, 0);
    if (rc_off1 != EINVAL) exitFail(101, "sys_futex wait with uaddr+1 did not return -EINVAL (-22)");

    const rc_off2 = sys4(202, uaddr + 2, FUTEX_WAIT, 0, 0);
    if (rc_off2 != EINVAL) exitFail(102, "sys_futex wait with uaddr+2 did not return -EINVAL (-22)");

    const rc_off3 = sys4(202, uaddr + 3, FUTEX_WAIT, 0, 0);
    if (rc_off3 != EINVAL) exitFail(103, "sys_futex wait with uaddr+3 did not return -EINVAL (-22)");

    const rc_wake_off = sys3(202, uaddr + 1, FUTEX_WAKE, 1);
    if (rc_wake_off != EINVAL) exitFail(104, "sys_futex wake with uaddr+1 did not return -EINVAL (-22)");

    // 2. Value mismatch: *uaddr == 12345, val == 99999 MUST return -EAGAIN (-11)
    const rc_mismatch = sys4(202, uaddr, FUTEX_WAIT, 99999, 0);
    if (rc_mismatch != EAGAIN) exitFail(105, "sys_futex wait value mismatch did not return -EAGAIN (-11)");

    writeStdout("[CHALLENGER14] Step 2: Testing sys_futex multi-waiter deschedule and exact wake count...\n");

    // Spawn Waiter 1
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SETTLS;
    const stack1_top = @intFromPtr(&waiter1_stack) + waiter1_stack.len;
    const clone1 = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call waiter1Entry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, 56)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack1_top),
          [a3] "{rdx}" (@as(usize, 0)),
          [a4] "{r10}" (@as(usize, 0)),
          [a5] "{r8}" (@intFromPtr(&waiter_tls)),
        : "rcx", "r11", "memory"
    );
    if (clone1 <= 0) exitFail(106, "clone waiter 1 failed");

    // Spawn Waiter 2
    const stack2_top = @intFromPtr(&waiter2_stack) + waiter2_stack.len;
    const clone2 = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call waiter2Entry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, 56)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack2_top),
          [a3] "{rdx}" (@as(usize, 0)),
          [a4] "{r10}" (@as(usize, 0)),
          [a5] "{r8}" (@intFromPtr(&waiter_tls)),
        : "rcx", "r11", "memory"
    );
    if (clone2 <= 0) exitFail(107, "clone waiter 2 failed");

    // Give both threads time to block in futex (yield via sys_sched_yield or busy-spin)
    var spin: usize = 0;
    while (spin < 500000) : (spin += 1) {
        asm volatile ("pause");
    }

    // 3. Wake with val = 1: MUST wake exactly 1 waiter
    const woken1 = sys3(202, @intFromPtr(&futex_multi_wait), FUTEX_WAKE, 1);
    if (woken1 != 1) exitFail(108, "sys_futex wake(val=1) did not return 1");

    // Wait for the woken waiter to update counter
    spin = 0;
    while (spin < 500000 and @atomicLoad(i32, &waiter1_woken, .seq_cst) == 0 and @atomicLoad(i32, &waiter2_woken, .seq_cst) == 0) : (spin += 1) {
        asm volatile ("pause");
    }

    const c1 = @atomicLoad(i32, &waiter1_woken, .seq_cst);
    const c2 = @atomicLoad(i32, &waiter2_woken, .seq_cst);
    if ((c1 + c2) != 1) exitFail(109, "exactly one waiter should have woken");

    // 4. Wake with val = 2: MUST wake remaining 1 waiter (returns 1)
    const woken2 = sys3(202, @intFromPtr(&futex_multi_wait), FUTEX_WAKE, 2);
    if (woken2 != 1) exitFail(110, "sys_futex wake(val=2) did not return 1 for remaining waiter");

    spin = 0;
    while (spin < 500000 and (@atomicLoad(i32, &waiter1_woken, .seq_cst) == 0 or @atomicLoad(i32, &waiter2_woken, .seq_cst) == 0)) : (spin += 1) {
        asm volatile ("pause");
    }

    if (@atomicLoad(i32, &waiter1_woken, .seq_cst) != 1 or @atomicLoad(i32, &waiter2_woken, .seq_cst) != 1) {
        exitFail(111, "both waiters should be woken");
    }

    // 5. Wake with val = 5 on empty queue: MUST return 0
    const woken_empty = sys3(202, @intFromPtr(&futex_multi_wait), FUTEX_WAKE, 5);
    if (woken_empty != 0) exitFail(112, "sys_futex wake on empty queue did not return 0");

    writeStdout("[CHALLENGER14] sys_futex misalignment, EAGAIN, and exact waiter wake count verified!\n");
}

// ----------------------------------------------------------------------------
// Challenge 2: Epoll 12-byte packing, CTL errnos, level-triggered drain & blocking wait
// ----------------------------------------------------------------------------
var blocker_pipe: [2]i32 align(8) = .{ -1, -1 };
var blocker_stack: [8192]u8 align(16) = undefined;

export fn blockerWorkerEntry() callconv(.C) noreturn {
    // Delay slightly to ensure main thread enters blocking sys_epoll_pwait
    var spin: usize = 0;
    while (spin < 1000000) : (spin += 1) {
        asm volatile ("pause");
    }
    const wake_byte = "W";
    _ = sys3(1, @intCast(blocker_pipe[1]), @intFromPtr(wake_byte.ptr), 1);
    _ = sys1(60, 0);
    unreachable;
}

fn challengeEpoll() void {
    writeStdout("[CHALLENGER14] Step 3: Testing epoll 12-byte struct layout & data offset 4...\n");

    if (@sizeOf(LinuxEpollEvent) != 12) exitFail(201, "LinuxEpollEvent size is not 12 bytes");

    const epfd = sys1(291, 0); // sys_epoll_create1(0)
    if (epfd < 0) exitFail(202, "sys_epoll_create1 failed");

    var test_pipe: [2]i32 align(8) = .{ -1, -1 };
    if (sys1(22, @intFromPtr(&test_pipe)) != 0) exitFail(203, "sys_pipe failed");

    // Register test_pipe[0] with 64-bit tag 0xFEDC_BA98_7654_3210
    var add_ev = LinuxEpollEvent{
        .events = EPOLLIN,
        .data = 0xFEDC_BA98_7654_3210,
    };
    if (sys4(233, @intCast(epfd), EPOLL_CTL_ADD, @intCast(test_pipe[0]), @intFromPtr(&add_ev)) != 0) {
        exitFail(204, "epoll_ctl ADD failed");
    }

    // Write 1 byte to trigger EPOLLIN
    _ = sys3(1, @intCast(test_pipe[1]), @intFromPtr("X".ptr), 1);

    // Read back via epoll_wait into packed 12-byte struct array
    var out_events: [2]LinuxEpollEvent align(1) = .{ .{}, .{} };
    const n_ready = sys4(281, @intCast(epfd), @intFromPtr(&out_events[0]), 2, 0);
    if (n_ready != 1) exitFail(205, "epoll_wait did not return 1 ready event");
    if ((out_events[0].events & EPOLLIN) == 0) exitFail(206, "ready event does not contain EPOLLIN");
    if (out_events[0].data != 0xFEDC_BA98_7654_3210) exitFail(207, "data u64 corrupted: offset 4 packing bug!");

    // Drain the pipe
    var dummy: [16]u8 = undefined;
    _ = sys3(0, @intCast(test_pipe[0]), @intFromPtr(&dummy), 1);

    writeStdout("[CHALLENGER14] Step 4: Testing epoll_ctl errnos (EEXIST, ENOENT, ENOSPC, EBADF, EINVAL)...\n");

    // 1. Duplicate EPOLL_CTL_ADD -> -EEXIST (-17)
    const rc_dup = sys4(233, @intCast(epfd), EPOLL_CTL_ADD, @intCast(test_pipe[0]), @intFromPtr(&add_ev));
    if (rc_dup != EEXIST) exitFail(210, "duplicate EPOLL_CTL_ADD did not return -EEXIST (-17)");

    // 2. EPOLL_CTL_MOD on valid fd not in epoll -> -ENOENT (-2)
    var mod_ev = LinuxEpollEvent{ .events = EPOLLOUT, .data = 999 };
    const rc_mod_noent = sys4(233, @intCast(epfd), EPOLL_CTL_MOD, @intCast(test_pipe[1]), @intFromPtr(&mod_ev));
    if (rc_mod_noent != ENOENT) exitFail(211, "EPOLL_CTL_MOD on unregistered fd did not return -ENOENT (-2)");

    // 3. EPOLL_CTL_DEL on unregistered fd -> -ENOENT (-2)
    const rc_del_noent = sys4(233, @intCast(epfd), EPOLL_CTL_DEL, @intCast(test_pipe[1]), 0);
    if (rc_del_noent != ENOENT) exitFail(212, "EPOLL_CTL_DEL on unregistered fd did not return -ENOENT (-2)");

    // 4. EPOLL_CTL_MOD on registered fd -> success (0)
    const rc_mod_ok = sys4(233, @intCast(epfd), EPOLL_CTL_MOD, @intCast(test_pipe[0]), @intFromPtr(&mod_ev));
    if (rc_mod_ok != 0) exitFail(213, "EPOLL_CTL_MOD failed on registered fd");

    // 5. Invalid epfd or target_fd -> -EBADF (-9)
    if (sys4(233, 999, EPOLL_CTL_ADD, @intCast(test_pipe[0]), @intFromPtr(&add_ev)) != EBADF) {
        exitFail(214, "invalid epfd did not return -EBADF (-9)");
    }
    if (sys4(233, @intCast(epfd), EPOLL_CTL_ADD, 999, @intFromPtr(&add_ev)) != EBADF) {
        exitFail(215, "invalid target_fd did not return -EBADF (-9)");
    }

    // 6. epfd == target_fd -> -EINVAL (-22)
    if (sys4(233, @intCast(epfd), EPOLL_CTL_ADD, @intCast(epfd), @intFromPtr(&add_ev)) != EINVAL) {
        exitFail(216, "epfd == target_fd did not return -EINVAL (-22)");
    }

    // 7. Max epoll items (16 items capacity): fill until -ENOSPC (-28)
    const epfd2 = sys1(291, 0);
    if (epfd2 < 0) exitFail(217, "second epoll_create1 failed");

    var fill_pipes: [16][2]i32 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (sys1(22, @intFromPtr(&fill_pipes[i])) != 0) exitFail(218, "pipe creation failed during fill");
        var ev_fill = LinuxEpollEvent{ .events = EPOLLIN, .data = i };
        const add_res = sys4(233, @intCast(epfd2), EPOLL_CTL_ADD, @intCast(fill_pipes[i][0]), @intFromPtr(&ev_fill));
        if (add_res != 0) exitFail(219, "failed to add up to 16 epoll items");
    }

    // 17th item MUST fail with -ENOSPC (-28)
    var overflow_pipe: [2]i32 = .{ -1, -1 };
    _ = sys1(22, @intFromPtr(&overflow_pipe));
    var ev_overflow = LinuxEpollEvent{ .events = EPOLLIN, .data = 17 };
    const rc_enospc = sys4(233, @intCast(epfd2), EPOLL_CTL_ADD, @intCast(overflow_pipe[0]), @intFromPtr(&ev_overflow));
    if (rc_enospc != ENOSPC) exitFail(220, "17th epoll item did not return -ENOSPC (-28)");

    // Clean up second epoll
    _ = sys1(3, @intCast(epfd2));

    writeStdout("[CHALLENGER14] Step 5: Testing level-triggered readiness transitions & pipe draining...\n");

    var lt_pipe: [2]i32 align(8) = .{ -1, -1 };
    if (sys1(22, @intFromPtr(&lt_pipe)) != 0) exitFail(230, "pipe creation failed");

    const epfd3 = sys1(291, 0);
    var lt_ev = LinuxEpollEvent{ .events = EPOLLIN, .data = 0x1234_5678 };
    _ = sys4(233, @intCast(epfd3), EPOLL_CTL_ADD, @intCast(lt_pipe[0]), @intFromPtr(&lt_ev));

    // A. Empty pipe -> 0 ready events
    var lt_out: [2]LinuxEpollEvent = .{ .{}, .{} };
    if (sys4(281, @intCast(epfd3), @intFromPtr(&lt_out[0]), 2, 0) != 0) {
        exitFail(231, "empty pipe reported ready events");
    }

    // B. Write 8 bytes -> triggers EPOLLIN
    _ = sys3(1, @intCast(lt_pipe[1]), @intFromPtr("LEVELTRG".ptr), 8);
    if (sys4(281, @intCast(epfd3), @intFromPtr(&lt_out[0]), 2, 0) != 1) {
        exitFail(232, "pipe with data did not report EPOLLIN");
    }

    // C. Check again WITHOUT reading -> STILL ready (level-triggered)
    if (sys4(281, @intCast(epfd3), @intFromPtr(&lt_out[0]), 2, 0) != 1) {
        exitFail(233, "level-triggered readiness lost without read");
    }

    // D. Read all 8 bytes -> drains pipe -> 0 ready events
    var drain_buf: [16]u8 = undefined;
    _ = sys3(0, @intCast(lt_pipe[0]), @intFromPtr(&drain_buf), 8);
    if (sys4(281, @intCast(epfd3), @intFromPtr(&lt_out[0]), 2, 0) != 0) {
        exitFail(234, "drained pipe still reported ready events");
    }

    writeStdout("[CHALLENGER14] Step 6: Testing epoll blocking wait (timeout > 0) wakes up on pipe write...\n");

    if (sys1(22, @intFromPtr(&blocker_pipe)) != 0) exitFail(240, "blocker pipe failed");
    const epfd_blk = sys1(291, 0);
    var blk_ev = LinuxEpollEvent{ .events = EPOLLIN, .data = 0xBEEF_CAFE };
    _ = sys4(233, @intCast(epfd_blk), EPOLL_CTL_ADD, @intCast(blocker_pipe[0]), @intFromPtr(&blk_ev));

    // Spawn worker to write to pipe after brief delay
    const flags_blk = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SETTLS;
    const blk_top = @intFromPtr(&blocker_stack) + blocker_stack.len;
    const blk_clone = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call blockerWorkerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, 56)),
          [a1] "{rdi}" (flags_blk),
          [a2] "{rsi}" (blk_top),
          [a3] "{rdx}" (@as(usize, 0)),
          [a4] "{r10}" (@as(usize, 0)),
          [a5] "{r8}" (@intFromPtr(&waiter_tls)),
        : "rcx", "r11", "memory"
    );
    if (blk_clone <= 0) exitFail(241, "clone blocker worker failed");

    // Call blocking sys_epoll_pwait with 5000ms timeout
    var blk_out: [2]LinuxEpollEvent = .{ .{}, .{} };
    const blk_res = sys4(281, @intCast(epfd_blk), @intFromPtr(&blk_out[0]), 2, 5000);
    if (blk_res != 1) exitFail(242, "blocking epoll_pwait did not wake up with 1 ready event");
    if ((blk_out[0].events & EPOLLIN) == 0 or blk_out[0].data != 0xBEEF_CAFE) {
        exitFail(243, "blocking epoll_pwait event or data tag mismatch");
    }

    _ = sys3(0, @intCast(blocker_pipe[0]), @intFromPtr(&drain_buf), 1);
    _ = sys1(3, @intCast(epfd_blk));

    writeStdout("[CHALLENGER14] Epoll 12-byte packing, CTL errnos, level-triggered drain & blocking wait verified!\n");
}

export fn challengerMain() callconv(.C) noreturn {
    writeStdout("=== Tinux TASK-014 Adversarial Challenger Suite ===\n");
    challengeFutex();
    challengeEpoll();
    writeStdout("\n[CHALLENGER14_PASS] ALL_ADVERSARIAL_CHALLENGES_CONFIRMED\n");
    _ = sys1(231, 0); // sys_exit_group(0)
    unreachable;
}

pub fn main() void {}
