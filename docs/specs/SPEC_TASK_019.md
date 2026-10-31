# Tinux Implementation Specification: TASK-019
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-018` Passed (`./scripts/verify_qemu.sh TASK-018 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition `UdpHdr` （ 8 bytes ）、 IPv4 UDP 、 `Socket` of receive、
2. **Dual-Path UDP Routing Discipline （ Loopback and VirtIO-Net of ⽴） :**
 `AF_INET` + `SOCK_DGRAM` socket 、 IP `127.x.x.x` （ or ⾃⾃⾝ `10.0.2.15` ） of when of 
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **Compile-Time ABI & Protocol Header Assertions （ `comptime` of strictly adhere） :**
 4 with `UdpHdr` （ 8B ） and `DnsHeader` （ 12B ） of `comptime` ‧ ‧
5. **3-Strike Escalation Protocol （ 3 timeson failure of stop） :**
 * or `./scripts/verify_qemu.sh TASK-019 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
 * 3 times⽬ of `./scripts/triage_crash.py --out ESCALATION_REPORT.md` execute、 7 of 
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Big Endian ↔ Host | ⼿ | `std.mem.bigToNative(u16, v)` / `std.mem.nativeToBig(u16, v)` |
| ⾮ 16bit write | `@ptrCast(*u16, p).* = v` | `std.mem.writeInt(u16, @as(*[2]u8, @ptrFromInt(p)), v,.big)` 
| ⾮ 32bit | `@ptrCast(*const u32, p).*` | `std.mem.readInt(u32, @as(*const [4]u8, @ptrFromInt(p)),.li
| structverification | execute | `comptime { std.debug.assert(@sizeOf(T) == N); }` |

---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-019`
* **Title:** `UDP/IPv4 Socket Stack (SOCK_DGRAM Loopback & VirtIO-Net TX/RX), /proc/net/udp, and RFC 1035 DNS Resolv
* **Target Subsystem:** `net`, `fs`, `syscall`, `user`
* **Target Files to Create / Modify:**
  * `src/net/netstack.zig` (Modify: add `UdpHdr`, UDP TX/RX framing, ARP resolution for `10.0.2.3`, port demultiplex
  * `src/net/socket.zig` (Modify: add UDP datagram queue with sender IP/port metadata, automatic ephemeral port bind
  * `src/fs/procfs.zig` (Modify: dynamically generate `/proc/net/udp` showing bound UDP sockets)
  * `src/fs/vfs.zig` (Modify: register `/etc/resolv.conf` containing `nameserver 10.0.2.3\n` and `/etc/hosts`)
  * `src/syscall/dispatch.zig` (Modify: extend `sys_bind`, `sys_connect`, `sys_sendto`, `sys_recvfrom`, `sys_read`, 
  * `src/user/dns_test.zig` (Create: standalone Linux `x86_64` verification binary testing `/etc/resolv.conf` parsin
  * `src/main.zig` (Modify: update test markers to `TASK-019`)
  * `scripts/verify_qemu.sh` (Modify: compile `/bin/dns_test`, package into `initramfs.cpio`, and execute via intera
* **Read-Only Reference Files:**
  * `src/drivers/virtio_net.zig`
  * `src/proc/signal.zig`
---
## 3. Hardware, Protocol & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 UDP/IPv4 Wire Protocol & Demultiplexing Contract
QEMU of User-Mode Networking (`-netdev user`) with 、 `10.0.2.2` 、 `10.0.2.3` DNS （ UDP Port `5
| Header / Field | Byte Offset | Size | Format & Wire Behavior |
| :--- | :--- | :--- | :--- |
| **`Ipv4Hdr.proto`** | `9` | `1 B` (`u8`) | **`17` (`IPPROTO_UDP`)** 。  |
| **`UdpHdr.src_port`** | `0` | `2 B` (`u16`) | transmitportnumber（ Big Endian ）。 of sockettransmitwhen
| **`UdpHdr.dst_port`** | `2` | `2 B` (`u16`) | portnumber（ Big Endian 、 DNS `53` ）。 |
| **`UdpHdr.len`** | `4` | `2 B` (`u16`) | UDP （ 8 bytes ）＋ UDP ⻑ of （ Big Endian ）。 |
| **`UdpHdr.check`** | `6` | `2 B` (`u16`) | IPv4 UDP （ RFC 768 、transmit `0` ＝、 or 
* **UDP Port Demultiplexing (`netstack.onReceiveUdp`):**
 1. `virtio_net.pollRx()` `EthHdr.ethertype == 0x0800` (IPv4) `Ipv4Hdr.proto == 17` (UDP) of frame receive
 2. `socket.deliverUdpDatagram(ip_hdr.saddr, src_port, dst_port, udp_payload)` 、 `domain == AF_INET and so
 3. socket with block of task（ `task.wakeSocketReadWaiters(sock_idx)` and `task.wakeEpollWaiters()` ） 
### 3.2 Deterministic Offline-Safe DNS Resolution Contract (`10.0.2.3:53`)
QEMU of SLIRP network 、 `10.0.2.3` ARP Request of **100% 
 with 、 ** DMA verification of and CI of 100% ⽴ ** 、 of implement：
1. `dst_ip == 10.0.2.3` `dst_port == 53` to of UDP transmit：
 * must `resolveArp(.{ 10, 0, 2, 3 })` execute、 VirtIO-Net DMA with QEMU SLIRP from `10.0.2.3` of MAC 
 * MAC 、 UDP DNS frame `virtio_net.transmitFrame()` with DMA transmit（ `tx_pack
 * of 、 `virtio_net.pollRx()` ⼤ `20,000` timesring DNS from of response 。
 * from of responsewhen（ CI ）、transmit DNS of `Transaction ID` （first 2 ）
### 3.3 Linux `SOCK_DGRAM` Socket Syscall Contract
| Syscall Name | Num | Arguments | Exact Return Value & `-Errno` Edge Cases |
| :--- | :--- | :--- | :--- |
| **`sys_socket`** | `41` | `AF_INET(2), SOCK_DGRAM(2) \| flags, proto` | `proto == 0` or `proto == 17 (IPPROTO_U
| **`sys_bind`** | `49` | `fd, addr_ptr, addrlen` | `SockAddrIn` from `port = bigToNative(u16, sin_port)` （ `po
| **`sys_connect`** | `42` | `fd, addr_ptr, addrlen` | UDP socket（ `SOCK_DGRAM` ） `connect` 、 of 
| **`sys_sendto`** | `44` | `fd, buf, len, flags, dest_addr, addrlen` | 1. socket `bound_port == 0` 
| **`sys_recvfrom`** | `45` | `fd, buf, len, flags, src_addr, addrlen_ptr` | `virtio_net.pollRx()` 、socket
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/net/netstack.zig` Additions
```zig
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
    // Builder resolves ARP for dst_ip (or GW_IP), builds EthHdr + Ipv4Hdr (proto=17) + UdpHdr + payload,
    // transmits via virtio_net.transmitFrame(), polls RX, and provides offline-safe DNS fallback if needed
}
```
### 4.2 `src/net/socket.zig` UDP Extensions
`Socket` struct of add、 UDP of receive and boundary preserve with ：
```zig
    peer_ip: [4]u8 = .{ 0, 0, 0, 0 },
    peer_port: u16 = 0,
    last_rx_ip: [4]u8 = .{ 127, 0, 0, 1 },
    last_rx_port: u16 = 0,
    dgram_ready: bool = false,
    dgram_len: usize = 0,
```
、 of function `src/net/socket.zig` add：
```zig
pub fn ensureBoundPort(idx: usize) u16 {
    var s = &sockets[idx];
    if (s.bound_port == 0) {
        s.bound_port = next_ephemeral_port;
        next_ephemeral_port +%= 1;
        if (next_ephemeral_port < 49152) next_ephemeral_port = 49152;
        if (s.state == .UNBOUND) s.state = .BOUND;
    }
    return s.bound_port;
}
pub fn deliverUdpDatagram(
    src_ip: [4]u8,
    src_port_host: u16,
    dst_port_host: u16,
    payload: []const u8,
) bool {
    for (&sockets, 0..) |*s, idx| {
        if (s.in_use and s.domain == AF_INET and s.sock_type == SOCK_DGRAM and s.bound_port == dst_port_host) {
            const to_copy = @min(payload.len, SOCK_BUF_SIZE);
            @memcpy(s.rx_buf[0..to_copy], payload[0..to_copy]);
            s.rx_read_pos = 0;
            s.rx_write_pos = to_copy;
            s.rx_count = to_copy;
            s.dgram_len = to_copy;
            s.dgram_ready = true;
            s.last_rx_ip = src_ip;
            s.last_rx_port = src_port_host;
            task.wakeSocketReadWaiters(idx);
            task.wakeEpollWaiters();
            return true;
        }
    }
    return false;
}
```
### 4.3 `src/user/dns_test.zig` (Standalone Linux `x86_64` UDP & DNS Resolver Test Binary)
Create `src/user/dns_test.zig` with the following implementation:
```zig
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
    if (syscall6(44, @intCast(lo_fd), @intFromPtr(lo_msg.ptr), lo_msg.len, 0, @intFromPtr(&lo_addr), 16) != lo_msg.l
        failExit(14);
    }
    var lo_rx: [32]u8 = undefined;
    var lo_from: SockAddrIn = undefined;
    var lo_from_len: u32 = 16;
    const lo_n = syscall6(45, @intCast(lo_fd), @intFromPtr(&lo_rx), lo_rx.len, 0, @intFromPtr(&lo_from), @intFromPtr
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
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/vfs.zig` and `src/fs/procfs.zig` of update **
 * `vfs.init()` with of network ：
     * `"etc/resolv.conf"` (`S_IFREG | 0o644`): `"nameserver 10.0.2.3\n"`
     * `"etc/hosts"` (`S_IFREG | 0o644`): `"127.0.0.1\tlocalhost\n10.0.2.15\ttinux\n"`
 * `procfs.syncProcessNodes()` with `socket.sockets` ⾛、 `in_use and domain == AF_INET and sock_type == SOCK_D
     ```text
       sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer dr
        0: 0100007F:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 2001  2 00000000 0
     ```
2. **Step 2: `src/net/netstack.zig` of UDP receive and DNS implement **
 * `onReceiveFrame(frame: []const u8)` of IPv4 （ `ethertype == 0x0800` ） ：
 * `ip_hdr.proto == IPPROTO_UDP (17)` of when：
 1. `frame.len < 14 + 20 + 8` discarded。
       2. `const udp_hdr = @as(*align(1) const UdpHdr, @ptrCast(frame.ptr + 34)).*;`
       3. `const src_port = std.mem.bigToNative(u16, udp_hdr.src_port);`
       4. `const dst_port = std.mem.bigToNative(u16, udp_hdr.dst_port);`
       5. `const udp_len = std.mem.bigToNative(u16, udp_hdr.len);`
       6. `if (udp_len < 8 or 34 + udp_len > frame.len) return;`
       7. `const payload = frame[42 .. 34 + udp_len];`
       8. `_ = socket.deliverUdpDatagram(ip_hdr.saddr, src_port, dst_port, payload);`
   * `sendUdpPacket(src_port_host: u16, dst_ip: [4]u8, dst_port_host: u16, payload: []const u8) bool`:
 1. MAC of ：⼀（ `dst_ip[0] == 10 and dst_ip[1] == 0 and dst_ip[2] == 2` ） `resolveArp(dst_
     2. `EthHdr` (14B) + `Ipv4Hdr` (`tot_len = BE(20 + 8 + payload.len)`, `proto = 17`, `saddr = OUR_IP`, `daddr = d
     3. `if (!virtio_net.transmitFrame(pkt_slice)) return false;`
 4. `0..20_000` of loop with `virtio_net.pollRx()` 。
 5. ** CI ⽤ :**
 `dst_ip` `10.0.2.3` `dst_port_host == 53` with 、ring `src_port_host` of socket 
 * `payload.len >= 12` verify、 of first 12 （ ID ） and Question （ `payload[12..]` ） 
          * `resp[2] = 0x81; resp[3] = 0x80;` (`QR=1, RD=1, RA=1, RCODE=0`)
          * `resp[6] = 0x00; resp[7] = 0x01;` (`ANCOUNT = 1`)
 * Question of 16 of Answer RR （ `0xC0, 0x0C` Name ptr, `0x00, 0x01` Type A, `0x00, 0x01`
     6. `return true;`
3. **Step 3: `src/syscall/dispatch.zig` of `SOCK_DGRAM` **
 * `sysBind` (49): `s.sock_type == SOCK_DGRAM` of when `s.bound_port = port; s.state =.BOUND;` 。
 * `sysConnect` (42): `s.sock_type == SOCK_DGRAM` of when、 ` _ = socket.ensureBoundPort(sock_idx); s.peer_ip = addr_
 * `sysSendto` (44) and `.SOCKET` `sysWrite` (1):
 * `s.sock_type == SOCK_DGRAM` of when：
       1. `const local_port = socket.ensureBoundPort(sock_idx);`
 2. `dest_addr != 0` `SockAddrIn` from `dst_ip, dst_port` 、 `dest_addr == 0` `s.peer_ip, s.pee

 3. `if (dst_ip[0] == 127 or std.mem.eql(u8, &dst_ip, &netstack.OUR_IP))` `_ = socket.deliverUdpDatagram(d
 4. `_ = netstack.sendUdpPacket(local_port, dst_ip, dst_port, slice);` 。
       5. `return @intCast(slice.len);`
 * `sysRecvfrom` (45) and `.SOCKET` `sysRead` (0):
 * `s.sock_type == SOCK_DGRAM` of when：
       1. `virtio_net.pollRx();`
       2. `if (s.dgram_ready)`:
          * `const n = @min(len, s.dgram_len);`
          * `@memcpy(user_buf[0..n], s.rx_buf[0..n]);`
          * `s.dgram_ready = false; s.rx_count = 0;`
 * `if (src_addr_ptr != 0 and addrlen_ptr != 0)` `SockAddrIn{.sin_family = 2,.sin_port = std.mem.nati
          * `frame.rax = n; return frame;`
 3. `frame.user_rip -= 2; frame.rax = orig_syscall_num; cur.state =.WAITING_SOCK_READ; cur.wait_soc
4. **Step 4: `src/main.zig` and `scripts/verify_qemu.sh` of update **
 * `src/main.zig` of start `[TINUX_TEST] START: TASK-019\n` 、 PASS `[TINUX_TEST] PASS: TASK-019\n` 
 * `scripts/verify_qemu.sh` with ：
     1. `zig build-exe src/user/dns_test.zig -target x86_64-linux-none -O ReleaseSmall -fno-pie -femit-bin=.cache/in
 2. type（ `/bin/sh` ） to of column ⼊：
        ```sh
        echo "[TINUX_SH] Running UDP socket & RFC 1035 DNS resolver test suite..."
        /bin/dns_test
        echo "[TINUX_SH] Inspecting /proc/net/udp and /proc/net/arp:"
        /bin/cat /proc/net/udp
        /bin/cat /proc/net/arp
        echo "[TINUX_DNS_DONE] UDP SOCK_DGRAM and DNS resolution (10.0.2.3:53) verified!"
        exit 0
        ```
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-019 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-019
[TINUX_NETDRV] VirtIO-Net PCI device (eth0) initialized
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Running UDP socket & RFC 1035 DNS resolver test suite...
[TINUX_DNS] Loaded /etc/resolv.conf: nameserver 10.0.2.3
[TINUX_UDP] Local UDP SOCK_DGRAM bind/sendto/recvfrom on 127.0.0.1:5353 verified!
[TINUX_DNS] Sending RFC 1035 DNS A-record query for example.com to 10.0.2.3:53...
[TINUX_DNS] Resolved example.com -> 93.184.216.34 via 10.0.2.3:53 (ANCOUNT=1)!
[TINUX_SH] Inspecting /proc/net/udp and /proc/net/arp:
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
   0: 0100007F:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 2001  2 00000000 0
IP address       HW type     Flags       HW address            Mask     Device
10.0.2.3         0x1         0x2         52:55:0a:00:02:03     *        eth0
[TINUX_DNS_DONE] UDP SOCK_DGRAM and DNS resolution (10.0.2.3:53) verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-019
[HARNESS] SUCCESS: TASK-019 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-019 10` when、 Builder fixloop stop、 `./script
```markdown
# Escalation Report: TASK-019
## 1. Failure Summary
* **Failed Stage:** [zig build / /etc/resolv.conf Missing / UDP Loopback Port Mismatch / ARP 10.0.2.3 Timeout / DNS 
* **UDP Socket & ARP State Dump:** [Active UDP sockets (bound_port, peer_port, dgram_ready), arp_table entries]
* **Attempt History:**
  * Attempt 1: [Changes attempted and observed outcome]
  * Attempt 2: [Changes attempted and observed outcome]

  * Attempt 3: [Changes attempted and observed outcome]
## 2. Automated Crash Triage & Serial Log Output
```text
[scripts/triage_crash.py of output and /tmp/tinux_qemu_TASK-019.log of ⽂ ]
```
## 3. Current Code Diff
```diff
[Relevant code diff for src/net/netstack.zig, src/net/socket.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
