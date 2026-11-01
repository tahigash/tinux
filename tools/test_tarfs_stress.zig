// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical stress test for USTAR tarfs:
// - invalid magic
// - corrupted / truncated headers
// - empty archive (all zero sectors)
// - multi-sector files (> 512 bytes)
// - boundary cases in unmountChildNodes
// - 8-space checksum oracle

const std = @import("std");

pub const SECTOR_SIZE: usize = 512;
pub const MAX_SECTORS: usize = 2048; // 1 MiB disk
pub const DISK_CAPACITY: usize = MAX_SECTORS * SECTOR_SIZE;
pub const MAX_NODES: usize = 64;

pub const S_IFDIR: u32 = 0o040000;
pub const S_IFREG: u32 = 0o100000;

pub const MockVirtioBlk = struct {
    storage: [DISK_CAPACITY]u8 = [_]u8{0} ** DISK_CAPACITY,
    dev_ready: bool = true,
    sectors_count: u64 = MAX_SECTORS,

    pub fn getCapacityBytes(self: *const MockVirtioBlk) usize {
        return @as(usize, @intCast(self.sectors_count)) * SECTOR_SIZE;
    }

    pub fn rwSector(self: *MockVirtioBlk, sector: u64, buf: *[SECTOR_SIZE]u8, is_write: bool) bool {
        if (!self.dev_ready or sector >= self.sectors_count) return false;
        const offset = @as(usize, @intCast(sector)) * SECTOR_SIZE;
        if (is_write) {
            @memcpy(self.storage[offset .. offset + SECTOR_SIZE], buf);
        } else {
            @memcpy(buf, self.storage[offset .. offset + SECTOR_SIZE]);
        }
        return true;
    }
};

pub const MockVfsNode = struct {
    name_buf: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    mode: u32 = 0,
    size: usize = 0,
    rw_buf: ?[*]u8 = null,
    rw_cap: usize = 0,
    in_use: bool = false,

    pub fn name(self: *const MockVfsNode) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn isDir(self: *const MockVfsNode) bool {
        return (self.mode & S_IFDIR) != 0;
    }

    pub fn slice(self: *const MockVfsNode) []const u8 {
        if (self.rw_buf) |ptr| {
            return ptr[0..self.size];
        }
        return "";
    }
};

pub const MockVfs = struct {
    nodes: [MAX_NODES]MockVfsNode = [_]MockVfsNode{.{}} ** MAX_NODES,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockVfs {
        return .{
            .nodes = [_]MockVfsNode{.{}} ** MAX_NODES,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockVfs) void {
        for (&self.nodes) |*n| {
            if (n.in_use and n.rw_buf != null) {
                self.allocator.free(n.rw_buf.?[0..n.rw_cap]);
                n.rw_buf = null;
            }
            n.in_use = false;
        }
    }

    pub fn normalizePath(raw: []const u8) []const u8 {
        var start: usize = 0;
        while (start < raw.len and (raw[start] == '/' or raw[start] == '.')) {
            if (raw[start] == '.' and start + 1 < raw.len and raw[start + 1] != '/') {
                break;
            }
            start += 1;
        }
        var end = raw.len;
        while (end > start and raw[end - 1] == '/') {
            end -= 1;
        }
        return raw[start..end];
    }

    pub fn registerNode(self: *MockVfs, norm_path: []const u8, mode: u32) usize {
        const norm = normalizePath(norm_path);
        for (&self.nodes, 0..) |*n, idx| {
            if (n.in_use and std.mem.eql(u8, n.name(), norm)) {
                n.mode = mode;
                return idx;
            }
        }
        for (&self.nodes, 0..) |*n, idx| {
            if (!n.in_use) {
                n.in_use = true;
                const copy_len = @min(norm.len, n.name_buf.len);
                @memcpy(n.name_buf[0..copy_len], norm[0..copy_len]);
                n.name_len = copy_len;
                n.mode = mode;
                n.size = 0;
                return idx;
            }
        }
        @panic("MockVfs: out of nodes");
    }

    pub fn writeNode(self: *MockVfs, idx: usize, offset: usize, data: []const u8) !void {
        const n = &self.nodes[idx];
        const end_pos = offset + data.len;
        if (end_pos > n.rw_cap) {
            var new_cap = if (n.rw_cap == 0) 512 else n.rw_cap * 2;
            while (new_cap < end_pos) new_cap *= 2;
            const new_slice = try self.allocator.alloc(u8, new_cap);
            if (n.rw_buf) |old_ptr| {
                @memcpy(new_slice[0..n.size], old_ptr[0..n.size]);
                self.allocator.free(old_ptr[0..n.rw_cap]);
            }
            n.rw_buf = new_slice.ptr;
            n.rw_cap = new_cap;
        }
        @memcpy(n.rw_buf.?[offset..end_pos], data);
        if (end_pos > n.size) n.size = end_pos;
    }

    pub fn unmountChildNodes(self: *MockVfs, prefix: []const u8) void {
        const norm_prefix = normalizePath(prefix);
        for (&self.nodes) |*n| {
            if (!n.in_use) continue;
            const name_slice = n.name();
            if (name_slice.len > norm_prefix.len and
                name_slice[norm_prefix.len] == '/' and
                std.mem.startsWith(u8, name_slice, norm_prefix))
            {
                if (n.rw_buf) |wp| {
                    self.allocator.free(wp[0..n.rw_cap]);
                    n.rw_buf = null;
                }
                n.in_use = false;
                n.mode = 0;
                n.size = 0;
                n.rw_cap = 0;
                n.name_len = 0;
                @memset(&n.name_buf, 0);
            }
        }
    }
};

// Mirror of tarfs logic adapted for isolated testing
pub const TarFsTestEngine = struct {
    blk: *MockVirtioBlk,
    vfs: *MockVfs,
    is_mounted: bool = false,
    mount_prefix_buf: [64]u8 = [_]u8{ 'm', 'n', 't' } ++ [_]u8{0} ** 61,
    mount_prefix_len: usize = 3,

    pub fn mountPrefix(self: *const TarFsTestEngine) []const u8 {
        return self.mount_prefix_buf[0..self.mount_prefix_len];
    }

    pub fn mountFromDisk(self: *TarFsTestEngine, target_canonical: []const u8) !usize {
        if (!self.blk.dev_ready) return error.DeviceNotReady;
        if (self.is_mounted) return error.Busy;

        const norm_target = MockVfs.normalizePath(target_canonical);
        if (norm_target.len == 0 or norm_target.len > self.mount_prefix_buf.len) return error.InvalidTarget;

        @memcpy(self.mount_prefix_buf[0..norm_target.len], norm_target);
        self.mount_prefix_len = norm_target.len;

        _ = self.vfs.registerNode(norm_target, S_IFDIR | 0o755);

        const total_sectors = self.blk.getCapacityBytes() / 512;
        var sector: u64 = 0;
        var consecutive_zero_blocks: usize = 0;
        var loaded_files: usize = 0;
        var hdr_buf: [512]u8 = undefined;

        while (sector < total_sectors) {
            if (!self.blk.rwSector(sector, &hdr_buf, false)) return error.IoError;

            var is_all_zero = true;
            for (hdr_buf) |b| {
                if (b != 0) {
                    is_all_zero = false;
                    break;
                }
            }

            if (is_all_zero) {
                consecutive_zero_blocks += 1;
                if (consecutive_zero_blocks >= 2) break;
                sector += 1;
                continue;
            }
            consecutive_zero_blocks = 0;

            if (!std.mem.startsWith(u8, hdr_buf[257..262], "ustar")) {
                break;
            }

            const raw_name = std.mem.sliceTo(hdr_buf[0..100], 0);
            const norm_rel = MockVfs.normalizePath(raw_name);
            if (norm_rel.len == 0) {
                sector += 1;
                continue;
            }

            const mode_slice = std.mem.trim(u8, hdr_buf[100..108], &[_]u8{ 0, ' ' });
            const file_mode: u32 = if (mode_slice.len > 0) std.fmt.parseInt(u32, mode_slice, 8) catch 0o644 else 0o644;

            const size_slice = std.mem.trim(u8, hdr_buf[124..136], &[_]u8{ 0, ' ' });
            const file_size: usize = if (size_slice.len > 0) std.fmt.parseInt(usize, size_slice, 8) catch 0 else 0;

            const typeflag = hdr_buf[156];

            var full_path_buf: [256]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ norm_target, norm_rel });

            if (typeflag == '5' or (raw_name.len > 0 and raw_name[raw_name.len - 1] == '/')) {
                _ = self.vfs.registerNode(full_path, S_IFDIR | (file_mode & 0o777));
                sector += 1;
            } else {
                const node_idx = self.vfs.registerNode(full_path, S_IFREG | (file_mode & 0o777));
                const data_sectors = (file_size + 511) / 512;
                var s: u64 = 0;
                var offset: usize = 0;
                var data_buf: [512]u8 = undefined;

                while (s < data_sectors) : (s += 1) {
                    if (!self.blk.rwSector(sector + 1 + s, &data_buf, false)) return error.IoError;
                    const chunk = @min(file_size - offset, 512);
                    try self.vfs.writeNode(node_idx, offset, data_buf[0..chunk]);
                    offset += chunk;
                }

                sector += 1 + data_sectors;
                loaded_files += 1;
            }
        }

        self.is_mounted = true;
        return loaded_files;
    }

    pub fn syncToDisk(self: *TarFsTestEngine) !void {
        if (!self.is_mounted or !self.blk.dev_ready) return;

        var sector: u64 = 0;
        const prefix = self.mountPrefix();

        for (0..MAX_NODES) |i| {
            const node = &self.vfs.nodes[i];
            if (!node.in_use) continue;

            const n_name = node.name();
            if (n_name.len > prefix.len and n_name[prefix.len] == '/' and std.mem.startsWith(u8, n_name, prefix)) {
                const rel_name = n_name[prefix.len + 1 ..];
                if (rel_name.len == 0) continue;

                var hdr: [512]u8 = [_]u8{0} ** 512;
                const is_dir = node.isDir();

                if (is_dir) {
                    var name_with_slash: [100]u8 = undefined;
                    const n_slice = if (rel_name.len < 99 and rel_name[rel_name.len - 1] != '/')
                        try std.fmt.bufPrint(&name_with_slash, "{s}/", .{rel_name})
                    else
                        rel_name;
                    const copy_len = @min(n_slice.len, 100);
                    @memcpy(hdr[0..copy_len], n_slice[0..copy_len]);
                    hdr[156] = '5';
                } else {
                    const copy_len = @min(rel_name.len, 100);
                    @memcpy(hdr[0..copy_len], rel_name[0..copy_len]);
                    hdr[156] = '0';
                }

                _ = try std.fmt.bufPrint(hdr[100..108], "{o:0>7}\x00", .{node.mode & 0o777});
                @memcpy(hdr[108..116], "0000000\x00");
                @memcpy(hdr[116..124], "0000000\x00");

                if (is_dir) {
                    @memcpy(hdr[124..136], "00000000000\x00");
                } else {
                    _ = try std.fmt.bufPrint(hdr[124..136], "{o:0>11}\x00", .{node.size});
                }

                @memcpy(hdr[136..148], "00000000000\x00");

                // Fill checksum field with 8 spaces before computing sum
                @memset(hdr[148..156], ' ');

                @memcpy(hdr[257..263], "ustar\x00");
                @memcpy(hdr[263..265], "00");
                @memcpy(hdr[265..270], "root\x00");
                @memcpy(hdr[297..302], "root\x00");

                var sum: u32 = 0;
                for (hdr) |b| {
                    sum += b;
                }
                _ = try std.fmt.bufPrint(hdr[148..156], "{o:0>6}\x00 ", .{sum});

                if (!self.blk.rwSector(sector, &hdr, true)) return error.IoError;
                sector += 1;

                if (!is_dir and node.size > 0) {
                    const file_data = node.slice();
                    var off: usize = 0;
                    var data_sector: [512]u8 = undefined;

                    while (off < file_data.len) {
                        const chunk = @min(file_data.len - off, 512);
                        @memcpy(data_sector[0..chunk], file_data[off .. off + chunk]);
                        if (chunk < 512) {
                            @memset(data_sector[chunk..512], 0);
                        }
                        if (!self.blk.rwSector(sector, &data_sector, true)) return error.IoError;
                        sector += 1;
                        off += chunk;
                    }
                }
            }
        }

        var zero_buf: [512]u8 = [_]u8{0} ** 512;
        if (!self.blk.rwSector(sector, &zero_buf, true)) return error.IoError;
        sector += 1;
        if (!self.blk.rwSector(sector, &zero_buf, true)) return error.IoError;
        sector += 1;
    }
};

test "Challenge 1: Empty Archive (All Zero Sectors) Boot, Mount, and Populate" {
    var blk = MockVirtioBlk{};
    var vfs = MockVfs.init(std.testing.allocator);
    defer vfs.deinit();

    var tar = TarFsTestEngine{ .blk = &blk, .vfs = &vfs };

    // Mounting completely zeroed disk:
    const loaded = try tar.mountFromDisk("/mnt");
    try std.testing.expectEqual(@as(usize, 0), loaded);
    try std.testing.expect(tar.is_mounted);

    // Register a new file under /mnt
    const idx = vfs.registerNode("mnt/notes.txt", S_IFREG | 0o644);
    try vfs.writeNode(idx, 0, "empirical challenger test notes");

    // Sync to disk
    try tar.syncToDisk();

    // Verify Sector 0 header
    var s0: [512]u8 = undefined;
    try std.testing.expect(blk.rwSector(0, &s0, false));
    try std.testing.expect(std.mem.startsWith(u8, s0[0..9], "notes.txt"));
    try std.testing.expectEqualStrings("ustar\x00", s0[257..263]);

    // Verify Sector 1 payload
    var s1: [512]u8 = undefined;
    try std.testing.expect(blk.rwSector(1, &s1, false));
    try std.testing.expect(std.mem.startsWith(u8, s1[0..31], "empirical challenger test notes"));

    // Verify Sectors 2 & 3 are dual zero EOA
    var s2: [512]u8 = undefined;
    var s3: [512]u8 = undefined;
    try std.testing.expect(blk.rwSector(2, &s2, false));
    try std.testing.expect(blk.rwSector(3, &s3, false));
    try std.testing.expect(std.mem.allEqual(u8, &s2, 0));
    try std.testing.expect(std.mem.allEqual(u8, &s3, 0));

    // Clear VFS and unmount, then remount to verify persistence from zero-start
    vfs.unmountChildNodes("mnt");
    tar.is_mounted = false;

    const reload_count = try tar.mountFromDisk("/mnt");
    try std.testing.expectEqual(@as(usize, 1), reload_count);
    const re_idx = for (&vfs.nodes, 0..) |*n, i| {
        if (n.in_use and std.mem.eql(u8, n.name(), "mnt/notes.txt")) break i;
    } else @panic("node not reloaded");

    try std.testing.expectEqualStrings("empirical challenger test notes", vfs.nodes[re_idx].slice());
}

test "Challenge 2: Robust Handling of Invalid Magic & Corrupted Headers" {
    var blk = MockVirtioBlk{};
    var vfs = MockVfs.init(std.testing.allocator);
    defer vfs.deinit();

    // Scenario A: Non-zero disk with invalid magic (e.g. MBR partition table or garbage)
    var garbage: [512]u8 = [_]u8{0xAA} ** 512;
    _ = blk.rwSector(0, &garbage, true);

    var tar = TarFsTestEngine{ .blk = &blk, .vfs = &vfs };
    const loaded_garbage = try tar.mountFromDisk("/mnt");
    // Invalid magic must stop scan gracefully without panic
    try std.testing.expectEqual(@as(usize, 0), loaded_garbage);
    tar.is_mounted = false;

    // Scenario B: Header with "ustar" magic but malformed non-octal size string "ZZZZ"
    var malformed_hdr: [512]u8 = [_]u8{0} ** 512;
    @memcpy(malformed_hdr[0..8], "bad.txt\x00");
    @memcpy(malformed_hdr[257..263], "ustar\x00");
    @memcpy(malformed_hdr[124..136], "ZZZZZZZZZZZ\x00"); // non-octal
    _ = blk.rwSector(0, &malformed_hdr, true);
    // Followed by dual zero blocks
    var zero_blk: [512]u8 = [_]u8{0} ** 512;
    _ = blk.rwSector(1, &zero_blk, true);
    _ = blk.rwSector(2, &zero_blk, true);

    const loaded_bad_size = try tar.mountFromDisk("/mnt");
    // Size parsing failure catches to 0, node registered with size 0, no panic
    try std.testing.expectEqual(@as(usize, 1), loaded_bad_size);
}

test "Challenge 3: Multi-Sector Files (> 512 Bytes) Read/Write Symmetry & Payload Integrity" {
    var blk = MockVirtioBlk{};
    var vfs = MockVfs.init(std.testing.allocator);
    defer vfs.deinit();

    var tar = TarFsTestEngine{ .blk = &blk, .vfs = &vfs };
    _ = try tar.mountFromDisk("/mnt");

    // Create 3 multi-sector files of distinct sizes:
    // 1) 513 bytes: crosses exactly 1 byte into 2nd data sector (2 sectors total)
    var buf513: [513]u8 = undefined;
    for (&buf513, 0..) |*b, i| b.* = @as(u8, @intCast(i % 251));
    const idx1 = vfs.registerNode("mnt/cross1.dat", S_IFREG | 0o644);
    try vfs.writeNode(idx1, 0, &buf513);

    // 2) Exactly 1024 bytes: 2 full data sectors, 0 padding bytes
    var buf1024: [1024]u8 = undefined;
    for (&buf1024, 0..) |*b, i| b.* = @as(u8, @intCast((i * 3 + 7) % 256));
    const idx2 = vfs.registerNode("mnt/full2sec.dat", S_IFREG | 0o644);
    try vfs.writeNode(idx2, 0, &buf1024);

    // 3) 3500 bytes: 7 data sectors (3500 = 6*512 + 428, padded with 84 zeros)
    var buf3500: [3500]u8 = undefined;
    for (&buf3500, 0..) |*b, i| b.* = @as(u8, @intCast((i * 13) % 256));
    const idx3 = vfs.registerNode("mnt/large7sec.dat", S_IFREG | 0o644);
    try vfs.writeNode(idx3, 0, &buf3500);

    // Sync all 3 multi-sector files to disk
    try tar.syncToDisk();

    // Reset VFS completely
    vfs.unmountChildNodes("mnt");
    tar.is_mounted = false;

    // Remount and reload all files from disk
    const loaded_count = try tar.mountFromDisk("/mnt");
    try std.testing.expectEqual(@as(usize, 3), loaded_count);

    // Verify bit-for-bit payload integrity across sector boundaries
    var found1 = false;
    var found2 = false;
    var found3 = false;

    for (&vfs.nodes) |*n| {
        if (!n.in_use) continue;
        if (std.mem.eql(u8, n.name(), "mnt/cross1.dat")) {
            try std.testing.expectEqual(@as(usize, 513), n.size);
            try std.testing.expectEqualSlices(u8, &buf513, n.slice());
            found1 = true;
        } else if (std.mem.eql(u8, n.name(), "mnt/full2sec.dat")) {
            try std.testing.expectEqual(@as(usize, 1024), n.size);
            try std.testing.expectEqualSlices(u8, &buf1024, n.slice());
            found2 = true;
        } else if (std.mem.eql(u8, n.name(), "mnt/large7sec.dat")) {
            try std.testing.expectEqual(@as(usize, 3500), n.size);
            try std.testing.expectEqualSlices(u8, &buf3500, n.slice());
            found3 = true;
        }
    }

    try std.testing.expect(found1 and found2 and found3);
}

test "Challenge 4: VFS unmountChildNodes Scoping & Prefix Substring Isolation" {
    var vfs = MockVfs.init(std.testing.allocator);
    defer vfs.deinit();

    // Register mount point
    _ = vfs.registerNode("mnt", S_IFDIR | 0o755);

    // Register mounted children
    _ = vfs.registerNode("mnt/file1.txt", S_IFREG | 0o644);
    _ = vfs.registerNode("mnt/subdir", S_IFDIR | 0o755);
    _ = vfs.registerNode("mnt/subdir/subfile.txt", S_IFREG | 0o644);

    // Register tricky path where prefix is a substring of the name but NOT a directory prefix
    _ = vfs.registerNode("mnt_backup/do_not_touch.txt", S_IFREG | 0o644);
    _ = vfs.registerNode("etc/motd", S_IFREG | 0o444);
    _ = vfs.registerNode("proc/mounts", S_IFREG | 0o444);

    vfs.unmountChildNodes("mnt");

    for (&vfs.nodes) |*n| {
        if (!n.in_use) continue;
        // Mount directory itself must remain
        if (std.mem.eql(u8, n.name(), "mnt")) continue;
        // mnt_backup, etc, proc must remain intact
        if (std.mem.eql(u8, n.name(), "mnt_backup/do_not_touch.txt")) continue;
        if (std.mem.eql(u8, n.name(), "etc/motd")) continue;
        if (std.mem.eql(u8, n.name(), "proc/mounts")) continue;

        // Any other node should not be present
        std.debug.panic("Node was not unmounted: {s}\n", .{n.name()});
    }

    // Verify that the child nodes under "mnt/" were truly freed
    for (&vfs.nodes) |*n| {
        if (n.in_use) {
            try std.testing.expect(!std.mem.startsWith(u8, n.name(), "mnt/"));
        }
    }
}

test "Challenge 5: 8-Space Checksum Strict POSIX Algorithm Invariant" {
    var hdr: [512]u8 = [_]u8{0} ** 512;
    @memcpy(hdr[0..13], "testfile.txt\x00");
    _ = try std.fmt.bufPrint(hdr[100..108], "{o:0>7}\x00", .{0o644});
    @memcpy(hdr[108..116], "0000000\x00");
    @memcpy(hdr[116..124], "0000000\x00");
    _ = try std.fmt.bufPrint(hdr[124..136], "{o:0>11}\x00", .{12345});
    @memcpy(hdr[136..148], "00000000000\x00");

    // 8 spaces
    @memset(hdr[148..156], ' ');
    hdr[156] = '0';
    @memcpy(hdr[257..263], "ustar\x00");
    @memcpy(hdr[263..265], "00");
    @memcpy(hdr[265..270], "root\x00");
    @memcpy(hdr[297..302], "root\x00");

    var sum: u32 = 0;
    for (hdr) |b| sum += b;

    var formatted: [8]u8 = undefined;
    _ = try std.fmt.bufPrint(&formatted, "{o:0>6}\x00 ", .{sum});

    // Verify format length and terminating bytes
    try std.testing.expectEqual(@as(usize, 8), formatted.len);
    try std.testing.expectEqual(@as(u8, 0), formatted[6]);
    try std.testing.expectEqual(@as(u8, ' '), formatted[7]);

    // Verify parse back matches sum
    const parsed_chk = try std.fmt.parseInt(u32, formatted[0..6], 8);
    try std.testing.expectEqual(sum, parsed_chk);
}
