# Tinux Implementation Specification: TASK-013
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-012` Passed (`./scripts/verify_qemu.sh TASK-012 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition `Socket` struct、 `SockAddrIn` （ 16 bytes ）、 `FdKind.SOCKET` of ⽅、Syscall Number、 and 
2. **Socket FD Lifecycle & Reference Counting （socketreferencedcount of strictly adhere） :**
 Linux socket FD `sendto`/`recvfrom` with of `read`/`write`/`writev` 、
3. **Network Byte Order Discipline （ of strictly adhere） :**
 `struct sockaddr_in` of `sin_port` (`u16`) and `sin_addr` (`u32`) network（ Big Endian ） with 
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-013 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Big Endian → Host | ⼿ | `std.mem.bigToNative(u16, net_port)` |
| Host → Big Endian | ⼿ | `std.mem.nativeToBig(u16, host_port)` |
| ⾮struct | `@ptrCast(*const SockAddrIn, ptr)` | `@as(*align(1) const SockAddrIn, @ptrFromInt(ptr)).*`
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-013`
* **Title:** `Linux Socket API (socket/bind/listen/accept/connect/sendto/recvfrom/socketpair), AF_INET (127.0.0.1 Lo

* **Target Subsystem:** `net`, `fs`, `proc`, `syscall`
* **Target Files to Create / Modify:**
  * `src/net/socket.zig` (Create: kernel socket table, loopback connection queue, full-duplex ring buffers, and peer
  * `src/fs/vfs.zig` (Modify: add `FdKind.SOCKET = 6` and integrate `socket.retain` / `socket.close` into FD operati
  * `src/fs/procfs.zig` (Modify: dynamically generate `/proc/net/tcp` and `/proc/net/unix`)
  * `src/proc/task.zig` (Modify: add `WAITING_SOCK_ACCEPT = 8` and `WAITING_SOCK_READ = 9`, plus socket wakeup helpe
  * `src/syscall/dispatch.zig` (Modify: implement syscalls `41..55` and `288`, and wire `.SOCKET` into `sysRead`/`sy
  * `src/user/net_test.zig` (Create: standalone Linux `x86_64` TCP/UNIX socket server & client test binary)
  * `src/main.zig` (Modify: call `socket.init()` and update test markers to `TASK-013`)
  * `scripts/verify_qemu.sh` (Modify: compile `/bin/net_test`, pack into `initramfs.cpio`, and run multi-process ser
---
## 3. Linux Socket ABI & Loopback Contract (Opus 5.5 Audited)
### 3.1 Socket Constants & Address Structures (`x86_64` Linux ABI)
1. **Domains (`family`):**
   * `AF_UNIX` (`AF_LOCAL`) = `1`
   * `AF_INET` = `2`
2. **Types & Bitmask Flags (`type`):**
   * Base type mask: `type & 0xFF` → `SOCK_STREAM = 1`, `SOCK_DGRAM = 2`
   * `SOCK_NONBLOCK` = `0o4000` (`0x800`)
   * `SOCK_CLOEXEC` = `0o2000000` (`0x80000`)
3. **Address Structures:**
   * **`SockAddrIn` (`AF_INET`, 16 bytes):**
     ```zig
     pub const SockAddrIn = extern struct {
         sin_family: u16 = 2, // AF_INET
         sin_port: u16 = 0,   // Network Byte Order (Big Endian)
         sin_addr: u32 = 0,   // Network Byte Order (127.0.0.1 = 0x0100007F in LE)
         sin_zero: [8]u8 = [_]u8{0} ** 8,
         comptime {
             std.debug.assert(@sizeOf(SockAddrIn) == 16);
         }
     };
     ```
   * **`SockAddrUn` (`AF_UNIX`, 110 bytes):**
     ```zig
     pub const SockAddrUn = extern struct {
         sun_family: u16 = 1, // AF_UNIX
         sun_path: [108]u8 = [_]u8{0} ** 108,
         comptime {
             std.debug.assert(@sizeOf(SockAddrUn) == 110);
         }
     };
     ```
### 3.2 Linux x86_64 Socket Syscall Contract
| Syscall Name | Num | Arguments | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_socket`** | `41` | `domain, type, proto` | `domain` `AF_UNIX(1)` or `AF_INET(2)` `-EAFNOSUPPO
| **`sys_connect`** | `42` | `fd, addr_ptr, addrlen` | `AF_INET` of when `port` （ `AF_UNIX` of when `sun_path` ） with 
| **`sys_accept` / `accept4`** | `43` / `288` | `fd, addr_ptr, addrlen_ptr (, flags)` | socket of `accept_queue` 
| **`sys_sendto`** | `44` | `fd, buf, len, flags, dest_addr, addrlen` | socket（ `.CONNECTED` ） 、（ `
| **`sys_recvfrom`** | `45` | `fd, buf, len, flags, src_addr, addrlen_ptr` | ⾃⾝ of receiveringbuffer `rx_buf` from ⼤
| **`sys_shutdown`** | `48` | `fd, how` | socket and EOF state notified、 of waitingtask woken `0` 。 
| **`sys_bind`** | `49` | `fd, addr_ptr, addrlen` | `AF_INET` `bigToNative(u16, sin_port)` `bound_port` 
| **`sys_listen`** | `50` | `fd, backlog` | socket of state `.LISTENING` 、 `0` 。 |
| **`sys_getsockname` / `getpeername`** | `51` / `52` | `fd, addr_ptr, addrlen_ptr` | or of `SockA
| **`sys_socketpair`** | `53` | `domain, type, proto, sv_ptr` | `.CONNECTED` with 2 of socket `s1, s2` 
| **`sys_setsockopt` / `getsockopt`** | `54` / `55` | `fd, level, optname, optval, optlen` | `SO_REUSEADDR (2)` 
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/uapi/errno.zig` Additions
`Errno` enum of network⽤error add：
```zig
    ENOTSOCK = 88,
    EOPNOTSUPP = 95,
    EAFNOSUPPORT = 97,
    EADDRINUSE = 98,
    EADDRNOTAVAIL = 99,

    ENETUNREACH = 101,
    ECONNABORTED = 103,
    ECONNRESET = 104,
    ENOBUFS = 105,
    EISCONN = 106,
    ENOTCONN = 107,
    ECONNREFUSED = 111,
```
### 4.2 `src/net/socket.zig`
```zig
const std = @import("std");
const Errno = @import("../uapi/errno.zig").Errno;
pub const MAX_SOCKETS: usize = 32;
pub const SOCK_BUF_SIZE: usize = 4096;
pub const ACCEPT_QUEUE_LEN: usize = 8;
pub const AF_UNIX: u16 = 1;
pub const AF_INET: u16 = 2;
pub const SOCK_STREAM: u32 = 1;
pub const SOCK_DGRAM: u32 = 2;
pub const SOCK_NONBLOCK: u32 = 0o4000;
pub const SOCK_CLOEXEC: u32 = 0o2000000;
pub const SocketState = enum(u8) {
    CLOSED = 0,
    UNBOUND = 1,
    BOUND = 2,
    LISTENING = 3,
    CONNECTED = 4,
};
pub const SockAddrIn = extern struct {
    sin_family: u16 = AF_INET,
    sin_port: u16 = 0,
    sin_addr: u32 = 0,
    sin_zero: [8]u8 = [_]u8{0} ** 8,
    comptime {
        std.debug.assert(@sizeOf(SockAddrIn) == 16);
    }
};
pub const SockReadResult = union(enum) {
    bytes: usize,
    eof: void,
    would_block: void,
};
pub const Socket = struct {
    in_use: bool = false,
    ref_count: usize = 0,
    domain: u16 = AF_INET,
    sock_type: u32 = SOCK_STREAM,
    nonblock: bool = false,
    state: SocketState = .CLOSED,
    bound_port: u16 = 0,
    bound_path: [64]u8 = [_]u8{0} ** 64,
    bound_path_len: usize = 0,
    peer_idx: ?usize = null,
    peer_closed: bool = false,
    // Accept queue for LISTENING sockets (stores indices of newly created server-side connected sockets)
    accept_queue: [ACCEPT_QUEUE_LEN]usize = [_]usize{0} ** ACCEPT_QUEUE_LEN,
    accept_head: usize = 0,
    accept_tail: usize = 0,
    accept_count: usize = 0,
    // Receive ring buffer (written by peer's sendto/write, read by this socket's recvfrom/read)
    rx_buf: [SOCK_BUF_SIZE]u8 = [_]u8{0} ** SOCK_BUF_SIZE,
    rx_read_pos: usize = 0,
    rx_write_pos: usize = 0,
    rx_count: usize = 0,
};
pub var sockets: [MAX_SOCKETS]Socket = [_]Socket{.{}} ** MAX_SOCKETS;
var next_ephemeral_port: u16 = 49152;

pub fn init() void {
    for (&sockets) |*s| s.* = .{};
    next_ephemeral_port = 49152;
}
pub fn alloc(domain: u16, sock_type: u32, nonblock: bool) ?usize {
    // Builder allocates unused Socket slot with ref_count = 1, state = .UNBOUND
}
pub fn retain(idx: usize) void {
    if (idx < MAX_SOCKETS and sockets[idx].in_use) {
        sockets[idx].ref_count += 1;
    }
}
pub fn close(idx: usize) ?usize {
    // Builder decrements ref_count. When ref_count == 0, marks state = .CLOSED, in_use = false.
    // If peer_idx is set, marks sockets[peer].peer_closed = true and returns peer_idx so caller can wake peer!
}
pub fn bindInet(idx: usize, port_host: u16) Errno!void {
    // Builder sets bound_port and state = .BOUND
}
pub fn bindUnix(idx: usize, path: []const u8) Errno!void {
    // Builder sets bound_path and state = .BOUND
}
pub fn listen(idx: usize) Errno!void {
    // Builder sets state = .LISTENING
}
pub fn connectInet(client_idx: usize, target_port_host: u16) Errno!usize {
    // Builder finds LISTENING socket on target_port_host, allocates server-side connected socket `srv_idx`,
    // links client_idx <-> srv_idx, pushes `srv_idx` to listener's accept_queue, returns listener_idx to wake!
}
pub fn connectUnix(client_idx: usize, target_path: []const u8) Errno!usize {
    // Builder finds LISTENING UNIX socket on target_path and connects just like connectInet
}
pub fn popAccept(listener_idx: usize) ?usize {
    // Builder pops and returns next connected server socket index from accept_queue, or null if empty
}
pub fn read(idx: usize, dst: []u8) SockReadResult {
    // Builder reads from sockets[idx].rx_buf, or returns .eof if peer_closed, or .would_block
}
pub fn write(idx: usize, src: []const u8) Errno!usize {
    // Builder writes into sockets[peer_idx].rx_buf and returns bytes written (or Errno.EPIPE if peer_closed)
}
```
### 4.3 `src/proc/task.zig` Additions
`TaskState` of 2 of waitingstate add、 `Task` struct `wait_sock_idx: usize = 0` add：
```zig
pub const TaskState = enum(u8) {
    UNUSED = 0,
    RUNNING = 1,
    READY = 2,
    WAITING = 3,
    ZOMBIE = 4,
    WAITING_PIPE = 5,
    WAITING_SLEEP = 6,
    WAITING_TTY = 7,
    WAITING_SOCK_ACCEPT = 8,
    WAITING_SOCK_READ = 9,
};
```
 、socket⽣ of woken 2 `src/proc/task.zig` add：
```zig
pub fn wakeSocketAcceptWaiters(listen_sock_idx: usize) void {
    for (&tasks) |*t| {
        if (t.state == .WAITING_SOCK_ACCEPT and t.wait_sock_idx == listen_sock_idx) {
            t.state = .READY;
        }
    }

}
pub fn wakeSocketReadWaiters(sock_idx: usize) void {
    for (&tasks) |*t| {
        if (t.state == .WAITING_SOCK_READ and t.wait_sock_idx == sock_idx) {
            t.state = .READY;
        }
    }
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/vfs.zig` and `src/proc/task.zig` to of `FdKind.SOCKET` **
 * `vfs.FdKind` `SOCKET = 6` add、 `FdEntry` `sock_idx: usize = 0` add。
 * ** referencedcount of completesynchronization :**
 1. `task.forkCurrentTask`: `child.fd_table` 、 `entry.kind ==.SOCKET` `socket.retain(entry.sock_idx)
 2. `vfs.dupTaskFd` / `vfs.dup2TaskFd`: duplicated `entry.kind ==.SOCKET` `socket.retain(entry.soc
 3. `vfs.closeTaskFd`: `entry.kind ==.SOCKET` of when、 `if (socket.close(entry.sock_idx)) |peer_idx| task.wakeSoc
2. **Step 2: `src/net/socket.zig` Implementation **
   * `connectInet(client_idx: usize, target_port_host: u16) Errno!usize`:
 1. `sockets` column ⾛、 `s.in_use and s.domain == AF_INET and s.state ==.LISTENING and s.bound_port == target
     2. `var listener = &sockets[listener_idx];`
     3. `if (listener.accept_count >= ACCEPT_QUEUE_LEN) return Errno.ECONNREFUSED;`
 4. of socket `const srv_idx = alloc(AF_INET, SOCK_STREAM, false) orelse return Errno.ENOBUFS;
     5. `sockets[srv_idx].state = .CONNECTED; sockets[srv_idx].bound_port = target_port_host; sockets[srv_idx].peer_
     6. `sockets[client_idx].state = .CONNECTED;`
     7. `if (sockets[client_idx].bound_port == 0) { sockets[client_idx].bound_port = next_ephemeral_port; next_ephem
     8. `sockets[client_idx].peer_idx = srv_idx;`
     9. `listener.accept_queue[listener.accept_tail] = srv_idx;`
     10. `listener.accept_tail = (listener.accept_tail + 1) % ACCEPT_QUEUE_LEN;`
     11. `listener.accept_count += 1;`
     12. `return listener_idx;`
   * `write(idx: usize, src: []const u8) Errno!usize`:
     1. `const s = &sockets[idx];`
     2. `if (s.state != .CONNECTED or s.peer_idx == null) return Errno.ENOTCONN;`
     3. `if (s.peer_closed) return Errno.EPIPE;`
     4. `var peer = &sockets[s.peer_idx.?];`
     5. `const space = SOCK_BUF_SIZE - peer.rx_count;`
     6. `const to_write = @min(src.len, space);`
     7. `for (0..to_write) |i| { peer.rx_buf[peer.rx_write_pos] = src[i]; peer.rx_write_pos = (peer.rx_write_pos + 1
     8. `peer.rx_count += to_write;`
     9. `return to_write;`
3. **Step 3: `src/fs/procfs.zig` with of `/proc/net/tcp` ⽣ **
 * `procfs.initAndRegister()` with `"proc/net"` （ `S_IFDIR | 0o555` ） 。
 * `procfs.syncProcessNodes()` with `socket.sockets` ⾛、 `in_use` `domain == AF_INET` of socket⼀ Lin
     ```text
       sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1001
     ```
 （ ※ port `8080` = `0x1F90` 、 LISTENING state = `0A` 、 CONNECTED state = `01` ）。
4. **Step 4: `src/syscall/dispatch.zig` of socketimplement **
 * **`sysRead` (0) / `sysWrite` (1) / `sysWritev` (20) of `.SOCKET` :**
 * `sysRead` with `entry.kind ==.SOCKET` of when、 `sysRecvfrom(frame, fd, buf_ptr, count, 0, 0, 0)` and （
 * `sysWrite` with `entry.kind ==.SOCKET` of when、 `socket.write(entry.sock_idx, slice)` 、 `task.wakeSocketRea
   * **`sysAccept` (43) / `sysAccept4` (288):**
 1. `entry.kind ==.SOCKET` verify、 `listen_idx = entry.sock_idx` 。
 2. `if (socket.popAccept(listen_idx)) |srv_conn_idx|` of when：
 * FD `conn_fd` `vfs.allocFd(&cur.fd_table, 0)` with allocated、 `cur.fd_table[conn_fd] =.{.kind =.SOCKET
 * `addr_ptr != 0 and addrlen_ptr != 0` of when、 `SockAddrIn{.sin_family = 2,.sin_port = std.mem.nativeToBig(
        * `frame.rax = conn_fd; return frame;`
 3. queueempty of when（blocking）：
        * `frame.user_rip -= 2;`
 * `frame.rax = orig_syscall_num;` (`43` or `288`)
        * `cur.state = .WAITING_SOCK_ACCEPT;`
        * `cur.wait_sock_idx = listen_idx;`
        * `cur.saved_frame = frame;`
        * `const next_idx = task.scheduleNextOrWait();`

        * `task.activateTask(next_idx);`
        * `return task.currentTask().saved_frame;`
5. **Step 5: `src/user/net_test.zig` and `scripts/verify_qemu.sh` Creation‧update **
 * `src/user/net_test.zig` create、arguments `argv[1]` of Linux `x86_6
 * **`/bin/net_test server` and when :**
 1. `sys_socket(AF_INET=2, SOCK_STREAM=1, 0)` with socket create。
 2. `sys_setsockopt(fd, SOL_SOCKET=1, SO_REUSEADDR=2, &one, 4)` execute。
       3. `127.0.0.1:8080` (`sin_family = 2`, `sin_port = nativeToBig(u16, 8080) = 0x901F`, `sin_addr = 0x0100007F`)
 4. `[TINUX_NET] Server listening on 127.0.0.1:8080` output to output。
 5. `sys_accept(fd,...)` with waiting（block）。
 6. FD from `sys_recvfrom` （ or `sys_read` ） with 、 `[TINUX_NET] Server received: PIN
 7. to `sys_sendto` （ or `sys_write` ） with `"PONG_FROM_TINUX_SERVER\n"` 、 FD `sys_ex
 * **`/bin/net_test client` and when :**
 1. `sys_socket(AF_INET=2, SOCK_STREAM=1, 0)` with socket create。
 2. `127.0.0.1:8080` to `sys_connect` execute。
 3. `sys_sendto` with `"PING_TINUX_SOCKET"` transmit。
 4. `sys_recvfrom` with from of response 、 `[TINUX_NET] Client received: PONG_FROM_TINUX_SERVER` output。
 5. `sys_socketpair(AF_UNIX=1, SOCK_STREAM=1, 0, &sv)` 、 `sv[0]` `sv[1]` from 
 * `vfs.lookup` `"bin/net_test"` / `"net_test"` when of CPIO of `"bin/net_test"` node 
 * `scripts/verify_qemu.sh` with QEMU ⼊⼒ type update：
     ```bash
     (
         sleep 0.4
         cat << 'EOF'
     echo "[TINUX_SH] Starting TCP loopback server in background..."
     /bin/net_test server &
     SRV_PID=$!
     /bin/sleep 1
     echo "[TINUX_SH] Inspecting /proc/net/tcp while server is listening:"
     /bin/cat /proc/net/tcp
     echo "[TINUX_SH] Running TCP & UNIX socket client..."
     /bin/net_test client
     wait $SRV_PID 2>/dev/null
     echo "[TINUX_SOCK] Full Linux Socket API (bind/listen/accept/connect/send/recv) verified!"
     exit 0
     EOF
     ) | timeout "$TIMEOUT_SEC" qemu-system-x86_64 ...
     ```
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-013 10
```
### 6.2 Expected Output (Pass Criteria)
QEMU output of ‧socket and `/proc/net/tcp` of output、 `verify_qemu.sh` 
```text
[TINUX_TEST] START: TASK-013
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Starting TCP loopback server in background...
[TINUX_NET] Server listening on 127.0.0.1:8080
[TINUX_SH] Inspecting /proc/net/tcp while server is listening:
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1001
[TINUX_SH] Running TCP & UNIX socket client...
[TINUX_NET] Server received: PING_TINUX_SOCKET
[TINUX_NET] Client received: PONG_FROM_TINUX_SERVER
[TINUX_NET] AF_UNIX socketpair IPC verified!
[TINUX_SOCK] Full Linux Socket API (bind/listen/accept/connect/send/recv) verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-013
[HARNESS] SUCCESS: TASK-013 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-013 10` when、 Builder fixloop stop、 `ESCALATI

```markdown
# Escalation Report: TASK-013
## 1. Failure Summary
* **Failed Stage:** [net_test.elf Build / sys_bind Port Endianness Mismatch / sys_accept Blocking Hang / sys_connect
* **Socket & Task State Dump:** [ Socket of state, bound_port, peer_idx, rx_count, and Task of pid, state, wait
* **Attempt History:**
  * Attempt 1: [Changes attempted and observed outcome]
  * Attempt 2: [Changes attempted and observed outcome]
  * Attempt 3: [Changes attempted and observed outcome]
## 2. Exact Error / Serial Log Output
```text
[Full build error output, or full contents of /tmp/tinux_qemu_*.log]
```
## 3. Current Code Diff
```diff
[Relevant code diff for src/net/socket.zig, src/proc/task.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
