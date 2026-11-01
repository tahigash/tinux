# Tinux Implementation Specification: TASK-014

> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-013` Passed (`./scripts/verify_qemu.sh TASK-013 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter the `sys_clone` register argument ordering, 12-byte `LinuxEpollEvent` layout, or physical address wait queues for futex operations.
2. **Critical x86_64 `epoll_event` 12-Byte Packing Rule:**
   The x86_64 Linux ABI specifies that `struct epoll_event` is packed to 12 bytes (`events: u32` followed immediately by `data: u64` at offset 4). Do not pad to 16 bytes.
3. **Strict Zig Version Idioms:**
   Adhere strictly to modern Zig idioms (0.13+) as defined in Section 1. Do not use deprecated functions like `@ptrToInt` or `@intToPtr`.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-014 10` fails 3 consecutive times, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Unaligned 32-bit read | `@ptrCast(*i32, addr).*` | `std.mem.readInt(i32, @as(*const [4]u8, @ptrFromInt(addr)), .little)` |
| Unaligned 64-bit write | `@ptrCast(*u64, addr).*` | `std.mem.writeInt(u64, @as(*[8]u8, @ptrFromInt(addr)), val, .little)` |
| Unsigned to signed cast | `@bitCast(i32, val_u32)` | `@as(i32, @bitCast(val_u32))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-014`
* **Title:** `Multi-Threading (CLONE_VM | CLONE_THREAD | CLONE_SETTLS | CLONE_CHILD_CLEARTID), Fast Userspace Locking (sys_futex FUTEX_WAIT / FUTEX_WAKE), and Epoll Multiplexing (sys_epoll_create1 / sys_epoll_ctl / sys_epoll_pwait)`
* **Target Subsystem:** `proc`, `sync`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/proc/futex.zig` (Create: physical-address-indexed futex wait/wake subsystem)
  * `src/fs/epoll.zig` (Create: kernel epoll table, interest list, and readiness polling across pipes/sockets/TTYs)
  * `src/fs/vfs.zig` (Modify: add `FdKind.EPOLL = 7` and integrate `epoll.close` into `closeTaskFd`)
  * `src/proc/task.zig` (Modify: add `tgid`, `is_thread`, `clear_child_tid`, `WAITING_FUTEX = 10`, `WAITING_EPOLL = 11`)
  * `src/syscall/dispatch.zig` (Modify: upgrade `sys_clone`, split `sys_exit` vs `sys_exit_group` for threads, add futex and epoll syscalls)
  * `src/user/thread_epoll_test.zig` (Create: standalone Linux `x86_64` multi-threaded + futex + epoll test binary)
  * `src/main.zig` (Modify: call `epoll.init()` and update test markers to `TASK-014`)
  * `scripts/verify_qemu.sh` (Modify: compile `/bin/thread_epoll_test`, include in `initramfs.cpio`, and execute via `/bin/sh`)
---
## 3. Threading, Futex & Epoll ABI Contract (Opus 5.5 Audited)
### 3.1 x86_64 `sys_clone` (Syscall 56) Raw Argument Order & Thread Flags
The raw x86_64 Linux kernel syscall ABI for `clone` passes arguments in specific registers:
* **`rdi` (Arg1):** `clone_flags: usize`
* **`rsi` (Arg2):** `child_stack: usize` (`newsp`)
* **`rdx` (Arg3):** `parent_tidptr: usize` (`int *ptid`)
* **`r10` (Arg4):** `child_tidptr: usize` (`int *ctid`)
* **`r8`  (Arg5):** `newtls: usize` (`tls` base address for `%fs`)
| Clone Flag | Hex Value | Exact Kernel Behavior |
| :--- | :--- | :--- |
| **`CLONE_VM`** | `0x0000_0100` | Share page tables. Child shares parent `pml4_phys` instead of creating new tables. |
| **`CLONE_SETTLS`** | `0x0008_0000` | Set child's `fs_base` to `r8` (`newtls`). Loaded via `MSR_FS_BASE` on task activation. |
| **`CLONE_PARENT_SETTID`** | `0x0010_0000` | If `parent_tidptr != 0`, store child PID to `parent_tidptr` in parent's address space. |
| **`CLONE_CHILD_CLEARTID`** | `0x0020_0000` | Record `clear_child_tid = child_tidptr`. On child thread exit, zero memory and wake futex. |
| **`CLONE_CHILD_SETTID`** | `0x0100_0000` | If `child_tidptr != 0`, store child PID to `child_tidptr` in child's address space. |
| **`CLONE_THREAD`** | `0x0001_0000` | Set child `tgid = parent.tgid` and `is_thread = true`. Syscall `getpid` returns `tgid`. |
### 3.2 `sys_futex` (Syscall 202) Contract
```text
sys_futex(uaddr: usize, futex_op: usize, val: u32, timeout: usize, uaddr2: usize, val3: u32) -> isize
```
* Extract command: `const cmd = futex_op & FUTEX_CMD_MASK;` (masking flags `FUTEX_PRIVATE_FLAG = 0x80` and `FUTEX_CLOCK_REALTIME = 0x100`).
* Translate address: ensure `uaddr` is 4-byte aligned and translate to physical address `paddr = vmm.translate(cur.pml4_phys, uaddr)`.
1. **`FUTEX_WAIT (0)` / `FUTEX_WAIT_BITSET (9)`:**
   * Read 32-bit value at physical address: `const cur_val = std.mem.readInt(i32, @as(*const [4]u8, @ptrFromInt(paddr)), .little);`.
   * If `cur_val != @as(i32, @bitCast(val))`, return `-EAGAIN (-11)`.
   * Otherwise, save user frame, set `cur.state = .WAITING_FUTEX`, set `cur.wait_futex_paddr = paddr`, and switch tasks. Return value on wake is 0.
2. **`FUTEX_WAKE (1)` / `FUTEX_WAKE_BITSET (10)`:**
   * Iterate tasks: find tasks with `t.state == .WAITING_FUTEX and t.wait_futex_paddr == paddr`.
   * Wake up to `val` tasks by transitioning to `.READY` and clearing `wait_futex_paddr`. Return count of woken tasks.
### 3.3 `epoll` (`sys_epoll_create1`, `sys_epoll_ctl`, `sys_epoll_pwait`) Contract
* **x86_64 `LinuxEpollEvent` struct (12 bytes, packed):**
  ```zig
  pub const LinuxEpollEvent = extern struct {
      events: u32 align(1) = 0,
      data: u64 align(1) = 0,
      comptime {
          std.debug.assert(@sizeOf(LinuxEpollEvent) == 12);
          std.debug.assert(@offsetOf(LinuxEpollEvent, "data") == 4);
      }
  };
  ```
* **Epoll Constants:**
  * `EPOLL_CTL_ADD = 1`, `EPOLL_CTL_DEL = 2`, `EPOLL_CTL_MOD = 3`
  * `EPOLLIN = 0x001`, `EPOLLOUT = 0x004`, `EPOLLERR = 0x008`, `EPOLLHUP = 0x010`
* **Readiness Evaluation (`epoll.checkFdReady(cur_task, target_fd, watched_events)`):**
  Check readiness based on descriptor kind in `cur_task.fd_table[target_fd]`:
  * `.PIPE_READ`: `count > 0` sets `EPOLLIN`; `writers == 0` sets `EPOLLHUP`.
  * `.PIPE_WRITE`: `count < PIPE_BUF_SIZE` sets `EPOLLOUT`; `readers == 0` sets `EPOLLERR`.
  * `.SOCKET`: `rx_count > 0` or `accept_count > 0` sets `EPOLLIN`; `peer_closed` sets `EPOLLHUP`.
  * `.CONSOLE_IN` / `.CONSOLE_OUT`: `tty.hasReadableData()` sets `EPOLLIN`; always sets `EPOLLOUT`.
  * `.VFS_FILE`: sets `EPOLLIN | EPOLLOUT`.
* **Blocking and Wakeup:**
  In `sys_epoll_wait(232)` / `sys_epoll_pwait(281)`, check ready events. If none ready and timeout > 0, block calling task in `.WAITING_EPOLL`. Wake when pipe, socket, or TTY activity occurs.
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/proc/futex.zig`
```zig
const task = @import("task.zig");
pub const FUTEX_WAIT: usize = 0;
pub const FUTEX_WAKE: usize = 1;
pub const FUTEX_WAIT_BITSET: usize = 9;
pub const FUTEX_WAKE_BITSET: usize = 10;
pub const FUTEX_CMD_MASK: usize = 0x7F;
pub fn wakeByPaddr(paddr: usize, max_wake: usize) usize {
    var woken: usize = 0;
    if (max_wake == 0) return 0;
    for (&task.tasks) |*t| {
        if (t.state == .WAITING_FUTEX and t.wait_futex_paddr == paddr) {
            t.state = .READY;
            t.wait_futex_paddr = 0;
            woken += 1;
            if (woken >= max_wake) break;
        }
    }
    return woken;
}
```
### 4.2 `src/fs/epoll.zig`
```zig
const std = @import("std");
const vfs = @import("vfs.zig");
const pipe = @import("pipe.zig");
const socket = @import("../net/socket.zig");
const tty = @import("../drivers/tty.zig");
const Errno = @import("../uapi/errno.zig").Errno;
pub const MAX_EPOLL_INSTANCES: usize = 8;
pub const MAX_EPOLL_ITEMS: usize = 16;
pub const EPOLL_CTL_ADD: usize = 1;
pub const EPOLL_CTL_DEL: usize = 2;
pub const EPOLL_CTL_MOD: usize = 3;
pub const EPOLLIN: u32 = 0x001;
pub const EPOLLOUT: u32 = 0x004;
pub const EPOLLERR: u32 = 0x008;
pub const EPOLLHUP: u32 = 0x010;
pub const LinuxEpollEvent = extern struct {
    events: u32 align(1) = 0,
    data: u64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxEpollEvent) == 12);
        std.debug.assert(@offsetOf(LinuxEpollEvent, "data") == 4);
    }
};
pub const EpollItem = struct {
    in_use: bool = false,
    fd: usize = 0,
    events: u32 = 0,
    data: u64 = 0,
};
pub const EpollInstance = struct {
    in_use: bool = false,
    ref_count: usize = 0,
    items: [MAX_EPOLL_ITEMS]EpollItem = [_]EpollItem{.{}} ** MAX_EPOLL_ITEMS,
};
var instances: [MAX_EPOLL_INSTANCES]EpollInstance = [_]EpollInstance{.{}} ** MAX_EPOLL_INSTANCES;
pub fn init() void {
    for (&instances) |*inst| inst.* = .{};
}
pub fn alloc() ?usize {
    for (&instances, 0..) |*inst, idx| {
        if (!inst.in_use) {
            inst.* = .{ .in_use = true, .ref_count = 1 };
            return idx;
        }
    }
    return null;
}
pub fn retain(idx: usize) void {
    if (idx < MAX_EPOLL_INSTANCES and instances[idx].in_use) {
        instances[idx].ref_count += 1;
    }
}
pub fn close(idx: usize) void {
    if (idx < MAX_EPOLL_INSTANCES and instances[idx].in_use) {
        if (instances[idx].ref_count > 0) instances[idx].ref_count -= 1;
        if (instances[idx].ref_count == 0) instances[idx].in_use = false;
    }
}
pub fn ctl(idx: usize, op: usize, target_fd: usize, ev: LinuxEpollEvent) Errno!void {
    // Builder implements EPOLL_CTL_ADD, EPOLL_CTL_MOD, EPOLL_CTL_DEL
}
pub fn collectReadyEvents(
    idx: usize,
    fd_table: *const [vfs.MAX_OPEN_FILES]vfs.FdEntry,
    out_events: []LinuxEpollEvent,
) usize {
    // Builder checks each registered item against pipe/socket/tty readiness and fills out_events
}
```
### 4.3 `src/user/thread_epoll_test.zig` (Verification Binary)
Create `src/user/thread_epoll_test.zig`:
```zig
const std = @import("std");
const CLONE_VM: usize = 0x00000100;
const CLONE_FS: usize = 0x00000200;
const CLONE_FILES: usize = 0x00000400;
const CLONE_SIGHAND: usize = 0x00000800;
const CLONE_THREAD: usize = 0x00010000;
const CLONE_SETTLS: usize = 0x00080000;
const CLONE_PARENT_SETTID: usize = 0x00100000;
const CLONE_CHILD_CLEARTID: usize = 0x00200000;
const FUTEX_WAIT: usize = 0;
const FUTEX_WAKE: usize = 1;
const EPOLL_CTL_ADD: usize = 1;
const EPOLLIN: u32 = 0x001;
const LinuxEpollEvent = extern struct {
    events: u32 align(1),
    data: u64 align(1),
};
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call mainThread
    );
}
inline fn syscall0(num: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
        : "rcx", "r11", "memory"
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
fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}
fn failExit(code: usize) noreturn {
    _ = syscall1(231, code); // sys_exit_group
    unreachable;
}
var worker_stack: [16384]u8 align(16) = undefined;
var worker_tls: [8]u64 align(16) = .{ 0xCAFE_BABE_ABCD_1234, 0, 0, 0, 0, 0, 0, 0 };
var shared_value: u64 = 0;
var futex_gate: i32 align(4) = 0;
var parent_tid_slot: i32 align(4) = 0;
var child_tid_futex: i32 align(4) = 999;
var pipe_fds: [2]i32 align(8) = .{ -1, -1 };
export fn workerEntry() callconv(.C) noreturn {
    const tls_magic = asm volatile ("movq %%fs:0, %[ret]"
        : [ret] "=r" (-> u64),
    );
    if (tls_magic != 0xCAFE_BABE_ABCD_1234) failExit(31);
    shared_value = 0x1337_C0DE_2026_ABCD;
    @atomicStore(i32, &futex_gate, 1, .seq_cst);
    _ = syscall3(202, @intFromPtr(&futex_gate), FUTEX_WAKE, 1);
    const msg = "[TINUX_THREAD] Worker thread event delivered via pipe to epoll!\n";
    _ = syscall3(1, @intCast(pipe_fds[1]), @intFromPtr(msg.ptr), msg.len);
    _ = syscall1(60, 0); // sys_exit(0)
    unreachable;
}
export fn mainThread() callconv(.C) noreturn {
    if (syscall1(22, @intFromPtr(&pipe_fds)) != 0) failExit(10);
    const epfd = syscall1(291, 0); // sys_epoll_create1(0)
    if (epfd < 0) failExit(11);
    var ev = LinuxEpollEvent{
        .events = EPOLLIN,
        .data = 0xDEAD_BEEF_CAFE_0001,
    };
    if (syscall4(233, @intCast(epfd), EPOLL_CTL_ADD, @intCast(pipe_fds[0]), @intFromPtr(&ev)) != 0) {
        failExit(12);
    }
    const stack_top = @intFromPtr(&worker_stack) + worker_stack.len;
    const flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND |
        CLONE_THREAD | CLONE_SETTLS | CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID;
    const clone_rc = asm volatile (
        \\ syscall
        \\ testq %rax, %rax
        \\ jnz 1f
        \\ xorq %rbp, %rbp
        \\ call workerEntry
        \\ 1:
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (@as(usize, 56)),
          [a1] "{rdi}" (flags),
          [a2] "{rsi}" (stack_top),
          [a3] "{rdx}" (@intFromPtr(&parent_tid_slot)),
          [a4] "{r10}" (@intFromPtr(&child_tid_futex)),
          [a5] "{r8}" (@intFromPtr(&worker_tls)),
        : "rcx", "r11", "memory"
    );
    if (clone_rc <= 0) failExit(13);
    if (parent_tid_slot != @as(i32, @intCast(clone_rc))) failExit(14);
    if (@atomicLoad(i32, &futex_gate, .seq_cst) == 0) {
        _ = syscall4(202, @intFromPtr(&futex_gate), FUTEX_WAIT, 0, 0);
    }
    if (shared_value != 0x1337_C0DE_2026_ABCD) failExit(15);
    writeStdout("[TINUX_FUTEX] Shared-VM thread spawned & synchronized via sys_futex!\n");
    var out_ev = LinuxEpollEvent{ .events = 0, .data = 0 };
    const n_ready = syscall4(281, @intCast(epfd), @intFromPtr(&out_ev), 1, 5000);
    if (n_ready != 1) failExit(16);
    if ((out_ev.events & EPOLLIN) == 0 or out_ev.data != 0xDEAD_BEEF_CAFE_0001) failExit(17);
    var rx_buf: [128]u8 = undefined;
    const n_read = syscall3(0, @intCast(pipe_fds[0]), @intFromPtr(&rx_buf), rx_buf.len);
    if (n_read <= 0) failExit(18);
    writeStdout(rx_buf[0..@intCast(n_read)]);
    while (@atomicLoad(i32, &child_tid_futex, .seq_cst) != 0) {
        const cur_tid = @atomicLoad(i32, &child_tid_futex, .seq_cst);
        if (cur_tid == 0) break;
        _ = syscall4(202, @intFromPtr(&child_tid_futex), FUTEX_WAIT, @as(u32, @bitCast(cur_tid)), 0);
    }
    writeStdout("[TINUX_JOIN] Worker thread joined cleanly via CLONE_CHILD_CLEARTID!\n");
    _ = syscall1(231, 0); // sys_exit_group(0)
    unreachable;
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Extend `src/proc/task.zig` for threads:**
   * Add `WAITING_FUTEX = 10` and `WAITING_EPOLL = 11` to `TaskState`.
   * Add thread tracking fields to `Task`:
     * `tgid: usize = 1`
     * `is_thread: bool = false`
     * `clear_child_tid: usize = 0`
     * `wait_futex_paddr: usize = 0`
     * `wait_epoll_idx: usize = 0`
   * Add `wakeEpollWaiters()` helper to wake tasks waiting on epoll events.
   * In `cloneCurrentTask(parent_frame, flags, child_stack, ptid_ptr, ctid_ptr, newtls)`:
     1. Allocate unused task slot `child_idx`.
     2. Check `const is_vm_shared = (flags & 0x0100) != 0;` (`CLONE_VM`).
     3. Check `const is_thread_flag = (flags & 0x0001_0000) != 0;` (`CLONE_THREAD`).
     4. Set `child.pml4_phys = if (is_vm_shared) parent.pml4_phys else (vmm.cloneUserPml4(parent.pml4_phys) orelse return error.OutOfMemory);`.
     5. Allocate new PID for child: `next_pid += 1; child.pid = next_pid;`.
     6. Assign thread group ID: `child.tgid = if (is_thread_flag) parent.tgid else child.pid;`.
     7. Assign parent PID: `child.parent_pid = if (is_thread_flag) parent.parent_pid else parent.pid;`.
     8. Set `child.is_thread = is_thread_flag;`.
     9. Set `child.fs_base = if ((flags & 0x0008_0000) != 0) newtls else parent.fs_base;`.
     10. Set `child.clear_child_tid = if ((flags & 0x0020_0000) != 0) ctid_ptr else 0;`.
     11. If `CLONE_PARENT_SETTID` is set and `ptid_ptr != 0`, write child PID to `ptid_ptr`.
     12. If `CLONE_CHILD_SETTID` is set and `ctid_ptr != 0`, write child PID to `ctid_ptr`.
     13. Duplicate file descriptors and increment reference counts on pipes, sockets, and epoll instances.
     14. Configure child saved frame: set `rax = 0`; if `child_stack != 0`, set `rsp = child_stack`.
2. **Step 2: Implement Syscalls in `src/syscall/dispatch.zig`:**
   * `sysGetpid (39)`: return `tgid`.
   * `sysGettid (186)`: return `pid`.
   * `sysSetTidAddress (218)`: set `cur.clear_child_tid = tidptr; return @intCast(cur.pid);`.
   * `sysExit (60)` vs `sysExitGroup (231)`:
     * If `cur.clear_child_tid != 0`, translate address, write 0 to user memory, and call `futex.wakeByPaddr(paddr, 1)`.
     * If `syscall_num == 60` and `cur.is_thread`, release thread resources, mark state `.UNUSED`, and switch tasks without waking parent wait4.
     * If process exit (`sysExitGroup` or last thread), mark state `.ZOMBIE` and wake parent process.
   * `sysFutex (202)`: implement `FUTEX_WAIT` and `FUTEX_WAKE` using physical address matching.
   * Epoll syscalls: `sysEpollCreate1 (291)`, `sysEpollCtl (233)`, `sysEpollPwait (281)`.
3. **Step 3: Update `scripts/verify_qemu.sh` and `src/main.zig`:**
   * Build `src/user/thread_epoll_test.zig` via `zig build-exe -target x86_64-linux-none -O ReleaseSmall`.
   * Add `/bin/thread_epoll_test` into initramfs.
   * Update `/etc/rc.sh` test sequence:
     ```bash
     echo "[TINUX_SH] Running multi-threaded futex & epoll verification suite..."
     /bin/thread_epoll_test
     echo "[TINUX_RUNTIME] CLONE_VM threads, futex synchronization, and epoll multiplexing verified!"
     exit 0
     ```
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-014 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-014
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Running multi-threaded futex & epoll verification suite...
[TINUX_FUTEX] Shared-VM thread spawned & synchronized via sys_futex!
[TINUX_THREAD] Worker thread event delivered via pipe to epoll!
[TINUX_JOIN] Worker thread joined cleanly via CLONE_CHILD_CLEARTID!
[TINUX_RUNTIME] CLONE_VM threads, futex synchronization, and epoll multiplexing verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-014
[HARNESS] SUCCESS: TASK-014 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-014 10` fails 3 consecutive times, stop execution and generate `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-014
## 1. Failure Summary
* **Failed Stage:** [thread_epoll_test Build / sys_clone Arg Order / TLS %fs:0 Fault / Futex Deadlock / Epoll 12-Byte Event]
* **Exit Code from thread_epoll_test (if applicable):** [10..31]
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
[Relevant code diff for src/proc/task.zig, src/proc/futex.zig, src/fs/epoll.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
