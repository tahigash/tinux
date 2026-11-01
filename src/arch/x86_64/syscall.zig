const std = @import("std");
const gdt = @import("gdt.zig");

pub const MSR_EFER: u32 = 0xC000_0080;
pub const MSR_STAR: u32 = 0xC000_0081;
pub const MSR_LSTAR: u32 = 0xC000_0082;
pub const MSR_FMASK: u32 = 0xC000_0084;
pub const MSR_FS_BASE: u32 = 0xC000_0100;
pub const MSR_GS_BASE: u32 = 0xC000_0101;
pub const MSR_KERNEL_GS_BASE: u32 = 0xC000_0102;

pub const EFER_SCE: u64 = 1 << 0;

pub const SyscallFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r9: u64,
    r8: u64,
    r10: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rax: u64,
    user_rflags: u64,
    user_rip: u64,
    user_rsp: u64,

    comptime {
        std.debug.assert(@sizeOf(SyscallFrame) == 128);
        std.debug.assert(@offsetOf(SyscallFrame, "rax") == 96);
        std.debug.assert(@offsetOf(SyscallFrame, "user_rip") == 112);
        std.debug.assert(@offsetOf(SyscallFrame, "user_rsp") == 120);
    }
};

extern fn syscallEntry() callconv(.C) void;
pub extern fn enterUserMode(entry_rip: usize, user_rsp: usize) callconv(.C) noreturn;

var default_syscall_stack: [16384]u8 align(16) = undefined;
export var kernel_rsp_scratch: usize = 0;
export var user_rsp_scratch: usize = 0;

pub inline fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}

pub inline fn wrmsr(msr: u32, val: u64) void {
    const low: u32 = @truncate(val);
    const high: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
        : "memory"
    );
}

pub fn setKernelRsp(rsp: usize) void {
    kernel_rsp_scratch = rsp;
    gdt.setKernelStack(rsp);
}

pub fn init() void {
    const top = @intFromPtr(&default_syscall_stack) + default_syscall_stack.len;
    setKernelRsp(top);

    const efer = rdmsr(MSR_EFER);
    wrmsr(MSR_EFER, efer | EFER_SCE);

    const star: u64 = (@as(u64, 0x0010) << 48) | (@as(u64, 0x0008) << 32);
    wrmsr(MSR_STAR, star);
    wrmsr(MSR_LSTAR, @intFromPtr(&syscallEntry));
    wrmsr(MSR_FMASK, 0x0000_0300);
}
