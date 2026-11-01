const std = @import("std");
const io = @import("../arch/x86_64/io.zig");
const pci = @import("pci.zig");
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
pub var mac_addr: [6]u8 = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
pub var rx_packets: u64 = 0;
pub var rx_bytes: u64 = 0;
pub var tx_packets: u64 = 0;
pub var tx_bytes: u64 = 0;

pub fn init() bool {
    // Builder probes PCI 1AF4:1000, negotiates VIRTIO_NET_F_MAC, reads mac_addr,
    // sets up Queue 0 (RXQ) with 16 pre-posted buffers and Queue 1 (TXQ), sets DRIVER_OK
}
pub fn isReady() bool {
    return dev_ready;
}
pub fn transmitFrame(eth_frame: []const u8) bool {
    // Builder prepends 10-byte zeroed VirtioNetHdr, pads frame to >= 60 bytes,
    // submits to TXQ (Queue 1), notifies port io_base + 0x10 with value 1, and waits for Used Ring
}
pub fn pollRx() void {
    // Builder checks RXQ Used Ring, passes received Ethernet frames (after 10-byte VirtioNetHdr)
    // to netstack.onReceiveFrame(), and re-posts the descriptor back to RXQ Available Ring
}
