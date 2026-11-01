const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const TOTAL_RAM_BYTES: usize = 128 * 1024 * 1024; // 128 MiB QEMU memory
pub const TOTAL_PAGES: usize = TOTAL_RAM_BYTES / PAGE_SIZE;

// 128 MiB = 32768 pages. A bitmap of 32768 bits = 4096 bytes (1 page).
var bitmap: [TOTAL_PAGES / 64]u64 = [_]u64{0} ** (TOTAL_PAGES / 64);
var free_pages: usize = TOTAL_PAGES;

pub fn init() void {
    // Reserve lower 16 MiB (first 4096 pages) for kernel, BIOS, GDT, IDT, page tables
    const reserved_pages = (16 * 1024 * 1024) / PAGE_SIZE;
    for (0..reserved_pages) |i| {
        markAllocated(i);
    }
}

inline fn markAllocated(page_idx: usize) void {
    const word = page_idx / 64;
    const bit: u6 = @truncate(page_idx % 64);
    if ((bitmap[word] & (@as(u64, 1) << bit)) == 0) {
        bitmap[word] |= (@as(u64, 1) << bit);
        if (free_pages > 0) free_pages -= 1;
    }
}

inline fn markFree(page_idx: usize) void {
    const word = page_idx / 64;
    const bit: u6 = @truncate(page_idx % 64);
    if ((bitmap[word] & (@as(u64, 1) << bit)) != 0) {
        bitmap[word] &= ~(@as(u64, 1) << bit);
        free_pages += 1;
    }
}

pub fn allocPage() ?usize {
    for (&bitmap, 0..) |*word, w_idx| {
        if (word.* != std.math.maxInt(u64)) {
            const bit = @ctz(~word.*);
            const page_idx = w_idx * 64 + bit;
            if (page_idx >= TOTAL_PAGES) return null;
            word.* |= (@as(u64, 1) << @as(u6, @truncate(bit)));
            if (free_pages > 0) free_pages -= 1;
            return page_idx * PAGE_SIZE;
        }
    }
    return null;
}

pub fn allocZeroedPage() ?usize {
    const paddr = allocPage() orelse return null;
    const ptr = @as([*]u8, @ptrFromInt(paddr));
    @memset(ptr[0..PAGE_SIZE], 0);
    return paddr;
}

pub fn freePage(paddr: usize) void {
    const page_idx = paddr / PAGE_SIZE;
    if (page_idx < TOTAL_PAGES) {
        markFree(page_idx);
    }
}

pub fn getFreePageCount() usize {
    return free_pages;
}

pub fn getTotalPageCount() usize {
    return TOTAL_PAGES;
}
