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
   Do not alter the `Socket` struct layout, `SockAddrIn` layout (16 bytes), `FdKind.SOCKET` descriptor kind, syscall numbers, or socket state transition machine specified here.
2. **Socket FD Lifecycle & Reference Counting:**
   Linux socket file descriptors must support standard `read`, `write`, and `writev` syscalls in addition to `sendto` and `recvfrom`. Reference count tracking across `fork`, `dup2`, and `close` must be strictly maintained.
3. **Network Byte Order Discipline:**
   The `sin_port` (`u16`) and `sin_addr` (`u32`) fields in `struct sockaddr_in` are in network byte order (Big Endian). Always convert using endian helpers when matching ports or generating `/proc/net/tcp`.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-013 10` fails 3 consecutive times, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Big Endian to Host | Manual byte shifts | `std.mem.bigToNative(u16, net_port)` |
| Host to Big Endian | Manual byte shifts | `std.mem.nativeToBig(u16, host_port)` |
| Unaligned struct read | `@ptrCast(*const SockAddrIn, ptr)` | `@as(*align(1) const SockAddrIn, @ptrFromInt(ptr)).*` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-013`
* **Title:** `Linux Socket API (socket/bind/listen/accept/connect/sendto/recvfrom/socketpair), AF_INET (127.0.0.1 Loopback & AF_UNIX IPC), TCP State Machine, and Multi-Process Server/Client Verification`
* **Target Subsystem:** `net`, `fs`, `proc`, `syscall`
* **Target Files to Create / Modify:**
  * `src/net/socket.zig` (Create: kernel socket table, loopback connection queue, full-duplex ring buffers, and peer linking)
  * `src/fs/vfs.zig` (Modify: add `FdKind.SOCKET = 6` and integrate `socket.retain` / `socket.close` into FD operations)
  * `src/fs/procfs.zig` (Modify: dynamically generate `/proc/net/tcp` and `/proc/net/unix`)
  * `src/proc/task.zig` (Modify: add `WAITING_SOCK_ACCEPT = 8` and `WAITING_SOCK_READ = 9`, plus socket wakeup helpers)
  * `src/syscall/dispatch.zig` (Modify: implement syscalls `41..55` and `288`, and wire `.SOCKET` into `sysRead`/`sysWrite`)
  * `src/user/net_test.zig` (Create: standalone Linux `x86_64` TCP/UNIX socket server and client test binary)
  * `src/main.zig` (Modify: call `socket.init()` and update test markers to `TASK-013`)
  * `scripts/verify_qemu.sh` (Modify: compile `/bin/net_test`, pack into `initramfs.cpio`, and run multi-process server/client test)
---
## 3. Linux Socket ABI & Loopback Contract (Opus 5.5 Audited)
### 3.1 Socket Constants & Address Structures (`x86_64` Linux ABI)
1. **Domains (`family`):**
   * `AF_UNIX` (`AF_LOCAL`) = `1`
   * `AF_INET` = `2`
2. **Types & Bitmask Flags (`type`):**
   * Base type mask: `type & 0xFF` -> `SOCK_STREAM = 1`, `SOCK_DGRAM = 2`
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
| **`sys_socket`** | `41` | `domain, type, proto` | If `domain` is not `AF_UNIX(1)` or `AF_INET(2)`, return `-EAFNOSUPPORT`. Allocate socket slot and return new FD. |
| **`sys_connect`** | `42` | `fd, addr_ptr, addrlen` | Connect to listening socket on requested port (or `sun_path` for `AF_UNIX`). Returns 0 on success. |
| **`sys_accept` / `accept4`** | `43` / `288` | `fd, addr_ptr, addrlen_ptr (, flags)` | Dequeue connected client from `accept_queue`. If empty, block caller in `WAITING_SOCK_ACCEPT`. |
| **`sys_sendto`** | `44` | `fd, buf, len, flags, dest_addr, addrlen` | Write payload into peer socket receive ring buffer. Wakes any peer waiting on read. Returns bytes written. |
| **`sys_recvfrom`** | `45` | `fd, buf, len, flags, src_addr, addrlen_ptr` | Read data from socket's `rx_buf`. If empty and peer closed, return 0 (EOF). If empty and connected, block caller. |
| **`sys_shutdown`** | `48` | `fd, how` | Mark socket peer connection terminated and wake waiting tasks. Returns 0. |
| **`sys_bind`** | `49` | `fd, addr_ptr, addrlen` | Bind socket to local port `sin_port` (or path) and set state to `BOUND`. Returns 0. |
| **`sys_listen`** | `50` | `fd, backlog` | Set socket state to `LISTENING`. Returns 0. |
| **`sys_getsockname` / `getpeername`** | `51` / `52` | `fd, addr_ptr, addrlen_ptr` | Write local or remote `SockAddrIn` address to user space. Returns 0. |
| **`sys_socketpair`** | `53` | `domain, type, proto, sv_ptr` | Create two interconnected `AF_UNIX` sockets in `CONNECTED` state and return both FDs. Returns 0. |
| **`sys_setsockopt` / `getsockopt`** | `54` / `55` | `fd, level, optname, optval, optlen` | Support `SO_REUSEADDR (2)`. Accepts option and returns 0. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/uapi/errno.zig` Additions
Add network error codes to `Errno` enum:
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
    accept_queue: [ACCEPT_QUEUE_LEN]usize = [_]usize{0} ** ACCEPT_QUEUE_LEN,
    accept_head: usize = 0,
    accept_tail: usize = 0,
    accept_count: usize = 0,
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
    // If peer_idx is set, marks sockets[peer].peer_closed = true and returns peer_idx so caller can wake peer.
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
    // Builder finds LISTENING socket on target_port_host, allocates server-side connected socket srv_idx,
    // links client_idx <-> srv_idx, pushes srv_idx to listener's accept_queue, returns listener_idx to wake
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
Add socket wait states and wake helpers to `src/proc/task.zig`:
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
1. **Step 1: Wire `FdKind.SOCKET` in `src/fs/vfs.zig` and `src/proc/task.zig`:**
   * In `src/fs/vfs.zig`, add `SOCKET = 6` to `FdKind` and add `sock_idx: usize = 0` to `FdEntry`.
   * Reference count synchronization across task operations:
     1. In `task.forkCurrentTask`: iterate `child.fd_table`; if `entry.kind == .SOCKET`, call `socket.retain(entry.sock_idx)`.
     2. In `vfs.dupTaskFd` / `vfs.dup2TaskFd`: if `entry.kind == .SOCKET`, call `socket.retain(entry.sock_idx)`.
     3. In `vfs.closeTaskFd`: if `entry.kind == .SOCKET`, call `if (socket.close(entry.sock_idx)) |peer_idx| task.wakeSocketReadWaiters(peer_idx);`.
2. **Step 2: Implement `src/net/socket.zig`:**
   * In `connectInet(client_idx: usize, target_port_host: u16) Errno!usize`:
     1. Search `sockets` array for a socket matching `s.in_use and s.domain == AF_INET and s.state == .LISTENING and s.bound_port == target_port_host`.
     2. If not found, return `Errno.ECONNREFUSED`.
     3. If listener accept queue is full (`listener.accept_count >= ACCEPT_QUEUE_LEN`), return `Errno.ECONNREFUSED`.
     4. Allocate server connection socket: `const srv_idx = alloc(AF_INET, SOCK_STREAM, false) orelse return Errno.ENOBUFS;`.
     5. Set `sockets[srv_idx].state = .CONNECTED; sockets[srv_idx].bound_port = target_port_host; sockets[srv_idx].peer_idx = client_idx;`.
     6. Set `sockets[client_idx].state = .CONNECTED;`.
     7. If client has no bound port, assign `next_ephemeral_port` and increment.
     8. Set `sockets[client_idx].peer_idx = srv_idx;`.
     9. Enqueue `srv_idx` into `listener.accept_queue` and increment `listener.accept_count`.
     10. Return `listener_idx` so the caller can wake accept waiters.
   * In `write(idx: usize, src: []const u8) Errno!usize`:
     1. Retrieve socket: `const s = &sockets[idx];`.
     2. Verify `s.state == .CONNECTED and s.peer_idx != null`, else return `Errno.ENOTCONN`.
     3. If `s.peer_closed`, return `Errno.EPIPE`.
     4. Retrieve peer: `var peer = &sockets[s.peer_idx.?];`.
     5. Calculate available capacity in peer's `rx_buf` and copy `to_write` bytes.
     6. Increment `peer.rx_count` and return bytes written.
3. **Step 3: Generate `/proc/net/tcp` in `src/fs/procfs.zig`:**
   * In `procfs.initAndRegister()`, register directory `"proc/net"` (`S_IFDIR | 0o555`).
   * In `procfs.syncProcessNodes()`, iterate `socket.sockets`; for each active `AF_INET` socket, emit standard Linux `/proc/net/tcp` formatted entries:
     ```text
       sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1001
     ```
     (Note: port `8080` in hex is `1F90`, `LISTENING` state is `0A`, `CONNECTED` state is `01`).
4. **Step 4: Implement Socket Syscalls in `src/syscall/dispatch.zig`:**
   * Wire `.SOCKET` into `sysRead` (0), `sysWrite` (1), `sysWritev` (20):
     * In `sysRead`, if `entry.kind == .SOCKET`, call `sysRecvfrom(frame, fd, buf_ptr, count, 0, 0, 0)`.
     * In `sysWrite`, if `entry.kind == .SOCKET`, call `socket.write(entry.sock_idx, slice)` and wake peer via `task.wakeSocketReadWaiters(peer_idx)`.
   * Implement `sysAccept(43)` / `sysAccept4(288)`:
     1. Verify descriptor kind is `.SOCKET`, retrieve `listen_idx = entry.sock_idx`.
     2. If `socket.popAccept(listen_idx)` returns connected socket `srv_conn_idx`:
        * Allocate new file descriptor `conn_fd` via `vfs.allocFd(&cur.fd_table, 0)`.
        * Set `cur.fd_table[conn_fd] = .{ .kind = .SOCKET, .sock_idx = srv_conn_idx }`.
        * If `addr_ptr != 0`, populate user `SockAddrIn` struct with remote peer info.
        * Set `frame.rax = conn_fd; return frame;`.
     3. If accept queue is empty, block calling task:
        * Rewind instruction pointer: `frame.user_rip -= 2;`.
        * Set `frame.rax = orig_syscall_num;` (43 or 288).
        * Set `cur.state = .WAITING_SOCK_ACCEPT; cur.wait_sock_idx = listen_idx; cur.saved_frame = frame;`.
        * Call `const next_idx = task.scheduleNextOrWait(); task.activateTask(next_idx); return task.currentTask().saved_frame;`.
5. **Step 5: Create `src/user/net_test.zig` and update `scripts/verify_qemu.sh`:**
   * Build `src/user/net_test.zig` as a standalone binary accepting `"server"` or `"client"`:
     * In server mode:
       1. Create socket via `sys_socket(AF_INET, SOCK_STREAM, 0)`.
       2. Set `SO_REUSEADDR` via `sys_setsockopt`.
       3. Bind to `127.0.0.1:8080` and listen.
       4. Log `[TINUX_NET] Server listening on 127.0.0.1:8080`.
       5. Accept connection, receive message, log `[TINUX_NET] Server received: PING_TINUX_SOCKET`.
       6. Reply with `"PONG_FROM_TINUX_SERVER\n"`, close socket, and exit.
     * In client mode:
       1. Create socket via `sys_socket(AF_INET, SOCK_STREAM, 0)`.
       2. Connect to `127.0.0.1:8080`.
       3. Send `"PING_TINUX_SOCKET"`.
       4. Receive server response and log `[TINUX_NET] Client received: PONG_FROM_TINUX_SERVER`.
       5. Exercise `sys_socketpair(AF_UNIX, SOCK_STREAM, 0, &sv)`, exchange payload across pair, and log `[TINUX_NET] AF_UNIX socketpair IPC verified!`.
   * In `scripts/verify_qemu.sh`, package `/bin/net_test` into initramfs and verify server/client coordination.
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-013 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
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
If `zig build` or `./scripts/verify_qemu.sh TASK-013 10` fails 3 consecutive times, stop execution and generate `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-013
## 1. Failure Summary
* **Failed Stage:** [net_test.elf Build / sys_bind Port Endianness Mismatch / sys_accept Blocking Hang / sys_connect Refused]
* **Socket & Task State Dump:** [Socket state, bound_port, peer_idx, rx_count, and Task pid, state, wait_sock_idx]
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
[Relevant code diff for src/net/socket.zig, src/proc/task.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
