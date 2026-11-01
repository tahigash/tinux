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

pub const IcmpReplyState = struct {
    has_reply: bool = false,
    src_ip: [4]u8 = .{ 0, 0, 0, 0 },
    data: [128]u8 = [_]u8{0} ** 128,
    data_len: usize = 0,
};

pub var last_icmp_reply: IcmpReplyState = .{};

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
    for (&arp_table) |*e| e.* = .{};
    last_icmp_reply = .{};
}

pub fn hasIcmpReply() bool {
    return last_icmp_reply.has_reply;
}

pub fn getIcmpReply(dst: []u8, src_ip_out: *[4]u8) ?usize {
    if (!last_icmp_reply.has_reply) return null;
    const len = @min(dst.len, last_icmp_reply.data_len);
    @memcpy(dst[0..len], last_icmp_reply.data[0..len]);
    src_ip_out.* = last_icmp_reply.src_ip;
    last_icmp_reply.has_reply = false;
    return len;
}

fn recordArp(ip: [4]u8, mac: [6]u8) void {
    for (&arp_table) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) {
            e.mac = mac;
            return;
        }
    }
    for (&arp_table) |*e| {
        if (!e.valid) {
            e.valid = true;
            e.ip = ip;
            e.mac = mac;
            return;
        }
    }
    arp_table[0].valid = true;
    arp_table[0].ip = ip;
    arp_table[0].mac = mac;
}

pub fn onReceiveFrame(frame: []const u8) void {
    if (frame.len < @sizeOf(EthHdr)) return;
    const eth = @as(*const EthHdr, @ptrCast(&frame[0]));
    const ethertype = std.mem.bigToNative(u16, eth.ethertype);

    if (ethertype == ETH_P_ARP) {
        if (frame.len < @sizeOf(EthHdr) + @sizeOf(ArpPkt)) return;
        const arp = @as(*const ArpPkt, @ptrCast(&frame[@sizeOf(EthHdr)]));
        const oper = std.mem.bigToNative(u16, arp.oper);

        recordArp(arp.spa, arp.sha);

        if (oper == 1) { // ARP Request
            if (std.mem.eql(u8, &arp.tpa, &OUR_IP)) {
                var rep_frame: [42]u8 = undefined;
                const rep_eth = @as(*EthHdr, @ptrCast(&rep_frame[0]));
                rep_eth.dst = arp.sha;
                rep_eth.src = virtio_net.mac_addr;
                rep_eth.ethertype = std.mem.nativeToBig(u16, ETH_P_ARP);

                const rep_arp = @as(*ArpPkt, @ptrCast(&rep_frame[@sizeOf(EthHdr)]));
                rep_arp.htype = std.mem.nativeToBig(u16, 1);
                rep_arp.ptype = std.mem.nativeToBig(u16, ETH_P_IP);
                rep_arp.hlen = 6;
                rep_arp.plen = 4;
                rep_arp.oper = std.mem.nativeToBig(u16, 2); // Reply
                rep_arp.sha = virtio_net.mac_addr;
                rep_arp.spa = OUR_IP;
                rep_arp.tha = arp.sha;
                rep_arp.tpa = arp.spa;

                _ = virtio_net.transmitFrame(&rep_frame);
            }
        }
    } else if (ethertype == ETH_P_IP) {
        if (frame.len < @sizeOf(EthHdr) + @sizeOf(Ipv4Hdr)) return;
        const ip = @as(*const Ipv4Hdr, @ptrCast(&frame[@sizeOf(EthHdr)]));
        if (ip.proto == IPPROTO_ICMP) {
            const ip_hdr_len: usize = (@as(usize, ip.ver_ihl & 0x0F)) * 4;
            const icmp_offset = @sizeOf(EthHdr) + ip_hdr_len;
            if (frame.len < icmp_offset + @sizeOf(IcmpHdr)) return;
            const icmp = @as(*const IcmpHdr, @ptrCast(&frame[icmp_offset]));

            if (icmp.icmp_type == ICMP_ECHO_REQUEST) {
                const icmp_len = frame.len - icmp_offset;
                var rep_buf: [1514]u8 = undefined;
                if (frame.len <= rep_buf.len) {
                    const rep_eth = @as(*EthHdr, @ptrCast(&rep_buf[0]));
                    rep_eth.dst = eth.src;
                    rep_eth.src = virtio_net.mac_addr;
                    rep_eth.ethertype = std.mem.nativeToBig(u16, ETH_P_IP);

                    const rep_ip = @as(*Ipv4Hdr, @ptrCast(&rep_buf[@sizeOf(EthHdr)]));
                    rep_ip.* = .{
                        .ver_ihl = 0x45,
                        .tos = 0,
                        .tot_len = std.mem.nativeToBig(u16, @as(u16, @intCast(@sizeOf(Ipv4Hdr) + icmp_len))),
                        .id = ip.id,
                        .frag_off = 0,
                        .ttl = 64,
                        .proto = IPPROTO_ICMP,
                        .check = 0,
                        .saddr = OUR_IP,
                        .daddr = ip.saddr,
                    };
                    rep_ip.check = internetChecksum(rep_buf[@sizeOf(EthHdr) .. @sizeOf(EthHdr) + @sizeOf(Ipv4Hdr)]);

                    const rep_icmp = @as(*IcmpHdr, @ptrCast(&rep_buf[icmp_offset]));
                    @memcpy(rep_buf[icmp_offset .. icmp_offset + icmp_len], frame[icmp_offset .. frame.len]);
                    rep_icmp.icmp_type = ICMP_ECHO_REPLY;
                    rep_icmp.code = 0;
                    rep_icmp.checksum = 0;
                    rep_icmp.checksum = internetChecksum(rep_buf[icmp_offset .. icmp_offset + icmp_len]);

                    _ = virtio_net.transmitFrame(rep_buf[0 .. icmp_offset + icmp_len]);
                }
            } else if (icmp.icmp_type == ICMP_ECHO_REPLY) {
                const icmp_len = frame.len - icmp_offset;
                const copy_len = @min(icmp_len, last_icmp_reply.data.len);
                @memcpy(last_icmp_reply.data[0..copy_len], frame[icmp_offset .. icmp_offset + copy_len]);
                last_icmp_reply.data_len = copy_len;
                last_icmp_reply.src_ip = ip.saddr;
                last_icmp_reply.has_reply = true;
            }
        }
    }
}

pub fn resolveArp(target_ip: [4]u8) ?[6]u8 {
    for (&arp_table) |e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &target_ip)) {
            return e.mac;
        }
    }

    var frame: [42]u8 = undefined;
    const eth = @as(*EthHdr, @ptrCast(&frame[0]));
    eth.dst = BROADCAST_MAC;
    eth.src = virtio_net.mac_addr;
    eth.ethertype = std.mem.nativeToBig(u16, ETH_P_ARP);

    const arp = @as(*ArpPkt, @ptrCast(&frame[@sizeOf(EthHdr)]));
    arp.htype = std.mem.nativeToBig(u16, 1);
    arp.ptype = std.mem.nativeToBig(u16, ETH_P_IP);
    arp.hlen = 6;
    arp.plen = 4;
    arp.oper = std.mem.nativeToBig(u16, 1); // 1 = Request
    arp.sha = virtio_net.mac_addr;
    arp.spa = OUR_IP;
    arp.tha = [_]u8{0} ** 6;
    arp.tpa = target_ip;

    if (!virtio_net.transmitFrame(&frame)) return null;

    var timeout: usize = 1_000_000;
    while (timeout > 0) : (timeout -= 1) {
        virtio_net.pollRx();
        for (&arp_table) |e| {
            if (e.valid and std.mem.eql(u8, &e.ip, &target_ip)) {
                return e.mac;
            }
        }
        asm volatile ("pause");
    }
    return null;
}

pub fn sendIcmpEchoRequest(dst_ip: [4]u8, id_be: u16, seq_be: u16, payload: []const u8) bool {
    const next_hop = if (dst_ip[0] == 10 and dst_ip[1] == 0 and dst_ip[2] == 2) dst_ip else GW_IP;
    const dst_mac = resolveArp(next_hop) orelse return false;

    const icmp_len = @sizeOf(IcmpHdr) + payload.len;
    const ip_tot_len = @sizeOf(Ipv4Hdr) + icmp_len;
    const raw_eth_len = @sizeOf(EthHdr) + ip_tot_len;
    const frame_len = @max(raw_eth_len, 60);

    var frame_buf: [1514]u8 = [_]u8{0} ** 1514;
    const eth = @as(*EthHdr, @ptrCast(&frame_buf[0]));
    eth.dst = dst_mac;
    eth.src = virtio_net.mac_addr;
    eth.ethertype = std.mem.nativeToBig(u16, ETH_P_IP);

    const ip = @as(*Ipv4Hdr, @ptrCast(&frame_buf[@sizeOf(EthHdr)]));
    ip.* = .{
        .ver_ihl = 0x45,
        .tos = 0,
        .tot_len = std.mem.nativeToBig(u16, @as(u16, @intCast(ip_tot_len))),
        .id = std.mem.nativeToBig(u16, 1),
        .frag_off = std.mem.nativeToBig(u16, 0x4000), // DF
        .ttl = 64,
        .proto = IPPROTO_ICMP,
        .check = 0,
        .saddr = OUR_IP,
        .daddr = dst_ip,
    };
    ip.check = internetChecksum(frame_buf[@sizeOf(EthHdr) .. @sizeOf(EthHdr) + @sizeOf(Ipv4Hdr)]);

    const icmp_offset = @sizeOf(EthHdr) + @sizeOf(Ipv4Hdr);
    const icmp = @as(*IcmpHdr, @ptrCast(&frame_buf[icmp_offset]));
    icmp.* = .{
        .icmp_type = ICMP_ECHO_REQUEST,
        .code = 0,
        .checksum = 0,
        .id = id_be,
        .sequence = seq_be,
    };
    @memcpy(frame_buf[icmp_offset + @sizeOf(IcmpHdr) .. icmp_offset + icmp_len], payload);

    icmp.checksum = internetChecksum(frame_buf[icmp_offset .. icmp_offset + icmp_len]);

    return virtio_net.transmitFrame(frame_buf[0..frame_len]);
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
    return true;
}
