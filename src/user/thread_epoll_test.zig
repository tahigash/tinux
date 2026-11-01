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
const EPOLLIN: u32 = 0x001;
const LinuxEpollEvent = extern struct {
    events: u32 align(1),
    data: u64 align(1),
};
pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call mainThread
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
    _ = syscall1(231, code); // sys_exit_group
    unreachable;
}
var worker_stack: [16384]u8 align(16) = undefined;
var worker_tls: [8]u64 align(16) = .{ 0xCAFE_BABE_ABCD_1234, 0, 0, 0, 0, 0, 0, 0 };
var shared_value: u64 = 0;
var futex_gate: i32 align(4) = 0;
var parent_tid_slot: i32 align(4) = 0;
var child_tid_futex: i32 align(4) = 999;
var pipe_fds: [2]i32 align(8) = .{ -1, -1 };
export fn workerEntry() callconv(.C) noreturn {
    // 1. Verify CLONE_SETTLS loaded %fs:0 properly
    const tls_magic = asm volatile ("movq %%fs:0, %[ret]"
        : [ret] "=r" (-> u64),
    );
    if (tls_magic != 0xCAFE_BABE_ABCD_1234) failExit(31);
    // 2. Mutate shared memory (proving CLONE_VM shared address space)
    shared_value = 0x1337_C0DE_2026_ABCD;
    // 3. Signal futex_gate = 1 and wake main thread via FUTEX_WAKE
    @atomicStore(i32, &futex_gate, 1, .seq_cst);
    _ = syscall3(202, @intFromPtr(&futex_gate), FUTEX_WAKE, 1);
    // 4. Write message into pipe monitored by main thread's epoll
    const msg = "[TINUX_THREAD] Worker thread event delivered via pipe to epoll!\n";
    _ = syscall3(1, @intCast(pipe_fds[1]), @intFromPtr(msg.ptr), msg.len);
    // 5. Exit only this worker thread via sys_exit(60) -> triggers CLONE_CHILD_CLEARTID
    _ = syscall1(60, 0);
    unreachable;
}
export fn mainThread() callconv(.C) noreturn {
    // 1. Create pipe for epoll notification
    if (syscall1(22, @intFromPtr(&pipe_fds)) != 0) failExit(10);
    // 2. Create epoll instance via sys_epoll_create1(0) (291)
    const epfd = syscall1(291, 0);
    if (epfd < 0) failExit(11);
    // 3. Register pipe_fds[0] with EPOLLIN and 64-bit tag 0xDEADBEEFCAFE0001
    var ev = LinuxEpollEvent{
        .events = EPOLLIN,
        .data = 0xDEAD_BEEF_CAFE_0001,
    };
    if (syscall4(233, @intCast(epfd), EPOLL_CTL_ADD, @intCast(pipe_fds[0]), @intFromPtr(&ev)) != 0) {
        failExit(12);
    }
    // 4. Spawn worker thread using raw x86_64 sys_clone(56)
    const stack_top = @intFromPtr(&worker_stack) + worker_stack.len;
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND |
        CLONE_THREAD | CLONE_SETTLS | CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID;
    const clone_rc = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call workerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, 56)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (@intFromPtr(&parent_tid_slot)),
          [a4] "{r10}" (@intFromPtr(&child_tid_futex)),
          [a5] "{r8}" (@intFromPtr(&worker_tls)),
        : "rcx", "r11", "memory"
    );
    if (clone_rc <= 0) failExit(13);
    if (parent_tid_slot != @as(i32, @intCast(clone_rc))) failExit(14);
    // 5. Wait on futex_gate if worker hasn't set it to 1 yet
    if (@atomicLoad(i32, &futex_gate, .seq_cst) == 0) {
        _ = syscall4(202, @intFromPtr(&futex_gate), FUTEX_WAIT, 0, 0);
    }
    if (shared_value != 0x1337_C0DE_2026_ABCD) failExit(15);
    writeStdout("[TINUX_FUTEX] Shared-VM thread spawned & synchronized via sys_futex!\n");
    // 6. Wait for pipe readability via sys_epoll_pwait(281)
    var out_ev = LinuxEpollEvent{ .events = 0, .data = 0 };
    const n_ready = syscall4(281, @intCast(epfd), @intFromPtr(&out_ev), 1, 5000);
    if (n_ready != 1) failExit(16);
    if ((out_ev.events & EPOLLIN) == 0 or out_ev.data != 0xDEAD_BEEF_CAFE_0001) failExit(17);
    var rx_buf: [128]u8 = undefined;
    const n_read = syscall3(0, @intCast(pipe_fds[0]), @intFromPtr(&rx_buf), rx_buf.len);
    if (n_read <= 0) failExit(18);
    writeStdout(rx_buf[0..@intCast(n_read)]);
    // 7. Join worker thread via CLONE_CHILD_CLEARTID futex
    while (@atomicLoad(i32, &child_tid_futex, .seq_cst) != 0) {
        const cur_tid = @atomicLoad(i32, &child_tid_futex, .seq_cst);
        if (cur_tid == 0) break;
        _ = syscall4(202, @intFromPtr(&child_tid_futex), FUTEX_WAIT, @as(u32, @bitCast(cur_tid)), 0);
    }
    writeStdout("[TINUX_JOIN] Worker thread joined cleanly via CLONE_CHILD_CLEARTID!\n");
    _ = syscall1(231, 0); // sys_exit_group(0)
    unreachable;
}

// Satisfies standard library root.main check when compiled for Linux targets
pub fn main() void {}
