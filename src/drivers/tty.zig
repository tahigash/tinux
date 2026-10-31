const std = @import("std");
const serial = @import("serial.zig");
const task = @import("../proc/task.zig");

pub const ICRNL: u32 = 0o000400; // 0x0100
pub const ISIG: u32 = 0o000001;  // 0x0001
pub const ICANON: u32 = 0o000002;// 0x0002
pub const ECHO: u32 = 0o000010;  // 0x0008

pub const TCGETS: usize = 0x5401;
pub const TCSETS: usize = 0x5402;
pub const TCSETSW: usize = 0x5403;
pub const TCSETSF: usize = 0x5404;
pub const TIOCGPGRP: usize = 0x540F;
pub const TIOCSPGRP: usize = 0x5410;
pub const TIOCGWINSZ: usize = 0x5413;
pub const TIOCSWINSZ: usize = 0x5414;

pub const LinuxTermios = extern struct {
    c_iflag: u32 align(1) = ICRNL,
    c_oflag: u32 align(1) = 0x0005,
    c_cflag: u32 align(1) = 0x00BF,
    c_lflag: u32 align(1) = ISIG | ICANON | ECHO | 0x8A30,
    c_line: u8 align(1) = 0,
    c_cc: [19]u8 align(1) = .{
        3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0,
    },
    comptime {
        std.debug.assert(@sizeOf(LinuxTermios) == 36);
    }
};

pub const LinuxWinsize = extern struct {
    ws_row: u16 align(1) = 25,
    ws_col: u16 align(1) = 80,
    ws_xpixel: u16 align(1) = 0,
    ws_ypixel: u16 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxWinsize) == 8);
    }
};

pub const TtyReadStatus = enum {
    bytes,
    eof,
    would_block,
};

pub const TtyReadResult = struct {
    status: TtyReadStatus,
    n: usize = 0,
};

const BUF_SIZE: usize = 4096;

var termios_state: LinuxTermios = .{};
var fg_pgrp: i32 = 1;

var line_buf: [512]u8 = undefined;
var line_len: usize = 0;

var ready_buf: [BUF_SIZE]u8 = undefined;
var ready_read_pos: usize = 0;
var ready_write_pos: usize = 0;
var ready_count: usize = 0;
var eof_pending: bool = false;

pub fn init() void {
    termios_state = .{};
    fg_pgrp = 1;
    line_len = 0;
    ready_read_pos = 0;
    ready_write_pos = 0;
    ready_count = 0;
    eof_pending = false;
}

pub fn hasReadableData() bool {
    return ready_count > 0 or eof_pending;
}

fn pushReadyByte(b: u8) void {
    if (ready_count < BUF_SIZE) {
        ready_buf[ready_write_pos] = b;
        ready_write_pos = (ready_write_pos + 1) % BUF_SIZE;
        ready_count += 1;
    }
}

pub fn onReceiveByte(raw_b: u8) void {
    var b = raw_b;
    // 1. CR-to-NL
    if ((termios_state.c_iflag & ICRNL) != 0 and b == '\r') {
        b = '\n';
    }

    const is_canon = (termios_state.c_lflag & ICANON) != 0;
    const is_echo = (termios_state.c_lflag & ECHO) != 0;

    // 2. Backspace
    if (b == 0x08 or b == 0x7F) {
        if (is_canon) {
            if (line_len > 0) {
                line_len -= 1;
                if (is_echo) {
                    serial.writeString("\x08 \x08");
                }
            }
            return;
        }
    }

    // 3. Ctrl+D (EOF)
    if (b == 0x04) {
        if (is_canon) {
            for (line_buf[0..line_len]) |c| {
                pushReadyByte(c);
            }
            line_len = 0;
            eof_pending = true;
            task.wakeTtyWaiters();
            return;
        }
    }

    // 4. Echo
    if (is_echo) {
        if (b == '\n') {
            serial.writeString("\r\n");
        } else {
            serial.writeChar(b);
        }
    }

    // 5. Buffering
    if (is_canon) {
        if (line_len < line_buf.len) {
            line_buf[line_len] = b;
            line_len += 1;
        }
        if (b == '\n') {
            for (line_buf[0..line_len]) |c| {
                pushReadyByte(c);
            }
            line_len = 0;
            task.wakeTtyWaiters();
        }
    } else {
        pushReadyByte(b);
        task.wakeTtyWaiters();
    }
}

pub fn onRxByte(b: u8) void {
    onReceiveByte(b);
}

pub fn read(dst: []u8) TtyReadResult {
    if (ready_count > 0) {
        const is_canon = (termios_state.c_lflag & ICANON) != 0;
        var to_read: usize = 0;

        while (to_read < dst.len and ready_count > 0) {
            const b = ready_buf[ready_read_pos];
            ready_read_pos = (ready_read_pos + 1) % BUF_SIZE;
            ready_count -= 1;
            dst[to_read] = b;
            to_read += 1;
            if (is_canon and b == '\n') {
                break;
            }
        }
        return .{ .status = .bytes, .n = to_read };
    }

    if (eof_pending) {
        eof_pending = false;
        return .{ .status = .eof, .n = 0 };
    }

    return .{ .status = .would_block, .n = 0 };
}

pub fn getTermios() LinuxTermios {
    return termios_state;
}

pub fn setTermios(new_t: LinuxTermios) void {
    const was_canon = (termios_state.c_lflag & ICANON) != 0;
    const now_canon = (new_t.c_lflag & ICANON) != 0;
    termios_state = new_t;

    if (was_canon and !now_canon and line_len > 0) {
        for (line_buf[0..line_len]) |c| {
            pushReadyByte(c);
        }
        line_len = 0;
        task.wakeTtyWaiters();
    }
}

pub fn getForegroundPgrp() i32 {
    return fg_pgrp;
}

pub fn setForegroundPgrp(pgrp: i32) void {
    fg_pgrp = pgrp;
}
