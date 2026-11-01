const std = @import("std");

// Embed explicit .interp section so LLD emits PT_INTERP = "/lib/ld-musl-x86_64.so.1"
pub export const interp_path: [25:0]u8 align(1) linksection(".interp") = "/lib/ld-musl-x86_64.so.1".*;

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call dynMain
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

export fn dynMain() callconv(.C) noreturn {
    // Verify the shared object mapped by ld-musl at 0x2500_0000 is accessible in our address space
    const so_slice = @as([*]const u8, @ptrFromInt(0x2500_0000))[0..24];
    if (!std.mem.eql(u8, so_slice[0..8], "TINUX_SO")) {
        _ = syscall1(231, 50);
        unreachable;
    }
    writeStdout("[TINUX_DYN] Main dynamic executable (AT_ENTRY) running & reading shared library memory!\n");
    _ = syscall1(231, 0);
    unreachable;
}
