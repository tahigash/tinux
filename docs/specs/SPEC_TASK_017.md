# Tinux Implementation Specification: TASK-017
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-016` Passed (`./scripts/verify_qemu.sh TASK-016 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**

 specification with definition VirtIO-Net Legacy PCI Register Offset、 2 of Virtqueue （ `RXQ = 0`, `TXQ = 1` ） of memoryplaced、
2. **Strict VirtIO-Net Dual-Queue DMA Discipline （ RX/TX DMA of strictly adhere） :**
 VirtIO-Net receive⽤ of **Queue 0 (`RXQ`)** and transmit⽤ of **Queue 1 (`TXQ`)** of 2 of Virtqueue use。 of ring
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **Compile-Time ABI & Protocol Header Assertions （ `comptime` of strictly adhere） :**
 4 with of networkstruct（ `VirtioNetHdr == 10`, `EthHdr == 14`, `ArpPkt == 28`, `Ipv4Hdr
5. **3-Strike Escalation Protocol （ 3 timeson failure of stop） :**
 * or `./scripts/verify_qemu.sh TASK-017 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
 * 3 times⽬ of `./scripts/triage_crash.py --out ESCALATION_REPORT.md` execute、 7 of 
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Big Endian → Host | ⼿ | `std.mem.bigToNative(u16, net_val)` |
| Host → Big Endian | ⼿ | `std.mem.nativeToBig(u16, host_val)` |
| ⾮ 16bit | `@ptrCast(*const u16, p).*` | `std.mem.readInt(u16, @as(*const [2]u8, @ptrFromInt(p)),.bi
| memory | with of DMA Ring update | `asm volatile ("mfence" ::: "memory");` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-017`
* **Title:** `VirtIO-Net PCI Network Driver (TX/RX Virtqueue DMA), Ethernet/ARP/IPv4/ICMP Stack, and External Gatewa
* **Target Subsystem:** `drivers`, `net`, `fs`, `syscall`, `user`
* **Target Files to Create / Modify:**
  * `src/drivers/virtio_net.zig` (Create: VirtIO-Net PCI `1AF4:1000` driver, RXQ/TXQ DMA ring manager, MAC reader)
  * `src/net/netstack.zig` (Create: Ethernet II, ARP table & responder/requester, IPv4, and ICMP Echo Request/Reply 
  * `src/net/socket.zig` (Modify: support `AF_INET` + `IPPROTO_ICMP = 1` external ping sockets connected to `netstac
  * `src/fs/procfs.zig` (Modify: dynamically generate `/proc/net/dev` and `/proc/net/arp`)
  * `src/drivers/timer.zig` (Modify: poll `virtio_net.pollRx()` inside `onTick()` so incoming packets are processed 
  * `src/syscall/dispatch.zig` (Modify: wire `IPPROTO_ICMP` `sendto`/`recvfrom` to external `netstack.sendPing` / `n
  * `src/user/ping_test.zig` (Create: standalone Linux `x86_64` ICMP ping verification binary targeting QEMU SLIRP g
  * `src/main.zig` (Modify: initialize `virtio_net.init()` and `netstack.init()`, update test markers to `TASK-017`)
  * `scripts/verify_qemu.sh` (Modify: attach `-netdev user,id=net0 -device virtio-net-pci,netdev=net0,disable-legacy
* **Read-Only Reference Files:**
  * `src/drivers/pci.zig`
  * `src/drivers/virtio_blk.zig`
  * `src/arch/x86_64/io.zig`
---
## 3. Hardware, Protocol & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 VirtIO-Net Legacy PCI (`0x1AF4:0x1000`) Register & Dual-Queue Contract
QEMU of `-device virtio-net-pci,netdev=net0,disable-legacy=off` PCI Vendor ID `0x1AF4` 、 Device ID **`0x1000`** and 
| Offset | Width | Name | Exact Initialization & Runtime Behavior |
| :--- | :--- | :--- | :--- |
| `+0x00` | `u32` (R) | `HOST_FEATURES` | Device 。 |
| `+0x04` | `u32` (W) | `GUEST_FEATURES` | `host_features & ((1 << 5) \| (1 << 27))` （ `VIRTIO_NET_F_MAC` and `VIRT
| `+0x08` | `u32` (RW)| `QUEUE_PFN` | of queue（ `QUEUE_SEL` ） of ringPhysical address `>> 12` 。 |
| `+0x0C` | `u16` (R) | `QUEUE_NUM` | of queue of `Q` （ QEMU `256` ） 。 |
| `+0x0E` | `u16` (RW)| `QUEUE_SEL` | **`0` = `RXQ` （receive⽤ Virtqueue ） ** 、 **`1` = `TXQ` （transmit⽤ Virtqueue ） ** 。⽅ and 
| `+0x10` | `u16` (W) | `QUEUE_NOTIFY` | receivebuffer `0` (`RXQ`) 、packettransmit `1` (`TXQ`) 。 |
| `+0x12` | `u8` (RW) | `DEVICE_STATUS` | `0x00` (Reset) → `0x01` (`ACK`) → `0x03` (`ACK\|DRIVER`) → Feature/RXQ/TXQ
| `+0x14..+0x19` | `6 x u8` (R) | `MAC_ADDR[0..6]` | Device of 6 MAC （ QEMU `52:54:00:12:34:56`
#### Legacy `VirtioNetHdr` (10 Bytes Fixed) & Descriptor Buffer Rules:
* `VIRTIO_NET_F_MRG_RXBUF` disabled Legacy with 、 of receiveframe of first **10 bytes** of `VirtioNetHdr` 
* **`RXQ` (Queue 0) of :**
 `init()` `NUM_RX_BUFS = 16` of receivebuffer（ `2048 bytes` ） Descriptor `0..15` （ `flags = VRING_DES
* **`TXQ` (Queue 1) of transmit :**
 10 of zerocleared `VirtioNetHdr` ＋ Ethernet frame（⼩ 60 ） `tx_buf` 、 `tx_descs[0

### 3.2 QEMU User-Mode Network (SLIRP) IPv4 & ARP/ICMP Contract
QEMU of `-netdev user` (SLIRP) network of ：
* **Tinux Guest IP (`OUR_IP`):** `10.0.2.15` (`{ 10, 0, 2, 15 }`)
* **QEMU Gateway / Router IP (`GW_IP`):** `10.0.2.2` (`{ 10, 0, 2, 2 }`)
* **Wire Packet Processing Rules (`netstack.zig`):**
  1. **RFC 1071 Checksum (`internetChecksum`):**
 16-bit Big-Endian of 1 of of 。 IPv4 （ 20 bytes ） and ICMP packet（ 8 bytes 
  2. **ARP (`EtherType = 0x0806`):**
 * receive ARP Request (`oper == 1`) of IP (`tpa`) `10.0.2.15` with 、 Tinux of MAC 
 * receive ARP packet（ Request or Reply ） of transmit IP (`spa`) and transmit MAC (`sha`) of ARP cache
  3. **IPv4 (`EtherType = 0x0800`) & ICMP (`proto = 1`):**
 * receive ICMP **Echo Request (`type == 8, code == 0`)** with 、 transmit to **Echo Reply (`type == 0, co
 * receive ICMP **Echo Reply (`type == 0, code == 0`)** with 、 `last_reply_seq`, `last_reply_id`, `last_rep
### 3.3 Linux Unprivileged ICMP Socket & `/proc/net/{dev,arp}` Contract
* **`sys_socket(AF_INET = 2, SOCK_DGRAM | SOCK_RAW, IPPROTO_ICMP = 1)`:**
 `proto == 1` (`IPPROTO_ICMP`) with createsocket 、 `sys_sendto` with 8 of `IcmpHdr` (`type = 8` Echo Request
* **`sys_recvfrom` on ICMP Socket:**
 `netstack` `Echo Reply` receive、 8 of `IcmpHdr` (`type = 0` Echo Reply) ＋ buffer 
* **`/proc/net/dev` & `/proc/net/arp`:**
 `eth0` of receivepacket‧、 and `10.0.2.2` of MAC （ `52:55:0a:00:02:02` ） Linux 
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/drivers/virtio_net.zig`
```zig
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
```
### 4.2 `src/net/netstack.zig`
```zig
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
```
### 4.3 `src/user/ping_test.zig` (Standalone Linux `x86_64` ICMP Ping Test Binary)
Create `src/user/ping_test.zig` with the following implementation:
```zig
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
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/drivers/virtio_net.zig` Implementation **
   * `init() bool`:
     1. `const pci_dev = pci.findDeviceAndEnableDma(VIRTIO_VENDOR_ID, VIRTIO_NET_DEVICE_ID) orelse return false;`
     2. `io_base = pci_dev.io_base;`
     3. `io.outb(io_base + 0x12, 0x00);` (Reset) → `0x01` (`ACK`) → `0x03` (`ACK | DRIVER`) 。
     4. `const host_feat = io.inl(io_base + 0x00);`
     5. `io.outl(io_base + 0x04, host_feat & (VIRTIO_NET_F_MAC | VIRTIO_F_ANY_LAYOUT));`
 6. `0..6` loop `mac_addr[i] = io.inb(io_base + 0x14 + @as(u16, @intCast(i)));` 。
 7. **Queue 0 (`RXQ`) of :**
        * `io.outw(io_base + 0x0E, 0);` (`QUEUE_SEL = 0`)
        * `rx_queue_size = io.inw(io_base + 0x0C);`
        * `@memset(&rx_vring_mem, 0);`
        * `io.outl(io_base + 0x08, @as(u32, @intCast(@intFromPtr(&rx_vring_mem) >> 12)));`
        * `rx_descs = @as([*]volatile VirtqDesc, @ptrFromInt(@intFromPtr(&rx_vring_mem)));`
        * `rx_avail_base = @intFromPtr(&rx_vring_mem) + (@as(usize, rx_queue_size) * 16);`
 * `0..NUM_RX_BUFS` of `i` 、 `rx_descs[i] =.{.addr = @intFromPtr(&rx_pkt_bufs[i]),.len = PA
 * `asm volatile ("mfence" ::: "memory");` of 、 `rx_avail_idx.* = NUM_RX_BUFS;` 。
 8. **Queue 1 (`TXQ`) of :**
        * `io.outw(io_base + 0x0E, 1);` (`QUEUE_SEL = 1`)
        * `tx_queue_size = io.inw(io_base + 0x0C);`
        * `@memset(&tx_vring_mem, 0);`
        * `io.outl(io_base + 0x08, @as(u32, @intCast(@intFromPtr(&tx_vring_mem) >> 12)));`
     9. `io.outb(io_base + 0x12, 0x07);` (`DRIVER_OK`)
 10. `io.outw(io_base + 0x10, 0);` (`QUEUE_NOTIFY = 0` with RX buffer QEMU notified) 。
     11. `dev_ready = true; return true;`
   * `pollRx() void`:
     * `if (!dev_ready) return;`
 * `RXQ` of Used Ring (`rx_used_base`) of `idx` verify、 `rx_last_used_idx != rx_used_idx` of loop：
       1. `const elem = rx_used_ring[rx_last_used_idx % rx_queue_size];`
       2. `const desc_id: usize = @intCast(elem.id);`
       3. `const total_len: usize = @intCast(elem.len);`
 4. `if (total_len > @sizeOf(VirtioNetHdr))` 、 `const eth_slice = rx_pkt_bufs[desc_id][10..total_len];` 
 5. `desc_id` `rx_avail_ring[cur_avail % rx_queue_size] = @intCast(desc_id)` 、 `mfence`
       6. `rx_last_used_idx +%= 1;`
2. **Step 2: `src/net/netstack.zig` of ARP / IPv4 / ICMP implement **
   * `resolveArp(target_ip: [4]u8) ?[6]u8`:
 1. `arp_table` `target_ip` of `mac` 。
 2. `EthHdr` (`dst = FF:FF:FF:FF:FF:FF`, `src = virtio_net.mac_addr`, `ethertype = nativeToBig(u16, 0x08
 3. ⼤ `100_000` of ringloop with `virtio_net.pollRx()` 、 `arp_table` of `ma
   * `sendIcmpEchoRequest(dst_ip: [4]u8, id_be: u16, seq_be: u16, payload: []const u8) bool`:
 1. ⼀（ `10.0.2.x` ） `dst_ip` 、 `GW_IP` (`10.0.2.2`) `resolveArp` with MAC 
 2. `EthHdr` (14B) + `Ipv4Hdr` (20B) + `IcmpHdr` (8B) + `payload` buffer ⽴。
 3. `IcmpHdr.checksum = 0` of state with ICMP （ `8 + payload.len` ） `internetChecksum` `IcmpHdr.ch
 4. `Ipv4Hdr.check = 0` of state with IPv4 （ 20 bytes ） `internetChecksum` `Ipv4Hdr.check` 
 5. `virtio_net.transmitFrame` with transmit。
3. **Step 3: socket（ `socket.zig` / `dispatch.zig` ） and `/proc/net/{dev,arp}` of **

 * `Socket` struct `proto: u16 = 0` add、 `sys_socket` (41) with `protocol` (`rdx`) 。
 * `sys_sendto` (44) 、 `sock.domain == AF_INET and sock.proto == 1` (`IPPROTO_ICMP`) of when：
 * `dest_addr` from `SockAddrIn` 、buffer of `IcmpHdr` (`id`, `sequence`) and `net
 * `sys_recvfrom` (45) 、 `sock.domain == AF_INET and sock.proto == 1` of when：
 * `virtio_net.pollRx()` 、 `netstack` ICMP Echo Reply buffer to `src_addr` 
 * `src/fs/procfs.zig` of `syncProcessNodes()` with ：
 * `"proc/net/dev"` `eth0: {rx_bytes} {rx_packets}... {tx_bytes} {tx_packets}` 。
 * `"proc/net/arp"` `arp_table` of （e.g.： `10.0.2.2 0x1 0x2 52:55:0a:00:02:02 * eth0` ） 
4. **Step 4: `src/main.zig` and `scripts/verify_qemu.sh` of update **
 * `src/main.zig` of `kmain()` with `virtio_blk.init()` of `if (virtio_net.init()) { netstack.init(); serial.wr
 * `scripts/verify_qemu.sh` with ：
     1. `zig build-exe src/user/ping_test.zig -target x86_64-linux-none -O ReleaseSmall -fno-pie -femit-bin=.cache/i
 2. QEMU of add：
        ```bash
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0,disable-legacy=off
        ```
 3. type（ `/bin/sh` ） to of column ⼊：
        ```sh
        echo "[TINUX_SH] Executing external ICMP ping over VirtIO-Net (eth0)..."
        /bin/ping_test
        echo "[TINUX_SH] Inspecting /proc/net/arp and /proc/net/dev:"
        /bin/cat /proc/net/arp
        /bin/cat /proc/net/dev
        echo "[TINUX_VIRTIONET] External ARP resolution and ICMP ping to 10.0.2.2 verified!"
        exit 0
        ```
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-017 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-017
[TINUX_NETDRV] VirtIO-Net PCI device (eth0) initialized
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Executing external ICMP ping over VirtIO-Net (eth0)...
[TINUX_PING] Sending ARP + ICMP Echo Request to QEMU Gateway 10.0.2.2...
[TINUX_PING] 24 bytes from 10.0.2.2: icmp_seq=1 ttl=255 (VirtIO-Net RX/TX DMA verified!)
[TINUX_SH] Inspecting /proc/net/arp and /proc/net/dev:
IP address       HW type     Flags       HW address            Mask     Device
10.0.2.2         0x1         0x2         52:55:0a:00:02:02     *        eth0
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets
  eth0:     102       2    0    0    0     0          0         0      102       2
[TINUX_VIRTIONET] External ARP resolution and ICMP ping to 10.0.2.2 verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-017
[HARNESS] SUCCESS: TASK-017 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-017 10` when、 Builder fixloop stop、 `./script
```markdown
# Escalation Report: TASK-017
## 1. Failure Summary
* **Failed Stage:** [zig build / PCI 1AF4:1000 Not Found / RXQ Buffer Not Populated / ARP Reply Timeout / IPv4 or IC
* **VirtIO-Net & ARP State Dump:** [io_base, mac_addr, rx_packets, tx_packets, arp_table entries]
* **Attempt History:**
  * Attempt 1: [Changes attempted and observed outcome]
  * Attempt 2: [Changes attempted and observed outcome]

  * Attempt 3: [Changes attempted and observed outcome]
## 2. Automated Crash Triage & Serial Log Output
```text
[scripts/triage_crash.py of output and /tmp/tinux_qemu_TASK-017.log of ⽂ ]
```
## 3. Current Code Diff
```diff
[Relevant code diff for src/drivers/virtio_net.zig, src/net/netstack.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
