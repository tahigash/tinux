const std = @import("std");

const AF_UNIX: u16 = 1;
const AF_INET: u16 = 2;
const SOCK_STREAM: usize = 1;
const SOL_SOCKET: usize = 1;
const SO_REUSEADDR: usize = 2;

const SockAddrIn = extern struct {
    sin_family: u16 = AF_INET,
    sin_port: u16 = 0,
    sin_addr: [4]u8 = .{ 127, 0, 0, 1 },
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call netMain
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

inline fn syscall2(num: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
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

inline fn syscall5(num: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}"  (a5),
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

fn runServer() noreturn {
    const listen_fd = syscall3(41, AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) failExit(10);

    var optval: i32 = 1;
    _ = syscall5(54, @intCast(listen_fd), SOL_SOCKET, SO_REUSEADDR, @intFromPtr(&optval), 4);

    var addr = SockAddrIn{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, 8080),
        .sin_addr = .{ 127, 0, 0, 1 },
    };
    if (syscall3(49, @intCast(listen_fd), @intFromPtr(&addr), @sizeOf(SockAddrIn)) != 0) failExit(11);
    if (syscall2(50, @intCast(listen_fd), 4) != 0) failExit(12);

    writeStdout("[TINUX_NET] TCP server listening on 127.0.0.1:8080...\n");

    var peer_addr: SockAddrIn = undefined;
    var peer_len: u32 = @sizeOf(SockAddrIn);
    const conn_fd = syscall3(43, @intCast(listen_fd), @intFromPtr(&peer_addr), @intFromPtr(&peer_len));
    if (conn_fd < 0) failExit(13);

    var rx_buf: [64]u8 = undefined;
    const n_read = syscall3(0, @intCast(conn_fd), @intFromPtr(&rx_buf), rx_buf.len);
    if (n_read <= 0) failExit(14);

    writeStdout("[TINUX_NET] Server received: ");
    writeStdout(rx_buf[0..@intCast(n_read)]);

    const reply = "PONG_FROM_TINUX_SERVER\n";
    if (syscall3(1, @intCast(conn_fd), @intFromPtr(reply.ptr), reply.len) != reply.len) failExit(15);

    _ = syscall1(3, @intCast(conn_fd));
    _ = syscall1(3, @intCast(listen_fd));
    _ = syscall1(231, 0);
    unreachable;
}

fn runClient() noreturn {
    // 1. Verify AF_UNIX socketpair(53) bidirectional IPC
    var sv: [2]i32 = .{ -1, -1 };
    if (syscall4(53, AF_UNIX, SOCK_STREAM, 0, @intFromPtr(&sv)) != 0) failExit(20);

    const u_msg = "UNIX_SOCKETPAIR_OK";
    if (syscall3(1, @intCast(sv[0]), @intFromPtr(u_msg.ptr), u_msg.len) != u_msg.len) failExit(21);

    var u_rx: [32]u8 = undefined;
    if (syscall3(0, @intCast(sv[1]), @intFromPtr(&u_rx), u_rx.len) != u_msg.len) failExit(22);

    _ = syscall1(3, @intCast(sv[0]));
    _ = syscall1(3, @intCast(sv[1]));
    writeStdout("[TINUX_NET] AF_UNIX socketpair bidirectional stream verified!\n");

    // 2. Connect to TCP server at 127.0.0.1:8080
    const sock_fd = syscall3(41, AF_INET, SOCK_STREAM, 0);
    if (sock_fd < 0) failExit(23);

    var srv_addr = SockAddrIn{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, 8080),
        .sin_addr = .{ 127, 0, 0, 1 },
    };
    if (syscall3(42, @intCast(sock_fd), @intFromPtr(&srv_addr), @sizeOf(SockAddrIn)) != 0) failExit(24);

    const ping = "PING_FROM_TINUX_CLIENT\n";
    if (syscall3(1, @intCast(sock_fd), @intFromPtr(ping.ptr), ping.len) != ping.len) failExit(25);

    var rx_buf: [64]u8 = undefined;
    const n_read = syscall3(0, @intCast(sock_fd), @intFromPtr(&rx_buf), rx_buf.len);
    if (n_read <= 0) failExit(26);

    writeStdout("[TINUX_NET] Client received: ");
    writeStdout(rx_buf[0..@intCast(n_read)]);

    _ = syscall1(3, @intCast(sock_fd));
    _ = syscall1(231, 0);
    unreachable;
}

export fn netMain(initial_rsp: [*]const u64) callconv(.C) noreturn {
    const argc = initial_rsp[0];
    if (argc >= 2) {
        const arg1_ptr = @as([*:0]const u8, @ptrFromInt(initial_rsp[2]));
        const arg1 = std.mem.sliceTo(arg1_ptr, 0);
        if (std.mem.eql(u8, arg1, "server")) {
            runServer();
        }
    }
    runClient();
}
