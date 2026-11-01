// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Comprehensive empirical adversarial challenge suite for TASK-019:
// UDP loopback, port conflicts, datagram boundaries, non-blocking sockets, and error paths.

const std = @import("std");

pub const SYS_READ: usize = 0;
pub const SYS_WRITE: usize = 1;
pub const SYS_CLOSE: usize = 3;
pub const SYS_SOCKET: usize = 41;
pub const SYS_CONNECT: usize = 42;
pub const SYS_SENDTO: usize = 44;
pub const SYS_RECVFROM: usize = 45;
pub const SYS_BIND: usize = 49;
pub const SYS_FCNTL: usize = 72;
pub const SYS_EXIT_GROUP: usize = 231;

pub const AF_INET: u16 = 2;
pub const SOCK_DGRAM: usize = 2;
pub const IPPROTO_UDP: usize = 17;
pub const SOCK_NONBLOCK: usize = 0o4000;
pub const O_NONBLOCK: usize = 0o4000;
pub const F_GETFL: usize = 3;
pub const F_SETFL: usize = 4;

pub const EBADF: isize = -9;
pub const EAGAIN: isize = -11;
pub const EFAULT: isize = -14;
pub const EINVAL: isize = -22;
pub const EDESTADDRREQ: isize = -89;
pub const EADDRINUSE: isize = -98;
pub const ENOTSOCK: isize = -88;

pub const SockAddrIn = extern struct {
    sin_family: u16 align(1) = AF_INET,
    sin_port: u16 align(1) = 0, // Big Endian
    sin_addr: [4]u8 align(1) = .{ 127, 0, 0, 1 },
    sin_zero: [8]u8 align(1) = [_]u8{0} ** 8,

    comptime {
        std.debug.assert(@sizeOf(SockAddrIn) == 16);
    }
};

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1) : "rcx", "r11", "memory");
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3) : "rcx", "r11", "memory");
}

inline fn sys6(n: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3), [d] "{r10}" (a4), [e] "{r8}" (a5), [f] "{r9}" (a6) : "rcx", "r11", "memory");
}

fn puts(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn printNum(num: isize) void {
    var buf: [32]u8 = undefined;
    var idx: usize = 0;
    if (num < 0) {
        buf[0] = '-';
        idx = 1;
    }
    var u: usize = if (num < 0) @intCast(-num) else @intCast(num);
    var temp: [24]u8 = undefined;
    var t_idx: usize = 0;
    if (u == 0) {
        temp[0] = '0';
        t_idx = 1;
    } else {
        while (u > 0) {
            temp[t_idx] = @intCast('0' + (u % 10));
            t_idx += 1;
            u = u / 10;
        }
    }
    while (t_idx > 0) {
        t_idx -= 1;
        buf[idx] = temp[t_idx];
        idx += 1;
    }
    puts(buf[0..idx]);
}

fn exit(code: usize) noreturn {
    _ = sys1(SYS_EXIT_GROUP, code);
    while (true) {}
}

fn assertEqual(desc: []const u8, expected: isize, actual: isize) void {
    puts(desc);
    puts(": expected=");
    printNum(expected);
    puts(" actual=");
    printNum(actual);
    if (expected == actual) {
        puts(" [OK]\n");
    } else {
        puts(" [FAIL]\n");
        exit(1);
    }
}

fn assertTrue(desc: []const u8, condition: bool) void {
    puts(desc);
    if (condition) {
        puts(" [OK]\n");
    } else {
        puts(" [FAIL]\n");
        exit(1);
    }
}

pub export fn challengerMain() callconv(.C) noreturn {
    puts("=== Tinux Milestone M19 (TASK-019) Adversarial Challenger Suite ===\n");

    // -------------------------------------------------------------
    // CHALLENGE 1: Local Port Binding & Port Conflict Collision (-EADDRINUSE)
    // -------------------------------------------------------------
    puts("\n--- Challenge 1: Port Conflict Detection (-EADDRINUSE) ---\n");
    const s1 = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    assertTrue("alloc s1", s1 >= 0);

    var addr5678 = SockAddrIn{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, 5678),
        .sin_addr = .{ 127, 0, 0, 1 },
    };

    // s1 binds to port 5678
    const b1 = sys3(SYS_BIND, @intCast(s1), @intFromPtr(&addr5678), @sizeOf(SockAddrIn));
    assertEqual("s1 bind to 5678", 0, b1);

    // Attempting to bind s1 again -> -EINVAL (already bound)
    const b1_again = sys3(SYS_BIND, @intCast(s1), @intFromPtr(&addr5678), @sizeOf(SockAddrIn));
    assertEqual("s1 rebinding same port returns -EINVAL", EINVAL, b1_again);

    // s2 attempts to bind to port 5678 -> -EADDRINUSE
    const s2 = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    assertTrue("alloc s2", s2 >= 0);
    const b2 = sys3(SYS_BIND, @intCast(s2), @intFromPtr(&addr5678), @sizeOf(SockAddrIn));
    assertEqual("s2 collision on 5678 returns -EADDRINUSE", EADDRINUSE, b2);

    // Close s1 and verify port 5678 is freed so s2 can now bind
    _ = sys1(SYS_CLOSE, @intCast(s1));
    const b2_retry = sys3(SYS_BIND, @intCast(s2), @intFromPtr(&addr5678), @sizeOf(SockAddrIn));
    assertEqual("s2 bind to 5678 after s1 close succeeds", 0, b2_retry);
    _ = sys1(SYS_CLOSE, @intCast(s2));

    // -------------------------------------------------------------
    // CHALLENGE 2: Unconnected sendto/write without destination (-EDESTADDRREQ)
    // -------------------------------------------------------------
    puts("\n--- Challenge 2: Unconnected sendto/write (-EDESTADDRREQ) ---\n");
    const s_unconn = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    assertTrue("alloc s_unconn", s_unconn >= 0);

    const test_payload = "HELLO_UDP";
    // write on unconnected UDP socket returns -EDESTADDRREQ (-89) in POSIX Linux ABI.
    const wr_unconn = sys3(SYS_WRITE, @intCast(s_unconn), @intFromPtr(test_payload.ptr), test_payload.len);
    assertEqual("unconnected write returns -EDESTADDRREQ", EDESTADDRREQ, wr_unconn);

    // sendto with NULL destination pointer and addrlen = 0
    const st_null = sys6(SYS_SENDTO, @intCast(s_unconn), @intFromPtr(test_payload.ptr), test_payload.len, 0, 0, 0);
    assertEqual("unconnected sendto with NULL dest returns -EDESTADDRREQ", EDESTADDRREQ, st_null);

    _ = sys1(SYS_CLOSE, @intCast(s_unconn));

    // -------------------------------------------------------------
    // CHALLENGE 3: Non-blocking Socket Receive (-EAGAIN)
    // -------------------------------------------------------------
    puts("\n--- Challenge 3: Non-blocking Socket Receive (-EAGAIN) ---\n");
    // 3a. Socket created with SOCK_NONBLOCK flag
    const s_nb = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, IPPROTO_UDP);
    assertTrue("alloc s_nb with SOCK_NONBLOCK", s_nb >= 0);

    var dummy_rx: [32]u8 = undefined;
    var dummy_from: SockAddrIn = undefined;
    var dummy_from_len: u32 = @sizeOf(SockAddrIn);

    const nb_recv = sys6(SYS_RECVFROM, @intCast(s_nb), @intFromPtr(&dummy_rx), dummy_rx.len, 0, @intFromPtr(&dummy_from), @intFromPtr(&dummy_from_len));
    assertEqual("SOCK_NONBLOCK recvfrom on empty queue returns -EAGAIN", EAGAIN, nb_recv);

    const nb_read = sys3(SYS_READ, @intCast(s_nb), @intFromPtr(&dummy_rx), dummy_rx.len);
    assertEqual("SOCK_NONBLOCK read on empty queue returns -EAGAIN", EAGAIN, nb_read);
    _ = sys1(SYS_CLOSE, @intCast(s_nb));

    // 3b. Socket switched to non-blocking via fcntl(fd, F_SETFL, O_NONBLOCK)
    const s_fcntl = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    assertTrue("alloc s_fcntl", s_fcntl >= 0);
    const setfl_res = sys3(SYS_FCNTL, @intCast(s_fcntl), F_SETFL, O_NONBLOCK);
    assertEqual("fcntl F_SETFL O_NONBLOCK", 0, setfl_res);

    const fcntl_recv = sys6(SYS_RECVFROM, @intCast(s_fcntl), @intFromPtr(&dummy_rx), dummy_rx.len, 0, 0, 0);
    assertEqual("fcntl O_NONBLOCK recvfrom on empty queue returns -EAGAIN", EAGAIN, fcntl_recv);

    const fcntl_read = sys3(SYS_READ, @intCast(s_fcntl), @intFromPtr(&dummy_rx), dummy_rx.len);
    assertEqual("fcntl O_NONBLOCK read on empty queue returns -EAGAIN", EAGAIN, fcntl_read);
    _ = sys1(SYS_CLOSE, @intCast(s_fcntl));

    // -------------------------------------------------------------
    // CHALLENGE 4: UDP Datagram Message Boundary & Truncation Semantics
    // -------------------------------------------------------------
    puts("\n--- Challenge 4: Datagram Boundaries & Truncation Semantics ---\n");
    // Receiver socket on 127.0.0.1:6500 (non-blocking so we can check remaining bytes)
    const s_rx = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, IPPROTO_UDP);
    assertTrue("alloc s_rx", s_rx >= 0);

    var addr_rx = SockAddrIn{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, 6500),
        .sin_addr = .{ 127, 0, 0, 1 },
    };
    const b_rx = sys3(SYS_BIND, @intCast(s_rx), @intFromPtr(&addr_rx), @sizeOf(SockAddrIn));
    assertEqual("bind s_rx to 6500", 0, b_rx);

    // Sender socket
    const s_tx = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    assertTrue("alloc s_tx", s_tx >= 0);

    // Send a 20-byte datagram: "DATAGRAM_MESSAGE_ONE"
    const dgram1 = "DATAGRAM_MESSAGE_ONE";
    const sent1 = sys6(SYS_SENDTO, @intCast(s_tx), @intFromPtr(dgram1.ptr), dgram1.len, 0, @intFromPtr(&addr_rx), @sizeOf(SockAddrIn));
    assertEqual("sendto dgram1 (20 bytes)", @intCast(dgram1.len), sent1);

    // Receive with a SMALL buffer (8 bytes only).
    // In UDP, reading less than datagram length returns buffer size and DISCARDS the rest.
    var small_buf: [8]u8 = [_]u8{0} ** 8;
    var from_peer: SockAddrIn = undefined;
    var from_len: u32 = @sizeOf(SockAddrIn);
    const recv_small = sys6(SYS_RECVFROM, @intCast(s_rx), @intFromPtr(&small_buf), small_buf.len, 0, @intFromPtr(&from_peer), @intFromPtr(&from_len));
    assertEqual("recvfrom with small buffer truncates to len", @intCast(small_buf.len), recv_small);
    assertTrue("truncated content matches prefix 'DATAGRAM'", std.mem.eql(u8, small_buf[0..8], "DATAGRAM"));

    // Verify sender ephemeral port was recorded and is in valid ephemeral range (>= 49152)
    const sender_port = std.mem.bigToNative(u16, from_peer.sin_port);
    assertTrue("sender ephemeral port is in [49152, 65535]", sender_port >= 49152);

    // CRITICAL ADVERSARIAL CHECK:
    // If the socket operated as a stream (like TCP), the remaining 12 bytes ("_MESSAGE_ONE")
    // would still be sitting in the queue.
    // For datagram sockets, the remainder MUST be discarded, so immediate non-blocking recv returns -EAGAIN!
    const recv_remainder = sys6(SYS_RECVFROM, @intCast(s_rx), @intFromPtr(&small_buf), small_buf.len, 0, 0, 0);
    assertEqual("datagram boundary preserved: remainder discarded -> -EAGAIN", EAGAIN, recv_remainder);

    // Send second datagram: "MESSAGE_TWO" (11 bytes)
    const dgram2 = "MESSAGE_TWO";
    const sent2 = sys6(SYS_SENDTO, @intCast(s_tx), @intFromPtr(dgram2.ptr), dgram2.len, 0, @intFromPtr(&addr_rx), @sizeOf(SockAddrIn));
    assertEqual("sendto dgram2 (11 bytes)", @intCast(dgram2.len), sent2);

    // Receive full second datagram
    var full_buf: [32]u8 = [_]u8{0} ** 32;
    const recv2 = sys6(SYS_RECVFROM, @intCast(s_rx), @intFromPtr(&full_buf), full_buf.len, 0, 0, 0);
    assertEqual("recvfrom full dgram2", @intCast(dgram2.len), recv2);
    assertTrue("dgram2 payload matches exact message", std.mem.eql(u8, full_buf[0..11], "MESSAGE_TWO"));

    _ = sys1(SYS_CLOSE, @intCast(s_rx));
    _ = sys1(SYS_CLOSE, @intCast(s_tx));

    // -------------------------------------------------------------
    // CHALLENGE 5: Connected UDP Sockets and SYS_WRITE Delivery
    // -------------------------------------------------------------
    puts("\n--- Challenge 5: Connected UDP Sockets (connect + write) ---\n");
    const s_srv = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, IPPROTO_UDP);
    var addr_srv = SockAddrIn{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, 7000),
        .sin_addr = .{ 127, 0, 0, 1 },
    };
    _ = sys3(SYS_BIND, @intCast(s_srv), @intFromPtr(&addr_srv), @sizeOf(SockAddrIn));

    const s_cli = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    const conn_res = sys3(SYS_CONNECT, @intCast(s_cli), @intFromPtr(&addr_srv), @sizeOf(SockAddrIn));
    assertEqual("connect UDP socket to 127.0.0.1:7000", 0, conn_res);

    // Once connected, standard sys_write sends datagram to peer
    const conn_msg = "CONNECTED_UDP_MSG";
    const wr_res = sys3(SYS_WRITE, @intCast(s_cli), @intFromPtr(conn_msg.ptr), conn_msg.len);
    assertEqual("write on connected UDP socket", @intCast(conn_msg.len), wr_res);

    // s_srv receives via sys_read
    var srv_rx: [32]u8 = [_]u8{0} ** 32;
    const rd_res = sys3(SYS_READ, @intCast(s_srv), @intFromPtr(&srv_rx), srv_rx.len);
    assertEqual("read on s_srv", @intCast(conn_msg.len), rd_res);
    assertTrue("received connected message matches payload", std.mem.eql(u8, srv_rx[0..conn_msg.len], conn_msg));

    _ = sys1(SYS_CLOSE, @intCast(s_srv));
    _ = sys1(SYS_CLOSE, @intCast(s_cli));

    // -------------------------------------------------------------
    // CHALLENGE 6: Negative Parameter Validation & Fault Tolerances
    // -------------------------------------------------------------
    puts("\n--- Challenge 6: Negative Parameter Validation ---\n");
    // Invalid FD
    const bad_fd_bind = sys3(SYS_BIND, 999, @intCast(@intFromPtr(&addr_srv)), @sizeOf(SockAddrIn));
    assertEqual("bind on invalid fd returns -EBADF", EBADF, bad_fd_bind);

    // Non-socket FD (fd 1 is CONSOLE_OUT)
    const nonsock_bind = sys3(SYS_BIND, 1, @intCast(@intFromPtr(&addr_srv)), @sizeOf(SockAddrIn));
    assertEqual("bind on non-socket fd returns -ENOTSOCK", ENOTSOCK, nonsock_bind);

    const nonsock_send = sys6(SYS_SENDTO, 1, @intFromPtr(test_payload.ptr), test_payload.len, 0, 0, 0);
    assertEqual("sendto on non-socket fd returns -ENOTSOCK", ENOTSOCK, nonsock_send);

    const nonsock_recv = sys6(SYS_RECVFROM, 0, @intFromPtr(&dummy_rx), dummy_rx.len, 0, 0, 0);
    assertEqual("recvfrom on non-socket fd returns -ENOTSOCK", ENOTSOCK, nonsock_recv);

    puts("\n[CHALLENGER_M19] All empirical adversarial challenges PASSED!\n");
    exit(0);
}
