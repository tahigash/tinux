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
 specification with definition `sys_clone` of arguments、 `LinuxEpollEvent` of 12 、 `futex` of Physical addresswaiting⽅
2. **Critical x86_64 `epoll_event` 12-Byte Packing Rule （important ABI contract） :**
 x86_64 Linux ABI of `struct epoll_event` **`__attribute__((packed))` of 12 bytes （ `events: u32` + `data: u64
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-014 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |

| ⾮ 32bit | `@ptrCast(*i32, addr).*` | `std.mem.readInt(i32, @as(*const [4]u8, @ptrFromInt(addr)),.li
| ⾮ 64bit | `@ptrCast(*u64, addr).*` | `std.mem.writeInt(u64, @as(*[8]u8, @ptrFromInt(addr)), val,.li
| → 32bit | `@bitCast(i32, val_u32)` | `@as(i32, @bitCast(val_u32))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-014`
* **Title:** `Multi-Threading (CLONE_VM | CLONE_THREAD | CLONE_SETTLS | CLONE_CHILD_CLEARTID), Fast Userspace Lockin
* **Target Subsystem:** `proc`, `sync`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/proc/futex.zig` (Create: physical-address-indexed futex wait/wake subsystem)
  * `src/fs/epoll.zig` (Create: kernel epoll table, interest list, and readiness polling across pipes/sockets/TTYs)
  * `src/fs/vfs.zig` (Modify: add `FdKind.EPOLL = 7` and integrate `epoll.close` into `closeTaskFd`)
  * `src/proc/task.zig` (Modify: add `tgid`, `is_thread`, `clear_child_tid`, `WAITING_FUTEX = 10`, `WAITING_EPOLL = 
  * `src/syscall/dispatch.zig` (Modify: upgrade `sys_clone`, split `sys_exit` vs `sys_exit_group` for threads, add `
  * `src/user/thread_epoll_test.zig` (Create: standalone Linux `x86_64` multi-threaded + futex + epoll test binary)
  * `src/main.zig` (Modify: call `epoll.init()` and update test markers to `TASK-014`)
  * `scripts/verify_qemu.sh` (Modify: compile `/bin/thread_epoll_test`, include in `initramfs.cpio`, and execute via
---
## 3. Threading, Futex & Epoll ABI Contract (Opus 5.5 Audited)
### 3.1 x86_64 `sys_clone` (Syscall 56) Raw Argument Order & Thread Flags
** 【】 ** C of `clone()` function and 、 x86_64 Linux of ⽣ of `syscall` ABI with arguments of 。 x86_
* **`rdi` (Arg1):** `clone_flags: usize`
* **`rsi` (Arg2):** `child_stack: usize` (`newsp`)
* **`rdx` (Arg3):** `parent_tidptr: usize` (`int *ptid`)
* **`r10` (Arg4):** `child_tidptr: usize` (`int *ctid`)
* **`r8`  (Arg5):** `newtls: usize` (`tls` base address for `%fs`)
| Clone Flag | Hex Value | Exact Kernel Behavior |
| :--- | :--- | :--- |
| **`CLONE_VM`** | `0x0000_0100` | pagestable 、 ** parenttask of `pml4_phys` of shared ** （parent⼦ of 
| **`CLONE_SETTLS`** | `0x0008_0000` | ⼦task of `fs_base` `r8` (`newtls`) （ `activateTask` `MSR_FS_
| **`CLONE_PARENT_SETTID`** | `0x0010_0000` | `parent_tidptr != 0` of when、 of ⼦ of `tid` (`child.pid`
| **`CLONE_CHILD_CLEARTID`** | `0x0020_0000` | ⼦task of `clear_child_tid = child_tidptr` (`r10`) 。 of 
| **`CLONE_CHILD_SETTID`** | `0x0100_0000` | `child_tidptr != 0` of when、 of ⼦ of `tid` (`child.pid`, 
| **`CLONE_THREAD`** | `0x0001_0000` | ⼦task of `tgid` parent of `tgid` and 、 `is_thread = true` 。 `sys_g
### 3.2 `sys_futex` (Syscall 202) Contract
```text
sys_futex(uaddr: usize, futex_op: usize, val: u32, timeout: usize, uaddr2: usize, val3: u32) -> isize
```
* number of ： `const cmd = futex_op & 0x7F;` （ `FUTEX_PRIVATE_FLAG = 0x80` `FUTEX_CLOCK_REALTIME = 0x10
* Physical address to of ： `uaddr` 4 verify、 `const paddr = vmm.translate(cur.pml4_ph
1. **`FUTEX_WAIT (0)` / `FUTEX_WAIT_BITSET (9)`:**
 * of 32bit value `const cur_val = std.mem.readInt(i32, @as(*const [4]u8, @ptrFromInt(paddr)),.little);` 。
 * `cur_val != @as(i32, @bitCast(val))` with 、block **`-EAGAIN (-11)`** 。
 * ⼀、 `frame.rax = 0;` （woken of return value `0` ）、 `cur.saved_frame = frame;` 、 `cur.wait_futex_paddr = paddr;
2. **`FUTEX_WAKE (1)` / `FUTEX_WAKE_BITSET (10)`:**
 * `tasks` table ⾛、 `t.state ==.WAITING_FUTEX and t.wait_futex_paddr == paddr` of task ⼤ `val` with `
### 3.3 `epoll` (`sys_epoll_create1`, `sys_epoll_ctl`, `sys_epoll_pwait`) Contract
* **x86_64 `LinuxEpollEvent` struct（ 12 bytes strictly adhere） :**
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
* ** constantsdefinition :**
  * `EPOLL_CTL_ADD = 1`, `EPOLL_CTL_DEL = 2`, `EPOLL_CTL_MOD = 3`
  * `EPOLLIN = 0x001`, `EPOLLOUT = 0x004`, `EPOLLERR = 0x008`, `EPOLLHUP = 0x010`
* **Readiness evaluation (`epoll.checkFdReady(cur_task, target_fd, watched_events)`):**
 `cur_task.fd_table[target_fd]` of of ⽣mask `revents: u32` ：
 * `.PIPE_READ`: pipe of `count > 0` `EPOLLIN` 、 `writers == 0` `EPOLLHUP` 。

 * `.PIPE_WRITE`: pipe of `count < PIPE_BUF_SIZE` `EPOLLOUT` 、 `readers == 0` `EPOLLERR` 。
 * `.SOCKET`: socket of `rx_count > 0` or `accept_count > 0` `EPOLLIN` 、 `peer_closed` `EPOLLHUP
 * `.CONSOLE_IN` / `.CONSOLE_OUT`: `tty.hasReadableData()` `EPOLLIN` 、 `EPOLLOUT` 。
 * `.VFS_FILE`: `EPOLLIN | EPOLLOUT` 。
* ** blocking and woken :**
 `sys_epoll_wait(232)` / `sys_epoll_pwait(281)` with of FD 1 、 `events_ptr` `LinuxEpollEvent` （ 12
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
### 4.3 `src/user/thread_epoll_test.zig` (Standalone Linux `x86_64` Thread + Futex + Epoll Verification Binary)
Create `src/user/thread_epoll_test.zig` with the following implementation:
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
    // 1. Verify CLONE_SETTLS loaded %fs:0 properly
    const tls_magic = asm volatile ("movq %%fs:0, %[ret]"
        : [ret] "=r" (-> u64),
    );
    if (tls_magic != 0xCAFE_BABE_ABCD_1234) failExit(31);
    // 2. Mutate shared memory (proving CLONE_VM shared address space)
    shared_value = 0x1337_C0DE_2026_ABCD;
    // 3. Signal futex_gate = 1 and wake main thread via FUTEX_WAKE
    @atomicStore(i32, &futex_gate, 1, .seq_cst);
    _ = syscall3(202, @intFromPtr(&futex_gate), FUTEX_WAKE, 1);
    // 4. Write message into pipe monitored by main thread's epoll
    const msg = "[TINUX_THREAD] Worker thread event delivered via pipe to epoll!\n";
    _ = syscall3(1, @intCast(pipe_fds[1]), @intFromPtr(msg.ptr), msg.len);
    // 5. Exit only this worker thread via sys_exit(60) -> triggers CLONE_CHILD_CLEARTID
    _ = syscall1(60, 0);
    unreachable;
}
export fn mainThread() callconv(.C) noreturn {

    // 1. Create pipe for epoll notification
    if (syscall1(22, @intFromPtr(&pipe_fds)) != 0) failExit(10);
    // 2. Create epoll instance via sys_epoll_create1(0) (291)
    const epfd = syscall1(291, 0);
    if (epfd < 0) failExit(11);
    // 3. Register pipe_fds[0] with EPOLLIN and 64-bit tag 0xDEADBEEFCAFE0001
    var ev = LinuxEpollEvent{
        .events = EPOLLIN,
        .data = 0xDEAD_BEEF_CAFE_0001,
    };
    if (syscall4(233, @intCast(epfd), EPOLL_CTL_ADD, @intCast(pipe_fds[0]), @intFromPtr(&ev)) != 0) {
        failExit(12);
    }
    // 4. Spawn worker thread using raw x86_64 sys_clone(56)
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
    // 5. Wait on futex_gate if worker hasn't set it to 1 yet
    if (@atomicLoad(i32, &futex_gate, .seq_cst) == 0) {
        _ = syscall4(202, @intFromPtr(&futex_gate), FUTEX_WAIT, 0, 0);
    }
    if (shared_value != 0x1337_C0DE_2026_ABCD) failExit(15);
    writeStdout("[TINUX_FUTEX] Shared-VM thread spawned & synchronized via sys_futex!\n");
    // 6. Wait for pipe readability via sys_epoll_pwait(281)
    var out_ev = LinuxEpollEvent{ .events = 0, .data = 0 };
    const n_ready = syscall4(281, @intCast(epfd), @intFromPtr(&out_ev), 1, 5000);
    if (n_ready != 1) failExit(16);
    if ((out_ev.events & EPOLLIN) == 0 or out_ev.data != 0xDEAD_BEEF_CAFE_0001) failExit(17);
    var rx_buf: [128]u8 = undefined;
    const n_read = syscall3(0, @intCast(pipe_fds[0]), @intFromPtr(&rx_buf), rx_buf.len);
    if (n_read <= 0) failExit(18);
    writeStdout(rx_buf[0..@intCast(n_read)]);
    // 7. Join worker thread via CLONE_CHILD_CLEARTID futex
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
1. **Step 1: `src/proc/task.zig` of thread **
 * `TaskState` `WAITING_FUTEX = 10` and `WAITING_EPOLL = 11` add。

 * `Task` struct of add：
 * `tgid: usize = 1` （ `initPid1` with `tgid = 1` ）
     * `is_thread: bool = false`
     * `clear_child_tid: usize = 0`
     * `wait_futex_paddr: usize = 0`
     * `wait_epoll_idx: usize = 0`
 * `task.zig` `pub fn wakeEpollWaiters() void` add、 `t.state ==.WAITING_EPOLL` of task `t.state =.READ
   * `cloneCurrentTask(parent_frame: *SyscallFrame, flags: usize, child_stack: usize, ptid_ptr: usize, ctid_ptr: usi
 1. emptytask `child_idx` allocated。
     2. `const is_vm_shared = (flags & 0x0100) != 0;` (`CLONE_VM`)
     3. `const is_thread_flag = (flags & 0x0001_0000) != 0;` (`CLONE_THREAD`)
     4. `const child_pml4 = if (is_vm_shared) parent.pml4_phys else (vmm.cloneUserPml4(parent.pml4_phys) orelse retu
     5. `next_pid += 1; child.pid = next_pid;`
     6. `child.tgid = if (is_thread_flag) parent.tgid else child.pid;`
     7. `child.parent_pid = if (is_thread_flag) parent.parent_pid else parent.pid;`
     8. `child.is_thread = is_thread_flag;`
     9. `child.pml4_phys = child_pml4;`
     10. `child.fs_base = if ((flags & 0x0008_0000) != 0) newtls else parent.fs_base;` (`CLONE_SETTLS`)
     11. `child.clear_child_tid = if ((flags & 0x0020_0000) != 0) ctid_ptr else 0;` (`CLONE_CHILD_CLEARTID`)
     12. `if ((flags & 0x0010_0000) != 0 and ptid_ptr != 0)` (`CLONE_PARENT_SETTID`):
         `std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(ptid_ptr)), @intCast(child.pid), .little);`
     13. `if ((flags & 0x0100_0000) != 0 and ctid_ptr != 0)` (`CLONE_CHILD_SETTID`):
         `std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(ctid_ptr)), @intCast(child.pid), .little);`
 14. `child.fd_table = parent.fd_table;` 、 FD of referencedcount（ `pipe.retain*`, `socket.retain`, `epoll.
 15. ⼦ of stack `parent_frame` 、 `child.saved_frame.rax = 0` 、 `if (child_stack != 0) chi
2. **Step 2: `src/syscall/dispatch.zig` of threadexit‧ Futex ‧ Epoll implement **
   * **`sysGetpid` (39) vs `sysGettid` (186):**
     * `sysGetpid`: `return @intCast(task.currentTask().tgid);`
     * `sysGettid`: `return @intCast(task.currentTask().pid);`
   * **`sysSetTidAddress` (218):**
     `cur.clear_child_tid = tidptr; return @intCast(cur.pid);`
 * **`sysExit` (60) and `sysExitGroup` (231) of :**
 * `cur.clear_child_tid != 0` of when：
 `if (vmm.translate(cur.pml4_phys, cur.clear_child_tid)) |paddr|` 、 `std.mem.writeInt(i32, @as(*[4]u8, 
 * `syscall_num == 60 (SYS_EXIT)` `cur.is_thread == true` of when（thread of exit）：
 `task.closeAllFds(cur);` 、 `cur.state =.UNUSED;` `const next_idx = task.scheduleNextOrWait(); tas
 * （process of exit or `SYS_EXIT_GROUP` ）：＋parentprocess of woken（ or PID 1 test PA
   * **`sysFutex` (202):**
 3.2 of 、 `FUTEX_WAIT` / `FUTEX_WAIT_BITSET` and `FUTEX_WAKE` / `FUTEX_WAKE_BITSET` implement。
   * **`sysEpollCreate1` (291) / `sysEpollCreate` (213), `sysEpollCtl` (233), `sysEpollWait` (232) / `sysEpollPwait`
 3.3 of 、 12 of `LinuxEpollEvent` and ‧blockingwaiting implement。
3. **Step 3: `scripts/verify_qemu.sh` and `src/main.zig` of update **
 * `scripts/verify_qemu.sh` with 、 `zig build-exe src/user/thread_epoll_test.zig -target x86_64-linux-none -O Releas
 * `vfs.lookup` with node `bin/thread_epoll_test` of verify。
 * `scripts/verify_qemu.sh` with QEMU ⼊⼒ to type update：
     ```bash
     (
         sleep 0.4
         cat << 'EOF'
     echo "[TINUX_SH] Running multi-threaded futex & epoll verification suite..."
     /bin/thread_epoll_test
     echo "[TINUX_RUNTIME] CLONE_VM threads, futex synchronization, and epoll multiplexing verified!"
     exit 0
     EOF
     ) | timeout "$TIMEOUT_SEC" qemu-system-x86_64 ...
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
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-014 10` when、 Builder fixloop stop、 `ESCALATI
```markdown
# Escalation Report: TASK-014
## 1. Failure Summary
* **Failed Stage:** [thread_epoll_test Build / sys_clone Arg Order / TLS %fs:0 Fault / Futex Deadlock / Epoll 12-Byt
* **Exit Code from thread_epoll_test (if applicable):** [10..31 of of with ]
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
[Relevant code diff for src/proc/task.zig, src/proc/futex.zig, src/fs/epoll.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
