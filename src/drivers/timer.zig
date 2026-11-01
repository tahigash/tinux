const std = @import("std");
const io = @import("../arch/x86_64/io.zig");
const task = @import("../proc/task.zig");

pub const PIC1_CMD: u16 = 0x20;
pub const PIC1_DATA: u16 = 0x21;
pub const PIC2_CMD: u16 = 0xA0;
pub const PIC2_DATA: u16 = 0xA1;
pub const PIC_EOI: u8 = 0x20;

pub const PIT_CH0_DATA: u16 = 0x40;
pub const PIT_CMD: u16 = 0x43;
pub const PIT_BASE_FREQ: u32 = 1193182;
pub const HZ: u32 = 100;

var ticks: u64 = 0;

pub fn init() void {
    // 1. Remap 8259A PIC to vectors 0x20..0x27 and 0x28..0x2F
    io.outb(PIC1_CMD, 0x11);
    io.ioWait();
    io.outb(PIC2_CMD, 0x11);
    io.ioWait();

    io.outb(PIC1_DATA, 0x20); // Master PIC offset = 0x20 (32)
    io.ioWait();
    io.outb(PIC2_DATA, 0x28); // Slave PIC offset = 0x28 (40)
    io.ioWait();

    io.outb(PIC1_DATA, 0x04); // Master has slave on IRQ2
    io.ioWait();
    io.outb(PIC2_DATA, 0x02); // Slave identity
    io.ioWait();

    io.outb(PIC1_DATA, 0x01); // 8086 mode
    io.ioWait();
    io.outb(PIC2_DATA, 0x01);
    io.ioWait();

    // Unmask IRQ0 (Timer) and IRQ4 (UART COM1) on Master PIC (0xEE); mask others
    io.outb(PIC1_DATA, 0xEE);
    io.ioWait();
    io.outb(PIC2_DATA, 0xFF);
    io.ioWait();

    // 2. Program 8254 PIT Channel 0 for 100 Hz
    const divisor: u16 = @intCast(PIT_BASE_FREQ / HZ);
    io.outb(PIT_CMD, 0x36);
    io.outb(PIT_CH0_DATA, @truncate(divisor & 0xFF));
    io.outb(PIT_CH0_DATA, @truncate((divisor >> 8) & 0xFF));
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        io.outb(PIC2_CMD, PIC_EOI);
    }
    io.outb(PIC1_CMD, PIC_EOI);
}

pub fn onTick() void {
    _ = @atomicRmw(u64, &ticks, .Add, 1, .seq_cst);
    // Poll UART in case an edge was missed
    const serial = @import("serial.zig");
    serial.pollRx();

    task.tickSleepWaiters();
    sendEoi(0);
}

pub fn getTicks() u64 {
    return @atomicLoad(u64, &ticks, .seq_cst);
}

pub fn waitForNextTick() void {
    asm volatile ("sti; hlt; cli" ::: "memory");
}
