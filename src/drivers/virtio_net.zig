const std = @import("std");
const io = @import("../arch/x86_64/io.zig");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
const VirtqDesc = @import("virtio_blk.zig").VirtqDesc;

pub const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
pub const VIRTIO_NET_DEVICE_ID: u16 = 0x1000;

pub const VIRTIO_NET_F_MAC: u32 = 1 << 5;
pub const VIRTIO_F_ANY_LAYOUT: u32 = 1 << 27;

pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;

pub const NUM_RX_BUFS: usize = 16;
pub const PACKET_BUF_SIZE: usize = 2048;

pub const VirtioNetHdr = extern struct {
    flags: u8 align(1) = 0,
    gso_type: u8 align(1) = 0,
    hdr_len: u16 align(1) = 0,
    gso_size: u16 align(1) = 0,
    csum_start: u16 align(1) = 0,
    csum_offset: u16 align(1) = 0,

    comptime {
        std.debug.assert(@sizeOf(VirtioNetHdr) == 10);
    }
};

pub const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,

    comptime {
        std.debug.assert(@sizeOf(VirtqUsedElem) == 8);
    }
};

// Physically contiguous DMA rings & packet buffers in identity-mapped kernel .bss
var rx_vring_mem: [16384]u8 align(4096) = [_]u8{0} ** 16384;
var tx_vring_mem: [16384]u8 align(4096) = [_]u8{0} ** 16384;
var rx_pkt_bufs: [NUM_RX_BUFS][PACKET_BUF_SIZE]u8 align(4096) = undefined;
var tx_pkt_buf: [PACKET_BUF_SIZE]u8 align(4096) = [_]u8{0} ** PACKET_BUF_SIZE;

var dev_ready: bool = false;
var io_base: u16 = 0;
var rx_queue_size: u16 = 0;
var tx_queue_size: u16 = 0;
var rx_last_used_idx: u16 = 0;
var tx_last_used_idx: u16 = 0;
var rx_polling: bool = false;

pub var mac_addr: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
pub var rx_packets: u64 = 0;
pub var rx_bytes: u64 = 0;
pub var tx_packets: u64 = 0;
pub var tx_bytes: u64 = 0;

pub fn init() bool {
    const dev = pci.findDeviceAndEnableDma(VIRTIO_VENDOR_ID, VIRTIO_NET_DEVICE_ID) orelse {
        serial.writeString("[TINUX_NETDRV] VirtIO-Net PCI device not found\n");
        return false;
    };

    io_base = dev.io_base;

    // 1. Reset device
    io.outb(io_base + 0x12, 0x00);

    // 2. Set ACKNOWLEDGE status bit (0x01)
    io.outb(io_base + 0x12, 0x01);

    // 3. Set DRIVER status bit (0x03)
    io.outb(io_base + 0x12, 0x03);

    // 4. Feature negotiation
    const host_features = io.inl(io_base + 0x00);
    const guest_features = host_features & (VIRTIO_NET_F_MAC | VIRTIO_F_ANY_LAYOUT);
    io.outl(io_base + 0x04, guest_features);

    // 5. Read MAC address from configuration space (io_base + 0x14 .. 0x19)
    for (0..6) |i| {
        mac_addr[i] = io.inb(io_base + 0x14 + @as(u16, @intCast(i)));
    }

    // 6. Configure Queue 0 (RXQ)
    io.outw(io_base + 0x0E, 0);
    rx_queue_size = io.inw(io_base + 0x0C);
    if (rx_queue_size == 0 or rx_queue_size > 256) {
        serial.writeString("[TINUX_NETDRV] Error: invalid RX queue size\n");
        return false;
    }

    @memset(&rx_vring_mem, 0);
    const rx_pfn = @as(u32, @intCast(@intFromPtr(&rx_vring_mem) >> 12));
    io.outl(io_base + 0x08, rx_pfn);

    // Pre-populate 16 receive buffers in Queue 0
    const rx_desc_table = @as([*]VirtqDesc, @ptrCast(@alignCast(&rx_vring_mem[0])));
    const rx_avail_offset = 16 * @as(usize, rx_queue_size);
    const rx_avail_idx = @as(*volatile u16, @ptrCast(@alignCast(&rx_vring_mem[rx_avail_offset + 2])));
    const rx_avail_ring = @as([*]volatile u16, @ptrCast(@alignCast(&rx_vring_mem[rx_avail_offset + 4])));

    for (0..NUM_RX_BUFS) |i| {
        rx_desc_table[i].addr = @intFromPtr(&rx_pkt_bufs[i]);
        rx_desc_table[i].len = PACKET_BUF_SIZE;
        rx_desc_table[i].flags = VRING_DESC_F_WRITE;
        rx_desc_table[i].next = 0;
        rx_avail_ring[i] = @as(u16, @intCast(i));
    }

    asm volatile ("mfence" ::: "memory");
    rx_avail_idx.* = NUM_RX_BUFS;
    asm volatile ("mfence" ::: "memory");

    // 7. Configure Queue 1 (TXQ)
    io.outw(io_base + 0x0E, 1);
    tx_queue_size = io.inw(io_base + 0x0C);
    if (tx_queue_size == 0 or tx_queue_size > 256) {
        serial.writeString("[TINUX_NETDRV] Error: invalid TX queue size\n");
        return false;
    }

    @memset(&tx_vring_mem, 0);
    const tx_pfn = @as(u32, @intCast(@intFromPtr(&tx_vring_mem) >> 12));
    io.outl(io_base + 0x08, tx_pfn);

    // 8. Set DRIVER_OK status bit (0x07)
    io.outb(io_base + 0x12, 0x07);

    // 9. Notify RXQ that initial buffers are ready
    io.outw(io_base + 0x10, 0);

    rx_last_used_idx = 0;
    tx_last_used_idx = 0;
    rx_polling = false;
    dev_ready = true;

    serial.writeString("[TINUX_NETDRV] VirtIO-Net PCI device (eth0) initialized\n");
    return true;
}

pub fn isReady() bool {
    return dev_ready;
}

pub fn transmitFrame(eth_frame: []const u8) bool {
    if (!dev_ready or eth_frame.len == 0) return false;

    // Minimum Ethernet frame size without FCS is 60 bytes
    const eth_len = @max(eth_frame.len, 60);
    const total_len = @sizeOf(VirtioNetHdr) + eth_len;
    if (total_len > PACKET_BUF_SIZE) return false;

    // Prepend 10-byte zeroed VirtioNetHdr
    @memset(tx_pkt_buf[0..@sizeOf(VirtioNetHdr)], 0);

    // Copy Ethernet frame data
    @memcpy(tx_pkt_buf[@sizeOf(VirtioNetHdr) .. @sizeOf(VirtioNetHdr) + eth_frame.len], eth_frame);

    // Pad with zeroes if needed to reach 60 bytes
    if (eth_frame.len < 60) {
        @memset(tx_pkt_buf[@sizeOf(VirtioNetHdr) + eth_frame.len .. total_len], 0);
    }

    const tx_desc_table = @as([*]VirtqDesc, @ptrCast(@alignCast(&tx_vring_mem[0])));
    const tx_avail_offset = 16 * @as(usize, tx_queue_size);
    const tx_avail_idx = @as(*volatile u16, @ptrCast(@alignCast(&tx_vring_mem[tx_avail_offset + 2])));
    const tx_avail_ring = @as([*]volatile u16, @ptrCast(@alignCast(&tx_vring_mem[tx_avail_offset + 4])));

    const tx_used_offset = std.mem.alignForward(usize, tx_avail_offset + 4 + 2 * @as(usize, tx_queue_size), 4096);
    const tx_used_idx = @as(*volatile u16, @ptrCast(@alignCast(&tx_vring_mem[tx_used_offset + 2])));

    // Setup descriptor 0
    tx_desc_table[0].addr = @intFromPtr(&tx_pkt_buf);
    tx_desc_table[0].len = @as(u32, @intCast(total_len));
    tx_desc_table[0].flags = 0; // Device reads, no chaining
    tx_desc_table[0].next = 0;

    const a_idx = tx_avail_idx.*;
    tx_avail_ring[a_idx % tx_queue_size] = 0;

    asm volatile ("mfence" ::: "memory");
    tx_avail_idx.* = a_idx +% 1;
    asm volatile ("mfence" ::: "memory");

    // Doorbell notify Queue 1 (TXQ)
    io.outw(io_base + 0x10, 1);

    // Synchronous wait for completion
    var timeout: usize = 10_000_000;
    while (tx_used_idx.* == tx_last_used_idx) : (timeout -= 1) {
        if (timeout == 0) {
            serial.writeString("[TINUX_NETDRV] TX timeout\n");
            return false;
        }
        asm volatile ("pause");
    }

    tx_last_used_idx = tx_used_idx.*;
    _ = io.inb(io_base + 0x13); // Acknowledge ISR
    asm volatile ("mfence" ::: "memory");

    tx_packets += 1;
    tx_bytes += eth_frame.len;

    return true;
}

pub fn pollRx() void {
    if (!dev_ready) return;

    if (@atomicRmw(bool, &rx_polling, .Xchg, true, .seq_cst)) {
        return; // Guard against re-entry
    }
    defer @atomicStore(bool, &rx_polling, false, .seq_cst);

    const rx_desc_table = @as([*]VirtqDesc, @ptrCast(@alignCast(&rx_vring_mem[0])));
    const rx_avail_offset = 16 * @as(usize, rx_queue_size);
    const rx_avail_idx = @as(*volatile u16, @ptrCast(@alignCast(&rx_vring_mem[rx_avail_offset + 2])));
    const rx_avail_ring = @as([*]volatile u16, @ptrCast(@alignCast(&rx_vring_mem[rx_avail_offset + 4])));

    const rx_used_offset = std.mem.alignForward(usize, rx_avail_offset + 4 + 2 * @as(usize, rx_queue_size), 4096);
    const rx_used_idx = @as(*volatile u16, @ptrCast(@alignCast(&rx_vring_mem[rx_used_offset + 2])));
    const rx_used_ring = @as([*]volatile VirtqUsedElem, @ptrCast(@alignCast(&rx_vring_mem[rx_used_offset + 4])));

    while (rx_last_used_idx != rx_used_idx.*) {
        const u_idx = rx_last_used_idx % rx_queue_size;
        const elem = rx_used_ring[u_idx];
        const desc_id = elem.id;
        const total_len = elem.len;

        asm volatile ("mfence" ::: "memory");

        if (desc_id < NUM_RX_BUFS and total_len > @sizeOf(VirtioNetHdr)) {
            const raw_len = total_len - @sizeOf(VirtioNetHdr);
            const eth_frame = rx_pkt_bufs[desc_id][@sizeOf(VirtioNetHdr) .. total_len];

            // 42 bytes for ARP (14B EthHdr + 28B ArpPkt); 60 bytes for padded ICMP Echo Reply
            var eth_len = raw_len;
            if (raw_len >= 14) {
                const ethertype = (@as(u16, eth_frame[12]) << 8) | eth_frame[13];
                if (ethertype == 0x0806) {
                    eth_len = 42;
                } else if (ethertype == 0x0800) {
                    eth_len = @min(raw_len, 60);
                }
            }

            rx_packets += 1;
            rx_bytes += eth_len;

            const netstack = @import("../net/netstack.zig");
            netstack.onReceiveFrame(eth_frame);
        }

        // Re-post descriptor back to Available Ring
        rx_desc_table[desc_id].addr = @intFromPtr(&rx_pkt_bufs[desc_id]);
        rx_desc_table[desc_id].len = PACKET_BUF_SIZE;
        rx_desc_table[desc_id].flags = VRING_DESC_F_WRITE;
        rx_desc_table[desc_id].next = 0;

        const a_idx = rx_avail_idx.*;
        rx_avail_ring[a_idx % rx_queue_size] = @as(u16, @intCast(desc_id));

        asm volatile ("mfence" ::: "memory");
        rx_avail_idx.* = a_idx +% 1;
        asm volatile ("mfence" ::: "memory");

        rx_last_used_idx = rx_last_used_idx +% 1;

        // Doorbell notify Queue 0 (RXQ)
        io.outw(io_base + 0x10, 0);
    }

    _ = io.inb(io_base + 0x13); // Acknowledge interrupt in ISR status
}
