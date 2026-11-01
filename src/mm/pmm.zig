const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const TOTAL_RAM_BYTES: usize = 128 * 1024 * 1024; // 128 MiB
pub const TOTAL_PAGES: usize = TOTAL_RAM_BYTES / PAGE_SIZE; // 32,768 pages
pub const BITMAP_SIZE: usize = TOTAL_PAGES / 8; // 4,096 bytes

extern const __kernel_start: u8;
extern const __kernel_end: u8;

var bitmap: [BITMAP_SIZE]u8 align(64) = [_]u8{0xFF} ** BITMAP_SIZE;
var free_pages_count: usize = 0;

pub fn init() void {
    @memset(&bitmap, 0xFF);
    const kernel_end_phys = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), PAGE_SIZE);
    const start_page = kernel_end_phys / PAGE_SIZE;
    std.debug.assert(start_page < TOTAL_PAGES);

    for (start_page..TOTAL_PAGES) |p| {
        const byte_idx = p / 8;
        const bit: u3 = @intCast(p % 8);
        bitmap[byte_idx] &= ~(@as(u8, 1) << bit);
    }
    free_pages_count = TOTAL_PAGES - start_page;
    std.debug.assert(free_pages_count >= 30000);
}

pub fn allocPage() ?usize {
    for (&bitmap, 0..) |*byte, byte_idx| {
        if (byte.* != 0xFF) {
            const bit: u3 = @intCast(@ctz(~byte.*));
            const page_idx = byte_idx * 8 + bit;
            if (page_idx >= TOTAL_PAGES) return null;
            byte.* |= (@as(u8, 1) << bit);
            if (free_pages_count > 0) {
                free_pages_count -= 1;
            }
            return page_idx * PAGE_SIZE;
        }
    }
    return null;
}

pub fn allocZeroedPage() ?usize {
    const addr = allocPage() orelse return null;
    const slice = @as([*]u8, @ptrFromInt(addr))[0..PAGE_SIZE];
    @memset(slice, 0);
    return addr;
}

pub fn freePage(phys_addr: usize) void {
    std.debug.assert(phys_addr % PAGE_SIZE == 0);
    std.debug.assert(phys_addr < TOTAL_RAM_BYTES);

    const page_idx = phys_addr / PAGE_SIZE;
    const byte_idx = page_idx / 8;
    const bit: u3 = @intCast(page_idx % 8);
    const mask = @as(u8, 1) << bit;

    std.debug.assert((bitmap[byte_idx] & mask) != 0);
    bitmap[byte_idx] &= ~mask;
    free_pages_count += 1;
}

pub fn getFreePageCount() usize {
    return free_pages_count;
}

pub fn getTotalPageCount() usize {
    return TOTAL_PAGES;
}
