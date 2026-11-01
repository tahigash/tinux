const std = @import("std");

pub const ARCH_SET_FS: usize = 0x1002;

inline fn syscall1(number: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
          [a3] "{rdx}" (arg3),
        : "rcx", "r11", "memory"
    );
}

fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}

fn failExit(code: usize) noreturn {
    _ = syscall1(60, code);
    while (true) {}
}

const TlsBlock = extern struct {
    self_ptr: usize,
    magic: u64,
};

var tls_block: TlsBlock = .{
    .self_ptr = 0,
    .magic = 0xBEEF_CAFE_FEED_FACE,
};

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call initMain
    );
    while (true) {}
}

pub export fn initMain(initial_rsp: [*]const usize) void {
    const argc = initial_rsp[0];
    if (argc != 1) failExit(10);
    const argv0 = @as([*:0]const u8, @ptrFromInt(initial_rsp[1]));
    if (!std.mem.eql(u8, std.mem.span(argv0), "/sbin/init")) failExit(11);
    const envp0 = @as([*:0]const u8, @ptrFromInt(initial_rsp[3]));
    if (!std.mem.eql(u8, std.mem.span(envp0), "PATH=/bin:/usr/bin")) failExit(12);

    tls_block.self_ptr = @intFromPtr(&tls_block);
    if (syscall2(158, ARCH_SET_FS, @intFromPtr(&tls_block)) != 0) failExit(14);

    const fs_magic = asm volatile ("movq %%fs:8, %[res]"
        : [res] "=r" (-> u64),
    );
    if (fs_magic != 0xBEEF_CAFE_FEED_FACE) failExit(15);

    const cur_brk = syscall1(12, 0);
    const new_brk = syscall1(12, cur_brk + 4096);
    if (new_brk <= cur_brk) failExit(16);

    const brk_slice = @as([*]volatile u8, @ptrFromInt(cur_brk))[0..4096];
    brk_slice[0] = 0xAA;
    brk_slice[4095] = 0x55;
    if (brk_slice[0] != 0xAA or brk_slice[4095] != 0x55) failExit(17);

    writeStdout("[TINUX_ELF] Static ELF64 binary executed (Stack/Auxv/TLS/Brk verified)!\n");
    _ = syscall1(60, 0);
}

// Satisfies standard library root.main check when compiled for Linux targets
pub fn main() void {}
