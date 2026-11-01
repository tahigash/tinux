const std = @import("std");
const io = @import("io.zig");
const idt = @import("idt.zig");
const syscall_arch = @import("syscall.zig");
const vmm = @import("../../mm/vmm.zig");
const serial = @import("../../drivers/serial.zig");
pub const MAX_CPUS: usize = 8;
pub const AP_STACK_SIZE: usize = 16384;
pub const LAPIC_PHYS_BASE: usize = 0xFEE0_0000;
pub const IOAPIC_PHYS_BASE: usize = 0xFEC0_0000;
pub const LAPIC_REG_ID: usize = 0x0020;
pub const LAPIC_REG_VER: usize = 0x0030;
pub const LAPIC_REG_TPR: usize = 0x0080;
pub const LAPIC_REG_EOI: usize = 0x00B0;
pub const LAPIC_REG_SVR: usize = 0x00F0;
pub const LAPIC_REG_ICR_LOW: usize = 0x0300;
pub const LAPIC_REG_ICR_HIGH: usize = 0x0310;
pub const TRAMPOLINE_ADDR: usize = 0x0000_8000;
pub const TRAMPOLINE_VECTOR: u8 = 0x08; // 0x08 * 0x1000 = 0x8000
pub const MAILBOX_CR3: usize = 0x0000_8F00;
pub const MAILBOX_RSP: usize = 0x0000_8F08;
pub const MAILBOX_ENTRY: usize = 0x0000_8F10;
pub const MAILBOX_READY: usize = 0x0000_8F18;
pub const MAILBOX_CPU_ID: usize = 0x0000_8F1C;
extern const ap_trampoline_start: u8;
extern const ap_trampoline_end: u8;
var ap_stacks: [MAX_CPUS][AP_STACK_SIZE]u8 align(16) = undefined;
var online_cpus: usize = 1;
var ioapic_max_entries: u32 = 0;
pub inline fn lapicRead(reg_offset: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(LAPIC_PHYS_BASE + reg_offset)).*;
}
pub inline fn lapicWrite(reg_offset: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(LAPIC_PHYS_BASE + reg_offset)).* = val;
}
pub inline fn ioapicRead(reg: u8) u32 {
    @as(*volatile u32, @ptrFromInt(IOAPIC_PHYS_BASE)).* = reg;
    return @as(*volatile u32, @ptrFromInt(IOAPIC_PHYS_BASE + 0x10)).*;
}
pub fn readLapicId() u32 {
    return lapicRead(LAPIC_REG_ID) >> 24;
}
pub fn getOnlineCpuCount() usize {
    return @atomicLoad(usize, &online_cpus, .seq_cst);
}
pub fn getIoapicRedirCount() u32 {
    return ioapic_max_entries;
}
pub export fn apMain() callconv(.C) noreturn {
    idt.loadIdtOnAp();
    lapicWrite(LAPIC_REG_TPR, 0x00);
    lapicWrite(LAPIC_REG_SVR, 0x0000_01FF);
    const my_id = readLapicId();
    @atomicStore(u32, @as(*u32, @ptrFromInt(MAILBOX_CPU_ID)), my_id, .seq_cst);
    _ = @atomicRmw(usize, &online_cpus, .Add, 1, .seq_cst);
    @atomicStore(u32, @as(*u32, @ptrFromInt(MAILBOX_READY)), 1, .seq_cst);
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn initAndBootSmp(target_cpus: usize) usize {
    // 1. Enable APIC on BSP via IA32_APIC_BASE MSR (0x1B bit 11)
    const apic_base = syscall_arch.rdmsr(0x1B);
    syscall_arch.wrmsr(0x1B, apic_base | 0x800);

    // 2. Clear TPR to unmask all interrupt priorities
    lapicWrite(LAPIC_REG_TPR, 0x00);

    // 3. Enable BSP Local APIC via SVR
    lapicWrite(LAPIC_REG_SVR, 0x0000_01FF);

    // 4. Read IOAPIC version register (index 0x01)
    const ver_reg = ioapicRead(0x01);
    ioapic_max_entries = ((ver_reg >> 16) & 0xFF) + 1;

    // 5. Copy AP trampoline to physical address 0x0000_8000
    const tramp_len = @intFromPtr(&ap_trampoline_end) - @intFromPtr(&ap_trampoline_start);
    const src = @as([*]const u8, @ptrFromInt(@intFromPtr(&ap_trampoline_start)))[0..tramp_len];
    const dst = @as([*]u8, @ptrFromInt(TRAMPOLINE_ADDR))[0..tramp_len];
    @memcpy(dst, src);

    // 6. Boot Application Processors 1..(target_cpus - 1)
    var apic_id: usize = 1;
    while (apic_id < target_cpus) : (apic_id += 1) {
        if (apic_id >= MAX_CPUS) break;

        // Prepare mailbox
        @as(*volatile u64, @ptrFromInt(MAILBOX_CR3)).* = vmm.getKernelPml4Phys();
        @as(*volatile u64, @ptrFromInt(MAILBOX_RSP)).* = @intFromPtr(&ap_stacks[apic_id]) + AP_STACK_SIZE;
        @as(*volatile u64, @ptrFromInt(MAILBOX_ENTRY)).* = @intFromPtr(&apMain);
        @atomicStore(u32, @as(*u32, @ptrFromInt(MAILBOX_READY)), 0, .seq_cst);
        asm volatile ("mfence" ::: "memory");

        // Send INIT IPI
        lapicWrite(LAPIC_REG_ICR_HIGH, @as(u32, @intCast(apic_id)) << 24);
        lapicWrite(LAPIC_REG_ICR_LOW, 0x0000_4500);

        // Wait 10 ms
        for (0..10_000) |_| io.ioWait();

        // Send SIPI (Vector 0x08 -> 0x8000)
        lapicWrite(LAPIC_REG_ICR_HIGH, @as(u32, @intCast(apic_id)) << 24);
        lapicWrite(LAPIC_REG_ICR_LOW, 0x0000_4600 | @as(u32, TRAMPOLINE_VECTOR));

        // Poll mailbox ready (up to 100,000 iterations)
        var polled: usize = 0;
        while (polled < 100_000) : (polled += 1) {
            if (@atomicLoad(u32, @as(*u32, @ptrFromInt(MAILBOX_READY)), .seq_cst) == 1) {
                serial.print("[TINUX_SMP] Application Processor (APIC ID {d}) booted into 64-bit Long Mode!\n", .{apic_id});
                break;
            }
            io.ioWait();
        }
    }

    return getOnlineCpuCount();
}
