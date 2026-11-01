const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

pub const KERNEL_HEAP_START: usize = 0x1000_0000;
pub const KERNEL_HEAP_INITIAL_PAGES: usize = 64; // 256 KiB
pub const KERNEL_HEAP_INITIAL_SIZE: usize = KERNEL_HEAP_INITIAL_PAGES * vmm.PAGE_SIZE;
pub const KERNEL_HEAP_SIZE: usize = KERNEL_HEAP_INITIAL_SIZE;

const BlockHeader = struct {
    size: usize, // Total size of payload following this header
    is_free: bool,
    next: ?*BlockHeader,
};

const HEADER_SIZE: usize = std.mem.alignForward(usize, @sizeOf(BlockHeader), 16);

var head_block: ?*BlockHeader = null;

pub fn init() void {
    const pml4 = vmm.getKernelPml4Phys();
    var i: usize = 0;
    while (i < KERNEL_HEAP_INITIAL_PAGES) : (i += 1) {
        const phys = pmm.allocZeroedPage() orelse @panic("Heap: out of physical pages");
        const vaddr = KERNEL_HEAP_START + (i * vmm.PAGE_SIZE);
        if (!vmm.mapPage(pml4, vaddr, phys, vmm.PTE_PRESENT | vmm.PTE_WRITABLE)) {
            @panic("Heap: failed to map heap page");
        }
    }

    const first = @as(*BlockHeader, @ptrFromInt(KERNEL_HEAP_START));
    first.* = .{
        .size = KERNEL_HEAP_INITIAL_SIZE - HEADER_SIZE,
        .is_free = true,
        .next = null,
    };
    head_block = first;
}

pub fn coalesceFreeBlocks() void {
    var curr = head_block;
    while (curr) |block| {
        if (block.is_free) {
            if (block.next) |next_blk| {
                const expected_next_addr = @intFromPtr(block) + HEADER_SIZE + block.size;
                if (next_blk.is_free and @intFromPtr(next_blk) == expected_next_addr) {
                    block.size += HEADER_SIZE + next_blk.size;
                    block.next = next_blk.next;
                    continue;
                }
            }
        }
        curr = block.next;
    }
}

pub fn kmallocAligned(size: usize, alignment: usize) ?[*]u8 {
    if (size == 0) return null;
    const eff_align = @max(alignment, 16);
    const aligned_len = std.mem.alignForward(usize, @max(size, 16), 16);

    var curr = head_block;
    while (curr) |block| : (curr = block.next) {
        if (!block.is_free) continue;

        const payload_start = @intFromPtr(block) + HEADER_SIZE;
        const aligned_start = std.mem.alignForward(usize, payload_start, eff_align);
        const align_pad = aligned_start - payload_start;

        if (block.size < align_pad + aligned_len) continue;

        if (align_pad >= HEADER_SIZE + 32) {
            // Split front padding into a separate free block
            const new_blk_addr = aligned_start - HEADER_SIZE;
            const new_blk = @as(*BlockHeader, @ptrFromInt(new_blk_addr));
            new_blk.* = .{
                .size = block.size - align_pad,
                .is_free = true,
                .next = block.next,
            };
            block.size = align_pad - HEADER_SIZE;
            block.next = new_blk;

            // Tail split on new_blk if space permits
            const rem_new = new_blk.size - aligned_len;
            if (rem_new >= HEADER_SIZE + 32) {
                const split_addr = aligned_start + aligned_len;
                const split_blk = @as(*BlockHeader, @ptrFromInt(split_addr));
                split_blk.* = .{
                    .size = rem_new - HEADER_SIZE,
                    .is_free = true,
                    .next = new_blk.next,
                };
                new_blk.size = aligned_len;
                new_blk.next = split_blk;
            }
            new_blk.is_free = false;
            return @as([*]u8, @ptrFromInt(aligned_start));
        }

        if (align_pad == 0) {
            const remaining = block.size - aligned_len;
            if (remaining >= HEADER_SIZE + 32) {
                const split_addr = payload_start + aligned_len;
                const split_blk = @as(*BlockHeader, @ptrFromInt(split_addr));
                split_blk.* = .{
                    .size = remaining - HEADER_SIZE,
                    .is_free = true,
                    .next = block.next,
                };
                block.size = aligned_len;
                block.next = split_blk;
            }
            block.is_free = false;
            return @as([*]u8, @ptrFromInt(payload_start));
        }
    }
    return null;
}

pub fn kfree(ptr: [*]u8) void {
    const addr = @intFromPtr(ptr);
    if (addr < KERNEL_HEAP_START + HEADER_SIZE or addr >= KERNEL_HEAP_START + KERNEL_HEAP_INITIAL_SIZE) return;
    const block = @as(*BlockHeader, @ptrFromInt(addr - HEADER_SIZE));
    block.is_free = true;
    coalesceFreeBlocks();
}

pub const rawAlloc = kmallocAligned;
pub const rawFree = kfree;

// --- Comptime Bridge for Zig 0.13 / 0.14 / 0.15+ std.mem.Allocator.VTable ---
const has_remap = @hasField(std.mem.Allocator.VTable, "remap");
const AlignParam = if (@hasDecl(std.mem, "Alignment")) std.mem.Alignment else u8;

fn allocFn(_: *anyopaque, len: usize, ptr_align: AlignParam, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const a: usize = if (@TypeOf(ptr_align) == u8)
        (@as(usize, 1) << @as(u6, @truncate(ptr_align)))
    else
        ptr_align.toByteUnits();
    return kmallocAligned(len, a);
}

fn resizeFn(_: *anyopaque, buf: []u8, buf_align: AlignParam, new_len: usize, ret_addr: usize) bool {
    _ = buf; _ = buf_align; _ = new_len; _ = ret_addr;
    return false;
}

fn freeFn(_: *anyopaque, buf: []u8, buf_align: AlignParam, ret_addr: usize) void {
    _ = buf_align; _ = ret_addr;
    kfree(buf.ptr);
}

fn remapFn(_: *anyopaque, memory: []u8, alignment: AlignParam, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = memory; _ = alignment; _ = new_len; _ = ret_addr;
    return null;
}

const heap_vtable: std.mem.Allocator.VTable = if (has_remap) .{
    .alloc = allocFn,
    .resize = resizeFn,
    .remap = remapFn,
    .free = freeFn,
} else .{
    .alloc = allocFn,
    .resize = resizeFn,
    .free = freeFn,
};

var dummy_state: u8 = 0;

pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = @ptrCast(&dummy_state),
        .vtable = &heap_vtable,
    };
}
