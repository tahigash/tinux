const std = @import("std");
const io = @import("../arch/x86_64/io.zig");

pub const COM1_PORT: u16 = 0x3F8;

pub fn init() void {
    io.outb(COM1_PORT + 1, 0x00); // 1. Disable all interrupts (polled mode)
    io.outb(COM1_PORT + 3, 0x80); // 2. Enable DLAB (set baud rate divisor)
    io.outb(COM1_PORT + 0, 0x03); // 3. Divisor low byte: 3 for 38400 baud (115200 / 3)
    io.outb(COM1_PORT + 1, 0x00); // 4. Divisor high byte: 0x00
    io.outb(COM1_PORT + 3, 0x03); // 5. Clear DLAB, set 8 data bits, 1 stop bit, no parity (8N1)
    io.outb(COM1_PORT + 2, 0xC7); // 6. Enable FIFO, clear TX/RX FIFOs, 14-byte threshold
    io.outb(COM1_PORT + 4, 0x0B); // 7. Enable IRQ gating, assert RTS and DTR
    io.outb(COM1_PORT + 1, 0x01); // 8. Enable Received Data Available interrupt (IER = 0x01)
}

pub fn enableRxInterrupt() void {
    io.outb(COM1_PORT + 1, 0x01); // Enable Received Data Available interrupt (for TASK-012 TTY)
}

pub fn disableInterrupts() void {
    io.outb(COM1_PORT + 1, 0x00);
}

pub fn isTransmitEmpty() bool {
    return (io.inb(COM1_PORT + 5) & 0x20) != 0;
}

pub fn writeByte(b: u8) void {
    while (!isTransmitEmpty()) {
        asm volatile ("pause");
    }
    io.outb(COM1_PORT, b);
}

pub const writeChar = writeByte;

pub fn writeString(s: []const u8) void {
    for (s) |b| {
        if (b == '\n') {
            writeByte('\r');
        }
        writeByte(b);
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

pub fn readByteNonBlocking() ?u8 {
    if ((io.inb(COM1_PORT + 5) & 0x01) == 0) return null;
    return io.inb(COM1_PORT);
}

pub fn readRxByte() ?u8 {
    return readByteNonBlocking();
}

pub fn pollRx() void {
    // When TTY is initialized, delegate to tty.onRxByte
    const tty = @import("tty.zig");
    while (readByteNonBlocking()) |b| {
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
        writeChar(hex_chars[nibble]);
        if (i == 0) break;
    }
}

