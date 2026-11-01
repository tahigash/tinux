const std = @import("std");

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_DS: u16 = 0x18 | 3;
pub const USER_CS: u16 = 0x20 | 3;
pub const TSS_SEL: u16 = 0x28;

pub const Tss = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iopb_offset: u16 = @sizeOf(Tss),
};

var tss: Tss = .{};

const GdtDescriptor = packed struct {
    limit: u16,
    base: u64,
};

var gdt_entries: [7]u64 = [_]u64{
    0, // 0: Null
    0x00209A0000000000, // 1 (0x08): Kernel Code 64 (Execute/Read, DPL 0, Long mode)
    0x0000920000000000, // 2 (0x10): Kernel Data 64 (Read/Write, DPL 0)
    0x0000F20000000000, // 3 (0x18): User Data 64 (Read/Write, DPL 3)
    0x0020FA0000000000, // 4 (0x20): User Code 64 (Execute/Read, DPL 3, Long mode)
    0, // 5 (0x28): TSS Low 64
    0, // 6 (0x30): TSS High 64
};

pub fn init() void {
    const tss_base = @intFromPtr(&tss);
    const tss_limit = @sizeOf(Tss) - 1;

    // TSS low 64 bits
    var tss_low: u64 = 0;
    tss_low |= (tss_limit & 0xFFFF);
    tss_low |= (tss_base & 0xFFFF) << 16;
    tss_low |= ((tss_base >> 16) & 0xFF) << 32;
    tss_low |= (@as(u64, 0x89) << 40); // Present, 64-bit TSS available
    tss_low |= (((tss_limit >> 16) & 0x0F) << 48);
    tss_low |= (((tss_base >> 24) & 0xFF) << 56);

    // TSS high 64 bits
    const tss_high = tss_base >> 32;

    gdt_entries[5] = tss_low;
    gdt_entries[6] = tss_high;

    const desc = GdtDescriptor{
        .limit = @sizeOf(@TypeOf(gdt_entries)) - 1,
        .base = @intFromPtr(&gdt_entries),
    };

    asm volatile (
        \\ lgdt (%rax)
        \\ movw $0x10, %cx
        \\ movw %cx, %ds
        \\ movw %cx, %es
        \\ movw %cx, %ss
        \\ movw %cx, %fs
        \\ movw %cx, %gs
        \\ pushq $0x08
        \\ leaq 1f(%rip), %rcx
        \\ pushq %rcx
        \\ lretq
        \\ 1:
        \\ movw $0x28, %ax
        \\ ltr %ax
        :
        : [desc] "{rax}" (&desc),
        : "rcx", "memory"
    );
}

pub fn setKernelRsp(rsp: usize) void {
    tss.rsp0 = rsp;
}

pub fn setKernelStack(rsp: usize) void {
    setKernelRsp(rsp);
}
