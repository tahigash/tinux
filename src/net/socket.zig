const std = @import("std");
const task = @import("../proc/task.zig");
const Errno = @import("../uapi/errno.zig").Errno;

pub const AF_UNIX: u16 = 1;
pub const AF_INET: u16 = 2;
pub const SOCK_STREAM: u16 = 1;
pub const SOCK_DGRAM: u16 = 2;
pub const SOCK_RAW: u16 = 3;

pub const MAX_SOCKETS: usize = 32;
pub const SOCK_BUF_SIZE: usize = 4096;
pub const MAX_ACCEPT_BACKLOG: usize = 8;

pub const SockAddrIn = extern struct {
    sin_family: u16 align(1) = AF_INET,
    sin_port: u16 align(1) = 0, // Big Endian
    sin_addr: [4]u8 align(1) = .{ 127, 0, 0, 1 },
    sin_zero: [8]u8 align(1) = [_]u8{0} ** 8,

    comptime {
        std.debug.assert(@sizeOf(SockAddrIn) == 16);
    }
};

pub const SocketState = enum(u8) {
    UNUSED = 0,
    UNBOUND = 1,
    BOUND = 2,
    LISTENING = 3,
    CONNECTED = 4,
    CLOSED = 5,
};

pub const Socket = struct {
    in_use: bool = false,
    ref_count: usize = 0,
    domain: u16 = AF_INET,
    sock_type: u16 = SOCK_STREAM,
    proto: u16 = 0,
    state: SocketState = .UNUSED,
    bound_port: u16 = 0,
    peer_idx: ?usize = null,
    peer_closed: bool = false,
    rx_buf: [SOCK_BUF_SIZE]u8 = [_]u8{0} ** SOCK_BUF_SIZE,
    rx_read_pos: usize = 0,
    rx_write_pos: usize = 0,
    rx_count: usize = 0,
    accept_queue: [MAX_ACCEPT_BACKLOG]usize = [_]usize{0} ** MAX_ACCEPT_BACKLOG,
    accept_count: usize = 0,
};

pub var sockets: [MAX_SOCKETS]Socket = [_]Socket{.{}} ** MAX_SOCKETS;
var next_ephemeral_port: u16 = 49152;

pub fn init() void {
    for (&sockets) |*s| s.* = .{};
}

pub fn alloc(domain: u16, sock_type: u16, proto: u16) ?usize {
    for (&sockets, 0..) |*s, idx| {
        if (!s.in_use) {
            s.* = .{
                .in_use = true,
                .ref_count = 1,
                .domain = domain,
                .sock_type = sock_type,
                .proto = proto,
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

pub fn close(idx: usize) void {
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) return;
    if (sockets[idx].ref_count > 0) sockets[idx].ref_count -= 1;
    if (sockets[idx].ref_count == 0) {
        if (sockets[idx].peer_idx) |p_idx| {
            if (p_idx < MAX_SOCKETS and sockets[p_idx].in_use) {
                sockets[p_idx].peer_closed = true;
                sockets[p_idx].peer_idx = null;
                task.wakeSocketReadWaiters(p_idx);
            }
        }
        sockets[idx].in_use = false;
        sockets[idx].state = .CLOSED;
    }
}

pub fn bind(idx: usize, port_host: u16) Errno!void {
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) return Errno.EBADF;
    for (&sockets, 0..) |*s, i| {
        if (i != idx and s.in_use and s.bound_port == port_host and s.state != .UNUSED and s.state != .CLOSED) {
            return Errno.EADDRINUSE;
        }
    }
    sockets[idx].bound_port = port_host;
    sockets[idx].state = .BOUND;
    return;
}

pub fn listen(idx: usize, backlog: usize) Errno!void {
    _ = backlog;
    if (idx >= MAX_SOCKETS or !sockets[idx].in_use) return Errno.EBADF;
    sockets[idx].state = .LISTENING;
    return;
}

pub fn connectLoopback(client_idx: usize, target_port_host: u16) Errno!void {
    if (client_idx >= MAX_SOCKETS or !sockets[client_idx].in_use) return Errno.EBADF;

    var listen_idx: ?usize = null;
    for (&sockets, 0..) |*s, idx| {
        if (s.in_use and s.state == .LISTENING and s.bound_port == target_port_host) {
            listen_idx = idx;
            break;
        }
    }

    const l_idx = listen_idx orelse return Errno.ECONNREFUSED;
    var listener = &sockets[l_idx];

    if (listener.accept_count >= MAX_ACCEPT_BACKLOG) {
        return Errno.ECONNREFUSED;
    }

    const srv_conn_idx = alloc(sockets[client_idx].domain, SOCK_STREAM, 0) orelse return Errno.ENOMEM;

    // Pair client and server
    sockets[client_idx].peer_idx = srv_conn_idx;
    sockets[client_idx].state = .CONNECTED;
    sockets[client_idx].bound_port = next_ephemeral_port;
    next_ephemeral_port +%= 1;

    sockets[srv_conn_idx].peer_idx = client_idx;
    sockets[srv_conn_idx].state = .CONNECTED;
    sockets[srv_conn_idx].bound_port = target_port_host;

    listener.accept_queue[listener.accept_count] = srv_conn_idx;
    listener.accept_count += 1;

    task.wakeSocketAcceptWaiters(l_idx);
}

pub fn popAcceptQueue(listen_idx: usize) ?usize {
    if (listen_idx >= MAX_SOCKETS or !sockets[listen_idx].in_use) return null;
    var listener = &sockets[listen_idx];
    if (listener.accept_count == 0) return null;

    const accepted_idx = listener.accept_queue[0];
    for (1..listener.accept_count) |i| {
        listener.accept_queue[i - 1] = listener.accept_queue[i];
    }
    listener.accept_count -= 1;
    return accepted_idx;
}

pub fn writeStream(sender_idx: usize, src: []const u8) Errno!usize {
    if (sender_idx >= MAX_SOCKETS or !sockets[sender_idx].in_use) return Errno.EBADF;
    const peer_idx = sockets[sender_idx].peer_idx orelse return Errno.EPIPE;
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

    task.wakeSocketReadWaiters(peer_idx);
    return to_write;
}

pub fn readStream(receiver_idx: usize, dst: []u8) struct { status: enum { bytes, eof, would_block }, n: usize } {
    if (receiver_idx >= MAX_SOCKETS or !sockets[receiver_idx].in_use) {
        return .{ .status = .eof, .n = 0 };
    }
    var sock = &sockets[receiver_idx];
    if (sock.rx_count > 0) {
        const to_read = @min(dst.len, sock.rx_count);
        for (0..to_read) |i| {
            dst[i] = sock.rx_buf[sock.rx_read_pos];
            sock.rx_read_pos = (sock.rx_read_pos + 1) % SOCK_BUF_SIZE;
        }
        sock.rx_count -= to_read;
        return .{ .status = .bytes, .n = to_read };
    }

    if (sock.peer_closed or sock.peer_idx == null) {
        return .{ .status = .eof, .n = 0 };
    }

    return .{ .status = .would_block, .n = 0 };
}
