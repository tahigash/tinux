// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical Challenger 1 adversarial test suite for TASK-015:
// Virtqueue DMA Integrity, Multi-Cycle Stress, and Host Disk Persistence

const std = @import("std");

pub const SYS_READ: usize = 0;
pub const SYS_WRITE: usize = 1;
pub const SYS_OPEN: usize = 2;
pub const SYS_CLOSE: usize = 3;
pub const SYS_LSEEK: usize = 8;
pub const SYS_SYNC: usize = 162;
pub const SYS_EXIT_GROUP: usize = 231;

pub const O_RDWR: usize = 2;
pub const SEEK_SET: usize = 0;
pub const SECTOR_SIZE: usize = 512;

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challenger1Main
    );
}

inline fn sys0(num: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
        : "rcx", "r11", "memory"
    );
}

inline fn sys1(num: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
        : "rcx", "r11", "memory"
    );
}

inline fn sys3(num: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}

fn puts(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn assertOrHalt(cond: bool, msg: []const u8) void {
    if (!cond) {
        puts("[CHALLENGER1_ASSERT_FAIL] ");
        puts(msg);
        puts("\n");
        _ = sys1(SYS_EXIT_GROUP, 1);
        unreachable;
    }
}

export fn challenger1Main() noreturn {
    puts("[CHALLENGER_M15_1] Starting empirical stress test for VirtIO-Block DMA...\n");

    const fd = sys3(SYS_OPEN, @intFromPtr("/dev/vda\x00"), O_RDWR, 0);
    assertOrHalt(fd >= 0, "Failed to open /dev/vda with O_RDWR");
    const vda_fd: usize = @intCast(fd);

    // ------------------------------------------------------------------------
    // Test 1: Verify Host-Seeded Sector 0 Content
    // ------------------------------------------------------------------------
    puts("[CHALLENGE_1_1] Verifying host-provisioned seed string in Sector 0...\n");
    {
        var sec0: [SECTOR_SIZE]u8 = undefined;
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 0, SEEK_SET) == 0, "LSEEK to 0 failed");
        const n0 = sys3(SYS_READ, vda_fd, @intFromPtr(&sec0), SECTOR_SIZE);
        assertOrHalt(n0 == SECTOR_SIZE, "Failed reading 512 bytes from Sector 0");

        const expected_seed = "[TINUX_DISK_SECTOR0] Host-provisioned VirtIO-Block image ready!\n";
        assertOrHalt(std.mem.startsWith(u8, sec0[0..expected_seed.len], expected_seed), "Sector 0 seed mismatch");
        puts("[CHALLENGE_1_1] PASS: Host-provisioned seed string verified in Sector 0!\n");
    }

    // ------------------------------------------------------------------------
    // Test 2: Single-Sector Write and Readback DMA Integrity (Sector 1)
    // ------------------------------------------------------------------------
    puts("[CHALLENGE_1_2] Testing single-sector DMA write and verified readback...\n");
    {
        var pattern: [SECTOR_SIZE]u8 = undefined;
        for (&pattern, 0..) |*b, idx| {
            b.* = @truncate((idx * 13 + 37) & 0xFF);
        }

        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 512, SEEK_SET) == 512, "LSEEK to 512 failed");
        const nw = sys3(SYS_WRITE, vda_fd, @intFromPtr(&pattern), SECTOR_SIZE);
        assertOrHalt(nw == SECTOR_SIZE, "Failed writing Sector 1");

        assertOrHalt(sys0(SYS_SYNC) == 0, "sys_sync failed");

        var readback: [SECTOR_SIZE]u8 = undefined;
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 512, SEEK_SET) == 512, "LSEEK back to 512 failed");
        const nr = sys3(SYS_READ, vda_fd, @intFromPtr(&readback), SECTOR_SIZE);
        assertOrHalt(nr == SECTOR_SIZE, "Failed reading back Sector 1");

        for (pattern, 0..) |expected, i| {
            assertOrHalt(readback[i] == expected, "Sector 1 byte mismatch in readback");
        }
        puts("[CHALLENGE_1_2] PASS: Sector 1 single-sector DMA readback verified bit-for-bit!\n");
    }

    // ------------------------------------------------------------------------
    // Test 3: Multi-Cycle Split Virtqueue DMA Stress Test (50 Sequential Sectors)
    // ------------------------------------------------------------------------
    puts("[CHALLENGE_1_3] Stress-testing split virtqueue DMA across 50 sectors (Sectors 10..59)...\n");
    {
        var sector_buf: [SECTOR_SIZE]u8 = undefined;

        // Write 50 sectors with distinct seed per sector
        for (10..60) |sec| {
            const sec_offset = sec * SECTOR_SIZE;
            for (&sector_buf, 0..) |*b, idx| {
                b.* = @truncate(((sec * 17) + (idx * 3)) & 0xFF);
            }
            assertOrHalt(sys3(SYS_LSEEK, vda_fd, sec_offset, SEEK_SET) == @as(isize, @intCast(sec_offset)), "LSEEK failed during stress write");
            const w = sys3(SYS_WRITE, vda_fd, @intFromPtr(&sector_buf), SECTOR_SIZE);
            assertOrHalt(w == SECTOR_SIZE, "Sector write failed during stress write");
        }

        assertOrHalt(sys0(SYS_SYNC) == 0, "sys_sync failed after stress write");

        // Read back all 50 sectors and verify
        for (10..60) |sec| {
            const sec_offset = sec * SECTOR_SIZE;
            assertOrHalt(sys3(SYS_LSEEK, vda_fd, sec_offset, SEEK_SET) == @as(isize, @intCast(sec_offset)), "LSEEK failed during stress read");
            const r = sys3(SYS_READ, vda_fd, @intFromPtr(&sector_buf), SECTOR_SIZE);
            assertOrHalt(r == SECTOR_SIZE, "Sector read failed during stress read");

            for (0..SECTOR_SIZE) |idx| {
                const expected: u8 = @truncate(((sec * 17) + (idx * 3)) & 0xFF);
                assertOrHalt(sector_buf[idx] == expected, "Stress readback byte corruption detected");
            }
        }
        puts("[CHALLENGE_1_3] PASS: 50-sector virtqueue DMA stress test completed with zero errors!\n");
    }

    // ------------------------------------------------------------------------
    // Test 4: Write Host Persistence Verification Tokens to Sector 0
    // ------------------------------------------------------------------------
    puts("[CHALLENGE_1_4] Committing Sector 0 persistence tokens to disk image...\n");
    {
        // Token 1 at offset 0 (41 bytes)
        const tok0 = "TINUX_PERSISTENCE_VERIFIED_ON_VIRTIO_BLK\n";
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 0, SEEK_SET) == 0, "LSEEK to 0 failed");
        const w0 = sys3(SYS_WRITE, vda_fd, @intFromPtr(tok0.ptr), tok0.len);
        assertOrHalt(w0 == @as(isize, @intCast(tok0.len)), "Writing persistence token 0 failed");

        // Token 2 at offset 128 (45 bytes)
        const tok1 = "CHALLENGER_M15_1_PERSISTENCE_SECTOR0_VERIFIED\n";
        assertOrHalt(sys3(SYS_LSEEK, vda_fd, 128, SEEK_SET) == 128, "LSEEK to 128 failed");
        const w1 = sys3(SYS_WRITE, vda_fd, @intFromPtr(tok1.ptr), tok1.len);
        assertOrHalt(w1 == @as(isize, @intCast(tok1.len)), "Writing persistence token 1 failed");

        assertOrHalt(sys0(SYS_SYNC) == 0, "sys_sync failed after persistence token write");
        puts("[CHALLENGE_1_4] PASS: Persistence tokens committed!\n");
    }

    _ = sys1(SYS_CLOSE, vda_fd);
    _ = sys0(SYS_SYNC);

    puts("[CHALLENGER_M15_1] ALL EMPIRICAL CHALLENGES PASSED!\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}
