const std = @import("std");

// Canonical selectors defined in SPEC_TASK_002
pub const KERNEL_CODE_SEL: u16 = 0x08;
pub const KERNEL_DATA_SEL: u16 = 0x10;
pub const USER_DATA_SEL: u16 = 0x18 | 3;
pub const USER_CODE_SEL: u16 = 0x20 | 3;
pub const TSS_SEL: u16 = 0x28;

// Backward-compatibility aliases
pub const KERNEL_CS: u16 = KERNEL_CODE_SEL;
pub const KERNEL_DS: u16 = KERNEL_DATA_SEL;
pub const USER_DS: u16 = USER_DATA_SEL;
pub const USER_CS: u16 = USER_CODE_SEL;

pub const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iomap_base: u16 align(1) = @sizeOf(Tss),

    comptime {
        std.debug.assert(@sizeOf(Tss) == 104);
        std.debug.assert(@offsetOf(Tss, "reserved0") == 0);
        std.debug.assert(@offsetOf(Tss, "rsp0") == 4);
        std.debug.assert(@offsetOf(Tss, "ist1") == 36);
        std.debug.assert(@offsetOf(Tss, "iomap_base") == 102);
    }
};

var gdt_entries: [7]u64 align(16) = .{
    0x0000000000000000, // 0x00: Null
    0x00209A0000000000, // 0x08: Kernel Code 64
    0x0000920000000000, // 0x10: Kernel Data
    0x0000F20000000000, // 0x18: User Data
    0x0020FA0000000000, // 0x20: User Code 64
    0x0000000000000000, // 0x28: TSS Low (Filled at init)
    0x0000000000000000, // 0x30: TSS High (Filled at init)
};

pub var tss: Tss align(16) = .{};
var df_stack: [16384]u8 align(16) = undefined;

pub fn init() void {
    // 1. Configure IST1 for Double Fault (#DF) handler
    tss.ist1 = @intFromPtr(&df_stack) + df_stack.len;

    // 2. Construct 16-byte TSS descriptor
    const tss_base: u64 = @intFromPtr(&tss);
    const tss_limit: u64 = @sizeOf(Tss) - 1; // 103

    // Low 64 bits (Index 5, 0x28)
    gdt_entries[5] = (tss_limit & 0xFFFF) |
        ((tss_base & 0xFFFFFF) << 16) |
        (@as(u64, 0x89) << 40) |
        (((tss_limit >> 16) & 0xF) << 48) |
        (((tss_base >> 24) & 0xFF) << 56);

    // High 64 bits (Index 6, 0x30)
    gdt_entries[6] = tss_base >> 32;

    // 3. Populate 10-byte GDTR descriptor buffer aligned to 16 bytes
    var gdtr: [10]u8 align(16) = undefined;
    const gdt_limit: u16 = @intCast(@sizeOf(@TypeOf(gdt_entries)) - 1);
    const gdt_base: u64 = @intFromPtr(&gdt_entries);
    std.mem.writeInt(u16, gdtr[0..2], gdt_limit, .little);
    std.mem.writeInt(u64, gdtr[2..10], gdt_base, .little);

    // 4. Load GDTR, reload CS via far return, reload data segments with 0x10, and load TSS via ltr
    asm volatile (
        \\ lgdt (%[gdtr])
        \\ pushq $0x08
        \\ leaq 1f(%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        \\ movw $0x10, %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ movw %%ax, %%ss
        \\ movw $0x28, %%ax
        \\ ltr %%ax
        :
        : [gdtr] "r" (&gdtr),
        : "rax", "memory"
    );
}

pub fn setKernelStack(rsp0: u64) void {
    tss.rsp0 = rsp0;
}

pub fn setKernelRsp(rsp: usize) void {
    setKernelStack(rsp);
}
