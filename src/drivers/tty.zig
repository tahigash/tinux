const std = @import("std");
const serial = @import("serial.zig");
const io = @import("../arch/x86_64/io.zig");
const task = @import("../proc/task.zig");
const Errno = @import("../uapi/errno.zig").Errno;

pub const TTY_BUF_SIZE: usize = 4096;

pub const TCGETS: usize = 0x5401;
pub const TCSETS: usize = 0x5402;
pub const TCSETSW: usize = 0x5403;
pub const TCSETSF: usize = 0x5404;
pub const TIOCSCTTY: usize = 0x540E;
pub const TIOCGPGRP: usize = 0x540F;
pub const TIOCSPGRP: usize = 0x5410;
pub const TIOCGWINSZ: usize = 0x5413;
pub const TIOCSWINSZ: usize = 0x5414;

pub const ICRNL: u32 = 0o000400; // 0x0100
pub const ISIG: u32 = 0o000001;  // 0x0001
pub const ICANON: u32 = 0o000002;// 0x0002
pub const ECHO: u32 = 0o000010;  // 0x0008

pub const KernelTermios = extern struct {
    c_iflag: u32 = 0x0500, // ICRNL | IXON
    c_oflag: u32 = 0x0005, // OPOST | ONLCR
    c_cflag: u32 = 0x00BF, // B38400 | CS8 | CREAD | HUPCL
    c_lflag: u32 = 0x8A3B, // ISIG | ICANON | ECHO | ECHOE | ECHOK | IEXTEN
    c_line: u8 = 0,
    c_cc: [19]u8 = .{
        3,   // VINTR (^C)
        28,  // VQUIT (^\)
        127, // VERASE (DEL)
        21,  // VKILL (^U)
        4,   // VEOF (^D)
        0,   // VTIME
        1,   // VMIN
        0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0,
    },
    comptime {
        std.debug.assert(@sizeOf(KernelTermios) == 36);
    }
};

pub const LinuxTermios = KernelTermios;

pub const Winsize = extern struct {
    ws_row: u16 = 24,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
    comptime {
        std.debug.assert(@sizeOf(Winsize) == 8);
    }
};

pub const LinuxWinsize = Winsize;

pub const TtyReadStatus = enum {
    bytes,
    eof,
    would_block,
};

pub const TtyReadResult = union(enum) {
    bytes: usize,
    eof: void,
    would_block: void,
};

var termios: KernelTermios = .{};
var fg_pgid: i32 = 1;
var winsize: Winsize = .{};

var rx_buf: [TTY_BUF_SIZE]u8 = [_]u8{0} ** TTY_BUF_SIZE;
var read_pos: usize = 0;
var write_pos: usize = 0;
var count: usize = 0;
var newline_count: usize = 0;
var eof_pending: bool = false;

pub fn init() void {
    termios = .{};
    fg_pgid = 1;
    winsize = .{};
    read_pos = 0;
    write_pos = 0;
    count = 0;
    newline_count = 0;
    eof_pending = false;
    pollSerialRx();
}

pub fn onCharReceived(raw_ch: u8) void {
    var ch = raw_ch;
    // 1. CR-to-NL translation
    if ((termios.c_iflag & ICRNL) != 0 and ch == '\r') {
        ch = '\n';
    }

    const is_sig = (termios.c_lflag & ISIG) != 0;
    const is_canon = (termios.c_lflag & ICANON) != 0;
    const is_echo = (termios.c_lflag & ECHO) != 0;

    // 2. Ctrl+C (VINTR = 0x03)
    if (ch == 0x03 and is_sig) {
        if (is_echo) {
            serial.writeString("^C\r\n");
        }
        // Deliver SIGINT to fg_pgid
        const signal = @import("../proc/signal.zig");
        const target_pgid: usize = @intCast(@max(fg_pgid, 1));
        for (&task.tasks) |*t| {
            if (t.state != .UNUSED and t.pgid == target_pgid) {
                signal.sendSignalToTask(t, signal.SIGINT);
            }
        }
        return;
    }

    // 3. Ctrl+D (VEOF = 0x04)
    if (ch == 0x04 and is_canon) {
        eof_pending = true;
        task.wakeTtyWaiters();
        return;
    }

    // 4. Backspace (VERASE = 0x08 or 0x7F)
    if ((ch == 0x08 or ch == 0x7F) and is_canon) {
        if (count > 0) {
            const prev_idx = if (write_pos == 0) TTY_BUF_SIZE - 1 else write_pos - 1;
            if (rx_buf[prev_idx] != '\n') {
                write_pos = prev_idx;
                count -= 1;
                if (is_echo) {
                    serial.writeString("\x08 \x08");
                }
            }
        }
        return;
    }

    // 5. Store byte in ring buffer and echo
    if (count < TTY_BUF_SIZE) {
        rx_buf[write_pos] = ch;
        write_pos = (write_pos + 1) % TTY_BUF_SIZE;
        count += 1;
        if (ch == '\n') {
            newline_count += 1;
        }
        if (is_echo) {
            if (ch == '\n') {
                serial.writeString("\n");
            } else {
                serial.writeByte(ch);
            }
        }
        task.wakeTtyWaiters();
    }
}

pub fn onRxByte(b: u8) void {
    onCharReceived(b);
}

pub fn pollSerialRx() void {
    while (serial.readByteNonBlocking()) |b| {
        onCharReceived(b);
    }
}

pub fn onIrq4() void {
    pollSerialRx();
    io.outb(0x20, 0x20); // Send EOI to Master PIC
}

pub fn hasReadableData() bool {
    pollSerialRx();
    if (eof_pending) return true;
    if ((termios.c_lflag & ICANON) != 0) {
        return newline_count > 0 or count >= TTY_BUF_SIZE / 2;
    }
    return count > 0;
}

pub fn read(dst: []u8) TtyReadResult {
    pollSerialRx();
    if (!hasReadableData()) {
        if (count == 0 and eof_pending) {
            eof_pending = false;
            return .eof;
        }
        return .would_block;
    }

    if (count == 0 and eof_pending) {
        eof_pending = false;
        return .eof;
    }

    const is_canon = (termios.c_lflag & ICANON) != 0;
    var n: usize = 0;
    while (n < dst.len and count > 0) {
        const b = rx_buf[read_pos];
        read_pos = (read_pos + 1) % TTY_BUF_SIZE;
        count -= 1;
        dst[n] = b;
        n += 1;
        if (b == '\n') {
            if (newline_count > 0) newline_count -= 1;
            if (is_canon) break;
        }
    }
    return .{ .bytes = n };
}

pub fn handleIoctl(req: usize, argp: usize, is_valid_buf_fn: *const fn (usize, usize) bool) Errno!isize {
    switch (req) {
        TCGETS => {
            if (!is_valid_buf_fn(argp, @sizeOf(KernelTermios))) return error.EFAULT;
            const p = @as(*KernelTermios, @ptrFromInt(argp));
            p.* = termios;
            return 0;
        },
        TCSETS, TCSETSW, TCSETSF => {
            if (!is_valid_buf_fn(argp, @sizeOf(KernelTermios))) return error.EFAULT;
            const p = @as(*const KernelTermios, @ptrFromInt(argp));
            termios = p.*;
            return 0;
        },
        TIOCSCTTY => {
            return 0;
        },
        TIOCGPGRP => {
            if (!is_valid_buf_fn(argp, @sizeOf(i32))) return error.EFAULT;
            const p = @as(*i32, @ptrFromInt(argp));
            p.* = fg_pgid;
            return 0;
        },
        TIOCSPGRP => {
            if (!is_valid_buf_fn(argp, @sizeOf(i32))) return error.EFAULT;
            const p = @as(*const i32, @ptrFromInt(argp));
            fg_pgid = p.*;
            return 0;
        },
        TIOCGWINSZ => {
            if (!is_valid_buf_fn(argp, @sizeOf(Winsize))) return error.EFAULT;
            const p = @as(*Winsize, @ptrFromInt(argp));
            p.* = winsize;
            return 0;
        },
        TIOCSWINSZ => {
            if (!is_valid_buf_fn(argp, @sizeOf(Winsize))) return error.EFAULT;
            const p = @as(*const Winsize, @ptrFromInt(argp));
            winsize = p.*;
            return 0;
        },
        else => return error.ENOTTY,
    }
}

pub fn getTermios() KernelTermios {
    return termios;
}

pub fn setTermios(t: KernelTermios) void {
    termios = t;
}

pub fn getForegroundPgrp() i32 {
    return fg_pgid;
}

pub fn setForegroundPgrp(p: i32) void {
    fg_pgid = p;
}
