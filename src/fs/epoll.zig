const std = @import("std");
const vfs = @import("vfs.zig");
const pipe = @import("pipe.zig");
const socket = @import("../net/socket.zig");
const tty = @import("../drivers/tty.zig");
const Errno = @import("../uapi/errno.zig").Errno;
pub const MAX_EPOLL_INSTANCES: usize = 8;
pub const MAX_EPOLL_ITEMS: usize = 16;
pub const EPOLL_CTL_ADD: usize = 1;
pub const EPOLL_CTL_DEL: usize = 2;
pub const EPOLL_CTL_MOD: usize = 3;
pub const EPOLLIN: u32 = 0x001;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLERR: u32 = 0x008;
pub const EPOLLHUP: u32 = 0x010;
pub const LinuxEpollEvent = extern struct {
    events: u32 align(1) = 0,
    data: u64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxEpollEvent) == 12);
        std.debug.assert(@offsetOf(LinuxEpollEvent, "data") == 4);
    }
};
pub const EpollItem = struct {
    in_use: bool = false,
    fd: usize = 0,
    events: u32 = 0,
    data: u64 = 0,
};
pub const EpollInstance = struct {
    in_use: bool = false,
    ref_count: usize = 0,
    items: [MAX_EPOLL_ITEMS]EpollItem = [_]EpollItem{.{}} ** MAX_EPOLL_ITEMS,
};
var instances: [MAX_EPOLL_INSTANCES]EpollInstance = [_]EpollInstance{.{}} ** MAX_EPOLL_INSTANCES;
pub fn init() void {
    for (&instances) |*inst| inst.* = .{};
}
pub fn alloc() ?usize {
    for (&instances, 0..) |*inst, idx| {
        if (!inst.in_use) {
            inst.* = .{ .in_use = true, .ref_count = 1 };
            return idx;
        }
    }
    return null;
}
pub fn retain(idx: usize) void {
    if (idx < MAX_EPOLL_INSTANCES and instances[idx].in_use) {
        instances[idx].ref_count += 1;
    }
}
pub fn close(idx: usize) void {
    if (idx < MAX_EPOLL_INSTANCES and instances[idx].in_use) {
        if (instances[idx].ref_count > 0) instances[idx].ref_count -= 1;
        if (instances[idx].ref_count == 0) instances[idx].in_use = false;
    }
}
pub fn checkFdReady(entry: *const vfs.FdEntry, watched: u32) u32 {
    var ready: u32 = 0;
    switch (entry.kind) {
        .PIPE_READ => {
            if (pipe.getPipe(entry.node_idx)) |p| {
                if (p.count > 0) ready |= EPOLLIN;
                if (p.writers == 0) ready |= EPOLLHUP | EPOLLIN;
            } else {
                ready |= EPOLLERR;
            }
        },
        .PIPE_WRITE => {
            if (pipe.getPipe(entry.node_idx)) |p| {
                if (p.count < pipe.PIPE_BUF_SIZE) ready |= EPOLLOUT;
                if (p.readers == 0) ready |= EPOLLERR;
            } else {
                ready |= EPOLLERR;
            }
        },
        .SOCKET => {
            const s_idx = if (entry.sock_idx != 0) entry.sock_idx else entry.node_idx;
            if (s_idx < socket.MAX_SOCKETS and socket.sockets[s_idx].in_use) {
                const s = &socket.sockets[s_idx];
                if (s.rx_count > 0 or s.accept_count > 0) ready |= EPOLLIN;
                if (s.peer_closed) ready |= EPOLLHUP | EPOLLIN;
                if (s.state == .CONNECTED) ready |= EPOLLOUT;
            } else {
                ready |= EPOLLERR;
            }
        },
        .CONSOLE_IN => {
            if (tty.hasReadableData()) ready |= EPOLLIN;
        },
        .CONSOLE_OUT, .CONSOLE_ERR => {
            ready |= EPOLLOUT;
        },
        .VFS_FILE => {
            ready |= (EPOLLIN | EPOLLOUT);
        },
        else => {
            ready |= EPOLLERR;
        },
    }
    return ready & (watched | EPOLLERR | EPOLLHUP);
}

pub fn ctl(idx: usize, op: usize, target_fd: usize, ev: LinuxEpollEvent) Errno!void {
    if (idx >= MAX_EPOLL_INSTANCES or !instances[idx].in_use) return Errno.EBADF;
    const inst = &instances[idx];
    switch (op) {
        EPOLL_CTL_ADD => {
            for (&inst.items) |*it| {
                if (it.in_use and it.fd == target_fd) return Errno.EEXIST;
            }
            for (&inst.items) |*it| {
                if (!it.in_use) {
                    it.* = .{
                        .in_use = true,
                        .fd = target_fd,
                        .events = ev.events,
                        .data = ev.data,
                    };
                    return;
                }
            }
            return Errno.ENOSPC;
        },
        EPOLL_CTL_DEL => {
            for (&inst.items) |*it| {
                if (it.in_use and it.fd == target_fd) {
                    it.* = .{};
                    return;
                }
            }
            return Errno.ENOENT;
        },
        EPOLL_CTL_MOD => {
            for (&inst.items) |*it| {
                if (it.in_use and it.fd == target_fd) {
                    it.events = ev.events;
                    it.data = ev.data;
                    return;
                }
            }
            return Errno.ENOENT;
        },
        else => return Errno.EINVAL,
    }
}

pub fn collectReadyEvents(
    idx: usize,
    fd_table: *const [vfs.MAX_OPEN_FILES]vfs.FdEntry,
    out_events: []LinuxEpollEvent,
) usize {
    if (idx >= MAX_EPOLL_INSTANCES or !instances[idx].in_use) return 0;
    const inst = &instances[idx];
    var ready_count: usize = 0;
    for (&inst.items) |*it| {
        if (!it.in_use) continue;
        if (it.fd >= vfs.MAX_OPEN_FILES or fd_table[it.fd].kind == .UNUSED) continue;
        const ready = checkFdReady(&fd_table[it.fd], it.events);
        if (ready != 0 and ready_count < out_events.len) {
            out_events[ready_count] = .{ .events = ready, .data = it.data };
            ready_count += 1;
        }
    }
    return ready_count;
}
