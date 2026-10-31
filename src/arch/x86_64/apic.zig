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


176 ---
    // Builder implements AP 64-bit initialization, LAPIC enable, and atomic handshake
}
pub fn initAndBootSmp(target_cpus: usize) usize {
    // Builder initializes BSP Local APIC + IOAPIC, copies trampoline to 0x8000,
    // and wakes APs 1..(target_cpus-1) via INIT-SIPI-SIPI protocol
}
