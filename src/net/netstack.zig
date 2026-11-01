const std = @import("std");
const virtio_net = @import("../drivers/virtio_net.zig");
const timer = @import("../drivers/timer.zig");
const task = @import("../proc/task.zig");
pub const ETH_P_IP: u16 = 0x0800;
pub const ETH_P_ARP: u16 = 0x0806;
pub const IPPROTO_ICMP: u8 = 1;
pub const IPPROTO_UDP: u8 = 17;
pub const ICMP_ECHO_REPLY: u8 = 0;
pub const ICMP_ECHO_REQUEST: u8 = 8;
pub const OUR_IP: [4]u8 = .{ 10, 0, 2, 15 };
pub const GW_IP: [4]u8 = .{ 10, 0, 2, 2 };
pub const BROADCAST_MAC: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
pub const EthHdr = extern struct {
    dst: [6]u8 align(1),
    src: [6]u8 align(1),
    ethertype: u16 align(1), // Big Endian
    comptime {
        std.debug.assert(@sizeOf(EthHdr) == 14);
    }
};
pub const ArpPkt = extern struct {
    htype: u16 align(1), // 1 = Ethernet (Big Endian)
    ptype: u16 align(1), // 0x0800 = IPv4 (Big Endian)
    hlen: u8 align(1),   // 6
    plen: u8 align(1),   // 4
    oper: u16 align(1),  // 1 = Request, 2 = Reply (Big Endian)
    sha: [6]u8 align(1),
    spa: [4]u8 align(1),
    tha: [6]u8 align(1),
    tpa: [4]u8 align(1),
    comptime {
        std.debug.assert(@sizeOf(ArpPkt) == 28);
    }
};
pub const Ipv4Hdr = extern struct {
    ver_ihl: u8 align(1) = 0x45,
    tos: u8 align(1) = 0,
    tot_len: u16 align(1),  // Big Endian
    id: u16 align(1),       // Big Endian
    frag_off: u16 align(1), // Big Endian (0x4000 = DF)
    ttl: u8 align(1) = 64,
    proto: u8 align(1),
    check: u16 align(1) = 0,
    saddr: [4]u8 align(1),
    daddr: [4]u8 align(1),
    comptime {
        std.debug.assert(@sizeOf(Ipv4Hdr) == 20);
    }
};
pub const IcmpHdr = extern struct {
    icmp_type: u8 align(1),
    code: u8 align(1) = 0,
    checksum: u16 align(1) = 0,
    id: u16 align(1),       // Big Endian
    sequence: u16 align(1), // Big Endian
    comptime {
        std.debug.assert(@sizeOf(IcmpHdr) == 8);
    }
};
pub const ArpEntry = struct {
    valid: bool = false,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
};
pub var arp_table: [8]ArpEntry = [_]ArpEntry{.{}} ** 8;
pub fn internetChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        const word = (@as(u16, data[i]) << 8) | @as(u16, data[i + 1]);
        sum += word;
    }
    if (i < data.len) {
        sum += (@as(u16, data[i]) << 8);
    }
    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return std.mem.nativeToBig(u16, @truncate(~sum));
}
pub fn init() void {
    // Builder initializes arp_table and reply state
}
pub fn onReceiveFrame(frame: []const u8) void {
    // Builder parses EthHdr -> handles ARP (0x0806) or IPv4/ICMP (0x0800),
    // updates arp_table, replies to Echo Requests, and records Echo Replies
}
pub fn resolveArp(target_ip: [4]u8) ?[6]u8 {
    // Builder checks arp_table; if missing, sends broadcast ARP Request and polls virtio_net.pollRx()
}
pub fn sendIcmpEchoRequest(dst_ip: [4]u8, id_be: u16, seq_be: u16, payload: []const u8) bool {
    // Builder resolves next-hop MAC (target_ip if 10.0.2.x else GW_IP), builds Eth + IPv4 + ICMP frame,
    // computes RFC 1071 checksums, and transmits via virtio_net.transmitFrame()
}


pub const UdpHdr = extern struct {
    src_port: u16 align(1), // Big Endian
    dst_port: u16 align(1), // Big Endian
    len: u16 align(1),      // Big Endian (8 + payload.len)
    check: u16 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(UdpHdr) == 8);
    }
};

pub const DNS_SERVER_IP: [4]u8 = .{ 10, 0, 2, 3 };
pub const DNS_PORT: u16 = 53;

pub fn sendUdpPacket(
    src_port_host: u16,
    dst_ip: [4]u8,
    dst_port_host: u16,
    payload: []const u8,
) bool {
    _ = src_port_host;
    _ = dst_ip;
    _ = dst_port_host;
    _ = payload;
    // Builder resolves ARP for dst_ip (or GW_IP), builds EthHdr + Ipv4Hdr (proto=17) + UdpHdr + payload,
    // transmits via virtio_net.transmitFrame(), polls RX, and provides offline-safe DNS fallback if needed
    return true;
}

