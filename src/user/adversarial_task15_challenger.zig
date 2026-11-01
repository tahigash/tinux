// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Comprehensive empirical adversarial challenge suite for TASK-015:
// VirtIO-Block DMA Driver, VFS /dev/vda integration, and syscall edge cases

const std = @import("std");

pub const SYS_READ: usize = 0;
pub const SYS_WRITE: usize = 1;
pub const SYS_OPEN: usize = 2;
pub const SYS_CLOSE: usize = 3;
pub const SYS_FSTAT: usize = 5;
pub const SYS_LSEEK: usize = 8;
pub const SYS_PREAD64: usize = 17;
pub const SYS_SYNC: usize = 162;
pub const SYS_EXIT: usize = 60;
pub const SYS_EXIT_GROUP: usize = 231;

pub const O_RDONLY: usize = 0;
pub const O_WRONLY: usize = 1;
pub const O_RDWR: usize = 2;

pub const SEEK_SET: usize = 0;
pub const SEEK_CUR: usize = 1;
pub const SEEK_END: usize = 2;

pub const EINVAL: isize = -22;
pub const EBADF: isize = -9;

pub const SECTOR_SIZE: usize = 512;
pub const DEV_CAPACITY: usize = 1024 * 1024; // 1 MiB

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

inline fn sys0(n: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n) : "rcx", "r11", "memory");
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1) : "rcx", "r11", "memory");
}

inline fn sys2(n: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2) : "rcx", "r11", "memory");
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3) : "rcx", "r11", "memory");
}

inline fn sys4(n: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3), [d] "{r10}" (a4) : "rcx", "r11", "memory");
}

fn puts(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn assertOrHalt(cond: bool, msg: []const u8) void {
    if (!cond) {
        puts("[CHALLENGER_ASSERT_FAIL] ");
        puts(msg);
        puts("\n");
        _ = sys1(SYS_EXIT_GROUP, 1);
        unreachable;
    }
}

export fn challengerMain() callconv(.C) noreturn {
    puts("[CHALLENGER_M15_2] Starting empirical adversarial suite for TASK-015...\n");

    const fd = sys3(SYS_OPEN, @intFromPtr("/dev/vda\x00"), O_RDWR, 0);
    assertOrHalt(fd >= 0, "Failed to open /dev/vda with O_RDWR");
    const vda_fd: usize = @intCast(fd);

    // ========================================================================
    // Directive 1: Challenge Unaligned and Multi-Sector Reads
    // ========================================================================
    puts("[CHALLENGE_1] Testing unaligned and multi-sector reads...\n");
    {
        // First, write a deterministic 4-sector test pattern at offset 2048 (Sector 4..7)
        var write_pattern: [2048]u8 = undefined;
        for (&write_pattern, 0..) |*b, idx| {
            b.* = @truncate((idx * 17 + 5) & 0xFF);
        }
        const seek_init = sys3(SYS_LSEEK, vda_fd, 2048, SEEK_SET);
        assertOrHalt(seek_init == 2048, "SEEK_SET to 2048 failed");
        const written = sys3(SYS_WRITE, vda_fd, @intFromPtr(&write_pattern), write_pattern.len);
        assertOrHalt(written == 2048, "Writing 4-sector test pattern failed");

        // 1.1 Read unaligned 23 bytes at offset 2048 + 17 via sys_pread64
        var unaligned_buf: [23]u8 = undefined;
        const pread_res = sys4(SYS_PREAD64, vda_fd, @intFromPtr(&unaligned_buf), unaligned_buf.len, 2048 + 17);
        assertOrHalt(pread_res == 23, "sys_pread64 unaligned read returned incorrect count");
        for (unaligned_buf, 0..) |b, i| {
            assertOrHalt(b == write_pattern[17 + i], "sys_pread64 unaligned byte mismatch");
        }

        // 1.2 Read 600 bytes spanning across sector boundary (offset 2048 + 450 to 2048 + 1050) via lseek + read
        const seek_mid = sys3(SYS_LSEEK, vda_fd, 2048 + 450, SEEK_SET);
        assertOrHalt(seek_mid == 2048 + 450, "SEEK_SET to unaligned offset failed");
        var span_buf: [600]u8 = undefined;
        const read_res = sys3(SYS_READ, vda_fd, @intFromPtr(&span_buf), span_buf.len);
        assertOrHalt(read_res == 600, "Multi-sector read returned incorrect count");
        for (span_buf, 0..) |b, i| {
            assertOrHalt(b == write_pattern[450 + i], "Multi-sector read byte mismatch across sector boundary");
        }

        // 1.3 Boundary read at capacity edge: seek to capacity - 10, request 50 bytes (must return 10)
        const seek_end = sys3(SYS_LSEEK, vda_fd, DEV_CAPACITY - 10, SEEK_SET);
        assertOrHalt(seek_end == @as(isize, @intCast(DEV_CAPACITY - 10)), "SEEK_SET near capacity failed");
        var edge_buf: [50]u8 = undefined;
        const edge_read = sys3(SYS_READ, vda_fd, @intFromPtr(&edge_buf), edge_buf.len);
        assertOrHalt(edge_read == 10, "Read at capacity edge did not truncate to available bytes");

        // 1.4 Read at exact capacity (must return 0 / EOF)
        const eof_read = sys3(SYS_READ, vda_fd, @intFromPtr(&edge_buf), edge_buf.len);
        assertOrHalt(eof_read == 0, "Read at capacity did not return 0 (EOF)");

        puts("[CHALLENGE_1] PASS: Unaligned and multi-sector reads verified!\n");
    }

    // ========================================================================
    // Directive 2: Challenge Partial-Sector Read-Modify-Write (RMW)
    // ========================================================================
    puts("[CHALLENGE_2] Testing partial-sector Read-Modify-Write (RMW) preservation...\n");
    {
        // 2.1 Prepare Sector 16 (offset 8192) with known background marker 0xBB
        const sec16_off = 16 * SECTOR_SIZE;
        var bg_buf: [SECTOR_SIZE]u8 = undefined;
        @memset(&bg_buf, 0xBB);
        _ = sys3(SYS_LSEEK, vda_fd, sec16_off, SEEK_SET);
        const w_bg = sys3(SYS_WRITE, vda_fd, @intFromPtr(&bg_buf), SECTOR_SIZE);
        assertOrHalt(w_bg == SECTOR_SIZE, "Writing sector 16 background failed");

        // 2.2 Write partial byte range: 10 bytes at sec16_off + 100
        const rmw_payload = "RMW_TEST10";
        _ = sys3(SYS_LSEEK, vda_fd, sec16_off + 100, SEEK_SET);
        const w_rmw = sys3(SYS_WRITE, vda_fd, @intFromPtr(rmw_payload.ptr), rmw_payload.len);
        assertOrHalt(w_rmw == @as(isize, @intCast(rmw_payload.len)), "Partial sector write failed");

        // 2.3 Read back the entire Sector 16 and verify untouched bytes
        var verify_buf: [SECTOR_SIZE]u8 = undefined;
        _ = sys3(SYS_LSEEK, vda_fd, sec16_off, SEEK_SET);
        const r_full = sys3(SYS_READ, vda_fd, @intFromPtr(&verify_buf), SECTOR_SIZE);
        assertOrHalt(r_full == SECTOR_SIZE, "Reading back sector 16 failed");

        // Verify untouched prefix: bytes 0..99 must still be 0xBB
        for (verify_buf[0..100], 0..) |b, idx| {
            _ = idx;
            assertOrHalt(b == 0xBB, "RMW corrupted untouched prefix in sector");
        }
        // Verify modified slice: bytes 100..109 must match rmw_payload
        for (verify_buf[100..110], 0..) |b, idx| {
            assertOrHalt(b == rmw_payload[idx], "RMW modified payload mismatch");
        }
        // Verify untouched suffix: bytes 110..511 must still be 0xBB
        for (verify_buf[110..512], 0..) |b, idx| {
            _ = idx;
            assertOrHalt(b == 0xBB, "RMW corrupted untouched suffix in sector");
        }

        puts("[CHALLENGE_2] PASS: Partial-sector RMW byte preservation verified!\n");
    }

    // ========================================================================
    // Directive 3: Challenge sys_lseek Edge Cases
    // ========================================================================
    puts("[CHALLENGE_3] Testing sys_lseek edge cases for .BLKDEV...\n");
    {
        // 3.1 SEEK_SET
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 0, SEEK_SET) == 0, "lseek SEEK_SET to 0 failed");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 512, SEEK_SET) == 512, "lseek SEEK_SET to 512 failed");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, DEV_CAPACITY, SEEK_SET) == @as(isize, @intCast(DEV_CAPACITY)), "lseek SEEK_SET to capacity failed");
        // Negative offset must return -EINVAL
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, @bitCast(@as(usize, 0xFFFF_FFFF_FFFF_FFFF)), SEEK_SET) == EINVAL, "lseek SEEK_SET with -1 did not return -EINVAL");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, @bitCast(@as(usize, 0xFFFF_FFFF_FFFF_FC00)), SEEK_SET) == EINVAL, "lseek SEEK_SET negative did not return -EINVAL");
        // Seeking past capacity must return -EINVAL
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, DEV_CAPACITY + 1, SEEK_SET) == EINVAL, "lseek SEEK_SET past capacity did not return -EINVAL");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, DEV_CAPACITY + 65536, SEEK_SET) == EINVAL, "lseek SEEK_SET far past capacity did not return -EINVAL");

        // 3.2 SEEK_CUR
        _ = sys3(SYS_LSEEK, vda_fd, 1000, SEEK_SET);
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 500, SEEK_CUR) == 1500, "lseek SEEK_CUR +500 failed");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, @bitCast(@as(usize, 0xFFFF_FFFF_FFFF_FC18)), SEEK_CUR) == 500, "lseek SEEK_CUR -1000 failed"); // -1000
        // Underflow < 0 must return -EINVAL
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, @bitCast(@as(usize, 0xFFFF_FFFF_FFFF_FDFF)), SEEK_CUR) == EINVAL, "lseek SEEK_CUR underflow below 0 did not return -EINVAL"); // -513
        // SEEK_CUR past capacity must return -EINVAL
        _ = sys3(SYS_LSEEK, vda_fd, DEV_CAPACITY - 100, SEEK_SET);
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 100, SEEK_CUR) == @as(isize, @intCast(DEV_CAPACITY)), "lseek SEEK_CUR to capacity failed");
        _ = sys3(SYS_LSEEK, vda_fd, DEV_CAPACITY - 100, SEEK_SET);
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 101, SEEK_CUR) == EINVAL, "lseek SEEK_CUR past capacity did not return -EINVAL");

        // 3.3 SEEK_END
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 0, SEEK_END) == @as(isize, @intCast(DEV_CAPACITY)), "lseek SEEK_END 0 failed");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, @bitCast(@as(usize, 0xFFFF_FFFF_FFFF_FE00)), SEEK_END) == @as(isize, @intCast(DEV_CAPACITY - 512)), "lseek SEEK_END -512 failed"); // -512
        // Seeking past capacity with positive offset must return -EINVAL
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 1, SEEK_END) == EINVAL, "lseek SEEK_END +1 did not return -EINVAL");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 1024, SEEK_END) == EINVAL, "lseek SEEK_END +1024 did not return -EINVAL");
        // Underflow < 0
        const neg_cap: isize = -@as(isize, @intCast(DEV_CAPACITY));
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, @bitCast(neg_cap), SEEK_END) == 0, "lseek SEEK_END -capacity failed");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, @bitCast(neg_cap - 1), SEEK_END) == EINVAL, "lseek SEEK_END underflow did not return -EINVAL");

        // 3.4 Invalid whence
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 0, 3) == EINVAL, "lseek with whence=3 did not return -EINVAL");
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 0, 99) == EINVAL, "lseek with whence=99 did not return -EINVAL");

        // 3.5 Invalid descriptor
        assertOrHalt(sys3(SYS_LSEEK, 9999, 0, SEEK_SET) == EBADF, "lseek with bad fd did not return -EBADF");

        puts("[CHALLENGE_3] PASS: sys_lseek edge cases verified!\n");
    }

    // ========================================================================
    // Directive 4: Challenge /proc/partitions Formatting and Dynamic Sizing
    // ========================================================================
    puts("[CHALLENGE_4] Testing /proc/partitions formatting...\n");
    {
        const pfd = sys3(SYS_OPEN, @intFromPtr("/proc/partitions\x00"), O_RDONLY, 0);
        assertOrHalt(pfd >= 0, "Failed to open /proc/partitions");
        var part_content: [256]u8 = undefined;
        const n_part = sys3(SYS_READ, @intCast(pfd), @intFromPtr(&part_content), part_content.len);
        assertOrHalt(n_part > 0, "Reading /proc/partitions returned empty");
        _ = sys1(SYS_CLOSE, @intCast(pfd));

        const part_slice = part_content[0..@intCast(n_part)];
        puts("[CHALLENGE_4] /proc/partitions content:\n");
        puts(part_slice);

        // Verify required headers and block count
        assertOrHalt(std.mem.indexOf(u8, part_slice, "major minor  #blocks  name") != null, "Header missing in /proc/partitions");
        assertOrHalt(std.mem.indexOf(u8, part_slice, "254") != null, "Major 254 missing in /proc/partitions");
        assertOrHalt(std.mem.indexOf(u8, part_slice, "1024") != null, "Block count 1024 missing in /proc/partitions");
        assertOrHalt(std.mem.indexOf(u8, part_slice, "vda") != null, "Device name vda missing in /proc/partitions");

        puts("[CHALLENGE_4] PASS: /proc/partitions formatting verified!\n");
    }

    // Close /dev/vda and sync
    _ = sys1(SYS_CLOSE, vda_fd);
    _ = sys0(SYS_SYNC);

    puts("[CHALLENGER_M15_2] ALL EMPIRICAL CHALLENGES PASSED!\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}
