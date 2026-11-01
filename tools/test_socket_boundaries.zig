// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical stress test for Tinux Socket Subsystem: Ring Buffer Wraparounds, Concurrency, and Accept Queue

const std = @import("std");

pub const AF_UNIX: u16 = 1;
pub const AF_LOCAL: u16 = 1;
pub const AF_INET: u16 = 2;

pub const SOCK_STREAM: u32 = 1;
pub const SOCK_DGRAM: u32 = 2;

pub const SOCK_NONBLOCK: u32 = 0o4000;
pub const SOCK_CLOEXEC: u32 = 0o2000000;

pub const MAX_SOCKETS: usize = 32;
pub const SOCK_BUF_SIZE: usize = 4096;
pub const ACCEPT_QUEUE_LEN: usize = 8;

pub const Errno = error{
    EAGAIN,
    EBADF,
    EINVAL,
    EPIPE,
    ECONNREFUSED,
    EISCONN,
    ENOBUFS,
    EADDRINUSE,
    ENOTCONN,
    EAFNOSUPPORT,
};

pub const SocketState = enum(u8) {
    CLOSED = 0,
    UNBOUND = 1,
    BOUND = 2,
    LISTENING = 3,
    CONNECTED = 4,
};

pub const SockReadResult = union(enum) {
    bytes: usize,
    eof: void,
    would_block: void,
};

pub const Socket = struct {
    in_use: bool = false,
    ref_count: usize = 0,
    domain: u16 = AF_INET,
    sock_type: u32 = SOCK_STREAM,
    proto: u32 = 0,
    nonblock: bool = false,
    state: SocketState = .CLOSED,
    bound_port: u16 = 0,
    bound_path: [64]u8 = [_]u8{0} ** 64,
    bound_path_len: usize = 0,
    peer_idx: ?usize = null,
    peer_closed: bool = false,
    accept_queue: [ACCEPT_QUEUE_LEN]usize = [_]usize{0} ** ACCEPT_QUEUE_LEN,
    accept_head: usize = 0,
    accept_tail: usize = 0,
    accept_count: usize = 0,
    rx_buf: [SOCK_BUF_SIZE]u8 = [_]u8{0} ** SOCK_BUF_SIZE,
    rx_read_pos: usize = 0,
    rx_write_pos: usize = 0,
    rx_count: usize = 0,
};

pub var sockets: [MAX_SOCKETS]Socket = [_]Socket{.{}} ** MAX_SOCKETS;
var next_ephemeral_port: u16 = 49152;

pub fn init() void {
    for (&sockets) |*s| s.* = .{};
    next_ephemeral_port = 49152;
}

pub fn alloc(domain: u16, sock_type: u32, nonblock: bool) ?usize {
    for (&sockets, 0..) |*s, idx| {
        if (!s.in_use) {
            s.* = .{
                .in_use = true,
                .ref_count = 1,
                .domain = domain,
                .sock_type = sock_type,
                .nonblock = nonblock,
                .state = .UNBOUND,
            };
            return idx;
        }
    }
    return null;
}

pub fn retain(idx: usize) void {
    if (idx < MAX_SOCKETS and sockets[idx].in_use) {
        sockets[idx].ref_count += 1;
    }
}

pub fn close(idx: usize) ?usize {
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) return null;
    if (sockets[idx].ref_count > 0) sockets[idx].ref_count -= 1;
    if (sockets[idx].ref_count == 0) {
        var wake_peer: ?usize = null;
        if (sockets[idx].peer_idx) |p_idx| {
            if (p_idx < MAX_SOCKETS and sockets[p_idx].in_use) {
                sockets[p_idx].peer_closed = true;
                wake_peer = p_idx;
            }
        }
        sockets[idx].in_use = false;
        sockets[idx].state = .CLOSED;
        sockets[idx].peer_idx = null;
        return wake_peer;
    }
    return null;
}

pub fn bindInet(idx: usize, port_host: u16) Errno!void {
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) return Errno.EBADF;
    if (sockets[idx].state != .UNBOUND) return Errno.EINVAL;
    for (&sockets, 0..) |*s, i| {
        if (i != idx and s.in_use and s.domain == AF_INET and s.bound_port == port_host and s.state != .CLOSED) {
            return Errno.EADDRINUSE;
        }
    }
    sockets[idx].bound_port = port_host;
    sockets[idx].state = .BOUND;
}

pub fn bindUnix(idx: usize, path: []const u8) Errno!void {
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) return Errno.EBADF;
    if (sockets[idx].state != .UNBOUND) return Errno.EINVAL;
    if (path.len > 64) return Errno.EINVAL;
    for (&sockets, 0..) |*s, i| {
        if (i != idx and s.in_use and s.domain == AF_UNIX and s.bound_path_len == path.len and std.mem.eql(u8, s.bound_path[0..s.bound_path_len], path) and s.state != .CLOSED) {
            return Errno.EADDRINUSE;
        }
    }
    @memset(&sockets[idx].bound_path, 0);
    @memcpy(sockets[idx].bound_path[0..path.len], path);
    sockets[idx].bound_path_len = path.len;
    sockets[idx].state = .BOUND;
}

pub fn listen(idx: usize) Errno!void {
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) return Errno.EBADF;
    if (sockets[idx].state == .CONNECTED) return Errno.EINVAL;
    sockets[idx].state = .LISTENING;
}

pub fn connectInet(client_idx: usize, target_port_host: u16) Errno!usize {
    if (client_idx >= MAX_SOCKETS or !sockets[client_idx].in_use) return Errno.EBADF;
    if (sockets[client_idx].state == .CONNECTED) return Errno.EISCONN;

    var listen_idx: ?usize = null;
    for (&sockets, 0..) |*s, idx| {
        if (s.in_use and s.domain == AF_INET and s.state == .LISTENING and s.bound_port == target_port_host) {
            listen_idx = idx;
            break;
        }
    }

    const l_idx = listen_idx orelse return Errno.ECONNREFUSED;
    var listener = &sockets[l_idx];

    if (listener.accept_count >= ACCEPT_QUEUE_LEN) {
        return Errno.ECONNREFUSED;
    }

    const srv_conn_idx = alloc(AF_INET, SOCK_STREAM, false) orelse return Errno.ENOBUFS;

    sockets[client_idx].peer_idx = srv_conn_idx;
    sockets[client_idx].state = .CONNECTED;
    if (sockets[client_idx].bound_port == 0) {
        sockets[client_idx].bound_port = next_ephemeral_port;
        next_ephemeral_port +%= 1;
    }

    sockets[srv_conn_idx].peer_idx = client_idx;
    sockets[srv_conn_idx].state = .CONNECTED;
    sockets[srv_conn_idx].bound_port = target_port_host;

    listener.accept_queue[listener.accept_tail] = srv_conn_idx;
    listener.accept_tail = (listener.accept_tail + 1) % ACCEPT_QUEUE_LEN;
    listener.accept_count += 1;

    return l_idx;
}

pub fn connectUnix(client_idx: usize, target_path: []const u8) Errno!usize {
    if (client_idx >= MAX_SOCKETS or !sockets[client_idx].in_use) return Errno.EBADF;
    if (sockets[client_idx].state == .CONNECTED) return Errno.EISCONN;

    var listen_idx: ?usize = null;
    for (&sockets, 0..) |*s, idx| {
        if (s.in_use and s.domain == AF_UNIX and s.state == .LISTENING and s.bound_path_len == target_path.len and std.mem.eql(u8, s.bound_path[0..s.bound_path_len], target_path)) {
            listen_idx = idx;
            break;
        }
    }

    const l_idx = listen_idx orelse return Errno.ECONNREFUSED;
    var listener = &sockets[l_idx];

    if (listener.accept_count >= ACCEPT_QUEUE_LEN) {
        return Errno.ECONNREFUSED;
    }

    const srv_conn_idx = alloc(AF_UNIX, SOCK_STREAM, false) orelse return Errno.ENOBUFS;

    sockets[client_idx].peer_idx = srv_conn_idx;
    sockets[client_idx].state = .CONNECTED;

    sockets[srv_conn_idx].peer_idx = client_idx;
    sockets[srv_conn_idx].state = .CONNECTED;
    sockets[srv_conn_idx].bound_path = listener.bound_path;
    sockets[srv_conn_idx].bound_path_len = listener.bound_path_len;

    listener.accept_queue[listener.accept_tail] = srv_conn_idx;
    listener.accept_tail = (listener.accept_tail + 1) % ACCEPT_QUEUE_LEN;
    listener.accept_count += 1;

    return l_idx;
}

pub fn popAccept(listen_idx: usize) ?usize {
    if (listen_idx >= MAX_SOCKETS or !sockets[listen_idx].in_use) return null;
    var listener = &sockets[listen_idx];
    if (listener.accept_count == 0) return null;

    const accepted_idx = listener.accept_queue[listener.accept_head];
    listener.accept_head = (listener.accept_head + 1) % ACCEPT_QUEUE_LEN;
    listener.accept_count -= 1;
    return accepted_idx;
}

pub fn write(idx: usize, src: []const u8) Errno!usize {
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) return Errno.EBADF;
    const s = &sockets[idx];
    if (s.state != .CONNECTED or s.peer_idx == null) return Errno.ENOTCONN;
    if (s.peer_closed) return Errno.EPIPE;

    const peer_idx = s.peer_idx.?;
    if (peer_idx >= MAX_SOCKETS or !sockets[peer_idx].in_use) return Errno.EPIPE;

    var peer = &sockets[peer_idx];
    const avail = SOCK_BUF_SIZE - peer.rx_count;
    if (avail == 0) {
        return Errno.EAGAIN;
    }

    const to_write = @min(src.len, avail);
    for (0..to_write) |i| {
        peer.rx_buf[peer.rx_write_pos] = src[i];
        peer.rx_write_pos = (peer.rx_write_pos + 1) % SOCK_BUF_SIZE;
    }
    peer.rx_count += to_write;

    return to_write;
}

pub fn read(idx: usize, dst: []u8) SockReadResult {
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) {
        return .{ .eof = {} };
    }
    var sock = &sockets[idx];
    if (sock.rx_count > 0) {
        const to_read = @min(dst.len, sock.rx_count);
        for (0..to_read) |i| {
            dst[i] = sock.rx_buf[sock.rx_read_pos];
            sock.rx_read_pos = (sock.rx_read_pos + 1) % SOCK_BUF_SIZE;
        }
        sock.rx_count -= to_read;
        return .{ .bytes = to_read };
    }

    if (sock.peer_closed or sock.peer_idx == null) {
        return .{ .eof = {} };
    }

    return .{ .would_block = {} };
}

pub fn socketpair(domain: u16, sock_type: u32, nonblock: bool) Errno![2]usize {
    if (domain != AF_UNIX) return Errno.EAFNOSUPPORT;
    const s0 = alloc(AF_UNIX, sock_type, nonblock) orelse return Errno.ENOBUFS;
    const s1 = alloc(AF_UNIX, sock_type, nonblock) orelse {
        _ = close(s0);
        return Errno.ENOBUFS;
    };

    sockets[s0].state = .CONNECTED;
    sockets[s0].peer_idx = s1;

    sockets[s1].state = .CONNECTED;
    sockets[s1].peer_idx = s0;

    return [2]usize{ s0, s1 };
}

// ============================================================================
// EMPIRICAL TESTS
// ============================================================================

fn testRingBufferWraparound() !void {
    std.debug.print("[TEST 1] Ring Buffer Wraparound & Data Integrity across multiple cycles...\n", .{});
    init();

    const pair = try socketpair(AF_UNIX, SOCK_STREAM, false);
    const s0 = pair[0];
    const s1 = pair[1];

    const TOTAL_BYTES: usize = 128 * 1024; // 128 KiB = 32 full 4096-byte wraps
    var send_counter: usize = 0;
    var recv_counter: usize = 0;

    const chunk_sizes = [_]usize{ 1, 7, 13, 64, 127, 256, 512, 1023, 1024, 2048, 4095, 4096 };
    var chunk_idx: usize = 0;

    var tx_buf: [4096]u8 = undefined;
    var rx_buf: [4096]u8 = undefined;

    while (recv_counter < TOTAL_BYTES) {
        const write_chunk = chunk_sizes[chunk_idx % chunk_sizes.len];
        chunk_idx += 1;
        const to_send = @min(write_chunk, TOTAL_BYTES - send_counter);

        if (to_send > 0) {
            for (0..to_send) |i| {
                tx_buf[i] = @truncate((send_counter + i) & 0xFF);
            }

            const w = write(s0, tx_buf[0..to_send]) catch |err| switch (err) {
                Errno.EAGAIN => @as(usize, 0),
                else => return err,
            };
            send_counter += w;
        }

        const read_chunk = chunk_sizes[(chunk_idx + 3) % chunk_sizes.len];
        const res = read(s1, rx_buf[0..read_chunk]);
        switch (res) {
            .bytes => |n| {
                for (0..n) |i| {
                    const expected: u8 = @truncate((recv_counter + i) & 0xFF);
                    if (rx_buf[i] != expected) {
                        std.debug.print("DATA CORRUPTION DETECTED at byte offset {d}: expected 0x{X:0>2}, got 0x{X:0>2}\n", .{ recv_counter + i, expected, rx_buf[i] });
                        return error.DataCorruption;
                    }
                }
                recv_counter += n;
            },
            .would_block => {
                if (to_send == 0 and send_counter == recv_counter) break;
            },
            .eof => return error.UnexpectedEof,
        }
    }

    try std.testing.expectEqual(TOTAL_BYTES, send_counter);
    try std.testing.expectEqual(TOTAL_BYTES, recv_counter);
    try std.testing.expectEqual(@as(usize, 0), sockets[s1].rx_count);

    _ = close(s0);
    _ = close(s1);

    std.debug.print("  [PASS] Successfully streamed {d} bytes across 32 ring buffer wraparound cycles with zero corruption\n", .{TOTAL_BYTES});
}

fn testBufferBoundaryExactCapacity() !void {
    std.debug.print("[TEST 2] Ring Buffer Exact Capacity Boundary (4095, 4096, 4097 bytes)...\n", .{});
    init();

    const pair = try socketpair(AF_UNIX, SOCK_STREAM, false);
    const s0 = pair[0];
    const s1 = pair[1];

    var big_buf: [4097]u8 = undefined;
    for (0..big_buf.len) |i| big_buf[i] = @truncate(i & 0xFF);

    // Write exactly 4096 bytes (capacity)
    const w1 = try write(s0, big_buf[0..4096]);
    try std.testing.expectEqual(@as(usize, 4096), w1);
    try std.testing.expectEqual(@as(usize, 4096), sockets[s1].rx_count);

    // Attempt to write 1 more byte when completely full -> MUST return EAGAIN
    const res_full = write(s0, big_buf[0..1]);
    try std.testing.expectError(Errno.EAGAIN, res_full);

    // Drain 1 byte
    var single_byte: [1]u8 = undefined;
    const r1 = read(s1, &single_byte);
    switch (r1) {
        .bytes => |n| {
            try std.testing.expectEqual(@as(usize, 1), n);
            try std.testing.expectEqual(@as(u8, 0), single_byte[0]);
        },
        else => return error.TestFailed,
    }
    try std.testing.expectEqual(@as(usize, 4095), sockets[s1].rx_count);

    // Now write 1 byte into wrapped position
    const w2 = try write(s0, &[_]u8{0xAA});
    try std.testing.expectEqual(@as(usize, 1), w2);
    try std.testing.expectEqual(@as(usize, 4096), sockets[s1].rx_count);
    try std.testing.expectEqual(@as(usize, 1), sockets[s1].rx_write_pos);

    // Drain all 4096 bytes
    var drain_buf: [4096]u8 = undefined;
    const r2 = read(s1, &drain_buf);
    switch (r2) {
        .bytes => |n| {
            try std.testing.expectEqual(@as(usize, 4096), n);
            for (0..4095) |i| {
                try std.testing.expectEqual(@as(u8, @truncate((i + 1) & 0xFF)), drain_buf[i]);
            }
            try std.testing.expectEqual(@as(u8, 0xAA), drain_buf[4095]);
        },
        else => return error.TestFailed,
    }

    try std.testing.expectEqual(@as(usize, 0), sockets[s1].rx_count);
    try std.testing.expectEqual(@as(usize, 1), sockets[s1].rx_read_pos);

    _ = close(s0);
    _ = close(s1);

    std.debug.print("  [PASS] Buffer exact capacity 4096 and EAGAIN saturation verified cleanly\n", .{});
}

fn testFullDuplexSocketpairSimultaneous() !void {
    std.debug.print("[TEST 3] AF_UNIX Socketpair Full-Duplex Simultaneous Exchange...\n", .{});
    init();

    const pair = try socketpair(AF_UNIX, SOCK_STREAM, false);
    const s0 = pair[0];
    const s1 = pair[1];

    const MSG_A = "ALPHA_TO_BETA_FULL_DUPLEX_STREAM_1234567890";
    const MSG_B = "BETA_TO_ALPHA_FULL_DUPLEX_STREAM_ZYXWVUTSRQ";

    const w0 = try write(s0, MSG_A);
    const w1 = try write(s1, MSG_B);
    try std.testing.expectEqual(MSG_A.len, w0);
    try std.testing.expectEqual(MSG_B.len, w1);

    var buf0: [128]u8 = undefined;
    var buf1: [128]u8 = undefined;

    const r1 = read(s1, &buf1);
    switch (r1) {
        .bytes => |n| {
            try std.testing.expectEqual(MSG_A.len, n);
            try std.testing.expectEqualSlices(u8, MSG_A, buf1[0..n]);
        },
        else => return error.TestFailed,
    }

    const r0 = read(s0, &buf0);
    switch (r0) {
        .bytes => |n| {
            try std.testing.expectEqual(MSG_B.len, n);
            try std.testing.expectEqualSlices(u8, MSG_B, buf0[0..n]);
        },
        else => return error.TestFailed,
    }

    _ = close(s0);
    _ = close(s1);

    std.debug.print("  [PASS] Full-duplex simultaneous exchange verified with zero cross-talk\n", .{});
}

fn testMultiConnectionAcceptQueueStress() !void {
    std.debug.print("[TEST 4] Multi-Connection Accept Queue Stress & ACCEPT_QUEUE_LEN Limit...\n", .{});
    init();

    const srv_idx = alloc(AF_INET, SOCK_STREAM, false) orelse return error.OutOfMemory;
    try bindInet(srv_idx, 9090);
    try listen(srv_idx);

    var clients: [ACCEPT_QUEUE_LEN]usize = undefined;
    for (0..ACCEPT_QUEUE_LEN) |i| {
        const c_idx = alloc(AF_INET, SOCK_STREAM, false) orelse return error.OutOfMemory;
        const l_woken = try connectInet(c_idx, 9090);
        try std.testing.expectEqual(srv_idx, l_woken);
        clients[i] = c_idx;
    }

    try std.testing.expectEqual(@as(usize, 8), sockets[srv_idx].accept_count);

    // 9th client connection MUST be rejected with ECONNREFUSED
    const c9 = alloc(AF_INET, SOCK_STREAM, false) orelse return error.OutOfMemory;
    const err_c9 = connectInet(c9, 9090);
    try std.testing.expectError(Errno.ECONNREFUSED, err_c9);
    _ = close(c9);

    try std.testing.expectEqual(@as(usize, 8), sockets[srv_idx].accept_count);

    // Pop 4 accepted connections from listener
    var accepted: [4]usize = undefined;
    for (0..4) |i| {
        accepted[i] = popAccept(srv_idx) orelse return error.TestFailed;
        try std.testing.expect(sockets[accepted[i]].state == .CONNECTED);
        try std.testing.expectEqual(clients[i], sockets[accepted[i]].peer_idx.?);
    }
    try std.testing.expectEqual(@as(usize, 4), sockets[srv_idx].accept_count);

    // Connect 4 new clients into the freed slots (exercising queue wraparound)
    var new_clients: [4]usize = undefined;
    for (0..4) |i| {
        const nc = alloc(AF_INET, SOCK_STREAM, false) orelse return error.OutOfMemory;
        const l_woken = try connectInet(nc, 9090);
        try std.testing.expectEqual(srv_idx, l_woken);
        new_clients[i] = nc;
    }
    try std.testing.expectEqual(@as(usize, 8), sockets[srv_idx].accept_count);

    // Overflow attempt again -> MUST return ECONNREFUSED
    const c10 = alloc(AF_INET, SOCK_STREAM, false) orelse return error.OutOfMemory;
    try std.testing.expectError(Errno.ECONNREFUSED, connectInet(c10, 9090));
    _ = close(c10);

    // Pop remaining 8 connections and verify FIFO ordering
    for (4..8) |i| {
        const a = popAccept(srv_idx) orelse return error.TestFailed;
        try std.testing.expectEqual(clients[i], sockets[a].peer_idx.?);
        _ = close(a);
        _ = close(clients[i]);
    }
    for (0..4) |i| {
        const a = popAccept(srv_idx) orelse return error.TestFailed;
        try std.testing.expectEqual(new_clients[i], sockets[a].peer_idx.?);
        _ = close(a);
        _ = close(new_clients[i]);
    }

    try std.testing.expectEqual(@as(usize, 0), sockets[srv_idx].accept_count);
    try std.testing.expect(popAccept(srv_idx) == null);

    for (accepted) |a| _ = close(a);
    _ = close(srv_idx);

    std.debug.print("  [PASS] Accept queue limit 8, clean -ECONNREFUSED rejection, and circular wraparound verified\n", .{});
}

fn testPeerCloseDrainAndEpipe() !void {
    std.debug.print("[TEST 5] Peer Close, Data Drain, EOF, and EPIPE Lifecycle...\n", .{});
    init();

    const pair = try socketpair(AF_UNIX, SOCK_STREAM, false);
    const s0 = pair[0];
    const s1 = pair[1];

    const PAYLOAD = "DRAINABLE_BUFFER_BEFORE_EOF";
    _ = try write(s0, PAYLOAD);

    const wake = close(s0);
    try std.testing.expectEqual(@as(?usize, s1), wake);

    var buf: [64]u8 = undefined;
    const r1 = read(s1, &buf);
    switch (r1) {
        .bytes => |n| {
            try std.testing.expectEqual(PAYLOAD.len, n);
            try std.testing.expectEqualSlices(u8, PAYLOAD, buf[0..n]);
        },
        else => return error.TestFailed,
    }

    const r2 = read(s1, &buf);
    switch (r2) {
        .eof => {},
        else => return error.TestFailed,
    }

    const w_err = write(s1, "SHOULD_FAIL");
    try std.testing.expectError(Errno.EPIPE, w_err);

    _ = close(s1);

    std.debug.print("  [PASS] Buffered data drain prior to EOF and EPIPE on broken peer verified\n", .{});
}

pub fn main() !void {
    std.debug.print("=== Tinux Socket Subsystem Empirical Boundary Tests ===\n", .{});
    try testRingBufferWraparound();
    try testBufferBoundaryExactCapacity();
    try testFullDuplexSocketpairSimultaneous();
    try testMultiConnectionAcceptQueueStress();
    try testPeerCloseDrainAndEpipe();
    std.debug.print("=== ALL EMPIRICAL SOCKET BOUNDARY TESTS PASSED CLEANLY ===\n", .{});
}
