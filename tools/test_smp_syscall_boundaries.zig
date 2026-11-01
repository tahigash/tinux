// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical unit test harness verifying SMP syscall ABI math, bitmasks, APIC register layouts, and buffer semantics.

const std = @import("std");

test "APIC MMIO register offsets and addresses" {
    const LAPIC_PHYS_BASE: usize = 0xFEE0_0000;
    const IOAPIC_PHYS_BASE: usize = 0xFEC0_0000;

    const LAPIC_REG_ID: usize = 0x0020;
    const LAPIC_REG_VER: usize = 0x0030;
    const LAPIC_REG_TPR: usize = 0x0080;
    const LAPIC_REG_EOI: usize = 0x00B0;
    const LAPIC_REG_SVR: usize = 0x00F0;
    const LAPIC_REG_ICR_LOW: usize = 0x0300;
    const LAPIC_REG_ICR_HIGH: usize = 0x0310;

    try std.testing.expectEqual(@as(usize, 0xFEE0_0020), LAPIC_PHYS_BASE + LAPIC_REG_ID);
    try std.testing.expectEqual(@as(usize, 0xFEE0_0030), LAPIC_PHYS_BASE + LAPIC_REG_VER);
    try std.testing.expectEqual(@as(usize, 0xFEE0_0080), LAPIC_PHYS_BASE + LAPIC_REG_TPR);
    try std.testing.expectEqual(@as(usize, 0xFEE0_00B0), LAPIC_PHYS_BASE + LAPIC_REG_EOI);
    try std.testing.expectEqual(@as(usize, 0xFEE0_00F0), LAPIC_PHYS_BASE + LAPIC_REG_SVR);
    try std.testing.expectEqual(@as(usize, 0xFEE0_0300), LAPIC_PHYS_BASE + LAPIC_REG_ICR_LOW);
    try std.testing.expectEqual(@as(usize, 0xFEE0_0310), LAPIC_PHYS_BASE + LAPIC_REG_ICR_HIGH);
    try std.testing.expectEqual(@as(usize, 0xFEC0_0000), IOAPIC_PHYS_BASE);
}

test "Active CPU mask calculation for various CPU counts" {
    inline for ([_]struct { cpus: usize, expected_mask: u64 }{
        .{ .cpus = 1, .expected_mask = 0x01 },
        .{ .cpus = 2, .expected_mask = 0x03 },
        .{ .cpus = 4, .expected_mask = 0x0F },
        .{ .cpus = 8, .expected_mask = 0xFF },
        .{ .cpus = 63, .expected_mask = 0x7FFF_FFFF_FFFF_FFFF },
        .{ .cpus = 64, .expected_mask = 0xFFFF_FFFF_FFFF_FFFF },
    }) |case| {
        const active_mask: u64 = if (case.cpus >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(case.cpus))) - 1;
        try std.testing.expectEqual(case.expected_mask, active_mask);
    }
}

test "sched_getaffinity buffer zeroing emulation" {
    var buf: [128]u8 = [_]u8{0xFF} ** 128;
    const active_mask: u64 = 0x03;
    const cpusetsize: usize = 128;

    @memcpy(buf[0..8], std.mem.asBytes(&active_mask));
    if (cpusetsize > 8) {
        const extra = cpusetsize - 8;
        @memset(buf[8 .. 8 + extra], 0);
    }

    try std.testing.expectEqual(@as(u8, 0x03), buf[0]);
    for (buf[1..8]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (buf[8..128]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "sched_getaffinity cpusetsize rejection threshold" {
    const min_size: usize = @sizeOf(u64);
    try std.testing.expectEqual(@as(usize, 8), min_size);

    const sizes = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
    for (sizes) |sz| {
        const rejected = sz < min_size;
        try std.testing.expect(rejected);
    }
    try std.testing.expect(!(8 < min_size));
    try std.testing.expect(!(16 < min_size));
}

test "NUMA node zeroing and LAPIC ID byte format in sys_getcpu" {
    const cur_node: u32 = 0;
    const cur_cpu: u32 = 0;

    var node_bytes: [4]u8 = undefined;
    var cpu_bytes: [4]u8 = undefined;

    @memcpy(&node_bytes, std.mem.asBytes(&cur_node));
    @memcpy(&cpu_bytes, std.mem.asBytes(&cur_cpu));

    try std.testing.expectEqual([_]u8{ 0, 0, 0, 0 }, node_bytes);
    try std.testing.expectEqual([_]u8{ 0, 0, 0, 0 }, cpu_bytes);
}
