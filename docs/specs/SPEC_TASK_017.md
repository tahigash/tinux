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
   Do not alter VirtIO-Net legacy PCI register offsets, dual-virtqueue layout (`RXQ = 0`, `TXQ = 1`), packet buffer layouts, or networking syscall signatures.
2. **Strict VirtIO-Net Dual-Queue DMA Discipline:**
   VirtIO-Net utilizes two independent virtqueues: Queue 0 (`RXQ`) for reception and Queue 1 (`TXQ`) for transmission. Queue ring buffers must be physically contiguous and properly decoupled.
3. **Strict Zig Version Idioms:**
   Adhere strictly to modern Zig idioms (0.13+) as defined in Section 1. Do not use deprecated functions like `@ptrToInt` or `@intToPtr`.
4. **Compile-Time ABI & Protocol Header Assertions:**
   Assert exact struct sizes at compile time for `VirtioNetHdr` (10 bytes), `EthHdr` (14 bytes), `ArpPkt` (28 bytes), `Ipv4Hdr` (20 bytes), and `IcmpHdr` (8 bytes).
5. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-017 10` fails 3 consecutive times, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Big Endian to Host | Manual byte shifts | `std.mem.bigToNative(u16, net_val)` |
| Host to Big Endian | Manual byte shifts | `std.mem.nativeToBig(u16, host_val)` |
| Unaligned 16-bit read | `@ptrCast(*const u16, p).*` | `std.mem.readInt(u16, @as(*const [2]u8, @ptrFromInt(p)), .big)` |
| Memory fence | Compiler barrier only | `asm volatile ("mfence" ::: "memory");` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-017`
* **Title:** `VirtIO-Net PCI Network Driver (TX/RX Virtqueue DMA), Ethernet/ARP/IPv4/ICMP Stack, and External Gateway Ping Verification (10.0.2.2)`
* **Target Subsystem:** `drivers`, `net`, `fs`, `syscall`, `user`
* **Target Files to Create / Modify:**
  * `src/drivers/virtio_net.zig` (Create: VirtIO-Net PCI `1AF4:1000` driver, RXQ/TXQ DMA ring manager, MAC reader)
  * `src/net/netstack.zig` (Create: Ethernet II, ARP table and responder/requester, IPv4, and ICMP Echo Request/Reply)
  * `src/net/socket.zig` (Modify: support `AF_INET` + `IPPROTO_ICMP = 1` external ping sockets connected to `netstack`)
  * `src/fs/procfs.zig` (Modify: dynamically generate `/proc/net/dev` and `/proc/net/arp`)
  * `src/drivers/timer.zig` (Modify: poll `virtio_net.pollRx()` inside `onTick()` so incoming packets are processed)
  * `src/syscall/dispatch.zig` (Modify: wire `IPPROTO_ICMP` `sendto`/`recvfrom` to external `netstack.sendPing` / `netstack.recvPing`)
  * `src/user/ping_test.zig` (Create: standalone Linux `x86_64` ICMP ping verification binary targeting QEMU SLIRP gateway)
  * `src/main.zig` (Modify: initialize `virtio_net.init()` and `netstack.init()`, update test markers to `TASK-017`)
  * `scripts/verify_qemu.sh` (Modify: attach `-netdev user,id=net0 -device virtio-net-pci,netdev=net0,disable-legacy=off`, compile test app)
* **Read-Only Reference Files:**
  * `src/drivers/pci.zig`
  * `src/drivers/virtio_blk.zig`
  * `src/arch/x86_64/io.zig`
---
## 3. Hardware, Protocol & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 VirtIO-Net Legacy PCI (`0x1AF4:0x1000`) Register & Dual-Queue Contract
QEMU presents transitional VirtIO network cards with PCI Vendor ID `0x1AF4` and Device ID `0x1000`:
| Offset | Width | Name | Exact Initialization & Runtime Behavior |
| :--- | :--- | :--- | :--- |
| `+0x00` | `u32` (R) | `HOST_FEATURES` | Read features supported by host device. |
| `+0x04` | `u32` (W) | `GUEST_FEATURES` | Write accepted features: `host_features & ((1 << 5) \| (1 << 27))` (`VIRTIO_NET_F_MAC` and `VIRTIO_F_ANY_LAYOUT`). |
| `+0x08` | `u32` (RW)| `QUEUE_PFN` | Write page frame number of selected virtqueue ring (`ring_phys >> 12`). |
| `+0x0C` | `u16` (R) | `QUEUE_NUM` | Read queue size `Q` reported by device (typically 256 in QEMU). |
| `+0x0E` | `u16` (RW)| `QUEUE_SEL` | Select queue index: write `0` for `RXQ` (reception), write `1` for `TXQ` (transmission). |
| `+0x10` | `u16` (W) | `QUEUE_NOTIFY` | Notify queue index: write `0` to signal posted RX buffers, write `1` to signal TX packet ready. |
| `+0x12` | `u8` (RW) | `DEVICE_STATUS` | State sequence: 0x00 (Reset) -> 0x01 (ACK) -> 0x03 (ACK\|DRIVER) -> Feature/Queue setup -> 0x07 (DRIVER_OK). |
| `+0x14..+0x19` | `6 x u8` (R) | `MAC_ADDR[0..6]` | Read device hardware MAC address (default QEMU MAC: `52:54:00:12:34:56`). |
#### Legacy `VirtioNetHdr` (10 Bytes Fixed) & Descriptor Buffer Rules:
* When `VIRTIO_NET_F_MRG_RXBUF` is disabled in legacy mode, every frame begins with a fixed 10-byte `VirtioNetHdr`.
* **`RXQ` (Queue 0) Configuration:**
  In `init()`, allocate 16 receive buffers (`2048 bytes` each). Populate descriptors `0..15` with `VRING_DESC_F_WRITE` and add indices to Available Ring.
* **`TXQ` (Queue 1) Transmission:**
  Prepend 10-byte zeroed `VirtioNetHdr` to the Ethernet frame (minimum frame size 60 bytes). Place into `tx_buf`, populate descriptor 0 without `VRING_DESC_F_WRITE`, and notify queue 1.
### 3.2 QEMU User-Mode Network (SLIRP) IPv4 & ARP/ICMP Contract
QEMU user-mode SLIRP networking parameters:
* **Tinux Guest IP (`OUR_IP`):** `10.0.2.15` (`{ 10, 0, 2, 15 }`)
* **QEMU Gateway / Router IP (`GW_IP`):** `10.0.2.2` (`{ 10, 0, 2, 2 }`)
* **Wire Packet Processing Rules (`netstack.zig`):**
  1. **RFC 1071 Checksum (`internetChecksum`):**
     Compute standard ones' complement sum over 16-bit big-endian words for IPv4 header (20 bytes) and ICMP messages (8+ bytes).
  2. **ARP (`EtherType = 0x0806`):**
     * On receiving ARP Request (`oper == 1`) for `10.0.2.15`, respond with ARP Reply (`oper == 2`) containing Tinux MAC.
     * Record sender IP (`spa`) and sender MAC (`sha`) into the ARP table cache.
  3. **IPv4 (`EtherType = 0x0800`) & ICMP (`proto = 1`):**
     * On receiving ICMP Echo Request (`type == 8, code == 0`), reply with ICMP Echo Reply (`type == 0, code == 0`).
     * On receiving ICMP Echo Reply (`type == 0, code == 0`), save sequence number, ID, and payload for waiting sockets.
### 3.3 Linux Unprivileged ICMP Socket & `/proc/net/{dev,arp}` Contract
* **`sys_socket(AF_INET = 2, SOCK_DGRAM | SOCK_RAW, IPPROTO_ICMP = 1)`:**
  Create ICMP socket. Syscall `sys_sendto` accepts 8-byte `IcmpHdr` with payload and initiates transmission.
* **`sys_recvfrom` on ICMP Socket:**
  When `netstack` receives an Echo Reply, return packet data and sender address to user space.
* **`/proc/net/dev` & `/proc/net/arp`:**
  Report `eth0` packet and byte counters, and list resolved ARP entries (including gateway `10.0.2.2` mapped to `52:55:0a:00:02:02`).
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
    ethertype: u16 align(1),
    comptime {
        std.debug.assert(@sizeOf(EthHdr) == 14);
    }
};
pub const ArpPkt = extern struct {
    htype: u16 align(1),
    ptype: u16 align(1),
    hlen: u8 align(1),
    plen: u8 align(1),
    oper: u16 align(1),
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
    tot_len: u16 align(1),
    id: u16 align(1),
    frag_off: u16 align(1),
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
    id: u16 align(1),
    sequence: u16 align(1),
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
    // Builder resolves next-hop MAC, builds Eth + IPv4 + ICMP frame,
    // computes RFC 1071 checksums, and transmits via virtio_net.transmitFrame()
}
```
### 4.3 `src/user/ping_test.zig` (Verification Binary)
Create `src/user/ping_test.zig`:
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
    const sock_fd = syscall3(41, AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (sock_fd < 0) failExit(10);
    var dest = SockAddrIn{};
    var req = IcmpEchoPkt{};
    writeStdout("[TINUX_PING] Sending ARP + ICMP Echo Request to QEMU Gateway 10.0.2.2...\n");
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
    if (reply.icmp_type != 0 or reply.code != 0) failExit(13);
    if (src_addr.sin_addr[0] != 10 or src_addr.sin_addr[3] != 2) failExit(14);
    writeStdout("[TINUX_PING] 24 bytes from 10.0.2.2: icmp_seq=1 ttl=255 (VirtIO-Net RX/TX DMA verified!)\n");
    _ = syscall1(231, 0);
    unreachable;
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Implement `src/drivers/virtio_net.zig`:**
   * In `init() bool`:
     1. Locate PCI network device via `pci.findDeviceAndEnableDma(VIRTIO_VENDOR_ID, VIRTIO_NET_DEVICE_ID)`. If not found, return false.
     2. Save `io_base`.
     3. Device status sequence: write `0x00` (Reset), `0x01` (`ACK`), `0x03` (`ACK | DRIVER`).
     4. Negotiate features: write `host_feat & (VIRTIO_NET_F_MAC | VIRTIO_F_ANY_LAYOUT)` to `GUEST_FEATURES`.
     5. Read MAC address from offsets `+0x14..+0x19`.
     6. Configure Queue 0 (`RXQ`): select queue 0, read `rx_queue_size`, zero `rx_vring_mem`, set `QUEUE_PFN`, populate 16 receive descriptors, and update available index.
     7. Configure Queue 1 (`TXQ`): select queue 1, read `tx_queue_size`, zero `tx_vring_mem`, and set `QUEUE_PFN`.
     8. Set status `0x07` (`DRIVER_OK`), notify RX queue, set `dev_ready = true`, and return true.
   * In `pollRx()`:
     1. Check Used Ring for new descriptors.
     2. For each descriptor, extract payload past 10-byte `VirtioNetHdr` and deliver to `netstack.onReceiveFrame()`.
     3. Re-post descriptor to Available Ring and apply memory barrier.
2. **Step 2: Implement ARP, IPv4, and ICMP in `src/net/netstack.zig`:**
   * In `resolveArp(target_ip: [4]u8) ?[6]u8`:
     1. Check `arp_table` for cached entry.
     2. If not found, transmit broadcast ARP Request packet via `virtio_net.transmitFrame()`.
     3. Poll `virtio_net.pollRx()` until response arrives or timeout occurs.
   * In `sendIcmpEchoRequest(dst_ip: [4]u8, id_be: u16, seq_be: u16, payload: []const u8) bool`:
     1. Determine next-hop MAC address (`dst_ip` if on local subnet `10.0.2.x`, else `GW_IP` 10.0.2.2).
     2. Build concatenated frame: `EthHdr` (14B) + `Ipv4Hdr` (20B) + `IcmpHdr` (8B) + payload.
     3. Calculate RFC 1071 checksums for ICMP header and IPv4 header.
     4. Transmit frame via `virtio_net.transmitFrame()`.
3. **Step 3: Integrate ICMP Socket in `socket.zig` and Syscalls:**
   * Add `proto: u16 = 0` field to `Socket` struct.
   * In `sys_sendto`: if socket protocol is `IPPROTO_ICMP = 1`, extract payload and destination IP, and call `netstack.sendIcmpEchoRequest()`.
   * In `sys_recvfrom`: poll RX queue and deliver incoming Echo Reply to user buffer.
   * In `src/fs/procfs.zig`, generate `/proc/net/dev` and `/proc/net/arp`.
4. **Step 4: Update `src/main.zig` and `scripts/verify_qemu.sh`:**
   * In `src/main.zig`, call `_ = virtio_net.init(); netstack.init();`.
   * In `scripts/verify_qemu.sh`, build `ping_test.zig`, attach virtio-net-pci device, and verify ICMP ping response.
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
If `zig build` or `./scripts/verify_qemu.sh TASK-017 10` fails 3 consecutive times, stop execution and generate `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-017
## 1. Failure Summary
* **Failed Stage:** [zig build / PCI 1AF4:1000 Not Found / RXQ Buffer Not Populated / ARP Reply Timeout / IPv4 Checksum Error]
* **VirtIO-Net & ARP State Dump:** [io_base, mac_addr, rx_packets, tx_packets, arp_table entries]
* **Attempt History:**
  * Attempt 1: [Changes attempted and observed outcome]
  * Attempt 2: [Changes attempted and observed outcome]
  * Attempt 3: [Changes attempted and observed outcome]
## 2. Automated Crash Triage & Serial Log Output
```text
[Full build error output, or full contents of /tmp/tinux_qemu_*.log]
```
## 3. Current Code Diff
```diff
[Relevant code diff for src/drivers/virtio_net.zig, src/net/netstack.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
