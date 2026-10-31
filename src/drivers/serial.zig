const std = @import("std");
const io = @import("../arch/x86_64/io.zig");

pub const COM1_PORT: u16 = 0x3F8;

pub fn init() void {
    io.outb(COM1_PORT + 1, 0x00); // Disable all interrupts
    io.outb(COM1_PORT + 3, 0x80); // Enable DLAB (set baud rate divisor)
    io.outb(COM1_PORT + 0, 0x01); // Set divisor to 1 (lo byte) 115200 baud
    io.outb(COM1_PORT + 1, 0x00); //                  (hi byte)
    io.outb(COM1_PORT + 3, 0x03); // 8 bits, no parity, one stop bit
    io.outb(COM1_PORT + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    io.outb(COM1_PORT + 4, 0x0B); // IRQs enabled, RTS/DSR set (Bit 3 OUT2 must be 1 for IRQ4!)
    io.outb(COM1_PORT + 1, 0x01); // Enable Received Data Available interrupt
}

pub fn isTransmitEmpty() bool {
    return (io.inb(COM1_PORT + 5) & 0x20) != 0;
}

pub fn writeChar(c: u8) void {
    while (!isTransmitEmpty()) {
        asm volatile ("pause");
    }
    io.outb(COM1_PORT, c);
}

pub fn writeString(s: []const u8) void {
    for (s) |c| {
        writeChar(c);
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeString(slice);
}

pub fn hasRxByte() bool {
    return (io.inb(COM1_PORT + 5) & 0x01) != 0;
}

pub fn readRxByte() ?u8 {
    if (!hasRxByte()) return null;
    return io.inb(COM1_PORT);
}

pub fn pollRx() void {
    // When TTY is initialized, delegate to tty.onRxByte
    const tty = @import("tty.zig");
    while (hasRxByte()) {
        const b = io.inb(COM1_PORT);
        tty.onRxByte(b);
    }
}

pub fn onInterrupt() void {
    pollRx();
}


pub fn writeHex(val: u64) void {
    const hex_chars = "0123456789ABCDEF";
    writeString("0x");
    var i: u6 = 60;
    while (true) : (i -%= 4) {
        const nibble: usize = @intCast((val >> i) & 0xF);
        writeByte(hex_chars[nibble]);
        if (i == 0) break;
    }
}

