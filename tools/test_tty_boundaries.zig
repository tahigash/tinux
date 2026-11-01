// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical stress test for TTY line discipline, circular buffer boundaries, and termios ABI

const std = @import("std");

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
};

pub const Winsize = extern struct {
    ws_row: u16 = 24,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

pub const TtyReadResult = union(enum) {
    bytes: usize,
    eof: void,
    would_block: void,
};

pub const MockTtyState = struct {
    termios: KernelTermios = .{},
    fg_pgid: i32 = 1,
    winsize: Winsize = .{},
    rx_buf: [TTY_BUF_SIZE]u8 = [_]u8{0} ** TTY_BUF_SIZE,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,
    newline_count: usize = 0,
    eof_pending: bool = false,
    echo_history: [8192]u8 = [_]u8{0} ** 8192,
    echo_len: usize = 0,
    sigint_delivered: bool = false,

    pub fn init() MockTtyState {
        return .{};
    }

    fn echoStr(self: *MockTtyState, s: []const u8) void {
        const copy_len = @min(s.len, self.echo_history.len - self.echo_len);
        @memcpy(self.echo_history[self.echo_len .. self.echo_len + copy_len], s[0..copy_len]);
        self.echo_len += copy_len;
    }

    pub fn onCharReceived(self: *MockTtyState, raw_ch: u8) void {
        var ch = raw_ch;
        if ((self.termios.c_iflag & ICRNL) != 0 and ch == '\r') {
            ch = '\n';
        }

        const is_sig = (self.termios.c_lflag & ISIG) != 0;
        const is_canon = (self.termios.c_lflag & ICANON) != 0;
        const is_echo = (self.termios.c_lflag & ECHO) != 0;

        // 2. Ctrl+C (VINTR = 0x03)
        if (ch == 0x03 and is_sig) {
            if (is_echo) {
                self.echoStr("^C\r\n");
            }
            self.sigint_delivered = true;
            return;
        }

        // 3. Ctrl+D (VEOF = 0x04)
        if (ch == 0x04 and is_canon) {
            self.eof_pending = true;
            return;
        }

        // 4. Backspace (VERASE = 0x08 or 0x7F)
        if ((ch == 0x08 or ch == 0x7F) and is_canon) {
            if (self.count > 0) {
                const prev_idx = if (self.write_pos == 0) TTY_BUF_SIZE - 1 else self.write_pos - 1;
                if (self.rx_buf[prev_idx] != '\n') {
                    self.write_pos = prev_idx;
                    self.count -= 1;
                    if (is_echo) {
                        self.echoStr("\x08 \x08");
                    }
                }
            }
            return;
        }

        // 5. Store byte in ring buffer and echo
        if (self.count < TTY_BUF_SIZE) {
            self.rx_buf[self.write_pos] = ch;
            self.write_pos = (self.write_pos + 1) % TTY_BUF_SIZE;
            self.count += 1;
            if (ch == '\n') {
                self.newline_count += 1;
            }
            if (is_echo) {
                if (ch == '\n') {
                    self.echoStr("\r\n");
                } else {
                    const b = [_]u8{ch};
                    self.echoStr(&b);
                }
            }
        }
    }

    pub fn hasReadableData(self: *const MockTtyState) bool {
        if (self.eof_pending) return true;
        if ((self.termios.c_lflag & ICANON) != 0) {
            return self.newline_count > 0 or self.count >= TTY_BUF_SIZE / 2;
        }
        return self.count > 0;
    }

    pub fn read(self: *MockTtyState, dst: []u8) TtyReadResult {
        if (!self.hasReadableData()) {
            if (self.count == 0 and self.eof_pending) {
                self.eof_pending = false;
                return .eof;
            }
            return .would_block;
        }

        if (self.count == 0 and self.eof_pending) {
            self.eof_pending = false;
            return .eof;
        }

        const is_canon = (self.termios.c_lflag & ICANON) != 0;
        var n: usize = 0;
        while (n < dst.len and self.count > 0) {
            const b = self.rx_buf[self.read_pos];
            self.read_pos = (self.read_pos + 1) % TTY_BUF_SIZE;
            self.count -= 1;
            dst[n] = b;
            n += 1;
            if (b == '\n') {
                if (self.newline_count > 0) self.newline_count -= 1;
                if (is_canon) break;
            }
        }
        return .{ .bytes = n };
    }
};

fn testAbiSizes() !void {
    std.debug.print("[CHALLENGE] 1. Checking struct ABI sizes and alignments...\n", .{});
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(KernelTermios));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Winsize));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(KernelTermios, "c_iflag"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(KernelTermios, "c_oflag"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(KernelTermios, "c_cflag"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(KernelTermios, "c_lflag"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(KernelTermios, "c_line"));
    try std.testing.expectEqual(@as(usize, 17), @offsetOf(KernelTermios, "c_cc"));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Winsize, "ws_row"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(Winsize, "ws_col"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Winsize, "ws_xpixel"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(Winsize, "ws_ypixel"));

    std.debug.print("  [PASS] ABI layout strictly complies with Linux x86_64 ktermios (36B) and winsize (8B)\n", .{});
}

fn testIoctlNumbers() !void {
    std.debug.print("[CHALLENGE] 2. Checking ioctl magic numbers against Linux ABI...\n", .{});
    try std.testing.expectEqual(@as(usize, 0x5401), TCGETS);
    try std.testing.expectEqual(@as(usize, 0x5402), TCSETS);
    try std.testing.expectEqual(@as(usize, 0x5403), TCSETSW);
    try std.testing.expectEqual(@as(usize, 0x5404), TCSETSF);
    try std.testing.expectEqual(@as(usize, 0x540E), TIOCSCTTY);
    try std.testing.expectEqual(@as(usize, 0x540F), TIOCGPGRP);
    try std.testing.expectEqual(@as(usize, 0x5410), TIOCSPGRP);
    try std.testing.expectEqual(@as(usize, 0x5413), TIOCGWINSZ);
    try std.testing.expectEqual(@as(usize, 0x5414), TIOCSWINSZ);
    std.debug.print("  [PASS] Ioctl magic numbers strictly match Linux 0x54xx sequence\n", .{});
}

fn testBackspaceOnEmpty() !void {
    std.debug.print("[CHALLENGE] 3. Testing backspace on empty buffer (underflow attack)...\n", .{});
    var state = MockTtyState.init();

    // Spam backspaces and DEL on empty buffer
    for (0..100) |_| {
        state.onCharReceived(0x08); // BS
        state.onCharReceived(0x7F); // DEL
    }

    try std.testing.expectEqual(@as(usize, 0), state.count);
    try std.testing.expectEqual(@as(usize, 0), state.write_pos);
    try std.testing.expectEqual(@as(usize, 0), state.read_pos);
    try std.testing.expectEqual(false, state.hasReadableData());

    var buf: [64]u8 = undefined;
    const res = state.read(&buf);
    try std.testing.expect(res == .would_block);
    std.debug.print("  [PASS] Empty buffer backspace is safe, count does not underflow\n", .{});
}

fn testBackspaceAfterCommittedLine() !void {
    std.debug.print("[CHALLENGE] 4. Testing backspace after committed newline (boundary protection)...\n", .{});
    var state = MockTtyState.init();

    // Type "echo hello\n"
    for ("echo hello\n") |c| {
        state.onCharReceived(c);
    }
    try std.testing.expectEqual(@as(usize, 11), state.count);
    try std.testing.expectEqual(@as(usize, 1), state.newline_count);

    // Now attempt backspaces after newline
    for (0..5) |_| {
        state.onCharReceived(0x08);
    }
    // Must NOT erase newline or characters from committed line!
    try std.testing.expectEqual(@as(usize, 11), state.count);
    try std.testing.expectEqual(@as(usize, 1), state.newline_count);

    // Type second line "world\n"
    for ("world\n") |c| {
        state.onCharReceived(c);
    }
    try std.testing.expectEqual(@as(usize, 17), state.count);
    try std.testing.expectEqual(@as(usize, 2), state.newline_count);

    // Read first line
    var read_buf: [32]u8 = undefined;
    const res1 = state.read(&read_buf);
    switch (res1) {
        .bytes => |n| {
            try std.testing.expectEqualStrings("echo hello\n", read_buf[0..n]);
        },
        else => return error.TestFailed,
    }

    // Read second line
    const res2 = state.read(&read_buf);
    switch (res2) {
        .bytes => |n| {
            try std.testing.expectEqualStrings("world\n", read_buf[0..n]);
        },
        else => return error.TestFailed,
    }

    try std.testing.expectEqual(@as(usize, 0), state.count);
    try std.testing.expectEqual(@as(usize, 0), state.newline_count);
    std.debug.print("  [PASS] Committed line boundary respected, cannot backspace across newline\n", .{});
}

fn testCarriageReturnTranslation() !void {
    std.debug.print("[CHALLENGE] 5. Testing carriage return translation (ICRNL)...\n", .{});
    var state = MockTtyState.init();

    // Default: ICRNL is enabled (0x0100)
    for ("uname -a\r") |c| {
        state.onCharReceived(c);
    }
    try std.testing.expectEqual(@as(usize, 9), state.count);
    try std.testing.expectEqual(@as(usize, 1), state.newline_count);

    var read_buf: [32]u8 = undefined;
    const res1 = state.read(&read_buf);
    switch (res1) {
        .bytes => |n| {
            try std.testing.expectEqualStrings("uname -a\n", read_buf[0..n]);
        },
        else => return error.TestFailed,
    }

    // Now disable ICRNL
    state.termios.c_iflag &= ~ICRNL;
    for ("test\r") |c| {
        state.onCharReceived(c);
    }
    // \r is NOT translated to \n, so newline_count stays 0!
    try std.testing.expectEqual(@as(usize, 5), state.count);
    try std.testing.expectEqual(@as(usize, 0), state.newline_count);
    // In canonical mode, without newline, hasReadableData is false (would block)
    try std.testing.expectEqual(false, state.hasReadableData());

    std.debug.print("  [PASS] ICRNL properly translates \\r to \\n and respects c_iflag disable\n", .{});
}

fn testEofBehavior() !void {
    std.debug.print("[CHALLENGE] 6. Testing Ctrl+D (VEOF) on empty vs non-empty buffer...\n", .{});

    // Subtest 6A: EOF on empty buffer
    {
        var state = MockTtyState.init();
        state.onCharReceived(0x04); // Ctrl+D
        try std.testing.expectEqual(true, state.hasReadableData());

        var read_buf: [32]u8 = undefined;
        const res = state.read(&read_buf);
        try std.testing.expect(res == .eof);
        // After reading EOF, eof_pending must be cleared
        try std.testing.expectEqual(false, state.hasReadableData());
        const res_after = state.read(&read_buf);
        try std.testing.expect(res_after == .would_block);
    }

    // Subtest 6B: EOF on pending text without newline ("cat\x04")
    {
        var state = MockTtyState.init();
        for ("cat") |c| {
            state.onCharReceived(c);
        }
        state.onCharReceived(0x04); // Ctrl+D

        try std.testing.expectEqual(true, state.hasReadableData());
        var read_buf: [32]u8 = undefined;

        // First read must flush pending "cat" (3 bytes)
        const res1 = state.read(&read_buf);
        switch (res1) {
            .bytes => |n| {
                try std.testing.expectEqualStrings("cat", read_buf[0..n]);
            },
            else => return error.TestFailed,
        }

        // Second read must immediately return EOF
        const res2 = state.read(&read_buf);
        try std.testing.expect(res2 == .eof);

        // Third read must now block
        const res3 = state.read(&read_buf);
        try std.testing.expect(res3 == .would_block);
    }

    std.debug.print("  [PASS] VEOF correctly returns EOF on empty buffer and flushes partial line before EOF\n", .{});
}

fn testBufferOverflowStress() !void {
    std.debug.print("[CHALLENGE] 7. Testing 4096-byte ring buffer overflow and wrap-around...\n", .{});
    var state = MockTtyState.init();

    // Fill buffer completely with 4096 bytes ('A')
    for (0..4096) |_| {
        state.onCharReceived('A');
    }
    try std.testing.expectEqual(@as(usize, 4096), state.count);

    // Attempt to overflow with 500 more bytes ('B')
    for (0..500) |_| {
        state.onCharReceived('B');
    }
    // Count must be clamped at 4096
    try std.testing.expectEqual(@as(usize, 4096), state.count);

    // Read out 1000 bytes
    var drain_buf: [1000]u8 = undefined;
    // Set raw mode temporarily to drain without newline
    state.termios.c_lflag &= ~ICANON;
    const r1 = state.read(&drain_buf);
    switch (r1) {
        .bytes => |n| {
            try std.testing.expectEqual(@as(usize, 1000), n);
            for (drain_buf) |b| {
                try std.testing.expectEqual(@as(u8, 'A'), b);
            }
        },
        else => return error.TestFailed,
    }
    try std.testing.expectEqual(@as(usize, 3096), state.count);

    // Now write 1000 bytes of 'C' into wrapped space
    for (0..1000) |_| {
        state.onCharReceived('C');
    }
    try std.testing.expectEqual(@as(usize, 4096), state.count);

    // Drain remaining 3096 'A's
    var drain_buf2: [3096]u8 = undefined;
    const r2 = state.read(&drain_buf2);
    switch (r2) {
        .bytes => |n| {
            try std.testing.expectEqual(@as(usize, 3096), n);
            for (drain_buf2) |b| {
                try std.testing.expectEqual(@as(u8, 'A'), b);
            }
        },
        else => return error.TestFailed,
    }

    // Drain the 1000 'C's
    var drain_buf3: [1000]u8 = undefined;
    const r3 = state.read(&drain_buf3);
    switch (r3) {
        .bytes => |n| {
            try std.testing.expectEqual(@as(usize, 1000), n);
            for (drain_buf3) |b| {
                try std.testing.expectEqual(@as(u8, 'C'), b);
            }
        },
        else => return error.TestFailed,
    }

    try std.testing.expectEqual(@as(usize, 0), state.count);
    std.debug.print("  [PASS] Buffer wrap-around and overflow clamping verified with zero data corruption\n", .{});
}

pub fn main() !void {
    std.debug.print("=== Tinux TTY Empirical Challenger Test Harness ===\n", .{});
    try testAbiSizes();
    try testIoctlNumbers();
    try testBackspaceOnEmpty();
    try testBackspaceAfterCommittedLine();
    try testCarriageReturnTranslation();
    try testEofBehavior();
    try testBufferOverflowStress();
    std.debug.print("=== ALL EMPIRICAL TTY CHALLENGES PASSED CLEANLY ===\n", .{});
}
