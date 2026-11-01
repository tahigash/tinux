// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Comprehensive empirical adversarial challenge suite for TASK-017:
// Syscall lifecycle, negative parameter validation, error returns, and ICMP networking over VirtIO-Net

const std = @import("std");

pub const SYS_READ: usize = 0;
pub const SYS_WRITE: usize = 1;
pub const SYS_OPEN: usize = 2;
pub const SYS_CLOSE: usize = 3;
pub const SYS_SOCKET: usize = 41;
pub const SYS_SENDTO: usize = 44;
pub const SYS_RECVFROM: usize = 45;
pub const SYS_EXIT_GROUP: usize = 231;

pub const AF_UNIX: u16 = 1;
pub const AF_INET: u16 = 2;
pub const SOCK_STREAM: usize = 1;
pub const SOCK_DGRAM: usize = 2;
pub const SOCK_RAW: usize = 3;
pub const IPPROTO_ICMP: usize = 1;

pub const EBADF: isize = -9;
pub const EFAULT: isize = -14;
pub const EINVAL: isize = -22;
pub const ENOTSOCK: isize = -88;
pub const EAFNOSUPPORT: isize = -97;

pub const SockAddrIn = extern struct {
    sin_family: u16 = AF_INET,
    sin_port: u16 = 0,
    sin_addr: [4]u8 = .{ 10, 0, 2, 2 },
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

pub const IcmpEchoPkt = extern struct {
    icmp_type: u8 = 8, // Echo Request
    code: u8 = 0,
    checksum: u16 align(1) = 0,
    id: u16 align(1) = 0x4224,
    sequence: u16 align(1) = 0x0100,
    payload: [16]u8 = "CHALLENGER_PING!".*,
};

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1) : "rcx", "r11", "memory");
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3) : "rcx", "r11", "memory");
}

inline fn sys6(n: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3), [d] "{r10}" (a4), [e] "{r8}" (a5), [f] "{r9}" (a6) : "rcx", "r11", "memory");
}

fn puts(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn printNum(num: isize) void {
    var buf: [32]u8 = undefined;
    var idx: usize = 0;
    if (num < 0) {
        buf[0] = '-';
        idx = 1;
    }
    var u: usize = if (num < 0) @intCast(-num) else @intCast(num);
    var temp: [24]u8 = undefined;
    var t_idx: usize = 0;
    if (u == 0) {
        temp[0] = '0';
        t_idx = 1;
    } else {
        while (u > 0) {
            temp[t_idx] = @intCast('0' + (u % 10));
            t_idx += 1;
            u = u / 10;
        }
    }
    while (t_idx > 0) {
        t_idx -= 1;
        buf[idx] = temp[t_idx];
        idx += 1;
    }
    puts(buf[0..idx]);
}

fn assertEqual(desc: []const u8, expected: isize, actual: isize) void {
    puts(desc);
    puts(": expected=");
    printNum(expected);
    puts(", got=");
    printNum(actual);
    if (expected == actual) {
        puts(" [PASS]\n");
    } else {
        puts(" [FAIL]\n");
        _ = sys1(SYS_EXIT_GROUP, 99);
    }
}

export fn challengerMain() callconv(.C) noreturn {
    puts("[CHALLENGER_M17] Starting empirical adversarial testing for TASK-017...\n");

    // ========================================================================
    // Challenge 1: sys_socket negative & boundary parameters
    // ========================================================================
    puts("[CHALLENGE_1] Testing sys_socket domain and type validation...\n");
    {
        // Invalid domain (99) -> -EAFNOSUPPORT (-97)
        const r_dom = sys3(SYS_SOCKET, 99, SOCK_DGRAM, IPPROTO_ICMP);
        assertEqual("  socket(domain=99, SOCK_DGRAM, 1)", EAFNOSUPPORT, r_dom);

        // Invalid base_type (99) -> -EINVAL (-22)
        const r_typ = sys3(SYS_SOCKET, AF_INET, 99, IPPROTO_ICMP);
        assertEqual("  socket(AF_INET, type=99, 1)", EINVAL, r_typ);

        // Valid ICMP socket (AF_INET, SOCK_DGRAM, 1) -> fd >= 0
        const sock_fd = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
        if (sock_fd < 0) {
            puts("  socket(AF_INET, SOCK_DGRAM, 1) failed unexpectedly! [FAIL]\n");
            _ = sys1(SYS_EXIT_GROUP, 100);
        }
        puts("  socket(AF_INET, SOCK_DGRAM, 1) returned valid fd=");
        printNum(sock_fd);
        puts(" [PASS]\n");

        // Valid RAW socket (AF_INET, SOCK_RAW, 1) -> fd >= 0
        const raw_fd = sys3(SYS_SOCKET, AF_INET, SOCK_RAW, IPPROTO_ICMP);
        if (raw_fd < 0) {
            puts("  socket(AF_INET, SOCK_RAW, 1) failed unexpectedly! [FAIL]\n");
            _ = sys1(SYS_EXIT_GROUP, 101);
        }
        puts("  socket(AF_INET, SOCK_RAW, 1) returned valid fd=");
        printNum(raw_fd);
        puts(" [PASS]\n");

        _ = sys1(SYS_CLOSE, @intCast(raw_fd));
        _ = sys1(SYS_CLOSE, @intCast(sock_fd));
    }

    // ========================================================================
    // Challenge 2: sys_sendto error paths
    // ========================================================================
    puts("[CHALLENGE_2] Testing sys_sendto error conditions on ICMP socket...\n");
    {
        const sock_fd = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
        var dest = SockAddrIn{};
        var req = IcmpEchoPkt{};

        // Invalid fd (-1) -> -EBADF (-9)
        const r_badf = sys6(SYS_SENDTO, @bitCast(@as(isize, -1)), @intFromPtr(&req), @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&dest), @sizeOf(SockAddrIn));
        assertEqual("  sendto(fd=-1)", EBADF, r_badf);

        // Invalid fd (100) -> -EBADF (-9)
        const r_badf2 = sys6(SYS_SENDTO, 100, @intFromPtr(&req), @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&dest), @sizeOf(SockAddrIn));
        assertEqual("  sendto(fd=100)", EBADF, r_badf2);

        // Non-socket fd (fd 0 is stdin / not a socket) -> -ENOTSOCK (-88)
        const r_notsock = sys6(SYS_SENDTO, 0, @intFromPtr(&req), @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&dest), @sizeOf(SockAddrIn));
        assertEqual("  sendto(fd=0 non-socket)", ENOTSOCK, r_notsock);

        // Invalid user buffer pointer (0x0) with len > 0 -> -EFAULT (-14)
        const r_fault = sys6(SYS_SENDTO, @intCast(sock_fd), 0, @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&dest), @sizeOf(SockAddrIn));
        assertEqual("  sendto(buf_ptr=NULL)", EFAULT, r_fault);

        // Null dest_addr_ptr (0x0) -> -EINVAL (-22)
        const r_nulladdr = sys6(SYS_SENDTO, @intCast(sock_fd), @intFromPtr(&req), @sizeOf(IcmpEchoPkt), 0, 0, @sizeOf(SockAddrIn));
        assertEqual("  sendto(dest_addr_ptr=NULL)", EINVAL, r_nulladdr);

        // Truncated dest_addr_len (< 16) -> -EINVAL (-22)
        const r_truncaddr = sys6(SYS_SENDTO, @intCast(sock_fd), @intFromPtr(&req), @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&dest), 8);
        assertEqual("  sendto(dest_addr_len=8)", EINVAL, r_truncaddr);

        // Truncated packet len (< 8 bytes ICMP header) -> -EINVAL (-22)
        const r_trunclen = sys6(SYS_SENDTO, @intCast(sock_fd), @intFromPtr(&req), 4, 0, @intFromPtr(&dest), @sizeOf(SockAddrIn));
        assertEqual("  sendto(len=4 < 8)", EINVAL, r_trunclen);

        _ = sys1(SYS_CLOSE, @intCast(sock_fd));
    }

    // ========================================================================
    // Challenge 3: sys_recvfrom error paths
    // ========================================================================
    puts("[CHALLENGE_3] Testing sys_recvfrom error conditions on ICMP socket...\n");
    {
        var reply: IcmpEchoPkt = undefined;
        var src_addr: SockAddrIn = undefined;
        var addrlen: u32 = @sizeOf(SockAddrIn);

        // Invalid fd (-1) -> -EBADF (-9)
        const r_badf = sys6(SYS_RECVFROM, @bitCast(@as(isize, -1)), @intFromPtr(&reply), @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&src_addr), @intFromPtr(&addrlen));
        assertEqual("  recvfrom(fd=-1)", EBADF, r_badf);

        // Non-socket fd (0) -> -ENOTSOCK (-88)
        const r_notsock = sys6(SYS_RECVFROM, 0, @intFromPtr(&reply), @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&src_addr), @intFromPtr(&addrlen));
        assertEqual("  recvfrom(fd=0 non-socket)", ENOTSOCK, r_notsock);

        // Invalid buffer pointer (0x0) -> -EFAULT (-14)
        const sock_fd = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
        const r_fault = sys6(SYS_RECVFROM, @intCast(sock_fd), 0, @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&src_addr), @intFromPtr(&addrlen));
        assertEqual("  recvfrom(buf_ptr=NULL)", EFAULT, r_fault);

        _ = sys1(SYS_CLOSE, @intCast(sock_fd));
    }

    // ========================================================================
    // Challenge 4: End-to-end ping over VirtIO-Net dual virtqueues
    // ========================================================================
    puts("[CHALLENGE_4] Executing live ICMP ping to gateway 10.0.2.2...\n");
    {
        const sock_fd = sys3(SYS_SOCKET, AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
        if (sock_fd < 0) {
            puts("  Failed to open ICMP socket [FAIL]\n");
            _ = sys1(SYS_EXIT_GROUP, 102);
        }

        var dest = SockAddrIn{};
        var req = IcmpEchoPkt{};

        const sent = sys6(SYS_SENDTO, @intCast(sock_fd), @intFromPtr(&req), @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&dest), @sizeOf(SockAddrIn));
        assertEqual("  sendto valid 24-byte ICMP packet", @sizeOf(IcmpEchoPkt), sent);

        var reply: IcmpEchoPkt = undefined;
        var src_addr: SockAddrIn = undefined;
        var addrlen: u32 = @sizeOf(SockAddrIn);
        const recvd = sys6(SYS_RECVFROM, @intCast(sock_fd), @intFromPtr(&reply), @sizeOf(IcmpEchoPkt), 0, @intFromPtr(&src_addr), @intFromPtr(&addrlen));

        if (recvd < 8) {
            puts("  recvfrom returned less than 8 bytes: ");
            printNum(recvd);
            puts(" [FAIL]\n");
            _ = sys1(SYS_EXIT_GROUP, 103);
        }
        puts("  recvfrom returned bytes: ");
        printNum(recvd);
        puts(" [PASS]\n");

        if (reply.icmp_type != 0 or reply.code != 0) {
            puts("  reply type/code not Echo Reply (0/0) [FAIL]\n");
            _ = sys1(SYS_EXIT_GROUP, 104);
        }
        puts("  reply type=0 code=0 (Echo Reply) verified [PASS]\n");

        if (src_addr.sin_addr[0] != 10 or src_addr.sin_addr[1] != 0 or src_addr.sin_addr[2] != 2 or src_addr.sin_addr[3] != 2) {
            puts("  reply src_addr is not 10.0.2.2 [FAIL]\n");
            _ = sys1(SYS_EXIT_GROUP, 105);
        }
        puts("  reply source address verified as 10.0.2.2 [PASS]\n");

        _ = sys1(SYS_CLOSE, @intCast(sock_fd));
    }

    puts("[CHALLENGER_M17] ALL EMPIRICAL CHALLENGES PASSED CLEANLY!\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}

pub fn main() void {}
