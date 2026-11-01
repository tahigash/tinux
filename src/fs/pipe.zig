const std = @import("std");
const task = @import("../proc/task.zig");

pub const MAX_PIPES: usize = 16;
pub const PIPE_BUF_SIZE: usize = 4096;

pub const Pipe = struct {
    in_use: bool = false,
    buf: [PIPE_BUF_SIZE]u8 = [_]u8{0} ** PIPE_BUF_SIZE,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,
    readers: usize = 0,
    writers: usize = 0,
};

pub const PipeReadStatus = enum {
    bytes,
    eof,
    would_block,
};

pub const PipeReadResult = struct {
    status: PipeReadStatus,
    n: usize = 0,
};

pub const PipeWriteStatus = enum {
    bytes,
    broken_pipe,
    would_block,
};

pub const PipeWriteResult = struct {
    status: PipeWriteStatus,
    n: usize = 0,
};

var pipes: [MAX_PIPES]Pipe = [_]Pipe{.{}} ** MAX_PIPES;

pub fn init() void {
    for (&pipes) |*p| p.* = .{};
}

pub fn alloc() ?usize {
    for (&pipes, 0..) |*p, idx| {
        if (!p.in_use) {
            p.* = .{
                .in_use = true,
                .readers = 1,
                .writers = 1,
            };
            return idx;
        }
    }
    return null;
}

pub fn retainReader(idx: usize) void {
    if (idx < MAX_PIPES and pipes[idx].in_use) {
        pipes[idx].readers += 1;
    }
}

pub fn retainWriter(idx: usize) void {
    if (idx < MAX_PIPES and pipes[idx].in_use) {
        pipes[idx].writers += 1;
    }
}

pub fn closeReader(idx: usize) void {
    if (idx < MAX_PIPES and pipes[idx].in_use) {
        if (pipes[idx].readers > 0) pipes[idx].readers -= 1;
        if (pipes[idx].readers == 0) {
            task.wakePipeWaiters(idx);
        }
        if (pipes[idx].readers == 0 and pipes[idx].writers == 0) {
            pipes[idx].in_use = false;
        }
    }
}

pub fn closeWriter(idx: usize) void {
    if (idx < MAX_PIPES and pipes[idx].in_use) {
        if (pipes[idx].writers > 0) pipes[idx].writers -= 1;
        if (pipes[idx].writers == 0) {
            task.wakePipeWaiters(idx);
        }
        if (pipes[idx].readers == 0 and pipes[idx].writers == 0) {
            pipes[idx].in_use = false;
        }
    }
}

pub const allocPipe = alloc;
pub const retainRead = retainReader;
pub const retainWrite = retainWriter;
pub const closeRead = closeReader;
pub const closeWrite = closeWriter;

pub fn read(idx: usize, dst: []u8) PipeReadResult {
    if (idx >= MAX_PIPES or !pipes[idx].in_use) return .{ .status = .eof, .n = 0 };
    var p = &pipes[idx];
    if (p.count > 0) {
        const to_read = @min(dst.len, p.count);
        for (0..to_read) |i| {
            dst[i] = p.buf[p.read_pos];
            p.read_pos = (p.read_pos + 1) % PIPE_BUF_SIZE;
        }
        p.count -= to_read;
        task.wakePipeWaiters(idx);
        return .{ .status = .bytes, .n = to_read };
    }
    if (p.writers == 0) {
        return .{ .status = .eof, .n = 0 };
    }
    return .{ .status = .would_block, .n = 0 };
}

pub fn write(idx: usize, src: []const u8) PipeWriteResult {
    if (idx >= MAX_PIPES or !pipes[idx].in_use) return .{ .status = .broken_pipe, .n = 0 };
    var p = &pipes[idx];
    if (p.readers == 0) {
        return .{ .status = .broken_pipe, .n = 0 };
    }
    const avail = PIPE_BUF_SIZE - p.count;
    if (avail > 0) {
        const to_write = @min(src.len, avail);
        for (0..to_write) |i| {
            p.buf[p.write_pos] = src[i];
            p.write_pos = (p.write_pos + 1) % PIPE_BUF_SIZE;
        }
        p.count += to_write;
        task.wakePipeWaiters(idx);
        return .{ .status = .bytes, .n = to_write };
    }
    return .{ .status = .would_block, .n = 0 };
}
