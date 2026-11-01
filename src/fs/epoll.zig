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
pub fn ctl(idx: usize, op: usize, target_fd: usize, ev: LinuxEpollEvent) Errno!void {
    // Builder implements EPOLL_CTL_ADD, EPOLL_CTL_MOD, EPOLL_CTL_DEL
}
pub fn collectReadyEvents(
    idx: usize,
    fd_table: *const [vfs.MAX_OPEN_FILES]vfs.FdEntry,
    out_events: []LinuxEpollEvent,
) usize {
    // Builder checks each registered item against pipe/socket/tty readiness and fills out_events
}
