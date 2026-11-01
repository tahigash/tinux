const std = @import("std");
const Errno = @import("../uapi/errno.zig").Errno;
const heap = @import("../mm/heap.zig");

pub const MAX_VFS_NODES: usize = 128;
pub const MAX_OPEN_FILES: usize = 64;
pub const MAX_PATH_LEN: usize = 128;
pub const MAX_FILE_SIZE: usize = 65536;

pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFBLK: u32 = 0o060000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFIFO: u32 = 0o010000;
pub const S_IFLNK: u32 = 0o120000;
pub const S_IFSOCK: u32 = 0o140000;

pub const O_RDONLY: u32 = 0o0;
pub const O_WRONLY: u32 = 0o1;
pub const O_RDWR: u32 = 0o2;
pub const O_CREAT: u32 = 0o100;
pub const O_EXCL: u32 = 0o200;
pub const O_TRUNC: u32 = 0o1000;
pub const O_APPEND: u32 = 0o2000;
pub const O_NONBLOCK: u32 = 0o4000;
pub const O_DIRECTORY: u32 = 0o200000;
pub const O_CLOEXEC: u32 = 0o2000000;

pub const AT_FDCWD: isize = -100;
pub const AT_REMOVEDIR: usize = 0x200;

pub const DT_UNKNOWN: u8 = 0;
pub const DT_FIFO: u8 = 1;
pub const DT_CHR: u8 = 2;
pub const DT_DIR: u8 = 4;
pub const DT_BLK: u8 = 6;
pub const DT_REG: u8 = 8;
pub const DT_LNK: u8 = 10;
pub const DT_SOCK: u8 = 12;

pub fn modeToDtype(mode: u32) u8 {
    return switch (mode & S_IFMT) {
        S_IFDIR => DT_DIR,
        S_IFCHR => DT_CHR,
        S_IFBLK => DT_BLK,
        S_IFREG => DT_REG,
        S_IFIFO => DT_FIFO,
        S_IFLNK => DT_LNK,
        S_IFSOCK => DT_SOCK,
        else => DT_REG,
    };
}

pub const LinuxStat = extern struct {
    st_dev: u64 = 1,
    st_ino: u64 = 1,
    st_nlink: u64 = 1,
    st_mode: u32 = 0,
    st_uid: u32 = 0,
    st_gid: u32 = 0,
    __pad0: u32 = 0,
    st_rdev: u64 = 0,
    st_size: i64 = 0,
    st_blksize: i64 = 4096,
    st_blocks: i64 = 0,
    st_atime: i64 = 0,
    st_atime_nsec: i64 = 0,
    st_mtime: i64 = 0,
    st_mtime_nsec: i64 = 0,
    st_ctime: i64 = 0,
    st_ctime_nsec: i64 = 0,
    __unused: [3]i64 = .{ 0, 0, 0 },

    comptime {
        std.debug.assert(@sizeOf(LinuxStat) == 144);
        std.debug.assert(@offsetOf(LinuxStat, "st_mode") == 24);
        std.debug.assert(@offsetOf(LinuxStat, "st_size") == 48);
    }
};

pub const LinuxIovec = extern struct {
    iov_base: usize,
    iov_len: usize,

    comptime {
        std.debug.assert(@sizeOf(LinuxIovec) == 16);
    }
};

pub const FdKind = enum(u8) {
    UNUSED = 0,
    CONSOLE_IN = 1,
    CONSOLE_OUT = 2,
    CONSOLE_ERR = 3,
    VFS_FILE = 4,
    PIPE_READ = 5,
    PIPE_WRITE = 6,
    EPOLL = 7,
    BLKDEV = 8,
    SOCKET = 9,
};

pub const FdEntry = struct {
    kind: FdKind = .UNUSED,
    node_idx: usize = 0,
    offset: usize = 0,
    flags: u32 = 0,
    cloexec: bool = false,
};

pub const VfsNode = struct {
    in_use: bool = false,
    name_buf: [MAX_PATH_LEN]u8 = [_]u8{0} ** MAX_PATH_LEN,
    name_len: usize = 0,
    mode: u32 = 0,
    static_data: []const u8 = "",
    rw_buf: ?[*]u8 = null,
    rw_cap: usize = 0,
    size: usize = 0,

    pub fn name(self: *const VfsNode) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn slice(self: *const VfsNode) []const u8 {
        if (self.rw_buf) |ptr| {
            return ptr[0..self.size];
        }
        return self.static_data[0..self.size];
    }

    pub fn isDir(self: *const VfsNode) bool {
        return (self.mode & S_IFMT) == S_IFDIR;
    }
};

pub var nodes: [MAX_VFS_NODES]VfsNode = [_]VfsNode{.{}} ** MAX_VFS_NODES;

pub fn normalizePath(raw_path: []const u8) []const u8 {
    var p = raw_path;
    while (p.len > 0 and (p[0] == '/' or (p.len >= 2 and p[0] == '.' and p[1] == '/'))) {
        if (p[0] == '/') {
            p = p[1..];
        } else {
            p = p[2..];
        }
    }
    while (p.len > 0 and p[p.len - 1] == '/') {
        p = p[0 .. p.len - 1];
    }
    return p;
}

pub fn resolveTaskPath(cwd_path: []const u8, raw_path: []const u8, out_buf: *[MAX_PATH_LEN]u8) []const u8 {
    const is_abs = raw_path.len > 0 and raw_path[0] == '/';
    var temp_buf: [MAX_PATH_LEN]u8 = undefined;
    var len: usize = 0;

    if (!is_abs) {
        const norm_cwd = normalizePath(cwd_path);
        if (norm_cwd.len > 0) {
            @memcpy(temp_buf[0..norm_cwd.len], norm_cwd);
            temp_buf[norm_cwd.len] = '/';
            len = norm_cwd.len + 1;
        }
    }

    const norm_raw = normalizePath(raw_path);
    if (len + norm_raw.len > MAX_PATH_LEN) {
        return "";
    }
    @memcpy(temp_buf[len .. len + norm_raw.len], norm_raw);
    len += norm_raw.len;

    // Split components and resolve . and ..
    var segs: [16][]const u8 = undefined;
    var seg_count: usize = 0;

    var it = std.mem.splitScalar(u8, temp_buf[0..len], '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) {
            continue;
        } else if (std.mem.eql(u8, part, "..")) {
            if (seg_count > 0) seg_count -= 1;
        } else {
            if (seg_count < segs.len) {
                segs[seg_count] = part;
                seg_count += 1;
            }
        }
    }

    var out_pos: usize = 0;
    for (segs[0..seg_count], 0..) |s, i| {
        if (i > 0) {
            out_buf[out_pos] = '/';
            out_pos += 1;
        }
        @memcpy(out_buf[out_pos .. out_pos + s.len], s);
        out_pos += s.len;
    }
    return out_buf[0..out_pos];
}

pub fn isDirectChild(dir_path: []const u8, node_path: []const u8) ?[]const u8 {
    const norm_dir = normalizePath(dir_path);
    const is_root = norm_dir.len == 0 or std.mem.eql(u8, norm_dir, ".");
    if (is_root) {
        if (node_path.len > 0 and !std.mem.eql(u8, node_path, ".") and std.mem.indexOfScalar(u8, node_path, '/') == null) {
            return node_path;
        }
        return null;
    }
    if (std.mem.startsWith(u8, node_path, norm_dir) and
        node_path.len > norm_dir.len and
        node_path[norm_dir.len] == '/')
    {
        const sub = node_path[norm_dir.len + 1 ..];
        if (sub.len > 0 and std.mem.indexOfScalar(u8, sub, '/') == null) {
            return sub;
        }
    }
    return null;
}

pub fn init() void {
    for (&nodes) |*n| {
        n.* = .{};
    }
    // Register standard root directories
    _ = registerNodeInternal("", S_IFDIR | 0o755, "");
    _ = registerNodeInternal("bin", S_IFDIR | 0o755, "");
    _ = registerNodeInternal("etc", S_IFDIR | 0o755, "");
    _ = registerNodeInternal("dev", S_IFDIR | 0o755, "");
    _ = registerNodeInternal("proc", S_IFDIR | 0o755, "");
    _ = registerNodeInternal("tmp", S_IFDIR | 0o777, "");
    _ = registerNodeInternal("mnt", S_IFDIR | 0o755, "");
    _ = registerNodeInternal("lib", S_IFDIR | 0o755, "");
    _ = registerNodeInternal("usr", S_IFDIR | 0o755, "");
    _ = registerNodeInternal("usr/lib", S_IFDIR | 0o755, "");

    // Register /dev/tty, /dev/console, and /dev/null as character devices
    _ = registerNodeInternal("dev/tty", S_IFCHR | 0o666, "");
    _ = registerNodeInternal("dev/console", S_IFCHR | 0o666, "");
    _ = registerNodeInternal("dev/null", S_IFCHR | 0o666, "");
}

fn registerNodeInternal(norm_path: []const u8, mode: u32, data: []const u8) usize {
    if (lookupExact(norm_path)) |existing| {
        nodes[existing].mode = mode;
        if (nodes[existing].rw_buf) |ptr| {
            heap.allocator().free(ptr[0..nodes[existing].rw_cap]);
            nodes[existing].rw_buf = null;
            nodes[existing].rw_cap = 0;
        }
        nodes[existing].static_data = data;
        nodes[existing].size = data.len;
        return existing;
    }

    for (&nodes, 0..) |*n, idx| {
        if (!n.in_use) {
            n.in_use = true;
            n.mode = mode;
            const cpy_len = @min(norm_path.len, MAX_PATH_LEN);
            @memcpy(n.name_buf[0..cpy_len], norm_path[0..cpy_len]);
            n.name_len = cpy_len;
            n.static_data = data;
            n.size = data.len;
            n.rw_buf = null;
            n.rw_cap = 0;
            return idx;
        }
    }
    @panic("VFS: out of node slots");
}

fn ensureParentDirs(norm_path: []const u8) void {
    var i: usize = 0;
    while (i < norm_path.len) : (i += 1) {
        if (norm_path[i] == '/') {
            const parent = norm_path[0..i];
            if (parent.len > 0 and lookupExact(parent) == null) {
                _ = registerNodeInternal(parent, S_IFDIR | 0o755, "");
            }
        }
    }
}

pub fn registerNode(norm_path: []const u8, mode: u32, data: []const u8) usize {
    ensureParentDirs(norm_path);
    return registerNodeInternal(norm_path, mode, data);
}

pub fn createNode(norm_path: []const u8, mode: u32) Errno!usize {
    if (norm_path.len == 0) return Errno.EINVAL;
    if (lookupExact(norm_path) != null) {
        return Errno.EEXIST;
    }

    // Verify parent directory exists and is a directory
    if (std.mem.lastIndexOfScalar(u8, norm_path, '/')) |slash_idx| {
        const parent_path = norm_path[0..slash_idx];
        const p_idx = lookupExact(parent_path) orelse return Errno.ENOENT;
        if (!nodes[p_idx].isDir()) return Errno.ENOTDIR;
    } else {
        const root_idx = lookupExact("") orelse return Errno.ENOENT;
        if (!nodes[root_idx].isDir()) return Errno.ENOTDIR;
    }

    for (&nodes, 0..) |*n, idx| {
        if (!n.in_use) {
            n.in_use = true;
            n.mode = mode;
            const cpy_len = @min(norm_path.len, MAX_PATH_LEN);
            @memcpy(n.name_buf[0..cpy_len], norm_path[0..cpy_len]);
            n.name_len = cpy_len;
            n.static_data = "";
            n.size = 0;
            n.rw_buf = null;
            n.rw_cap = 0;
            return idx;
        }
    }
    return Errno.ENOSPC;
}

pub fn truncateNode(node_idx: usize) void {
    if (node_idx >= MAX_VFS_NODES or !nodes[node_idx].in_use) return;
    nodes[node_idx].size = 0;
    if (nodes[node_idx].rw_buf) |wp| {
        @memset(wp[0..nodes[node_idx].rw_cap], 0);
    }
}

pub fn writeNode(node_idx: usize, offset: usize, src: []const u8) Errno!usize {
    if (node_idx >= MAX_VFS_NODES or !nodes[node_idx].in_use) return Errno.EBADF;
    var node = &nodes[node_idx];
    if (node.isDir()) return Errno.EISDIR;
    if (src.len == 0) return 0;

    const end_pos = std.math.add(usize, offset, src.len) catch return Errno.ENOSPC;
    if (end_pos > MAX_FILE_SIZE) return Errno.ENOSPC;

    if (node.rw_buf == null or end_pos > node.rw_cap) {
        const aligned = std.mem.alignForward(usize, end_pos, 256);
        const new_cap = @min(MAX_FILE_SIZE, @max(aligned, 256));
        const new_slice = heap.allocator().alloc(u8, new_cap) catch return Errno.ENOMEM;
        @memset(new_slice, 0);

        if (node.size > 0) {
            const old_slice = node.slice();
            const copy_len = @min(node.size, old_slice.len);
            @memcpy(new_slice[0..copy_len], old_slice[0..copy_len]);
        }

        if (node.rw_buf) |old_ptr| {
            heap.allocator().free(old_ptr[0..node.rw_cap]);
        }

        node.rw_buf = new_slice.ptr;
        node.rw_cap = new_cap;
    }

    @memcpy(node.rw_buf.?[offset .. offset + src.len], src);
    if (end_pos > node.size) {
        node.size = end_pos;
    }
    return src.len;
}

pub fn unlinkNode(norm_path: []const u8, remove_dir: bool) Errno!void {
    if (norm_path.len == 0) return Errno.EBUSY;
    const idx = lookupExact(norm_path) orelse return Errno.ENOENT;
    const node = &nodes[idx];
    if (node.isDir() and !remove_dir) {
        return Errno.EISDIR;
    }
    if (!node.isDir() and remove_dir) {
        return Errno.ENOTDIR;
    }
    if (node.isDir()) {
        for (&nodes) |*cand| {
            if (cand.in_use and isDirectChild(norm_path, cand.name()) != null) {
                return Errno.ENOTEMPTY;
            }
        }
    }
    if (node.rw_buf) |wp| {
        heap.allocator().free(wp[0..node.rw_cap]);
        node.rw_buf = null;
    }
    node.in_use = false;
    node.mode = 0;
    node.static_data = "";
    node.size = 0;
    node.rw_cap = 0;
    node.name_len = 0;
    @memset(&node.name_buf, 0);
}

pub fn lookupExact(norm_path: []const u8) ?usize {
    for (&nodes, 0..) |*n, idx| {
        if (n.in_use and std.mem.eql(u8, n.name(), norm_path)) {
            return idx;
        }
    }
    return null;
}

pub fn lookup(raw_path: []const u8) ?usize {
    const norm = normalizePath(raw_path);
    if (lookupExact(norm)) |idx| {
        return idx;
    }

    // Musl dynamic linker reciprocal aliasing
    if (std.mem.eql(u8, norm, "lib/libc.musl-x86_64.so.1") or std.mem.eql(u8, norm, "libc.musl-x86_64.so.1")) {
        if (lookupExact("lib/ld-musl-x86_64.so.1")) |ld_idx| {
            return ld_idx;
        }
    } else if (std.mem.eql(u8, norm, "lib/ld-musl-x86_64.so.1") or std.mem.eql(u8, norm, "ld-musl-x86_64.so.1")) {
        if (lookupExact("lib/libc.musl-x86_64.so.1")) |libc_idx| {
            return libc_idx;
        }
    }

    // BusyBox multi-call applet fallback
    const applets = [_][]const u8{
        "bin/cat", "cat",
        "bin/sh", "sh",
        "bin/echo", "echo",
        "bin/grep", "grep",
        "bin/ls", "ls",
        "bin/mkdir", "mkdir",
        "bin/touch", "touch",
        "bin/rm", "rm",
        "bin/rmdir", "rmdir",
        "bin/sleep", "sleep",
        "bin/ps", "ps",
        "bin/kill", "kill",
        "bin/sync", "sync",
        "bin/mount", "mount",
        "bin/umount", "umount",
    };

    for (applets) |app| {
        if (std.mem.eql(u8, norm, app)) {
            if (lookupExact("bin/busybox")) |bb_idx| {
                return bb_idx;
            }
        }
    }
    return null;
}

pub fn getNode(idx: usize) *VfsNode {
    return &nodes[idx];
}

pub fn fillStat(node_idx: usize, stat_out: *LinuxStat) void {
    if (node_idx >= MAX_VFS_NODES or !nodes[node_idx].in_use) {
        stat_out.* = .{};
        return;
    }
    const node = &nodes[node_idx];
    stat_out.* = .{
        .st_dev = 1,
        .st_ino = @as(u64, node_idx + 1),
        .st_nlink = 1,
        .st_mode = node.mode,
        .st_uid = 0,
        .st_gid = 0,
        .__pad0 = 0,
        .st_rdev = 0,
        .st_size = @as(i64, @intCast(node.size)),
        .st_blksize = 4096,
        .st_blocks = @as(i64, @intCast((node.size + 511) / 512)),
        .st_atime = 0,
        .st_atime_nsec = 0,
        .st_mtime = 0,
        .st_mtime_nsec = 0,
        .st_ctime = 0,
        .st_ctime_nsec = 0,
        .__unused = .{ 0, 0, 0 },
    };
}

pub fn readDirEntries64(dir_node_idx: usize, cursor_inout: *usize, user_buf: []u8) Errno!usize {
    if (dir_node_idx >= MAX_VFS_NODES or !nodes[dir_node_idx].in_use or !nodes[dir_node_idx].isDir()) {
        return Errno.ENOTDIR;
    }

    const dir_path = nodes[dir_node_idx].name();
    var cur = cursor_inout.*;
    var written: usize = 0;

    while (cur < MAX_VFS_NODES + 2) {
        var d_name: []const u8 = "";
        var d_type: u8 = DT_DIR;
        var d_ino: u64 = 1;

        if (cur == 0) {
            d_name = ".";
            d_type = DT_DIR;
            d_ino = @as(u64, dir_node_idx + 1);
        } else if (cur == 1) {
            d_name = "..";
            d_type = DT_DIR;
            if (dir_path.len == 0) {
                d_ino = 1;
            } else {
                const p_name = if (std.mem.lastIndexOfScalar(u8, dir_path, '/')) |idx| dir_path[0..idx] else "";
                d_ino = if (lookupExact(p_name)) |p_idx| @as(u64, p_idx + 1) else 1;
            }
        } else {
            const n_idx = cur - 2;
            if (n_idx < MAX_VFS_NODES and nodes[n_idx].in_use) {
                const node = &nodes[n_idx];
                if (isDirectChild(dir_path, node.name())) |rel_name| {
                    d_name = rel_name;
                    d_type = modeToDtype(node.mode);
                    d_ino = @as(u64, n_idx + 1);
                }
            }
        }

        if (d_name.len > 0) {
            // struct linux_dirent64 layout:
            // 0..7: d_ino (u64)
            // 8..15: d_off (i64)
            // 16..17: d_reclen (u16)
            // 18: d_type (u8)
            // 19..19+name.len: d_name + NUL
            // pad to 8 bytes
            const rec_min = 19 + d_name.len + 1;
            const reclen = std.mem.alignForward(usize, rec_min, 8);

            if (written + reclen > user_buf.len) {
                if (written == 0) {
                    return Errno.EINVAL;
                }
                break; // Buffer full
            }

            const rec_ptr = user_buf.ptr + written;
            std.mem.writeInt(u64, rec_ptr[0..8], d_ino, .little);
            std.mem.writeInt(i64, rec_ptr[8..16], @as(i64, @intCast(cur + 1)), .little);
            std.mem.writeInt(u16, rec_ptr[16..18], @as(u16, @intCast(reclen)), .little);
            rec_ptr[18] = d_type;
            @memcpy(rec_ptr[19 .. 19 + d_name.len], d_name);
            @memset(rec_ptr[19 + d_name.len .. reclen], 0);

            written += reclen;
        }

        cur += 1;
    }

    cursor_inout.* = cur;
    return written;
}

pub fn initTaskFdTable(fd_table: *[MAX_OPEN_FILES]FdEntry) void {
    for (fd_table) |*e| {
        e.* = .{};
    }
    // FD 0: CONSOLE_IN
    fd_table[0] = .{ .kind = .CONSOLE_IN, .flags = O_RDONLY };
    // FD 1: CONSOLE_OUT
    fd_table[1] = .{ .kind = .CONSOLE_OUT, .flags = O_WRONLY };
    // FD 2: CONSOLE_ERR
    fd_table[2] = .{ .kind = .CONSOLE_ERR, .flags = O_WRONLY };
}
