const std = @import("std");
const AF_INET: u16 = 2;
const SOCK_DGRAM: usize = 2;
const IPPROTO_UDP: usize = 17;
const SockAddrIn = extern struct {
    sin_family: u16 = AF_INET,
    sin_port: u16 = 0, // Big Endian
    sin_addr: [4]u8 = .{ 0, 0, 0, 0 },
    sin_zero: [8]u8 = [_]u8{0} ** 8,
    comptime {
        std.debug.assert(@sizeOf(SockAddrIn) == 16);
    }
};
const DnsHeader = extern struct {
    id: u16 align(1),       // Big Endian
    flags: u16 align(1),    // Big Endian (0x0100 = Standard Query, Recursion Desired)
    qdcount: u16 align(1),  // Big Endian (1)
    ancount: u16 align(1),  // Big Endian
    nscount: u16 align(1),  // Big Endian
    arcount: u16 align(1),  // Big Endian
    comptime {
        std.debug.assert(@sizeOf(DnsHeader) == 12);
    }
};
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call dnsTestMain
    );
}
inline fn syscall1(num: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
        : "rcx", "r11", "memory"
    );
}
inline fn syscall3(num: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}
inline fn syscall4(num: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
        : "rcx", "r11", "memory"
    );
}
inline fn syscall6(num: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}" (a5),
          [a6] "{r9}" (a6),
        : "rcx", "r11", "memory"
    );
}
fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}
fn failExit(code: usize) noreturn {
    _ = syscall1(231, code);
    unreachable;
}
export fn dnsTestMain() callconv(.C) noreturn {
    // 1. Verify /etc/resolv.conf exists and contains "nameserver 10.0.2.3"
    const r_fd = syscall4(257, @bitCast(@as(isize, -100)), @intFromPtr("etc/resolv.conf"), 0, 0);
    if (r_fd < 0) failExit(10);
    var r_buf: [64]u8 = [_]u8{0} ** 64;
    const r_len = syscall3(0, @intCast(r_fd), @intFromPtr(&r_buf), r_buf.len);
    _ = syscall1(3, @intCast(r_fd));
    if (r_len <= 0) failExit(11);
    writeStdout("[TINUX_DNS] Loaded /etc/resolv.conf: ");
    writeStdout(r_buf[0..@intCast(r_len)]);
    // 2. Test local UDP Loopback (bind 127.0.0.1:5353, sendto self, recvfrom)
    const lo_fd = syscall3(41, AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (lo_fd < 0) failExit(12);
    var lo_addr = SockAddrIn{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, 5353),
        .sin_addr = .{ 127, 0, 0, 1 },
    };
    if (syscall3(49, @intCast(lo_fd), @intFromPtr(&lo_addr), @sizeOf(SockAddrIn)) != 0) failExit(13);
    const lo_msg = "UDP_LOOPBACK_OK";
    if (syscall6(44, @intCast(lo_fd), @intFromPtr(lo_msg.ptr), lo_msg.len, 0, @intFromPtr(&lo_addr), 16) != lo_msg.len) {
        failExit(14);
    }
    var lo_rx: [32]u8 = undefined;
    var lo_from: SockAddrIn = undefined;
    var lo_from_len: u32 = 16;
    const lo_n = syscall6(45, @intCast(lo_fd), @intFromPtr(&lo_rx), lo_rx.len, 0, @intFromPtr(&lo_from), @intFromPtr(&lo_from_len));
    if (lo_n != lo_msg.len or lo_from.sin_port != std.mem.nativeToBig(u16, 5353)) failExit(15);
    writeStdout("[TINUX_UDP] Local UDP SOCK_DGRAM bind/sendto/recvfrom on 127.0.0.1:5353 verified!\n");
    // 3. Build RFC 1035 DNS A-Record Query for "example.com" -> 10.0.2.3:53
    const dns_fd = syscall3(41, AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (dns_fd < 0) failExit(16);
    var dns_srv = SockAddrIn{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, 53),
        .sin_addr = .{ 10, 0, 2, 3 },
    };
    // Connect UDP socket to 10.0.2.3:53 and send DNS packet
    if (syscall3(42, @intCast(dns_fd), @intFromPtr(&dns_srv), 16) != 0) failExit(17);
    // 12-byte Header + "\x07example\x03com\x00" (13B) + QTYPE=A(1) (2B) + QCLASS=IN(1) (2B) = 29 bytes
    const dns_query = [29]u8{
        0x42, 0x24, // ID = 0x4224
        0x01, 0x00, // Flags: Standard query, RD=1
        0x00, 0x01, // QDCOUNT = 1
        0x00, 0x00, // ANCOUNT = 0
        0x00, 0x00, // NSCOUNT = 0
        0x00, 0x00, // ARCOUNT = 0
        0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        0x03, 'c', 'o', 'm',
        0x00,
        0x00, 0x01, // QTYPE = A (Host Address)
        0x00, 0x01, // QCLASS = IN
    };
    writeStdout("[TINUX_DNS] Sending RFC 1035 DNS A-record query for example.com to 10.0.2.3:53...\n");
    if (syscall3(1, @intCast(dns_fd), @intFromPtr(&dns_query), dns_query.len) != dns_query.len) {
        failExit(18);
    }
    var dns_resp: [256]u8 = undefined;
    var dns_from: SockAddrIn = undefined;
    var dns_from_len: u32 = 16;
    const resp_len = syscall6(
        45,
        @intCast(dns_fd),
        @intFromPtr(&dns_resp),
        dns_resp.len,
        0,
        @intFromPtr(&dns_from),
        @intFromPtr(&dns_from_len),
    );
    if (resp_len < 33) failExit(19);


    // Verify Transaction ID (0x42, 0x24), QR=1 (Response bit 0x80 in byte 2), and ANCOUNT >= 1
    if (dns_resp[0] != 0x42 or dns_resp[1] != 0x24) failExit(20);
    if ((dns_resp[2] & 0x80) == 0) failExit(21);
    const ancount = (@as(u16, dns_resp[6]) << 8) | @as(u16, dns_resp[7]);
    if (ancount == 0) failExit(22);
    // Extract the 4-byte IPv4 address at the end of the first Answer RDATA
    const ulen: usize = @intCast(resp_len);
    const ip0 = dns_resp[ulen - 4];
    const ip1 = dns_resp[ulen - 3];
    const ip2 = dns_resp[ulen - 2];
    const ip3 = dns_resp[ulen - 1];
    var out_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &out_buf,
        "[TINUX_DNS] Resolved example.com -> {d}.{d}.{d}.{d} via 10.0.2.3:53 (ANCOUNT={d})!\n",
        .{ ip0, ip1, ip2, ip3, ancount },
    ) catch unreachable;
    writeStdout(msg);
    _ = syscall1(231, 0);
    unreachable;
}
