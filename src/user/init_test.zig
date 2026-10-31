const std = @import("std");

const ARCH_SET_FS: usize = 0x1002;
const ARCH_GET_FS: usize = 0x1003;
const AT_PAGESZ: u64 = 6;
const AT_RANDOM: u64 = 25;

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call initMain
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

fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}

fn failExit(code: usize) noreturn {
    _ = syscall1(231, code);
    unreachable;
}

var bss_canary: [64]u64 = undefined; // Must be zero-initialized by ELF loader!
var tls_block: [8]u64 align(16) = .{ 0xDEAD_BEEF_CAFE_BABE, 0, 0, 0, 0, 0, 0, 0 };

export fn initMain(initial_rsp: [*]const u64) callconv(.C) noreturn {
    // 1. Verify initial_rsp is 16-byte aligned
    if ((@intFromPtr(initial_rsp) & 0xF) != 0) failExit(10);

    // 2. Verify .bss was zeroed by kernel ELF loader
    for (bss_canary) |v| {
        if (v != 0) failExit(11);
    }

    // 3. Walk argc, argv, envp, and auxv on System V AMD64 stack
    const argc = initial_rsp[0];
    if (argc < 1) failExit(12);

    var idx: usize = 1 + @as(usize, @intCast(argc)) + 1; // Skip argc + argv + NULL
    while (initial_rsp[idx] != 0) : (idx += 1) {} // Skip envp
    idx += 1; // Skip envp NULL terminator -> now pointing at auxv[0]

    var pagesz: u64 = 0;
    var rand_ptr: u64 = 0;
    while (initial_rsp[idx] != 0) : (idx += 2) {
        const a_type = initial_rsp[idx];
        const a_val = initial_rsp[idx + 1];
        if (a_type == AT_PAGESZ) pagesz = a_val;
        if (a_type == AT_RANDOM) rand_ptr = a_val;
    }
    if (pagesz != 4096 or rand_ptr == 0) failExit(13);
    writeStdout("[TINUX_ELF] System V AMD64 stack (argc/argv/envp/auxv) & .bss verified!\n");

    // 4. Test Thread-Local Storage (TLS) via sys_arch_prctl(ARCH_SET_FS) & %fs:0 read
    if (syscall2(158, ARCH_SET_FS, @intFromPtr(&tls_block)) != 0) failExit(14);
    const fs_val = asm volatile ("movq %%fs:0, %[ret]"
        : [ret] "=r" (-> u64),
    );
    if (fs_val != 0xDEAD_BEEF_CAFE_BABE) failExit(15);
    var queried_fs: u64 = 0;
    if (syscall2(158, ARCH_GET_FS, @intFromPtr(&queried_fs)) != 0) failExit(16);
    if (queried_fs != @intFromPtr(&tls_block)) failExit(17);
    writeStdout("[TINUX_TLS] arch_prctl(ARCH_SET_FS) and %fs:0 Thread-Local Storage verified!\n");

    // 5. Test dynamic user heap expansion via sys_brk(12)
    const cur_brk = syscall1(12, 0);
    if (cur_brk <= 0) failExit(18);
    const u_brk: usize = @intCast(cur_brk);
    const new_brk = syscall1(12, u_brk + 8192);
    if (new_brk != @as(isize, @intCast(u_brk + 8192))) failExit(19);

    const heap_ptr = @as([*]volatile u64, @ptrFromInt(u_brk));
    if (heap_ptr[0] != 0) failExit(20); // Newly mapped brk pages must be zeroed
    heap_ptr[0] = 0x2026_ABCD_1234_5678;
    heap_ptr[512] = 0x8765_4321_DCBA_6202; // Second page of expansion
    if (heap_ptr[0] != 0x2026_ABCD_1234_5678 or heap_ptr[512] != 0x8765_4321_DCBA_6202) failExit(21);
    writeStdout("[TINUX_BRK] User heap expansion via sys_brk (2 pages mapped & RW) verified!\n");

    _ = syscall1(231, 0);
    unreachable;
}
