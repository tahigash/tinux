const std = @import("std");
const task = @import("../proc/task.zig");
const Errno = @import("../uapi/errno.zig").Errno;

pub const AF_UNIX: u16 = 1;
pub const AF_LOCAL: u16 = 1;
pub const AF_INET: u16 = 2;

pub const SOCK_STREAM: u32 = 1;
pub const SOCK_DGRAM: u32 = 2;
pub const SOCK_RAW: u32 = 3;

pub const SOCK_NONBLOCK: u32 = 0o4000; // 0x800
pub const SOCK_CLOEXEC: u32 = 0o2000000; // 0x80000

pub const SOL_SOCKET: u32 = 1;
pub const SO_REUSEADDR: u32 = 2;

pub const MAX_SOCKETS: usize = 32;
pub const SOCK_BUF_SIZE: usize = 4096;
pub const ACCEPT_QUEUE_LEN: usize = 8;
pub const MAX_ACCEPT_BACKLOG: usize = ACCEPT_QUEUE_LEN;

pub const SockAddrIn = extern struct {
    sin_family: u16 align(1) = AF_INET,
    sin_port: u16 align(1) = 0, // Big Endian
    sin_addr: u32 align(1) = 0x0100007F, // 127.0.0.1 (0x0100007F in LE)
    sin_zero: [8]u8 align(1) = [_]u8{0} ** 8,

    comptime {
        std.debug.assert(@sizeOf(SockAddrIn) == 16);
    }
};

pub const SockAddrUn = extern struct {
    sun_family: u16 align(1) = AF_UNIX,
    sun_path: [108]u8 align(1) = [_]u8{0} ** 108,

    comptime {
        std.debug.assert(@sizeOf(SockAddrUn) == 110);
    }
};

pub const SockReadResult = union(enum) {
    bytes: usize,
    eof: void,
    would_block: void,
};

pub const SocketState = enum(u8) {
    CLOSED = 0,
    UNBOUND = 1,
    BOUND = 2,
    LISTENING = 3,
    CONNECTED = 4,
};

pub const Socket = struct {
    in_use: bool = false,
    ref_count: usize = 0,
    domain: u16 = AF_INET,
    sock_type: u32 = SOCK_STREAM,
    proto: u32 = 0,
    nonblock: bool = false,
    state: SocketState = .CLOSED,
    bound_port: u16 = 0, // Host byte order
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
                sockets[p_idx].peer_idx = null;
                wake_peer = p_idx;
            }
        }
        if (sockets[idx].state == .LISTENING) {
            task.wakeSocketAcceptWaiters(idx);
        }
        while (sockets[idx].accept_count > 0) {
            const queued_idx = sockets[idx].accept_queue[sockets[idx].accept_head];
            sockets[idx].accept_head = (sockets[idx].accept_head + 1) % ACCEPT_QUEUE_LEN;
            sockets[idx].accept_count -= 1;
            if (queued_idx < MAX_SOCKETS and sockets[queued_idx].in_use) {
                if (close(queued_idx)) |client_p_idx| {
                    task.wakeSocketReadWaiters(client_p_idx);
                }
            }
        }
        sockets[idx] = .{};
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

    // Pair client and server
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

    // Pair client and server
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
    if (s.peer_closed) return Errno.EPIPE;
    if (s.state != .CONNECTED or s.peer_idx == null) return Errno.ENOTCONN;

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

// Backward-compatibility wrappers
pub fn bind(idx: usize, port_host: u16) Errno!void {
    return bindInet(idx, port_host);
}

pub fn connectLoopback(client_idx: usize, target_port_host: u16) Errno!void {
    _ = try connectInet(client_idx, target_port_host);
}

pub fn popAcceptQueue(listen_idx: usize) ?usize {
    return popAccept(listen_idx);
}

pub fn writeStream(sender_idx: usize, src: []const u8) Errno!usize {
    return write(sender_idx, src);
}

pub fn readStream(receiver_idx: usize, dst: []u8) struct { status: enum { bytes, eof, would_block }, n: usize } {
    const res = read(receiver_idx, dst);
    return switch (res) {
        .bytes => |n| .{ .status = .bytes, .n = n },
        .eof => .{ .status = .eof, .n = 0 },
        .would_block => .{ .status = .would_block, .n = 0 },
    };
}
