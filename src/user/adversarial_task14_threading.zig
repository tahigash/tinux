// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical Adversarial Challenge Verification Suite for TASK-014 (Threading Focus)

const std = @import("std");

const SYS_READ: usize = 0;
const SYS_WRITE: usize = 1;
const SYS_BRK: usize = 12;
const SYS_GETPID: usize = 39;
const SYS_CLONE: usize = 56;
const SYS_FORK: usize = 57;
const SYS_EXIT: usize = 60;
const SYS_WAIT4: usize = 61;
const SYS_GETTID: usize = 186;
const SYS_FUTEX: usize = 202;
const SYS_SET_TID_ADDRESS: usize = 218;
const SYS_EXIT_GROUP: usize = 231;

const CLONE_VM: usize = 0x00000100;
const CLONE_FS: usize = 0x00000200;
const CLONE_FILES: usize = 0x00000400;
const CLONE_SIGHAND: usize = 0x00000800;
const CLONE_THREAD: usize = 0x00010000;
const CLONE_SETTLS: usize = 0x00080000;
const CLONE_PARENT_SETTID: usize = 0x00100000;
const CLONE_CHILD_CLEARTID: usize = 0x00200000;
const CLONE_CHILD_SETTID: usize = 0x01000000;

const FUTEX_WAIT: usize = 0;
const FUTEX_WAKE: usize = 1;

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

inline fn sys0(num: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
        : "rcx", "r11", "memory"
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

fn writeStr(str: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(str.ptr), str.len);
}

fn assertCond(cond: bool, msg: []const u8, fail_code: usize) void {
    if (!cond) {
        writeStr("[CHALLENGER_ASSERT_FAIL] ");
        writeStr(msg);
        writeStr("\n");
        _ = sys1(SYS_EXIT_GROUP, fail_code);
        unreachable;
    }
}

// -----------------------------------------------------------------------------
// Test 1: CLONE_VM True Memory Sharing & Concurrency
// -----------------------------------------------------------------------------
var t1_stack: [16384]u8 align(16) = undefined;
var t1_shared_array: [512]u32 = [_]u32{0} ** 512;
var t1_gate: i32 align(4) = 0;
var t1_worker_done: i32 align(4) = 0;

export fn t1WorkerEntry() callconv(.C) noreturn {
    while (@atomicLoad(i32, &t1_gate, .seq_cst) != 1) {
        _ = sys4(SYS_FUTEX, @intFromPtr(&t1_gate), FUTEX_WAIT, 0, 0);
    }

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const expected = @as(u32, @intCast(0x5500 + i));
        if (t1_shared_array[2 * i] != expected) {
            _ = sys1(SYS_EXIT_GROUP, 101);
        }
        t1_shared_array[2 * i + 1] = @as(u32, @intCast(0xAA00 + i));
    }

    @atomicStore(i32, &t1_worker_done, 1, .seq_cst);
    _ = sys3(SYS_FUTEX, @intFromPtr(&t1_worker_done), FUTEX_WAKE, 1);
    _ = sys1(SYS_EXIT, 0);
    unreachable;
}

fn testCloneVmSharing() void {
    writeStr("[CHALLENGE 1] Verifying CLONE_VM true memory sharing across threads...\n");

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        t1_shared_array[2 * i] = @as(u32, @intCast(0x5500 + i));
    }

    const stack_top = @intFromPtr(&t1_stack) + t1_stack.len;
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD;

    const rc = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call t1WorkerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, SYS_CLONE)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (@as(usize, 0)),
          [a4] "{r10}" (@as(usize, 0)),
          [a5] "{r8}" (@as(usize, 0)),
        : "rcx", "r11", "memory"
    );
    assertCond(rc > 0, "CLONE_VM spawn failed", 102);

    @atomicStore(i32, &t1_gate, 1, .seq_cst);
    _ = sys3(SYS_FUTEX, @intFromPtr(&t1_gate), FUTEX_WAKE, 1);

    while (@atomicLoad(i32, &t1_worker_done, .seq_cst) != 1) {
        _ = sys4(SYS_FUTEX, @intFromPtr(&t1_worker_done), FUTEX_WAIT, 0, 0);
    }

    i = 0;
    while (i < 256) : (i += 1) {
        const expected = @as(u32, @intCast(0xAA00 + i));
        assertCond(t1_shared_array[2 * i + 1] == expected, "Shared array modification mismatch", 103);
    }
    writeStr("  -> CLONE_VM memory sharing confirmed.\n");
}

// -----------------------------------------------------------------------------
// Test 2: CLONE_THREAD and PID/TID group semantics
// -----------------------------------------------------------------------------
var t2_stack: [16384]u8 align(16) = undefined;
var t2_worker_pid: isize = 0;
var t2_worker_tid: isize = 0;
var t2_done: i32 align(4) = 0;

export fn t2WorkerEntry() callconv(.C) noreturn {
    t2_worker_pid = sys0(SYS_GETPID);
    t2_worker_tid = sys0(SYS_GETTID);
    @atomicStore(i32, &t2_done, 1, .seq_cst);
    _ = sys3(SYS_FUTEX, @intFromPtr(&t2_done), FUTEX_WAKE, 1);
    _ = sys1(SYS_EXIT, 0);
    unreachable;
}

fn testCloneThreadConsistency() void {
    writeStr("[CHALLENGE 2] Verifying CLONE_THREAD thread group ID consistency...\n");
    const leader_pid = sys0(SYS_GETPID);
    const leader_tid = sys0(SYS_GETTID);
    assertCond(leader_pid == leader_tid, "Leader getpid != gettid", 201);

    const stack_top = @intFromPtr(&t2_stack) + t2_stack.len;
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD;

    const rc = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call t2WorkerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, SYS_CLONE)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (@as(usize, 0)),
          [a4] "{r10}" (@as(usize, 0)),
          [a5] "{r8}" (@as(usize, 0)),
        : "rcx", "r11", "memory"
    );
    assertCond(rc > 0, "CLONE_THREAD spawn failed", 202);

    while (@atomicLoad(i32, &t2_done, .seq_cst) != 1) {
        _ = sys4(SYS_FUTEX, @intFromPtr(&t2_done), FUTEX_WAIT, 0, 0);
    }

    assertCond(t2_worker_pid == leader_pid, "Worker getpid != leader PID", 203);
    assertCond(t2_worker_tid != leader_pid, "Worker gettid == leader PID", 204);
    assertCond(t2_worker_tid == rc, "Worker gettid != clone returned TID", 205);
    writeStr("  -> CLONE_THREAD PID/TID group consistency confirmed.\n");
}

// -----------------------------------------------------------------------------
// Test 3: CLONE_SETTLS and %fs:0 Dereferencing
// -----------------------------------------------------------------------------
var t3_stack: [16384]u8 align(16) = undefined;
var t3_tls: [8]u64 align(16) = .{
    0xFEED_FACE_CAFE_BABE, // fs:0
    0, // fs:8
    0x11223344, // fs:16
    0, 0, 0, 0, 0,
};
var t3_done: i32 align(4) = 0;
var t3_read_magic: u64 = 0;
var t3_read_self: u64 = 0;
var t3_read_mutated: u64 = 0;

export fn t3WorkerEntry() callconv(.C) noreturn {
    t3_read_magic = asm volatile ("movq %%fs:0, %[ret]"
        : [ret] "=r" (-> u64),
    );
    t3_read_self = asm volatile ("movq %%fs:8, %[ret]"
        : [ret] "=r" (-> u64),
    );

    asm volatile (
        \\ movq $0x9988776655443322, %%rax
        \\ movq %%rax, %%fs:16
        ::: "rax", "memory"
    );

    t3_read_mutated = asm volatile ("movq %%fs:16, %[ret]"
        : [ret] "=r" (-> u64),
    );

    @atomicStore(i32, &t3_done, 1, .seq_cst);
    _ = sys3(SYS_FUTEX, @intFromPtr(&t3_done), FUTEX_WAKE, 1);
    _ = sys1(SYS_EXIT, 0);
    unreachable;
}

fn testCloneSettls() void {
    writeStr("[CHALLENGE 3] Verifying CLONE_SETTLS and %fs:0 dereferencing...\n");
    t3_tls[1] = @intFromPtr(&t3_tls);

    const stack_top = @intFromPtr(&t3_stack) + t3_stack.len;
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SETTLS;

    const rc = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call t3WorkerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, SYS_CLONE)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (@as(usize, 0)),
          [a4] "{r10}" (@as(usize, 0)),
          [a5] "{r8}" (@intFromPtr(&t3_tls)),
        : "rcx", "r11", "memory"
    );
    assertCond(rc > 0, "CLONE_SETTLS spawn failed", 301);

    while (@atomicLoad(i32, &t3_done, .seq_cst) != 1) {
        _ = sys4(SYS_FUTEX, @intFromPtr(&t3_done), FUTEX_WAIT, 0, 0);
    }

    assertCond(t3_read_magic == 0xFEED_FACE_CAFE_BABE, "TLS magic mismatch at %fs:0", 302);
    assertCond(t3_read_self == @intFromPtr(&t3_tls), "TLS self ptr mismatch at %fs:8", 303);
    assertCond(t3_read_mutated == 0x9988776655443322, "TLS mutated read mismatch at %fs:16", 304);
    assertCond(t3_tls[2] == 0x9988776655443322, "Memory backing TLS not updated", 305);
    writeStr("  -> CLONE_SETTLS %fs segment dereferencing confirmed.\n");
}

// -----------------------------------------------------------------------------
// Test 4: CLONE_PARENT_SETTID & CLONE_CHILD_SETTID Pointer Validation
// -----------------------------------------------------------------------------
var t4_stack: [16384]u8 align(16) = undefined;
var t4_parent_tid: i32 align(4) = 0;
var t4_child_tid: i32 align(4) = 0;
var t4_done: i32 align(4) = 0;

export fn t4WorkerEntry() callconv(.C) noreturn {
    @atomicStore(i32, &t4_done, 1, .seq_cst);
    _ = sys3(SYS_FUTEX, @intFromPtr(&t4_done), FUTEX_WAKE, 1);
    _ = sys1(SYS_EXIT, 0);
    unreachable;
}

fn testCloneSettidPointers() void {
    writeStr("[CHALLENGE 4] Verifying CLONE_PARENT_SETTID and CLONE_CHILD_SETTID...\n");

    const stack_top = @intFromPtr(&t4_stack) + t4_stack.len;
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND |
        CLONE_THREAD | CLONE_PARENT_SETTID | CLONE_CHILD_SETTID;

    const rc = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call t4WorkerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, SYS_CLONE)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (@intFromPtr(&t4_parent_tid)),
          [a4] "{r10}" (@intFromPtr(&t4_child_tid)),
          [a5] "{r8}" (@as(usize, 0)),
        : "rcx", "r11", "memory"
    );
    assertCond(rc > 0, "CLONE_PARENT/CHILD_SETTID spawn failed", 401);
    assertCond(t4_parent_tid == @as(i32, @intCast(rc)), "parent_tid mismatch", 402);
    assertCond(t4_child_tid == @as(i32, @intCast(rc)), "child_tid mismatch", 403);

    while (@atomicLoad(i32, &t4_done, .seq_cst) != 1) {
        _ = sys4(SYS_FUTEX, @intFromPtr(&t4_done), FUTEX_WAIT, 0, 0);
    }

    const bad_ptr: usize = 0xDEAD_0000;
    const rc_bad = asm volatile (
        \\ syscall
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, SYS_CLONE)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (bad_ptr),
          [a4] "{r10}" (@as(usize, 0)),
          [a5] "{r8}" (@as(usize, 0)),
        : "rcx", "r11", "memory"
    );
    assertCond(rc_bad < 0, "Expected clone with bad ptid_ptr to fail", 404);
    writeStr("  -> CLONE_PARENT_SETTID and CLONE_CHILD_SETTID verified (valid and rejected unmapped).\n");
}

// -----------------------------------------------------------------------------
// Test 5: CLONE_CHILD_CLEARTID Deterministic Futex Wakeup & Zeroing
// -----------------------------------------------------------------------------
var t5_stack: [16384]u8 align(16) = undefined;
var t5_child_tid_futex: i32 align(4) = 8888;

export fn t5WorkerEntry() callconv(.C) noreturn {
    var sum: u64 = 0;
    var k: usize = 0;
    while (k < 1000) : (k += 1) {
        sum +%= k;
    }
    _ = sys1(SYS_EXIT, 0);
    unreachable;
}

fn testCloneChildCleartid() void {
    writeStr("[CHALLENGE 5] Verifying CLONE_CHILD_CLEARTID zeroing and deterministic futex wakeup...\n");

    const stack_top = @intFromPtr(&t5_stack) + t5_stack.len;
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND |
        CLONE_THREAD | CLONE_CHILD_CLEARTID;

    const rc = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call t5WorkerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, SYS_CLONE)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (@as(usize, 0)),
          [a4] "{r10}" (@intFromPtr(&t5_child_tid_futex)),
          [a5] "{r8}" (@as(usize, 0)),
        : "rcx", "r11", "memory"
    );
    assertCond(rc > 0, "CLONE_CHILD_CLEARTID spawn failed", 501);

    while (@atomicLoad(i32, &t5_child_tid_futex, .seq_cst) != 0) {
        const cur_val = @atomicLoad(i32, &t5_child_tid_futex, .seq_cst);
        if (cur_val == 0) break;
        const futex_res = sys4(SYS_FUTEX, @intFromPtr(&t5_child_tid_futex), FUTEX_WAIT, @as(u32, @bitCast(cur_val)), 0);
        assertCond(futex_res == 0 or futex_res == -11, "Futex wait returned unexpected code", 502);
    }

    assertCond(t5_child_tid_futex == 0, "Target memory was not zeroed on thread exit", 503);
    writeStr("  -> CLONE_CHILD_CLEARTID deterministic zeroing and wake verified.\n");
}

// -----------------------------------------------------------------------------
// Test 6: Thread Exit Isolation (Worker sys_exit vs Parent Process & wait4)
// -----------------------------------------------------------------------------
var t6_stack: [16384]u8 align(16) = undefined;

export fn t6WorkerEntry() callconv(.C) noreturn {
    _ = sys1(SYS_EXIT, 42);
    unreachable;
}

fn testThreadExitIsolation() void {
    writeStr("[CHALLENGE 6] Verifying thread exit isolation (sys_exit does NOT reap or kill parent)...\n");

    const stack_top = @intFromPtr(&t6_stack) + t6_stack.len;
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD;

    const rc = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call t6WorkerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, SYS_CLONE)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (@as(usize, 0)),
          [a4] "{r10}" (@as(usize, 0)),
          [a5] "{r8}" (@as(usize, 0)),
        : "rcx", "r11", "memory"
    );
    assertCond(rc > 0, "Thread spawn failed", 601);

    var dummy: usize = 0;
    while (dummy < 5000) : (dummy += 1) {}

    var status: i32 = -1;
    const wait_rc = sys4(SYS_WAIT4, @bitCast(@as(isize, -1)), @intFromPtr(&status), 1, 0);
    assertCond(wait_rc == -10, "wait4 reaped a worker thread as a zombie child!", 602);

    const fork_rc = sys0(SYS_FORK);
    assertCond(fork_rc >= 0, "Fork failed", 603);
    if (fork_rc == 0) {
        _ = sys1(SYS_EXIT, 77);
        unreachable;
    }

    var p_status: i32 = 0;
    const reaped_pid = sys4(SYS_WAIT4, @intCast(fork_rc), @intFromPtr(&p_status), 0, 0);
    assertCond(reaped_pid == fork_rc, "wait4 failed to reap child process", 604);
    assertCond(((p_status >> 8) & 0xFF) == 77, "Child exit status mismatch", 605);

    writeStr("  -> Thread exit isolation vs child process exit confirmed.\n");
}

// -----------------------------------------------------------------------------
// Test 7: Futex Edge Cases & Error Semantics
// -----------------------------------------------------------------------------
fn testFutexEdgeCases() void {
    writeStr("[CHALLENGE 7] Verifying futex edge cases and error handling...\n");

    var futex_var: i32 align(4) = 100;

    const err_eagain = sys4(SYS_FUTEX, @intFromPtr(&futex_var), FUTEX_WAIT, 99, 0);
    assertCond(err_eagain == -11, "Futex value mismatch did not return -EAGAIN", 701);

    const unaligned_addr = @intFromPtr(&futex_var) + 1;
    const err_inval = sys4(SYS_FUTEX, unaligned_addr, FUTEX_WAIT, 100, 0);
    assertCond(err_inval == -22, "Unaligned futex address did not return -EINVAL", 702);

    const bad_addr: usize = 0xDEADC000;
    const err_fault = sys4(SYS_FUTEX, bad_addr, FUTEX_WAIT, 0, 0);
    assertCond(err_fault == -14, "Bad futex address did not return -EFAULT", 703);

    const woken_zero = sys3(SYS_FUTEX, @intFromPtr(&futex_var), FUTEX_WAKE, 1);
    assertCond(woken_zero == 0, "FUTEX_WAKE with 0 waiters did not return 0", 704);

    writeStr("  -> Futex error semantics and return values confirmed.\n");
}

// -----------------------------------------------------------------------------
// Main Entry
// -----------------------------------------------------------------------------
export fn challengerMain() callconv(.C) noreturn {
    writeStr("=================================================================\n");
    writeStr("Tinux TASK-014 Empirical Adversarial Challenger Verification\n");
    writeStr("=================================================================\n");

    testCloneVmSharing();
    testCloneThreadConsistency();
    testCloneSettls();
    testCloneSettidPointers();
    testCloneChildCleartid();
    testThreadExitIsolation();
    testFutexEdgeCases();

    writeStr("=================================================================\n");
    writeStr("[CHALLENGER_PASS] All TASK-014 adversarial threading challenges passed cleanly!\n");
    writeStr("=================================================================\n");

    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}

pub fn main() void {}
