// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical stress test for VirtIO-Block VFS integration, unaligned RMW, sys_lseek, and /proc/partitions

const std = @import("std");

pub const SECTOR_SIZE: usize = 512;
pub const DISK_SECTORS: usize = 2048; // 1 MiB disk
pub const DISK_CAPACITY: usize = DISK_SECTORS * SECTOR_SIZE;

pub const SEEK_SET: u32 = 0;
pub const SEEK_CUR: u32 = 1;
pub const SEEK_END: u32 = 2;

pub const EINVAL: isize = 22;
pub const EBADF: isize = 9;

// Mock disk state simulating QEMU VirtIO block backend storage
pub const MockDisk = struct {
    storage: [DISK_CAPACITY]u8 = [_]u8{0} ** DISK_CAPACITY,
    dev_ready: bool = true,
    total_sectors: u64 = DISK_SECTORS,

    pub fn getCapacityBytes(self: *const MockDisk) usize {
        return @as(usize, @intCast(self.total_sectors)) * SECTOR_SIZE;
    }

    pub fn rwSector(self: *MockDisk, sector: u64, buf: *[SECTOR_SIZE]u8, is_write: bool) bool {
        if (!self.dev_ready or sector >= self.total_sectors) return false;
        const offset = @as(usize, @intCast(sector)) * SECTOR_SIZE;
        if (is_write) {
            @memcpy(self.storage[offset .. offset + SECTOR_SIZE], buf);
        } else {
            @memcpy(buf, self.storage[offset .. offset + SECTOR_SIZE]);
        }
        return true;
    }

    // Exact replica of virtio_blk.readBytes logic
    pub fn readBytes(self: *MockDisk, offset: usize, dst: []u8) usize {
        if (!self.dev_ready or dst.len == 0) return 0;
        const cap = self.getCapacityBytes();
        if (offset >= cap) return 0;

        const count = @min(dst.len, cap - offset);
        var transferred: usize = 0;
        var cur_off = offset;
        var remaining = count;

        while (remaining > 0) {
            const sector = cur_off / SECTOR_SIZE;
            const sec_off = cur_off % SECTOR_SIZE;
            const chunk = @min(SECTOR_SIZE - sec_off, remaining);

            var tmp: [SECTOR_SIZE]u8 = undefined;
            if (!self.rwSector(sector, &tmp, false)) break;

            @memcpy(dst[transferred .. transferred + chunk], tmp[sec_off .. sec_off + chunk]);
            transferred += chunk;
            cur_off += chunk;
            remaining -= chunk;
        }

        return transferred;
    }

    // Exact replica of virtio_blk.writeBytes logic
    pub fn writeBytes(self: *MockDisk, offset: usize, src: []const u8) usize {
        if (!self.dev_ready or src.len == 0) return 0;
        const cap = self.getCapacityBytes();
        if (offset >= cap) return 0;

        const count = @min(src.len, cap - offset);
        var transferred: usize = 0;
        var cur_off = offset;
        var remaining = count;

        while (remaining > 0) {
            const sector = cur_off / SECTOR_SIZE;
            const sec_off = cur_off % SECTOR_SIZE;
            const chunk = @min(SECTOR_SIZE - sec_off, remaining);

            var tmp: [SECTOR_SIZE]u8 = undefined;
            if (sec_off == 0 and chunk == SECTOR_SIZE) {
                @memcpy(&tmp, src[transferred .. transferred + SECTOR_SIZE]);
                if (!self.rwSector(sector, &tmp, true)) break;
            } else {
                if (!self.rwSector(sector, &tmp, false)) break;
                @memcpy(tmp[sec_off .. sec_off + chunk], src[transferred .. transferred + chunk]);
                if (!self.rwSector(sector, &tmp, true)) break;
            }

            transferred += chunk;
            cur_off += chunk;
            remaining -= chunk;
        }

        return transferred;
    }
};

// Exact replica of sysLseek logic for .BLKDEV
pub fn mockSysLseek(fd_valid: bool, dev_capacity: usize, cur_offset: *usize, offset: i64, whence: u32) isize {
    if (!fd_valid) return -EBADF;
    const dev_size: i64 = @intCast(dev_capacity);
    const curr_off: i64 = @intCast(cur_offset.*);
    var new_off: i64 = 0;
    switch (whence) {
        SEEK_SET => new_off = offset,
        SEEK_CUR => new_off = curr_off + offset,
        SEEK_END => new_off = dev_size + offset,
        else => return -EINVAL,
    }
    if (new_off < 0 or new_off > dev_size) {
        return -EINVAL;
    } else {
        cur_offset.* = @intCast(new_off);
        return @intCast(new_off);
    }
}

// Exact replica of /proc/partitions dynamic formatting logic
pub fn formatProcPartitions(capacity_bytes: usize, out_buf: []u8) []const u8 {
    const num_blocks = capacity_bytes / 1024;
    return std.fmt.bufPrint(
        out_buf,
        "major minor  #blocks  name\n 254        0       {d} vda\n",
        .{num_blocks},
    ) catch "major minor  #blocks  name\n 254        0       1024 vda\n";
}

// ============================================================================
// 1. Challenge Directive 1: Unaligned and Multi-Sector Reads
// ============================================================================
test "Challenge 1: Unaligned and multi-sector reads across sector boundaries" {
    var disk = MockDisk{};

    // Seed disk storage with recognizable pseudo-random sequence
    for (&disk.storage, 0..) |*b, idx| {
        b.* = @truncate((idx * 31 + 17) & 0xFF);
    }

    // 1.1 Read single unaligned byte in sector 0
    var b1: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), disk.readBytes(123, &b1));
    try std.testing.expectEqual(disk.storage[123], b1[0]);

    // 1.2 Read unaligned span crossing exactly 1 sector boundary (500 .. 530)
    var b2: [30]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 30), disk.readBytes(500, &b2));
    try std.testing.expectEqualSlices(u8, disk.storage[500..530], &b2);

    // 1.3 Read multi-sector unaligned span crossing multiple boundaries (100 .. 2100)
    var b3: [2000]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2000), disk.readBytes(100, &b3));
    try std.testing.expectEqualSlices(u8, disk.storage[100..2100], &b3);

    // 1.4 Read ending exactly at sector boundary (e.g. 500..512)
    var b4: [12]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 12), disk.readBytes(500, &b4));
    try std.testing.expectEqualSlices(u8, disk.storage[500..512], &b4);

    // 1.5 Read starting exactly at sector boundary with unaligned length (e.g. 512..525)
    var b5: [13]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 13), disk.readBytes(512, &b5));
    try std.testing.expectEqualSlices(u8, disk.storage[512..525], &b5);

    // 1.6 Boundary condition: read at capacity - 5 with length 20 (truncated read)
    var b6: [20]u8 = undefined;
    const end_offset = DISK_CAPACITY - 5;
    const n6 = disk.readBytes(end_offset, &b6);
    try std.testing.expectEqual(@as(usize, 5), n6);
    try std.testing.expectEqualSlices(u8, disk.storage[end_offset..DISK_CAPACITY], b6[0..5]);

    // 1.7 Boundary condition: read at or beyond capacity
    var b7: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), disk.readBytes(DISK_CAPACITY, &b7));
    try std.testing.expectEqual(@as(usize, 0), disk.readBytes(DISK_CAPACITY + 100, &b7));

    // 1.8 Boundary condition: zero-length read
    var b8: [0]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), disk.readBytes(0, &b8));
}

// ============================================================================
// 2. Challenge Directive 2: Partial-Sector Read-Modify-Write (RMW)
// ============================================================================
test "Challenge 2: Partial-sector RMW preserves untouched bytes" {
    var disk = MockDisk{};

    // Fill sector 0, 1, 2 with distinctive background marker 0xEE
    @memset(disk.storage[0 .. 3 * SECTOR_SIZE], 0xEE);

    // 2.1 Single byte partial write at offset 7
    const one_byte = [_]u8{0x42};
    try std.testing.expectEqual(@as(usize, 1), disk.writeBytes(7, &one_byte));
    try std.testing.expectEqual(@as(u8, 0x42), disk.storage[7]);
    // Check untouched prefix (0..6)
    for (disk.storage[0..7]) |b| {
        try std.testing.expectEqual(@as(u8, 0xEE), b);
    }
    // Check untouched suffix (8..511)
    for (disk.storage[8..SECTOR_SIZE]) |b| {
        try std.testing.expectEqual(@as(u8, 0xEE), b);
    }

    // 2.2 Unaligned multi-sector write spanning 3 sectors:
    // Write 600 bytes starting at offset 400.
    // - Sector 0: offset 400..512 (112 bytes) -> partial write. Prefix 0..399 must be untouched.
    // - Sector 1: offset 512..1024 (512 bytes) -> full sector write.
    // - Sector 2: offset 1024..1000 (remaining: 600 - 112 - 512 = 0? wait, 112 + 512 = 624 > 600.
    //   Remaining in sector 2: 600 - 112 = 488 bytes into sector 1!
    // Let's test a true 3-sector span: write 700 bytes starting at offset 450:
    // - Sector 0: 450..512 = 62 bytes (partial head)
    // - Sector 1: 512..1024 = 512 bytes (full sector)
    // - Sector 2: 1024..1150 = 126 bytes (partial tail, remaining: 700 - 62 - 512 = 126)
    // Suffix 1150..1536 must remain 0xEE!
    var payload: [700]u8 = undefined;
    for (&payload, 0..) |*p, idx| {
        p.* = @truncate((idx * 7 + 3) & 0xFF);
    }

    try std.testing.expectEqual(@as(usize, 700), disk.writeBytes(450, &payload));

    // Verify written data matches payload
    try std.testing.expectEqualSlices(u8, &payload, disk.storage[450 .. 450 + 700]);

    // Verify Sector 0 untouched prefix (0..449)
    // Note: byte 7 was written earlier to 0x42, all others must be 0xEE!
    try std.testing.expectEqual(@as(u8, 0x42), disk.storage[7]);
    for (disk.storage[0..7]) |b| try std.testing.expectEqual(@as(u8, 0xEE), b);
    for (disk.storage[8..450]) |b| try std.testing.expectEqual(@as(u8, 0xEE), b);

    // Verify Sector 2 untouched suffix (1150..1536)
    for (disk.storage[1150 .. 3 * SECTOR_SIZE]) |b| {
        try std.testing.expectEqual(@as(u8, 0xEE), b);
    }

    // 2.3 Boundary write at capacity edge (partial write at end of disk)
    const cap = disk.getCapacityBytes();
    const tail_buf = [_]u8{ 0xAA, 0xBB, 0xCC };
    try std.testing.expectEqual(@as(usize, 3), disk.writeBytes(cap - 3, &tail_buf));
    try std.testing.expectEqualSlices(u8, &tail_buf, disk.storage[cap - 3 .. cap]);

    // Beyond capacity write returns 0
    try std.testing.expectEqual(@as(usize, 0), disk.writeBytes(cap, &tail_buf));
    try std.testing.expectEqual(@as(usize, 0), disk.writeBytes(cap + 100, &tail_buf));
}

// ============================================================================
// 3. Challenge Directive 3: sys_lseek Edge Cases
// ============================================================================
test "Challenge 3: sys_lseek edge cases for .BLKDEV" {
    const dev_cap: usize = DISK_CAPACITY;
    var cur_off: usize = 0;

    // 3.1 SEEK_SET valid cases
    try std.testing.expectEqual(@as(isize, 0), mockSysLseek(true, dev_cap, &cur_off, 0, SEEK_SET));
    try std.testing.expectEqual(@as(usize, 0), cur_off);

    try std.testing.expectEqual(@as(isize, 512), mockSysLseek(true, dev_cap, &cur_off, 512, SEEK_SET));
    try std.testing.expectEqual(@as(usize, 512), cur_off);

    try std.testing.expectEqual(@as(isize, @intCast(dev_cap)), mockSysLseek(true, dev_cap, &cur_off, @intCast(dev_cap), SEEK_SET));
    try std.testing.expectEqual(dev_cap, cur_off);

    // 3.2 SEEK_SET invalid cases: negative offsets must return -EINVAL
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, -1, SEEK_SET));
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, -99999, SEEK_SET));

    // 3.3 SEEK_SET invalid cases: seeking past capacity must return -EINVAL
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, @as(i64, @intCast(dev_cap)) + 1, SEEK_SET));
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, @as(i64, @intCast(dev_cap)) + 5000, SEEK_SET));

    // 3.4 SEEK_CUR cases
    cur_off = 1000;
    try std.testing.expectEqual(@as(isize, 1500), mockSysLseek(true, dev_cap, &cur_off, 500, SEEK_CUR));
    try std.testing.expectEqual(@as(usize, 1500), cur_off);

    try std.testing.expectEqual(@as(isize, 500), mockSysLseek(true, dev_cap, &cur_off, -1000, SEEK_CUR));
    try std.testing.expectEqual(@as(usize, 500), cur_off);

    // SEEK_CUR underflow below 0 returns -EINVAL
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, -501, SEEK_CUR));
    try std.testing.expectEqual(@as(usize, 500), cur_off); // Offset unchanged on error

    // SEEK_CUR to exact capacity succeeds
    cur_off = dev_cap - 100;
    try std.testing.expectEqual(@as(isize, @intCast(dev_cap)), mockSysLseek(true, dev_cap, &cur_off, 100, SEEK_CUR));

    // SEEK_CUR past capacity returns -EINVAL
    cur_off = dev_cap - 100;
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, 101, SEEK_CUR));

    // 3.5 SEEK_END cases
    // SEEK_END with 0 returns capacity (EOF)
    try std.testing.expectEqual(@as(isize, @intCast(dev_cap)), mockSysLseek(true, dev_cap, &cur_off, 0, SEEK_END));
    try std.testing.expectEqual(dev_cap, cur_off);

    // SEEK_END with negative offset within bounds
    try std.testing.expectEqual(@as(isize, @intCast(dev_cap - 512)), mockSysLseek(true, dev_cap, &cur_off, -512, SEEK_END));
    try std.testing.expectEqual(dev_cap - 512, cur_off);

    // SEEK_END to 0 (offset = -dev_cap)
    try std.testing.expectEqual(@as(isize, 0), mockSysLseek(true, dev_cap, &cur_off, -@as(i64, @intCast(dev_cap)), SEEK_END));
    try std.testing.expectEqual(@as(usize, 0), cur_off);

    // SEEK_END underflow below 0 returns -EINVAL
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, -@as(i64, @intCast(dev_cap)) - 1, SEEK_END));

    // SEEK_END past capacity (positive offset) returns -EINVAL
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, 1, SEEK_END));

    // 3.6 Invalid whence values
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, 0, 3));
    try std.testing.expectEqual(-EINVAL, mockSysLseek(true, dev_cap, &cur_off, 0, 99));

    // 3.7 Invalid file descriptor
    try std.testing.expectEqual(-EBADF, mockSysLseek(false, dev_cap, &cur_off, 0, SEEK_SET));
}

// ============================================================================
// 4. Challenge Directive 4: /proc/partitions Formatting and Dynamic Sizing
// ============================================================================
test "Challenge 4: /proc/partitions formatting and dynamic sizing" {
    var buf: [128]u8 = undefined;

    // 4.1 Standard 1 MiB disk (1024 KiB = 1024 blocks)
    const out_1m = formatProcPartitions(1024 * 1024, &buf);
    const expected_1m = "major minor  #blocks  name\n 254        0       1024 vda\n";
    try std.testing.expectEqualStrings(expected_1m, out_1m);

    // 4.2 2 MiB disk (2048 blocks)
    const out_2m = formatProcPartitions(2 * 1024 * 1024, &buf);
    const expected_2m = "major minor  #blocks  name\n 254        0       2048 vda\n";
    try std.testing.expectEqualStrings(expected_2m, out_2m);

    // 4.3 16 MiB disk (16384 blocks)
    const out_16m = formatProcPartitions(16 * 1024 * 1024, &buf);
    const expected_16m = "major minor  #blocks  name\n 254        0       16384 vda\n";
    try std.testing.expectEqualStrings(expected_16m, out_16m);

    // 4.4 1 GiB disk (1048576 blocks)
    const out_1g = formatProcPartitions(1024 * 1024 * 1024, &buf);
    const expected_1g = "major minor  #blocks  name\n 254        0       1048576 vda\n";
    try std.testing.expectEqualStrings(expected_1g, out_1g);

    // 4.5 0-byte capacity
    const out_0 = formatProcPartitions(0, &buf);
    const expected_0 = "major minor  #blocks  name\n 254        0       0 vda\n";
    try std.testing.expectEqualStrings(expected_0, out_0);
}
