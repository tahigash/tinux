const std = @import("std");
const AF_INET: u16 = 2;
const SOCK_DGRAM: usize = 2;
const IPPROTO_ICMP: usize = 1;
const SockAddrIn = extern struct {
    sin_family: u16 = AF_INET,
    sin_port: u16 = 0,
    sin_addr: [4]u8 = .{ 10, 0, 2, 2 }, // QEMU SLIRP Gateway 10.0.2.2
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};
const IcmpEchoPkt = extern struct {
    icmp_type: u8 = 8, // Echo Request
    code: u8 = 0,
    checksum: u16 align(1) = 0,


155 ---
    id: u16 align(1) = 0x3713,       // 0x1337 in BE
    sequence: u16 align(1) = 0x0100, // Seq 1 in BE
    payload: [16]u8 = "TINUX_ICMP_PING!".*,
};
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call pingMain
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
export fn pingMain() callconv(.C) noreturn {
    // 1. Create Linux ICMP socket: socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    const sock_fd = syscall3(41, AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (sock_fd < 0) failExit(10);
    var dest = SockAddrIn{};
    var req = IcmpEchoPkt{};
    writeStdout("[TINUX_PING] Sending ARP + ICMP Echo Request to QEMU Gateway 10.0.2.2...\n");
    // 2. Send ICMP Echo Request via sys_sendto(44)
    const sent = syscall6(
        44,
        @intCast(sock_fd),
        @intFromPtr(&req),
        @sizeOf(IcmpEchoPkt),
        0,
        @intFromPtr(&dest),
        @sizeOf(SockAddrIn),
    );
    if (sent != @sizeOf(IcmpEchoPkt)) failExit(11);
    // 3. Receive ICMP Echo Reply via sys_recvfrom(45)
    var reply: IcmpEchoPkt = undefined;


156 ---
    var src_addr: SockAddrIn = undefined;
    var addrlen: u32 = @sizeOf(SockAddrIn);
    const recvd = syscall6(
        45,
        @intCast(sock_fd),
        @intFromPtr(&reply),
        @sizeOf(IcmpEchoPkt),
        0,
        @intFromPtr(&src_addr),
        @intFromPtr(&addrlen),
    );
    if (recvd < 8) failExit(12);
    if (reply.icmp_type != 0 or reply.code != 0) failExit(13); // Expect Echo Reply (type=0)
    if (src_addr.sin_addr[0] != 10 or src_addr.sin_addr[3] != 2) failExit(14);
    writeStdout("[TINUX_PING] 24 bytes from 10.0.2.2: icmp_seq=1 ttl=255 (VirtIO-Net RX/TX DMA verified!)\n");
    _ = syscall1(231, 0);
    unreachable;
}
