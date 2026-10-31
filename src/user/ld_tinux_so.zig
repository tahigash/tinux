const std = @import("std");

const AT_PHDR: u64 = 3;
const AT_PHENT: u64 = 4;
const AT_PHNUM: u64 = 5;
const AT_BASE: u64 = 7;
const AT_ENTRY: u64 = 9;

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call ldMain
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

inline fn syscall6(num: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}"  (a5),
          [a6] "{r9}"  (a6),
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

export fn ldMain(initial_rsp: [*]const u64) callconv(.C) noreturn {
    // 1. Parse argc, argv, envp, auxv passed by kernel
    const argc = initial_rsp[0];
    var idx: usize = 1 + @as(usize, @intCast(argc)) + 1;
    while (initial_rsp[idx] != 0) : (idx += 1) {}
    idx += 1;

    var at_base: u64 = 0;
    var at_entry: u64 = 0;
    var at_phdr: u64 = 0;
    while (initial_rsp[idx] != 0) : (idx += 2) {
        const k = initial_rsp[idx];
        const v = initial_rsp[idx + 1];
        if (k == AT_BASE) at_base = v;
        if (k == AT_ENTRY) at_entry = v;
        if (k == AT_PHDR) at_phdr = v;
    }

    if (at_base != 0x1800_0000 or at_entry == 0 or at_phdr == 0) failExit(40);
    writeStdout("[TINUX_DYN] Dynamic linker (/lib/ld-musl-x86_64.so.1) started at AT_BASE=0x18000000!\n");

    // 2. Open shared library /lib/libtinux.so via openat(257), verify pread64(17), and mmap(MAP_FIXED)
    const fd = syscall4(257, @bitCast(@as(isize, -100)), @intFromPtr("/lib/libtinux.so"), 0, 0);
    if (fd < 0) failExit(41);

    var hdr_magic: [16]u8 = undefined;
    const n_pread = syscall4(17, @intCast(fd), @intFromPtr(&hdr_magic), 16, 0); // sys_pread64 at offset 0
    if (n_pread != 16 or !std.mem.eql(u8, hdr_magic[0..8], "TINUX_SO")) failExit(42);

    // Map shared library page at fixed address 0x2500_0000 using MAP_PRIVATE(0x02) | MAP_FIXED(0x10)
    const map_addr: usize = 0x2500_0000;
    const mapped = syscall6(9, map_addr, 4096, 3, 0x12, @intCast(fd), 0);
    _ = syscall1(3, @intCast(fd));
    if (mapped != @as(isize, @intCast(map_addr))) failExit(43);
    writeStdout("[TINUX_DYN] Shared object /lib/libtinux.so mapped at 0x25000000 via pread64 + mmap(MAP_FIXED)!\n");

    // 3. Transfer control to main executable's AT_ENTRY with original stack pointer
    asm volatile (
        \\ movq %[orig_rsp], %%rsp
        \\ xorq %%rdx, %%rdx
        \\ jmp *%[entry]
        :
        : [orig_rsp] "r" (initial_rsp),
          [entry] "r" (@as(usize, @intCast(at_entry))),
        : "memory"
    );
    unreachable;
}
