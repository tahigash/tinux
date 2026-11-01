const std = @import("std");
const io = @import("../arch/x86_64/io.zig");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
pub const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
pub const VIRTIO_BLK_DEVICE_ID: u16 = 0x1001;
pub const SECTOR_SIZE: usize = 512;
pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;
pub const VIRTIO_BLK_T_IN: u32 = 0;  // Read from disk
pub const VIRTIO_BLK_T_OUT: u32 = 1; // Write to disk
pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
    comptime {
        std.debug.assert(@sizeOf(VirtqDesc) == 16);
    }
};
pub const VirtioBlkReqHeader = extern struct {
    req_type: u32,
    reserved: u32 = 0,
    sector: u64,
    comptime {
        std.debug.assert(@sizeOf(VirtioBlkReqHeader) == 16);
    }
};
// Physically contiguous 16 KiB buffer in identity-mapped kernel .bss (supports Queue Size up to 256)
var vring_mem: [16384]u8 align(4096) = [_]u8{0} ** 16384;
var dma_req_hdr: VirtioBlkReqHeader align(64) = .{ .req_type = 0, .sector = 0 };
var dma_sector_buf: [SECTOR_SIZE]u8 align(64) = [_]u8{0} ** SECTOR_SIZE;
var dma_status_byte: u8 align(16) = 0xFF;
var dev_ready: bool = false;
var io_base: u16 = 0;
var queue_size: u16 = 0;
var last_used_idx: u16 = 0;
var total_sectors: u64 = 0;
pub fn init() bool {
    const dev = pci.findDeviceAndEnableDma(VIRTIO_VENDOR_ID, VIRTIO_BLK_DEVICE_ID) orelse {
        serial.writeString("[TINUX_BLK] VirtIO-Block PCI device not found\n");
        return false;
    };

    io_base = dev.io_base;

    // 1. Reset device
    io.outb(io_base + 0x12, 0x00);

    // 2. Set ACKNOWLEDGE status bit
    io.outb(io_base + 0x12, 0x01);

    // 3. Set DRIVER status bit
    io.outb(io_base + 0x12, 0x03);

    // 4. Feature negotiation: accept 0 guest features
    _ = io.inl(io_base + 0x00);
    io.outl(io_base + 0x04, 0x00);

    // 5. Select Queue 0 and read queue size
    io.outw(io_base + 0x0E, 0);
    queue_size = io.inw(io_base + 0x0C);
    if (queue_size == 0) {
        serial.writeString("[TINUX_BLK] Error: queue size is 0\n");
        return false;
    }

    // 6. Zero virtqueue memory and write QUEUE_PFN
    @memset(&vring_mem, 0);
    const ring_phys = @intFromPtr(&vring_mem);
    io.outl(io_base + 0x08, @as(u32, @intCast(ring_phys >> 12)));

    // 7. Read disk capacity in sectors (512 bytes each)
    const cap_low = io.inl(io_base + 0x14);
    const cap_high = io.inl(io_base + 0x18);
    total_sectors = (@as(u64, cap_high) << 32) | @as(u64, cap_low);

    // 8. Set DRIVER_OK status bit
    io.outb(io_base + 0x12, 0x07);

    last_used_idx = 0;
    dev_ready = true;

    serial.writeString("[TINUX_BLK] VirtIO-Block PCI device (/dev/vda) initialized\n");
    return true;
}
pub fn isReady() bool {
    return dev_ready;
}
pub fn getCapacityBytes() usize {
    return @as(usize, @intCast(total_sectors)) * SECTOR_SIZE;
}
pub fn rwSector(sector: u64, buf: *[SECTOR_SIZE]u8, is_write: bool) bool {
    if (!dev_ready or sector >= total_sectors or queue_size < 3) {
        return false;
    }

    const desc_table = @as([*]VirtqDesc, @ptrCast(@alignCast(&vring_mem[0])));
    const avail_offset = 16 * @as(usize, queue_size);
    const avail_idx = @as(*volatile u16, @ptrCast(@alignCast(&vring_mem[avail_offset + 2])));
    const avail_ring = @as([*]volatile u16, @ptrCast(@alignCast(&vring_mem[avail_offset + 4])));

    const used_offset = std.mem.alignForward(usize, avail_offset + 4 + 2 * @as(usize, queue_size), 4096);
    const used_idx = @as(*volatile u16, @ptrCast(@alignCast(&vring_mem[used_offset + 2])));

    dma_req_hdr.req_type = if (is_write) VIRTIO_BLK_T_OUT else VIRTIO_BLK_T_IN;
    dma_req_hdr.reserved = 0;
    dma_req_hdr.sector = sector;

    desc_table[0].addr = @intFromPtr(&dma_req_hdr);
    desc_table[0].len = @sizeOf(VirtioBlkReqHeader);
    desc_table[0].flags = VRING_DESC_F_NEXT;
    desc_table[0].next = 1;

    if (is_write) {
        @memcpy(&dma_sector_buf, buf);
    }
    desc_table[1].addr = @intFromPtr(&dma_sector_buf);
    desc_table[1].len = SECTOR_SIZE;
    desc_table[1].flags = VRING_DESC_F_NEXT | (if (is_write) 0 else VRING_DESC_F_WRITE);
    desc_table[1].next = 2;

    dma_status_byte = 0xFF;
    desc_table[2].addr = @intFromPtr(&dma_status_byte);
    desc_table[2].len = 1;
    desc_table[2].flags = VRING_DESC_F_WRITE;
    desc_table[2].next = 0;

    const a_idx = avail_idx.*;
    avail_ring[a_idx % queue_size] = 0;

    asm volatile ("mfence" ::: "memory");
    avail_idx.* = a_idx +% 1;
    asm volatile ("mfence" ::: "memory");

    io.outw(io_base + 0x10, 0);

    var timeout: usize = 10_000_000;
    while (used_idx.* == last_used_idx) : (timeout -= 1) {
        if (timeout == 0) {
            serial.writeString("[TINUX_BLK] Error: request timeout\n");
            return false;
        }
        asm volatile ("pause");
    }

    last_used_idx = used_idx.*;

    _ = io.inb(io_base + 0x13);
    asm volatile ("mfence" ::: "memory");

    if (dma_status_byte == 0) {
        if (!is_write) {
            @memcpy(buf, &dma_sector_buf);
        }
        return true;
    }

    return false;
}
pub fn readBytes(offset: usize, dst: []u8) usize {
    if (!dev_ready or dst.len == 0) return 0;
    const cap = getCapacityBytes();
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
        if (!rwSector(sector, &tmp, false)) break;

        @memcpy(dst[transferred .. transferred + chunk], tmp[sec_off .. sec_off + chunk]);
        transferred += chunk;
        cur_off += chunk;
        remaining -= chunk;
    }

    return transferred;
}
pub fn writeBytes(offset: usize, src: []const u8) usize {
    if (!dev_ready or src.len == 0) return 0;
    const cap = getCapacityBytes();
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
            if (!rwSector(sector, &tmp, true)) break;
        } else {
            if (!rwSector(sector, &tmp, false)) break;
            @memcpy(tmp[sec_off .. sec_off + chunk], src[transferred .. transferred + chunk]);
            if (!rwSector(sector, &tmp, true)) break;
        }

        transferred += chunk;
        cur_off += chunk;
        remaining -= chunk;
    }

    return transferred;
}
