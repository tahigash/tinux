const std = @import("std");
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call smpTestMain
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
fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}
fn failExit(code: usize) noreturn {
    _ = syscall1(231, code);
    unreachable;
}
export fn smpTestMain() callconv(.C) noreturn {
    // 1. Query online CPU affinity mask via sys_sched_getaffinity(204)
    var cpu_mask: u64 = 0;
    const aff_rc = syscall3(204, 0, @sizeOf(u64), @intFromPtr(&cpu_mask));
    if (aff_rc < 8) failExit(10);
    const num_cpus: usize = @popCount(cpu_mask);
    if (num_cpus < 2 or cpu_mask != 0x03) failExit(11); // Expect 2 CPUs (mask 0b11 == 3)
    // 2. Query active CPU and NUMA node via sys_getcpu(309)
    var cur_cpu: u32 = 999;
    var cur_node: u32 = 999;
    if (syscall3(309, @intFromPtr(&cur_cpu), @intFromPtr(&cur_node), 0) != 0) failExit(12);
    if (cur_cpu >= 2 or cur_node != 0) failExit(13);
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "[TINUX_SMP] sched_getaffinity mask=0x{X:0>2} ({d} CPUs online), running on CPU {d} (node {d})!\n",
        .{ cpu_mask, num_cpus, cur_cpu, cur_node },
    ) catch unreachable;
    writeStdout(msg);
    _ = syscall1(231, 0);
    unreachable;
}
