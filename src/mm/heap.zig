const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

pub const KERNEL_HEAP_START: usize = 0x1000_0000;
pub const KERNEL_HEAP_INITIAL_PAGES: usize = 64; // 256 KiB
pub const KERNEL_HEAP_SIZE: usize = KERNEL_HEAP_INITIAL_PAGES * pmm.PAGE_SIZE;

const BlockHeader = struct {
    size: usize, // Total size of payload following this header
    is_free: bool,
    next: ?*BlockHeader,
};

const HEADER_SIZE: usize = @sizeOf(BlockHeader);

var head_block: ?*BlockHeader = null;

pub fn init() void {
    const pml4 = vmm.getKernelPml4Phys();
    var i: usize = 0;
    while (i < KERNEL_HEAP_INITIAL_PAGES) : (i += 1) {
        const phys = pmm.allocZeroedPage() orelse @panic("Heap: out of physical pages");
        const vaddr = KERNEL_HEAP_START + (i * pmm.PAGE_SIZE);
        if (!vmm.mapPage(pml4, vaddr, phys, vmm.PTE_PRESENT | vmm.PTE_WRITABLE)) {
            @panic("Heap: failed to map heap page");
        }
    }

    const first = @as(*BlockHeader, @ptrFromInt(KERNEL_HEAP_START));
    first.* = .{
        .size = KERNEL_HEAP_SIZE - HEADER_SIZE,
        .is_free = true,
        .next = null,
    };
    head_block = first;
}

fn coalesceFreeBlocks() void {
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

pub fn rawAlloc(len: usize, alignment: usize) ?[*]u8 {
    if (len == 0) return null;
    const eff_align = @max(alignment, @alignOf(BlockHeader));
    const aligned_len = std.mem.alignForward(usize, len, @alignOf(BlockHeader));

    var curr = head_block;
    while (curr) |block| : (curr = block.next) {
        if (!block.is_free) continue;

        const payload_start = @intFromPtr(block) + HEADER_SIZE;
        const aligned_start = std.mem.alignForward(usize, payload_start, eff_align);
        const align_pad = aligned_start - payload_start;

        if (block.size < align_pad + aligned_len) continue;

        // If alignment padding is large enough to hold a BlockHeader, split front pad
        if (align_pad >= HEADER_SIZE + 16) {
            const new_blk_addr = aligned_start - HEADER_SIZE;
            const new_blk = @as(*BlockHeader, @ptrFromInt(new_blk_addr));
            new_blk.* = .{
                .size = block.size - align_pad,
                .is_free = true,
                .next = block.next,
            };
            block.size = align_pad - HEADER_SIZE;
            block.next = new_blk;
            return rawAlloc(len, alignment);
        }

        if (align_pad == 0) {
            const remaining = block.size - aligned_len;
            if (remaining >= HEADER_SIZE + 16) {
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

pub fn rawFree(ptr: [*]u8) void {
    const addr = @intFromPtr(ptr);
    if (addr < KERNEL_HEAP_START + HEADER_SIZE or addr >= KERNEL_HEAP_START + KERNEL_HEAP_SIZE) return;
    const block = @as(*BlockHeader, @ptrFromInt(addr - HEADER_SIZE));
    block.is_free = true;
    coalesceFreeBlocks();
}

const AlignParamType = u8;

inline fn alignParamToBytes(a: AlignParamType) usize {
    return @as(usize, 1) << @intCast(a);
}

fn vtableAlloc(_: *anyopaque, len: usize, alignment: AlignParamType, _: usize) ?[*]u8 {
    return rawAlloc(len, alignParamToBytes(alignment));
}

fn vtableResize(_: *anyopaque, buf: []u8, _: AlignParamType, new_len: usize, _: usize) bool {
    const addr = @intFromPtr(buf.ptr);
    if (addr < KERNEL_HEAP_START + HEADER_SIZE) return false;
    const block = @as(*BlockHeader, @ptrFromInt(addr - HEADER_SIZE));
    return new_len <= block.size;
}

fn vtableFree(_: *anyopaque, buf: []u8, _: AlignParamType, _: usize) void {
    rawFree(buf.ptr);
}

var dummy_state: u8 = 0;

const heap_vtable: std.mem.Allocator.VTable = if (@hasField(std.mem.Allocator.VTable, "remap")) .{
    .alloc = vtableAlloc,
    .resize = vtableResize,
    .remap = std.mem.Allocator.noRemap,
    .free = vtableFree,
} else .{
    .alloc = vtableAlloc,
    .resize = vtableResize,
    .free = vtableFree,
};

pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = @ptrCast(&dummy_state),
        .vtable = &heap_vtable,
    };
}
