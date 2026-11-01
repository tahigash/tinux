// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Dedicated Empirical Adversarial Challenge Binary for TASK-013 (Sockets, Concurrency & Wraparound)

const std = @import("std");

const AF_UNIX: usize = 1;
const AF_INET: usize = 2;
const SOCK_STREAM: usize = 1;
const SOL_SOCKET: usize = 1;
const SO_REUSEADDR: usize = 2;

const ECONNREFUSED: isize = -111;
const EPIPE: isize = -32;
const EAFNOSUPPORT: isize = -97;

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
// CHALLENGE 3: Edge Cases (Invalid domain, Refused port, EPIPE)
// ----------------------------------------------------------------------------
fn challengeEdgeCases() void {
    writeStdout("[CHALLENGER] Testing socket edge cases (EAFNOSUPPORT, ECONNREFUSED, EPIPE)...\n");

    // 1. Invalid domain (AF_IPX = 4) -> -EAFNOSUPPORT (-97)
    const bad_dom = syscall3(41, 4, SOCK_STREAM, 0);
    if (bad_dom != EAFNOSUPPORT) {
        exitFail(30, "invalid domain did not return -EAFNOSUPPORT");
    }

    // 2. Connect to closed port 12345 -> -ECONNREFUSED (-111)
    const dead_sock = syscall3(41, AF_INET, SOCK_STREAM, 0);
    var dead_addr = SockAddrIn{
        .sin_family = 2,
        .sin_port = std.mem.nativeToBig(u16, 12345),
        .sin_addr = 0x0100007F,
    };
    const ref_ret = syscall3(42, @intCast(dead_sock), @intFromPtr(&dead_addr), @sizeOf(SockAddrIn));
    if (ref_ret != ECONNREFUSED) {
        exitFail(31, "connect to dead port did not return -ECONNREFUSED");
    }
    _ = syscall1(3, @intCast(dead_sock));

    // 3. EPIPE on writing to closed peer
    var pair: [2]i32 = .{ -1, -1 };
    _ = syscall4(53, AF_UNIX, SOCK_STREAM, 0, @intFromPtr(&pair));
    // Close receiver pair[1]
    _ = syscall1(3, @intCast(pair[1]));
    // Write on sender pair[0] -> must fail with -EPIPE (-32)
    const pipe_ret = syscall3(1, @intCast(pair[0]), @intFromPtr("X".ptr), 1);
    if (pipe_ret != EPIPE) {
        exitFail(32, "write to closed peer did not return -EPIPE");
    }
    _ = syscall1(3, @intCast(pair[0]));

    writeStdout("[CHALLENGER] All socket edge cases verified!\n");
}

export fn challengerMain(_: [*]const u64) callconv(.C) noreturn {
    writeStdout("=== Tinux TASK-013 Adversarial Challenger Suite ===\n");
    challengeSocketpairFullDuplex();
    challengeAcceptQueueStress();
    challengeEdgeCases();
    writeStdout("[CHALLENGER_PASS] All TASK-013 adversarial challenges passed cleanly!\n");
    _ = syscall1(231, 0);
    unreachable;
}

pub fn main() void {}
