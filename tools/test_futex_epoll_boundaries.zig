// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical unit and boundary stress test for Tinux Futex and Epoll Subsystems

const std = @import("std");

// ============================================================================
// 1. Epoll Data Structures & ABI Layout Verification
// ============================================================================
pub const LinuxEpollEvent = extern struct {
    events: u32 align(1) = 0,
    data: u64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxEpollEvent) == 12);
        std.debug.assert(@offsetOf(LinuxEpollEvent, "data") == 4);
    }
};

pub const MAX_EPOLL_INSTANCES: usize = 8;
pub const MAX_EPOLL_ITEMS: usize = 16;
pub const EPOLL_CTL_ADD: usize = 1;
pub const EPOLL_CTL_DEL: usize = 2;
pub const EPOLL_CTL_MOD: usize = 3;

pub const EPOLLIN: u32 = 0x001;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLERR: u32 = 0x008;
pub const EPOLLHUP: u32 = 0x010;

pub const Errno = error{
    EBADF,
    EEXIST,
    ENOENT,
    ENOSPC,
    EINVAL,
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

pub var epoll_instances: [MAX_EPOLL_INSTANCES]EpollInstance = [_]EpollInstance{.{}} ** MAX_EPOLL_INSTANCES;

pub fn epollInit() void {
    for (&epoll_instances) |*inst| inst.* = .{};
}

pub fn epollAlloc() ?usize {
    for (&epoll_instances, 0..) |*inst, idx| {
        if (!inst.in_use) {
            inst.* = .{ .in_use = true, .ref_count = 1 };
            return idx;
        }
    }
    return null;
}

pub fn epollClose(idx: usize) void {
    if (idx < MAX_EPOLL_INSTANCES and epoll_instances[idx].in_use) {
        if (epoll_instances[idx].ref_count > 0) epoll_instances[idx].ref_count -= 1;
        if (epoll_instances[idx].ref_count == 0) epoll_instances[idx].in_use = false;
    }
}

pub fn epollCtl(idx: usize, op: usize, target_fd: usize, ev: LinuxEpollEvent) Errno!void {
    if (idx >= MAX_EPOLL_INSTANCES or !epoll_instances[idx].in_use) return Errno.EBADF;
    const inst = &epoll_instances[idx];
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

// Mock descriptor types for readiness evaluation
pub const FdKind = enum {
    UNUSED,
    PIPE_READ,
    PIPE_WRITE,
    CONSOLE_IN,
    CONSOLE_OUT,
    VFS_FILE,
};

pub const MockPipe = struct {
    count: usize = 0,
    readers: usize = 1,
    writers: usize = 1,
};

pub const MockFdEntry = struct {
    kind: FdKind = .UNUSED,
    pipe_ref: ?*MockPipe = null,
};

pub fn checkFdReady(entry: *const MockFdEntry, watched: u32) u32 {
    var ready: u32 = 0;
    switch (entry.kind) {
        .PIPE_READ => {
            if (entry.pipe_ref) |p| {
                if (p.count > 0) ready |= EPOLLIN;
                if (p.writers == 0) ready |= EPOLLHUP | EPOLLIN;
            } else {
                ready |= EPOLLERR;
            }
        },
        .PIPE_WRITE => {
            if (entry.pipe_ref) |p| {
                if (p.count < 4096) ready |= EPOLLOUT;
                if (p.readers == 0) ready |= EPOLLERR;
            } else {
                ready |= EPOLLERR;
            }
        },
        .CONSOLE_IN => {
            // Simulated empty or ready
        },
        .CONSOLE_OUT => {
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

// ============================================================================
// 2. Futex Wait Queue Oracle Verification
// ============================================================================
pub const MockTaskState = enum {
    RUNNING,
    READY,
    WAITING_FUTEX,
};

pub const MockTask = struct {
    pid: usize = 0,
    state: MockTaskState = .RUNNING,
    wait_futex_paddr: usize = 0,
};

pub var mock_tasks: [16]MockTask = [_]MockTask{.{}} ** 16;

pub fn wakeByPaddr(paddr: usize, max_wake: usize) usize {
    var woken: usize = 0;
    if (max_wake == 0) return 0;
    for (&mock_tasks) |*t| {
        if (t.state == .WAITING_FUTEX and t.wait_futex_paddr == paddr) {
            t.state = .READY;
            t.wait_futex_paddr = 0;
            woken += 1;
            if (woken >= max_wake) break;
        }
    }
    return woken;
}

// ============================================================================
// Test Suites
// ============================================================================

test "LinuxEpollEvent 12-byte packed alignment and memory offset verification" {
    // 1. Strict size check
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(LinuxEpollEvent));

    // 2. Exact offset of fields
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(LinuxEpollEvent, "events"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(LinuxEpollEvent, "data"));

    // 3. Array packing: array of 4 events MUST occupy exactly 48 bytes (not 64 bytes!)
    const events_array = [_]LinuxEpollEvent{
        .{ .events = 0x01, .data = 0xAAAA_BBBB_CCCC_DDD0 },
        .{ .events = 0x04, .data = 0xAAAA_BBBB_CCCC_DDD1 },
        .{ .events = 0x08, .data = 0xAAAA_BBBB_CCCC_DDD2 },
        .{ .events = 0x10, .data = 0xAAAA_BBBB_CCCC_DDD3 },
    };
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(@TypeOf(events_array)));

    // 4. Raw byte offset inspection
    const raw_bytes: *const [48]u8 = @ptrCast(&events_array);
    // Event 0: events at 0..3, data at 4..11
    const ev0_events = std.mem.readInt(u32, raw_bytes[0..4], .little);
    const ev0_data = std.mem.readInt(u64, raw_bytes[4..12], .little);
    try std.testing.expectEqual(@as(u32, 0x01), ev0_events);
    try std.testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDD0), ev0_data);

    // Event 1: starts at offset 12 (NOT 16!), data at offset 16..23
    const ev1_events = std.mem.readInt(u32, raw_bytes[12..16], .little);
    const ev1_data = std.mem.readInt(u64, raw_bytes[16..24], .little);
    try std.testing.expectEqual(@as(u32, 0x04), ev1_events);
    try std.testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDD1), ev1_data);

    // Event 2: starts at offset 24, data at offset 28..35
    const ev2_events = std.mem.readInt(u32, raw_bytes[24..28], .little);
    const ev2_data = std.mem.readInt(u64, raw_bytes[28..36], .little);
    try std.testing.expectEqual(@as(u32, 0x08), ev2_events);
    try std.testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDD2), ev2_data);

    // Event 3: starts at offset 36, data at offset 40..47
    const ev3_events = std.mem.readInt(u32, raw_bytes[36..40], .little);
    const ev3_data = std.mem.readInt(u64, raw_bytes[40..48], .little);
    try std.testing.expectEqual(@as(u32, 0x10), ev3_events);
    try std.testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDD3), ev3_data);
}

test "epoll_ctl errnos: EEXIST, ENOENT, ENOSPC, and EBADF" {
    epollInit();
    const ep_idx = epollAlloc().?;

    // 1. EPOLL_CTL_MOD and EPOLL_CTL_DEL on non-existent fd -> ENOENT
    const dummy_ev = LinuxEpollEvent{ .events = EPOLLIN, .data = 100 };
    try std.testing.expectError(error.ENOENT, epollCtl(ep_idx, EPOLL_CTL_MOD, 5, dummy_ev));
    try std.testing.expectError(error.ENOENT, epollCtl(ep_idx, EPOLL_CTL_DEL, 5, dummy_ev));

    // 2. EPOLL_CTL_ADD -> success
    try epollCtl(ep_idx, EPOLL_CTL_ADD, 5, dummy_ev);

    // 3. Duplicate EPOLL_CTL_ADD on same fd -> EEXIST
    try std.testing.expectError(error.EEXIST, epollCtl(ep_idx, EPOLL_CTL_ADD, 5, dummy_ev));

    // 4. Fill remaining 15 slots (total 16 items)
    var fd: usize = 6;
    while (fd < 21) : (fd += 1) {
        try epollCtl(ep_idx, EPOLL_CTL_ADD, fd, .{ .events = EPOLLIN, .data = fd });
    }

    // 5. 17th item addition MUST fail with ENOSPC
    try std.testing.expectError(error.ENOSPC, epollCtl(ep_idx, EPOLL_CTL_ADD, 99, dummy_ev));

    // 6. Delete an item and verify slot can be reused
    try epollCtl(ep_idx, EPOLL_CTL_DEL, 5, dummy_ev);
    // Deleting again -> ENOENT
    try std.testing.expectError(error.ENOENT, epollCtl(ep_idx, EPOLL_CTL_DEL, 5, dummy_ev));
    // Adding new item now succeeds into freed slot
    try epollCtl(ep_idx, EPOLL_CTL_ADD, 99, dummy_ev);

    // 7. Invalid instance index -> EBADF
    try std.testing.expectError(error.EBADF, epollCtl(99, EPOLL_CTL_ADD, 1, dummy_ev));

    // Close instance
    epollClose(ep_idx);
    try std.testing.expectError(error.EBADF, epollCtl(ep_idx, EPOLL_CTL_ADD, 1, dummy_ev));
}

test "epoll level-triggered pipe readiness and drain transitions" {
    var mock_pipe = MockPipe{ .count = 0, .readers = 1, .writers = 1 };
    const read_entry = MockFdEntry{ .kind = .PIPE_READ, .pipe_ref = &mock_pipe };

    // 1. Initial state: pipe empty, writers active -> NOT ready
    var ready = checkFdReady(&read_entry, EPOLLIN);
    try std.testing.expectEqual(@as(u32, 0), ready);

    // 2. Write data (pipe count > 0) -> EPOLLIN triggered
    mock_pipe.count = 128;
    ready = checkFdReady(&read_entry, EPOLLIN);
    try std.testing.expectEqual(EPOLLIN, ready);

    // 3. Repeated check without reading -> Still ready (level-triggered)
    ready = checkFdReady(&read_entry, EPOLLIN);
    try std.testing.expectEqual(EPOLLIN, ready);

    // 4. Read data until empty (drain) -> EPOLLIN clears
    mock_pipe.count = 0;
    ready = checkFdReady(&read_entry, EPOLLIN);
    try std.testing.expectEqual(@as(u32, 0), ready);

    // 5. Writer closes (writers == 0) -> EPOLLHUP | EPOLLIN
    mock_pipe.writers = 0;
    ready = checkFdReady(&read_entry, EPOLLIN);
    try std.testing.expectEqual(EPOLLHUP | EPOLLIN, ready);
}

test "sys_futex wait and wake releases exactly val waiters" {
    for (&mock_tasks) |*t| t.* = .{};

    const paddr_alpha: usize = 0x1000_4000;
    const paddr_beta: usize = 0x2000_8000;

    // Set up 4 waiters on paddr_alpha
    mock_tasks[1] = .{ .pid = 1, .state = .WAITING_FUTEX, .wait_futex_paddr = paddr_alpha };
    mock_tasks[2] = .{ .pid = 2, .state = .WAITING_FUTEX, .wait_futex_paddr = paddr_alpha };
    mock_tasks[3] = .{ .pid = 3, .state = .WAITING_FUTEX, .wait_futex_paddr = paddr_alpha };
    mock_tasks[4] = .{ .pid = 4, .state = .WAITING_FUTEX, .wait_futex_paddr = paddr_alpha };

    // Set up 2 waiters on paddr_beta
    mock_tasks[5] = .{ .pid = 5, .state = .WAITING_FUTEX, .wait_futex_paddr = paddr_beta };
    mock_tasks[6] = .{ .pid = 6, .state = .WAITING_FUTEX, .wait_futex_paddr = paddr_beta };

    // 1. Wake with max_wake = 0 -> returns 0, no waiters released
    const woken0 = wakeByPaddr(paddr_alpha, 0);
    try std.testing.expectEqual(@as(usize, 0), woken0);
    try std.testing.expectEqual(MockTaskState.WAITING_FUTEX, mock_tasks[1].state);

    // 2. Wake with max_wake = 1 on paddr_alpha -> exactly 1 waiter woken
    const woken1 = wakeByPaddr(paddr_alpha, 1);
    try std.testing.expectEqual(@as(usize, 1), woken1);
    try std.testing.expectEqual(MockTaskState.READY, mock_tasks[1].state);
    try std.testing.expectEqual(@as(usize, 0), mock_tasks[1].wait_futex_paddr);
    try std.testing.expectEqual(MockTaskState.WAITING_FUTEX, mock_tasks[2].state);
    try std.testing.expectEqual(MockTaskState.WAITING_FUTEX, mock_tasks[3].state);
    try std.testing.expectEqual(MockTaskState.WAITING_FUTEX, mock_tasks[4].state);
    // Beta waiters must be unaffected
    try std.testing.expectEqual(MockTaskState.WAITING_FUTEX, mock_tasks[5].state);
    try std.testing.expectEqual(MockTaskState.WAITING_FUTEX, mock_tasks[6].state);

    // 3. Wake with max_wake = 2 on paddr_alpha -> exactly 2 waiters woken
    const woken2 = wakeByPaddr(paddr_alpha, 2);
    try std.testing.expectEqual(@as(usize, 2), woken2);
    try std.testing.expectEqual(MockTaskState.READY, mock_tasks[2].state);
    try std.testing.expectEqual(MockTaskState.READY, mock_tasks[3].state);
    try std.testing.expectEqual(MockTaskState.WAITING_FUTEX, mock_tasks[4].state);

    // 4. Wake with max_wake = 10 on paddr_alpha -> only 1 remaining waiter woken (returns 1)
    const woken_last = wakeByPaddr(paddr_alpha, 10);
    try std.testing.expectEqual(@as(usize, 1), woken_last);
    try std.testing.expectEqual(MockTaskState.READY, mock_tasks[4].state);

    // 5. Wake on paddr_alpha again -> returns 0 (queue now empty)
    const woken_empty = wakeByPaddr(paddr_alpha, 1);
    try std.testing.expectEqual(@as(usize, 0), woken_empty);

    // 6. Wake on paddr_beta with max_wake = 2 -> both woken
    const woken_beta = wakeByPaddr(paddr_beta, 2);
    try std.testing.expectEqual(@as(usize, 2), woken_beta);
    try std.testing.expectEqual(MockTaskState.READY, mock_tasks[5].state);
    try std.testing.expectEqual(MockTaskState.READY, mock_tasks[6].state);
}

pub fn main() void {
    std.debug.print("Run via `zig test tools/test_futex_epoll_boundaries.zig`\n", .{});
}
