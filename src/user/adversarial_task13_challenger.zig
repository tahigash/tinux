// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Dedicated Empirical Adversarial Challenge Binary for TASK-013 (Sockets, Concurrency & Wraparound)

const std = @import("std");

const AF_UNIX: usize = 1;
const AF_INET: usize = 2;
const SOCK_STREAM: usize = 1;
const SOL_SOCKET: usize = 1;
const SO_REUSEADDR: usize = 2;

const EBADF: isize = -9;
const EAGAIN: isize = -11;
const EPIPE: isize = -32;
const ENOTSOCK: isize = -88;
const EOPNOTSUPP: isize = -95;
const EAFNOSUPPORT: isize = -97;
const EADDRINUSE: isize = -98;
const ECONNREFUSED: isize = -111;

const SockAddrIn = extern struct {
    sin_family: u16 = 2,
    sin_port: u16 = 0,
    sin_addr: u32 = 0x0100007F, // 127.0.0.1
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

inline fn syscall1(num: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall2(num: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall3(num: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall4(num: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall5(num: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}" (a5),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall6(num: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}" (a5),
          [a6] "{r9}" (a6),
        : "rcx", "r11", "memory"
    );
}

fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}

fn exitFail(code: usize, msg: []const u8) noreturn {
    writeStdout("[CHALLENGER_FAIL] ");
    writeStdout(msg);
    writeStdout("\n");
    _ = syscall1(231, code);
    unreachable;
}

// ----------------------------------------------------------------------------
// CHALLENGE 1: Socketpair Full-Duplex Simultaneous Exchange & Wraparounds
// ----------------------------------------------------------------------------
fn challengeSocketpairFullDuplex() void {
    writeStdout("[CHALLENGER] Testing AF_UNIX socketpair full-duplex exchange...\n");

    var sv: [2]i32 = .{ -1, -1 };
    if (syscall4(53, AF_UNIX, SOCK_STREAM, 0, @intFromPtr(&sv)) != 0) {
        exitFail(1, "sys_socketpair failed");
    }

    const fd0: usize = @intCast(sv[0]);
    const fd1: usize = @intCast(sv[1]);

    const msg0 = "FULL_DUPLEX_PAYLOAD_FROM_END_0_ABCDEFGHIJ";
    const msg1 = "FULL_DUPLEX_PAYLOAD_FROM_END_1_1234567890";

    // Write on fd0 and fd1 before reading either (simultaneous full-duplex)
    if (syscall3(1, fd0, @intFromPtr(msg0.ptr), msg0.len) != msg0.len) {
        exitFail(2, "write fd0 failed");
    }
    if (syscall3(1, fd1, @intFromPtr(msg1.ptr), msg1.len) != msg1.len) {
        exitFail(3, "write fd1 failed");
    }

    var rx0: [64]u8 = undefined;
    var rx1: [64]u8 = undefined;

    // fd1 reads message sent by fd0
    const n1 = syscall3(0, fd1, @intFromPtr(&rx1), rx1.len);
    if (n1 != msg0.len) exitFail(4, "read fd1 length mismatch");
    if (!std.mem.eql(u8, rx1[0..@intCast(n1)], msg0)) exitFail(5, "read fd1 corrupted");

    // fd0 reads message sent by fd1
    const n0 = syscall3(0, fd0, @intFromPtr(&rx0), rx0.len);
    if (n0 != msg1.len) exitFail(6, "read fd0 length mismatch");
    if (!std.mem.eql(u8, rx0[0..@intCast(n0)], msg1)) exitFail(7, "read fd0 corrupted");

    // Now stream 16 KiB (4 full ring buffer wraparounds) across fd0 -> fd1
    writeStdout("[CHALLENGER] Streaming 16 KiB across socketpair to test multiple ring wraparounds...\n");
    const STREAM_SIZE: usize = 16 * 1024;
    var sent: usize = 0;
    var recvd: usize = 0;

    var chunk_tx: [1024]u8 = undefined;
    var chunk_rx: [1024]u8 = undefined;

    while (recvd < STREAM_SIZE) {
        if (sent < STREAM_SIZE) {
            const to_send = @min(chunk_tx.len, STREAM_SIZE - sent);
            for (0..to_send) |i| {
                chunk_tx[i] = @truncate((sent + i) & 0xFF);
            }
            const w = syscall3(1, fd0, @intFromPtr(&chunk_tx), to_send);
            if (w > 0) {
                sent += @intCast(w);
            }
        }

        const r = syscall3(0, fd1, @intFromPtr(&chunk_rx), chunk_rx.len);
        if (r > 0) {
            const rn: usize = @intCast(r);
            for (0..rn) |i| {
                const exp: u8 = @truncate((recvd + i) & 0xFF);
                if (chunk_rx[i] != exp) {
                    exitFail(8, "socketpair 16 KiB streaming data corruption");
                }
            }
            recvd += rn;
        }
    }

    _ = syscall1(3, fd0);
    _ = syscall1(3, fd1);
    writeStdout("[CHALLENGER] Socketpair full-duplex & 16 KiB wraparound verified!\n");
}

// ----------------------------------------------------------------------------
// CHALLENGE 2: Multi-Connection Accept Queue Stress & Rejection
// ----------------------------------------------------------------------------
fn challengeAcceptQueueStress() void {
    writeStdout("[CHALLENGER] Testing multi-connection accept queue capacity & ECONNREFUSED...\n");

    const listen_fd = syscall3(41, AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) exitFail(10, "sys_socket failed for listener");

    var optval: i32 = 1;
    _ = syscall5(54, @intCast(listen_fd), SOL_SOCKET, SO_REUSEADDR, @intFromPtr(&optval), 4);

    const TEST_PORT: u16 = 9099;
    var srv_addr = SockAddrIn{
        .sin_family = 2,
        .sin_port = std.mem.nativeToBig(u16, TEST_PORT),
        .sin_addr = 0x0100007F,
    };

    if (syscall3(49, @intCast(listen_fd), @intFromPtr(&srv_addr), @sizeOf(SockAddrIn)) != 0) {
        exitFail(11, "sys_bind failed");
    }
    if (syscall2(50, @intCast(listen_fd), 8) != 0) {
        exitFail(12, "sys_listen failed");
    }

    // Connect 8 clients (filling accept queue)
    var client_fds: [8]isize = undefined;
    for (0..8) |i| {
        const c_fd = syscall3(41, AF_INET, SOCK_STREAM, 0);
        if (c_fd < 0) exitFail(13, "failed to allocate client socket");
        const conn_ret = syscall3(42, @intCast(c_fd), @intFromPtr(&srv_addr), @sizeOf(SockAddrIn));
        if (conn_ret != 0) {
            exitFail(14, "client failed to connect to listener");
        }
        client_fds[i] = c_fd;
    }

    // 9th client connection MUST be rejected with -ECONNREFUSED (-111)
    const c9_fd = syscall3(41, AF_INET, SOCK_STREAM, 0);
    if (c9_fd < 0) exitFail(15, "failed to allocate 9th client socket");
    const c9_ret = syscall3(42, @intCast(c9_fd), @intFromPtr(&srv_addr), @sizeOf(SockAddrIn));
    if (c9_ret != ECONNREFUSED) {
        exitFail(16, "9th connection did not return ECONNREFUSED (-111)");
    }
    _ = syscall1(3, @intCast(c9_fd));
    writeStdout("[CHALLENGER] Accept queue limit 8 properly enforced (-ECONNREFUSED returned on 9th)!\n");

    // Accept 4 connections
    for (0..4) |i| {
        var p_addr: SockAddrIn = undefined;
        var p_len: u32 = @sizeOf(SockAddrIn);
        const a_fd = syscall3(43, @intCast(listen_fd), @intFromPtr(&p_addr), @intFromPtr(&p_len));
        if (a_fd < 0) exitFail(17, "failed to accept connection");

        // Verify communication
        const ping = "PING_QUEUE";
        _ = syscall3(1, @intCast(client_fds[i]), @intFromPtr(ping.ptr), ping.len);
        var buf: [32]u8 = undefined;
        const nr = syscall3(0, @intCast(a_fd), @intFromPtr(&buf), buf.len);
        if (nr != ping.len or !std.mem.eql(u8, buf[0..@intCast(nr)], ping)) {
            exitFail(18, "accepted connection communication failure");
        }

        _ = syscall1(3, @intCast(a_fd));
        _ = syscall1(3, @intCast(client_fds[i]));
    }

    // Now connect 2 new clients (exercising circular queue slot re-use)
    for (0..2) |_| {
        const nc = syscall3(41, AF_INET, SOCK_STREAM, 0);
        if (nc < 0) exitFail(19, "failed to allocate new client");
        if (syscall3(42, @intCast(nc), @intFromPtr(&srv_addr), @sizeOf(SockAddrIn)) != 0) {
            exitFail(20, "failed to connect into freed accept slot");
        }
        _ = syscall1(3, @intCast(nc));
    }

    // Clean up remaining clients
    for (4..8) |i| {
        _ = syscall1(3, @intCast(client_fds[i]));
    }
    _ = syscall1(3, @intCast(listen_fd));
    writeStdout("[CHALLENGER] Multi-connection accept queue stress verified!\n");
}

// ----------------------------------------------------------------------------
// CHALLENGE 3: Edge Cases (Invalid domains, socketpair, bind collision, EPIPE, buffer limits)
// ----------------------------------------------------------------------------
fn challengeEdgeCases() void {
    writeStdout("[CHALLENGER] Testing socket edge cases (EAFNOSUPPORT, EOPNOTSUPP, ECONNREFUSED, EADDRINUSE, EPIPE, buffer limits)...\n");

    // 1-3. Invalid domains (AF_APPLETALK=5, AF_INET6=10, 9999) -> -EAFNOSUPPORT (-97)
    if (syscall3(41, 5, SOCK_STREAM, 0) != EAFNOSUPPORT) {
        exitFail(301, "AF_APPLETALK did not return -EAFNOSUPPORT");
    }
    if (syscall3(41, 10, SOCK_STREAM, 0) != EAFNOSUPPORT) {
        exitFail(302, "AF_INET6 did not return -EAFNOSUPPORT");
    }
    if (syscall3(41, 9999, SOCK_STREAM, 0) != EAFNOSUPPORT) {
        exitFail(303, "domain 9999 did not return -EAFNOSUPPORT");
    }

    // 4. socketpair with AF_INET -> -EOPNOTSUPP (-95)
    var sv_inet: [2]i32 = .{ -1, -1 };
    if (syscall4(53, AF_INET, SOCK_STREAM, 0, @intFromPtr(&sv_inet)) != EOPNOTSUPP) {
        exitFail(304, "sys_socketpair(AF_INET) did not return -EOPNOTSUPP");
    }

    // 5. Connect to closed port 29999 -> -ECONNREFUSED (-111)
    const dead_sock = syscall3(41, AF_INET, SOCK_STREAM, 0);
    var dead_addr = SockAddrIn{
        .sin_family = 2,
        .sin_port = std.mem.nativeToBig(u16, 29999),
        .sin_addr = 0x0100007F,
    };
    const ref_ret = syscall3(42, @intCast(dead_sock), @intFromPtr(&dead_addr), @sizeOf(SockAddrIn));
    if (ref_ret != ECONNREFUSED) {
        exitFail(305, "connect to dead port did not return -ECONNREFUSED");
    }
    _ = syscall1(3, @intCast(dead_sock));

    // 6-7. Duplicate sys_bind on port 17777 without SO_REUSEADDR -> -EADDRINUSE (-98)
    const b1 = syscall3(41, AF_INET, SOCK_STREAM, 0);
    const b2 = syscall3(41, AF_INET, SOCK_STREAM, 0);
    var b_addr = SockAddrIn{
        .sin_family = 2,
        .sin_port = std.mem.nativeToBig(u16, 17777),
        .sin_addr = 0x0100007F,
    };
    if (syscall3(49, @intCast(b1), @intFromPtr(&b_addr), @sizeOf(SockAddrIn)) != 0) {
        exitFail(306, "initial sys_bind failed");
    }
    if (syscall3(49, @intCast(b2), @intFromPtr(&b_addr), @sizeOf(SockAddrIn)) != EADDRINUSE) {
        exitFail(307, "duplicate sys_bind did not return -EADDRINUSE");
    }
    _ = syscall1(3, @intCast(b1));
    _ = syscall1(3, @intCast(b2));

    // 8-9. Zero-byte operations on connected socketpair -> 0
    var pair0: [2]i32 = .{ -1, -1 };
    _ = syscall4(53, AF_UNIX, SOCK_STREAM, 0, @intFromPtr(&pair0));
    var zero_buf: [1]u8 = undefined;
    if (syscall6(44, @intCast(pair0[0]), @intFromPtr(&zero_buf), 0, 0, 0, 0) != 0) {
        exitFail(308, "zero-length sendto did not return 0");
    }
    if (syscall6(45, @intCast(pair0[1]), @intFromPtr(&zero_buf), 0, 0, 0, 0) != 0) {
        exitFail(309, "zero-length recvfrom did not return 0");
    }

    // 10-11. Buffer saturation & partial write (>4096 bytes write)
    var large_tx: [5000]u8 = undefined;
    @memset(&large_tx, 0x55);
    const w_large = syscall6(44, @intCast(pair0[0]), @intFromPtr(&large_tx), large_tx.len, 0, 0, 0);
    if (w_large != 4096) {
        exitFail(310, "large sendto did not return 4096 partial write");
    }
    // Writing to completely full buffer must return -EAGAIN (-11)
    const w_full = syscall6(44, @intCast(pair0[0]), @intFromPtr(&large_tx), 10, 0, 0, 0);
    if (w_full != EAGAIN) {
        exitFail(311, "sendto on saturated buffer did not return -EAGAIN");
    }

    // Drain buffer
    var drain_buf: [4096]u8 = undefined;
    _ = syscall3(0, @intCast(pair0[1]), @intFromPtr(&drain_buf), drain_buf.len);

    // 12-13. EPIPE on writing to closed peer (both sys_sendto and sys_write)
    _ = syscall1(3, @intCast(pair0[1]));
    const sendto_pipe = syscall6(44, @intCast(pair0[0]), @intFromPtr("X".ptr), 1, 0, 0, 0);
    if (sendto_pipe != EPIPE) {
        exitFail(312, "sys_sendto to closed peer did not return -EPIPE");
    }
    const write_pipe = syscall3(1, @intCast(pair0[0]), @intFromPtr("X".ptr), 1);
    if (write_pipe != EPIPE) {
        exitFail(313, "sys_write to closed peer did not return -EPIPE");
    }
    _ = syscall1(3, @intCast(pair0[0]));

    writeStdout("[CHALLENGER] All socket edge cases verified!\n");
}

// ----------------------------------------------------------------------------
// CHALLENGE 4: Non-Socket Descriptors (-ENOTSOCK) and Invalid FDs (-EBADF)
// ----------------------------------------------------------------------------
fn challengeNonSocketAndInvalidFds() void {
    writeStdout("[CHALLENGER] Testing socket syscalls on non-socket and invalid FDs...\n");

    var pfd: [2]i32 = .{ -1, -1 };
    if (syscall2(293, @intFromPtr(&pfd), 0) != 0) {
        exitFail(400, "pipe2 failed");
    }
    const pipe_read: usize = @intCast(pfd[0]);
    const pipe_write: usize = @intCast(pfd[1]);

    var sin: SockAddrIn = .{
        .sin_family = 2,
        .sin_port = std.mem.nativeToBig(u16, 8080),
        .sin_addr = 0x0100007F,
    };
    var sin_len: u32 = @sizeOf(SockAddrIn);
    var optval: i32 = 1;
    var optlen: u32 = 4;
    var dummy_buf: [16]u8 = undefined;

    // 1. sys_accept(43) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall3(43, pipe_read, @intFromPtr(&sin), @intFromPtr(&sin_len)) != ENOTSOCK) {
        exitFail(401, "sys_accept on pipe FD did not return -ENOTSOCK");
    }

    // 2. sys_connect(42) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall3(42, pipe_read, @intFromPtr(&sin), sin_len) != ENOTSOCK) {
        exitFail(402, "sys_connect on pipe FD did not return -ENOTSOCK");
    }

    // 3. sys_sendto(44) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall6(44, pipe_read, @intFromPtr(&dummy_buf), 1, 0, 0, 0) != ENOTSOCK) {
        exitFail(403, "sys_sendto on pipe FD did not return -ENOTSOCK");
    }

    // 4. sys_recvfrom(45) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall6(45, pipe_read, @intFromPtr(&dummy_buf), 1, 0, 0, 0) != ENOTSOCK) {
        exitFail(404, "sys_recvfrom on pipe FD did not return -ENOTSOCK");
    }

    // 5. sys_bind(49) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall3(49, pipe_read, @intFromPtr(&sin), sin_len) != ENOTSOCK) {
        exitFail(405, "sys_bind on pipe FD did not return -ENOTSOCK");
    }

    // 6. sys_listen(50) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall2(50, pipe_read, 4) != ENOTSOCK) {
        exitFail(406, "sys_listen on pipe FD did not return -ENOTSOCK");
    }

    // 7. sys_shutdown(48) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall2(48, pipe_read, 2) != ENOTSOCK) {
        exitFail(407, "sys_shutdown on pipe FD did not return -ENOTSOCK");
    }

    // 8. sys_getsockname(51) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall3(51, pipe_read, @intFromPtr(&sin), @intFromPtr(&sin_len)) != ENOTSOCK) {
        exitFail(408, "sys_getsockname on pipe FD did not return -ENOTSOCK");
    }

    // 9. sys_getpeername(52) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall3(52, pipe_read, @intFromPtr(&sin), @intFromPtr(&sin_len)) != ENOTSOCK) {
        exitFail(409, "sys_getpeername on pipe FD did not return -ENOTSOCK");
    }

    // 10. sys_setsockopt(54) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall5(54, pipe_read, 1, 2, @intFromPtr(&optval), 4) != ENOTSOCK) {
        exitFail(410, "sys_setsockopt on pipe FD did not return -ENOTSOCK");
    }

    // 11. sys_getsockopt(55) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall5(55, pipe_read, 1, 2, @intFromPtr(&optval), @intFromPtr(&optlen)) != ENOTSOCK) {
        exitFail(411, "sys_getsockopt on pipe FD did not return -ENOTSOCK");
    }

    // 12. sys_accept4(288) on open pipe FD -> MUST return -ENOTSOCK (-88)
    if (syscall4(288, pipe_read, @intFromPtr(&sin), @intFromPtr(&sin_len), 0) != ENOTSOCK) {
        exitFail(412, "sys_accept4 on pipe FD did not return -ENOTSOCK");
    }

    // 13. Also verify stdout (fd 1) returns -ENOTSOCK (-88)
    if (syscall2(50, 1, 4) != ENOTSOCK) {
        exitFail(413, "sys_listen on stdout FD 1 did not return -ENOTSOCK");
    }

    _ = syscall1(3, pipe_read);
    _ = syscall1(3, pipe_write);

    // 14-23. Invalid and unused descriptors -> MUST return -EBADF (-9)
    const bad_fds = [_]usize{ ~@as(usize, 0), 60, 1024 };
    for (bad_fds) |bad_fd| {
        if (syscall2(50, bad_fd, 4) != EBADF) {
            exitFail(414, "sys_listen on invalid FD did not return -EBADF");
        }
        if (syscall3(42, bad_fd, @intFromPtr(&sin), sin_len) != EBADF) {
            exitFail(415, "sys_connect on invalid FD did not return -EBADF");
        }
        if (syscall3(43, bad_fd, @intFromPtr(&sin), @intFromPtr(&sin_len)) != EBADF) {
            exitFail(416, "sys_accept on invalid FD did not return -EBADF");
        }
        if (syscall6(44, bad_fd, @intFromPtr(&dummy_buf), 1, 0, 0, 0) != EBADF) {
            exitFail(417, "sys_sendto on invalid FD did not return -EBADF");
        }
        if (syscall6(45, bad_fd, @intFromPtr(&dummy_buf), 1, 0, 0, 0) != EBADF) {
            exitFail(418, "sys_recvfrom on invalid FD did not return -EBADF");
        }
        if (syscall3(49, bad_fd, @intFromPtr(&sin), sin_len) != EBADF) {
            exitFail(419, "sys_bind on invalid FD did not return -EBADF");
        }
        if (syscall2(48, bad_fd, 2) != EBADF) {
            exitFail(420, "sys_shutdown on invalid FD did not return -EBADF");
        }
        if (syscall3(51, bad_fd, @intFromPtr(&sin), @intFromPtr(&sin_len)) != EBADF) {
            exitFail(421, "sys_getsockname on invalid FD did not return -EBADF");
        }
        if (syscall3(52, bad_fd, @intFromPtr(&sin), @intFromPtr(&sin_len)) != EBADF) {
            exitFail(422, "sys_getpeername on invalid FD did not return -EBADF");
        }
        if (syscall5(54, bad_fd, 1, 2, @intFromPtr(&optval), 4) != EBADF) {
            exitFail(423, "sys_setsockopt on invalid FD did not return -EBADF");
        }
    }

    writeStdout("[CHALLENGER] Non-socket descriptors (-ENOTSOCK) & invalid descriptors (-EBADF) verified!\n");
}

export fn challengerMain(_: [*]const u64) callconv(.C) noreturn {
    writeStdout("=== Tinux TASK-013 Adversarial Challenger Suite ===\n");
    challengeSocketpairFullDuplex();
    challengeAcceptQueueStress();
    challengeEdgeCases();
    challengeNonSocketAndInvalidFds();
    writeStdout("[CHALLENGER_PASS] All TASK-013 adversarial challenges passed cleanly!\n");
    _ = syscall1(231, 0);
    unreachable;
}


pub fn main() void {}
