# Tinux Implementation Specification: TASK-008
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-007` Passed (`./scripts/verify_qemu.sh TASK-007 5` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition `PipeBuffer` struct、 `FdEntry` of （ `FdKind` ）、pipereferencedcount of 、 `/proc` ⽣
2. **Strict Pipe Reference Counting （pipereferencedcount of strictly adhere） :**
 pipe（ `cmd1 | cmd2` ） `cmd2` （ `grep` ） EOF （ `read == 0` ） with 、 `fork` ‧ `dup`/
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-008 5` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| buffer to of output | `std.fmt.bufPrint` on failure of | `std.fmt.bufPrint(&buf, fmt, args) catch unreachable`
| 32bit columnwrite | referenced | `@as(*align(1) [2]i32, @ptrFromInt(user_ptr)).* =.{ r_fd, w_fd
| Enum to integer | `@enumToInt(e)` | `@intFromEnum(e)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-008`
* **Title:** `IPC Pipes (sys_pipe / sys_pipe2), Standard I/O Redirection (sys_dup2 / O_CLOEXEC), /proc Pseudo-Filesy
* **Target Subsystem:** `fs`, `proc`, `syscall`
* **Target Files to Create / Modify:**
  * `src/fs/pipe.zig` (Create: kernel ring-buffer pipe table and reference counting)
  * `src/fs/procfs.zig` (Create: dynamic `/proc/version`, `/proc/meminfo`, `/proc/cpuinfo`, `/proc/mounts` generator
  * `src/fs/vfs.zig` (Modify: unify FD `0..63` under `FdEntry` with `FdKind`, integrate `/proc` lookup and `cloexec`
  * `src/proc/task.zig` (Modify: handle `WAITING_PIPE` state, pipe refcount increment on `fork`, FD cleanup on `exit
  * `src/syscall/dispatch.zig` (Modify: implement `sys_pipe`, `sys_pipe2`, unified `sys_read`/`sys_write`/`sys_close
  * `src/main.zig` (Modify: initialize `pipe.init()` and `procfs.init()`, run TASK-008 verification)
  * `scripts/verify_qemu.sh` (Modify: update `/etc/rc.sh` to execute `/proc` inspection and `cat /etc/motd | grep Ti
---
## 3. Pipe, Redirection & `/proc` Contract (Opus 5.5 Audited)
### 3.1 Unified File Descriptor Table (`fd_table[0..64]`)
`sys_dup2(pipe_write_fd, 1)` `sys_dup2(pipe_read_fd, 0)` ⼊output（ FD `0, 1, 2` ）pipe 
| `FdKind` | `sys_read` of | `sys_write` / `sys_writev` of | `sys_close` of |
| :--- | :--- | :--- | :--- |
| **`.NONE`** | `-EBADF (-9)` | `-EBADF (-9)` | `-EBADF (-9)` |
| **`.CONSOLE_IN`** | `0` (EOF) | `-EBADF (-9)` | `.NONE` cleared `0` |
| **`.CONSOLE_OUT`** | `-EBADF (-9)` | `serial.writeString` output | `.NONE` cleared `0` 
| **`.VFS_FILE`** | `VfsNode` （ or `/proc` buffer） from 、 `offset` | `-EBADF` （ or `/dev/null
| **`.PIPE_READ`** | `pipe.read(pipe_idx,...)` execute。empty `writers > 0` of whenblockingwaiting | `-EBADF 
| **`.PIPE_WRITE`** | `-EBADF (-9)` | `pipe.write(pipe_idx,...)` execute。 `readers == 0` `-EPIPE (-32)` | `pipe.
### 3.2 Pipe Lifecycle & Reference Counting Contract (Deadlock Prevention)

 `cat /etc/motd | grep Tinux` execute、parent and 2 of ⼦process with pipe FD duplicated。 of 5 of rules **1 
1. **`pipe.allocPipe(cloexec: bool)`:**
 empty `Pipe` allocated、 `readers = 1`, `writers = 1`, `read_pos = 0`, `write_pos = 0`, `count = 0` initialized
2. **`task.forkCurrentTask` :**
 parent of `fd_table[0..64]` ⼦ to 、 ：
 * `.PIPE_READ` `pipe.retainRead(entry.pipe_idx)` （ `readers += 1` ） 。
 * `.PIPE_WRITE` `pipe.retainWrite(entry.pipe_idx)` （ `writers += 1` ） 。
3. **`sys_dup` / `sys_dup2` / `sys_dup3` / `sys_fcntl(F_DUPFD)` :**
 * `dup2(oldfd, newfd)` with `oldfd == newfd` of when `newfd` （ `oldfd` `-EBADF` ）。
 * of `newfd` `.NONE` （） with 、 `vfs.closeTaskFd(&cur.fd_table, newfd)` with 
 * `oldfd` `newfd` 、 `.PIPE_READ` `pipe.retainRead` 、 `.PIPE_WRITE` `pipe.retainWrite` 
 * **POSIX `cloexec` rules :** `dup` / `dup2` / `F_DUPFD` with duplicated FD of `cloexec` flagsmust **`false` cleared
4. **`sys_execve` (`closeCloexecFds`):**
 ELF switch、 `cur.fd_table[0..64]` ⾛、 `entry.kind !=.NONE and entry.cloexec == true` of 
5. **`sys_exit` / `sys_exit_group` (`closeAllFds`):**
 processexit、state `cur.fd_table[0..64]` of of FD `vfs.closeTaskFd(&cur.fd_t
### 3.3 Cooperative Blocking on Pipe Read (`WAITING_PIPE`)
thread‧task 、⼦process 2 （ `grep` ）⼦process 1 （ `cat` ） empty of pipe
1. `pipe.read` `WouldBlock` （ `count == 0` `writers > 0` ） when：
 * of task of `frame.user_rip -= 2` （ `syscall` `0F 05` of 2 ） and `frame.rax = 0` （ `SYS_READ`
 * `cur.state =.WAITING_PIPE;` 、 `cur.wait_pipe_idx = pipe_idx;` 。
 * `task.findNextRunnable()` with executetask（ `cat` or parent） 、 `task.activateTask(next_idx)` with 
2. `pipe.write` with 、 or `pipe.closeWrite` with `writers == 0` ：
 * `task.wakePipeWaiters(pipe_idx)` 、 `state ==.WAITING_PIPE and wait_pipe_idx == pipe_idx` of task `
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/fs/pipe.zig`
```zig
const std = @import("std");
pub const MAX_PIPES: usize = 16;
pub const PIPE_BUF_SIZE: usize = 4096;
pub const PipeReadResult = union(enum) {
    bytes: usize,
    eof: void,
    would_block: void,
};
pub const Pipe = struct {
    in_use: bool = false,
    buf: [PIPE_BUF_SIZE]u8 = [_]u8{0} ** PIPE_BUF_SIZE,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,
    readers: usize = 0,
    writers: usize = 0,
};
var pipes: [MAX_PIPES]Pipe = [_]Pipe{.{}} ** MAX_PIPES;
pub fn init() void {
    for (&pipes) |*p| p.* = .{};
}
pub fn alloc() ?usize {
    for (&pipes, 0..) |*p, idx| {
        if (!p.in_use) {
            p.* = .{
                .in_use = true,
                .readers = 1,
                .writers = 1,
            };
            return idx;
        }
    }
    return null;
}

pub fn retainRead(idx: usize) void {
    pipes[idx].readers += 1;
}
pub fn retainWrite(idx: usize) void {
    pipes[idx].writers += 1;
}
pub fn closeRead(idx: usize) void {
    var p = &pipes[idx];
    if (p.readers > 0) p.readers -= 1;
    if (p.readers == 0 and p.writers == 0) p.in_use = false;
}
pub fn closeWrite(idx: usize) bool {
    var p = &pipes[idx];
    if (p.writers > 0) p.writers -= 1;
    const hit_zero = (p.writers == 0);
    if (p.readers == 0 and p.writers == 0) p.in_use = false;
    return hit_zero;
}
pub fn read(idx: usize, dst: []u8) PipeReadResult {
    var p = &pipes[idx];
    if (p.count == 0) {
        if (p.writers == 0) return .eof;
        return .would_block;
    }
    const to_read = @min(dst.len, p.count);
    for (0..to_read) |i| {
        dst[i] = p.buf[p.read_pos];
        p.read_pos = (p.read_pos + 1) % PIPE_BUF_SIZE;
    }
    p.count -= to_read;
    return .{ .bytes = to_read };
}
pub fn write(idx: usize, src: []const u8) ?usize {
    var p = &pipes[idx];
    if (p.readers == 0) return null; // Broken pipe (EPIPE)
    const space = PIPE_BUF_SIZE - p.count;
    const to_write = @min(src.len, space);
    for (0..to_write) |i| {
        p.buf[p.write_pos] = src[i];
        p.write_pos = (p.write_pos + 1) % PIPE_BUF_SIZE;
    }
    p.count += to_write;
    return to_write;
}
```
### 4.2 `src/fs/procfs.zig`
```zig
const std = @import("std");
const pmm = @import("../mm/pmm.zig");
const vfs = @import("vfs.zig");
var version_buf: [128]u8 = undefined;
var cpuinfo_buf: [256]u8 = undefined;
var meminfo_buf: [256]u8 = undefined;
var mounts_buf: [128]u8 = undefined;
pub fn initAndRegister() void {
    // Register /proc directory and dynamic pseudo-files into VFS
    _ = vfs.registerNode("proc", vfs.S_IFDIR | 0o555, "");
    const ver_str = "Linux version 6.12.0-tinux (zig@tinux) #1 SMP PREEMPT_DYNAMIC\n";
    @memcpy(version_buf[0..ver_str.len], ver_str);
    _ = vfs.registerNode("proc/version", vfs.S_IFREG | 0o444, version_buf[0..ver_str.len]);
    const cpu_str =
        "processor\t: 0\n" ++
        "vendor_id\t: TinuxZig\n" ++
        "model name\t: Tinux Virtual x86_64 CPU\n" ++
        "cpu MHz\t\t: 3000.000\n\n";
    @memcpy(cpuinfo_buf[0..cpu_str.len], cpu_str);
    _ = vfs.registerNode("proc/cpuinfo", vfs.S_IFREG | 0o444, cpuinfo_buf[0..cpu_str.len]);
    const mnt_str = "rootfs / rootfs rw 0 0\nproc /proc proc rw 0 0\n";

    @memcpy(mounts_buf[0..mnt_str.len], mnt_str);
    _ = vfs.registerNode("proc/mounts", vfs.S_IFREG | 0o444, mounts_buf[0..mnt_str.len]);
    refreshMeminfo();
}
pub fn refreshMeminfo() void {
    const total_kb = (pmm.TOTAL_PAGES * 4);
    const free_kb = (pmm.getFreePageCount() * 4);
    const slice = std.fmt.bufPrint(
        &meminfo_buf,
        "MemTotal:         {d} kB\nMemFree:          {d} kB\nMemAvailable:     {d} kB\n",
        .{ total_kb, free_kb, free_kb },
    ) catch unreachable;
    _ = vfs.registerNode("proc/meminfo", vfs.S_IFREG | 0o444, slice);
}
```
### 4.3 `src/fs/vfs.zig` Unified `FdEntry` Design
`vfs.zig` of `OpenFile` of `FdEntry` （ or ）、⼊output‧‧pipe ⼀ ：
```zig
pub const FdKind = enum(u8) {
    NONE = 0,
    CONSOLE_IN = 1,
    CONSOLE_OUT = 2,
    VFS_FILE = 3,
    PIPE_READ = 4,
    PIPE_WRITE = 5,
};
pub const FdEntry = struct {
    kind: FdKind = .NONE,
    cloexec: bool = false,
    node_idx: usize = 0,
    pipe_idx: usize = 0,
    offset: usize = 0,
    flags: u32 = 0,
};
pub fn initStdio(table: *[MAX_OPEN_FILES]FdEntry) void {
    for (table) |*entry| entry.* = .{};
    table[0] = .{ .kind = .CONSOLE_IN };
    table[1] = .{ .kind = .CONSOLE_OUT };
    table[2] = .{ .kind = .CONSOLE_OUT };
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/vfs.zig` of FD implement **
 * `vfs.lookup(raw_path)` of BusyBox `"bin/grep"`, `"grep"`, `"bin/ls"`, `"ls"` add
   * `allocFd(table: *[MAX_OPEN_FILES]FdEntry, min_fd: usize) ?usize`:
 `min_fd.. MAX_OPEN_FILES` of with `table[fd].kind ==.NONE` of of 。
   * `closeTaskFd(table: *[MAX_OPEN_FILES]FdEntry, fd: usize) Errno!void`:
     1. `if (fd >= MAX_OPEN_FILES or table[fd].kind == .NONE) return Errno.EBADF;`
     2. `const entry = table[fd];`
     3. `table[fd] = .{};`
     4. `if (entry.kind == .PIPE_READ) pipe.closeRead(entry.pipe_idx);`
 5. `if (entry.kind ==.PIPE_WRITE)` of when、 `if (pipe.closeWrite(entry.pipe_idx)) task.wakePipeWaiters(entry.pip
   * `dupTaskFd(table: *[MAX_OPEN_FILES]FdEntry, old_fd: usize, min_new_fd: usize, cloexec: bool) Errno!usize`:
     1. `if (old_fd >= MAX_OPEN_FILES or table[old_fd].kind == .NONE) return Errno.EBADF;`
     2. `const new_fd = allocFd(table, min_new_fd) orelse return Errno.EMFILE;`
     3. `table[new_fd] = table[old_fd];`
     4. `table[new_fd].cloexec = cloexec;`
     5. `if (table[new_fd].kind == .PIPE_READ) pipe.retainRead(table[new_fd].pipe_idx);`
     6. `if (table[new_fd].kind == .PIPE_WRITE) pipe.retainWrite(table[new_fd].pipe_idx);`
     7. `return new_fd;`
   * `dup2TaskFd(table: *[MAX_OPEN_FILES]FdEntry, old_fd: usize, new_fd: usize, cloexec: bool) Errno!usize`:
     1. `if (old_fd >= MAX_OPEN_FILES or new_fd >= MAX_OPEN_FILES or table[old_fd].kind == .NONE) return Errno.EBADF
     2. `if (old_fd == new_fd) return new_fd;`
     3. `if (table[new_fd].kind != .NONE) closeTaskFd(table, new_fd) catch {};`
     4. `table[new_fd] = table[old_fd];`
     5. `table[new_fd].cloexec = cloexec;`
     6. `if (table[new_fd].kind == .PIPE_READ) pipe.retainRead(table[new_fd].pipe_idx);`
     7. `if (table[new_fd].kind == .PIPE_WRITE) pipe.retainWrite(table[new_fd].pipe_idx);`
     8. `return new_fd;`

2. **Step 2: `src/proc/task.zig` of update（pipewaiting and ） **
 * `TaskState` `WAITING_PIPE = 5` add、 `Task` struct `wait_pipe_idx: usize = 0` add。
 * `initPid1` with `vfs.initStdio(&t.fd_table);` 。
 * `forkCurrentTask` with `child.fd_table = parent.fd_table;` 、 `for (&child.fd_table) |*entry|` with 
 * `wakePipeWaiters(pipe_idx: usize)` implement、 `tasks` of `t.state ==.WAITING_PIPE and t.wait_pipe_idx == pipe_i
 * `closeCloexecFds(t: *Task)` and `closeAllFds(t: *Task)` implement、 `execve` and `exit` must 。
3. **Step 3: `src/syscall/dispatch.zig` of implement **
   * **`sysPipe2(fd_pair_ptr: usize, flags: usize) isize` (293) & `sysPipe(fd_pair_ptr: usize) isize` (22):**
     1. `if (!validateUserBuffer(fd_pair_ptr, 8)) return errno_mod.toReturn(.EFAULT);`
     2. `const cur = task.currentTask();`
     3. `const pipe_idx = pipe.alloc() orelse return errno_mod.toReturn(.ENFILE);`
     4. `const r_fd = vfs.allocFd(&cur.fd_table, 0) orelse { pipe.closeRead(pipe_idx); _ = pipe.closeWrite(pipe_idx)
     5. `const cloexec = (flags & 0o2000000) != 0;` (`O_CLOEXEC = 0x80000`)
     6. `cur.fd_table[r_fd] = .{ .kind = .PIPE_READ, .pipe_idx = pipe_idx, .cloexec = cloexec };`
     7. `const w_fd = vfs.allocFd(&cur.fd_table, 0) orelse { vfs.closeTaskFd(&cur.fd_table, r_fd) catch {}; _ = pipe
     8. `cur.fd_table[w_fd] = .{ .kind = .PIPE_WRITE, .pipe_idx = pipe_idx, .cloexec = cloexec };`
     9. `@as(*align(1) [2]i32, @ptrFromInt(fd_pair_ptr)).* = .{ @intCast(r_fd), @intCast(w_fd) };`
     10. `return 0;`
 * ** `sysRead` (0) and blocking :**
 `cur.fd_table[fd]` of `kind` ：
     * `.CONSOLE_IN` -> `0` (EOF)
 * `.VFS_FILE` -> node from 
 * `.PIPE_READ` -> of ⼀buffer（ or buffer） to `pipe.read(entry.pipe_idx, slice)` execute
 * `.bytes => |n|` `n` 。
 * `.eof` `0` 。
 * `.would_block` ： `frame.user_rip -= 2; frame.rax = 0; cur.state =.WAITING_PIPE; cur.wait_pipe_idx = ent
 * ** `sysWrite` (1) & `sysWritev` (20):**
 `cur.fd_table[fd]` of `kind` ：
 * `.CONSOLE_OUT` -> `serial.writeString(slice)` with output `count` 。
 * `.PIPE_WRITE` -> `pipe.write(entry.pipe_idx, slice)` 、 `task.wakePipeWaiters(entry.pipe_idx)` 
 * `.VFS_FILE` -> `count` （ `/dev/null` to of write⽤）。
   * **`sysOpenat` (257):**
 `O_CLOEXEC (0o2000000)` `flags` when `entry.cloexec = true` 。
   * **`sysFstat` (5):**
 `cur.fd_table[fd].kind` `.CONSOLE_IN` / `.CONSOLE_OUT` `S_IFCHR | 0o666` 、 `.PIPE_READ` / `.PIPE_WRITE` 
4. **Step 4: `scripts/verify_qemu.sh` and `src/main.zig` of update **
 * `scripts/verify_qemu.sh` of `.cache/initramfs_root/etc/rc.sh` of update：
     ```sh
     #!/bin/sh
     echo "[TINUX_SH] Testing /proc pseudo-filesystem..."
     /bin/cat /proc/version
     /bin/cat /proc/meminfo
     echo "[TINUX_SH] Executing shell pipeline: cat /etc/motd | grep Tinux"
     /bin/cat /etc/motd | /bin/grep Tinux
     echo "[TINUX_PIPE] Shell pipeline (pipe2 + dup2 + fork + execve + wait4) verified!"
     exit 0
     ```
 * `.cache/initramfs_root/bin/` `grep` of （ or ） add（
 * `src/main.zig` of `kmain()` with `vfs.init()`, `pipe.init()`, `cpio.mountInitramfs(...)`, `procfs.initAndRegister(
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-008 5
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-008
[TINUX_INIT] Spawning PID 1 (/bin/sh /etc/rc.sh)...
[TINUX_SH] Testing /proc pseudo-filesystem...
Linux version 6.12.0-tinux (zig@tinux) #1 SMP PREEMPT_DYNAMIC
MemTotal:         131072 kB
[TINUX_SH] Executing shell pipeline: cat /etc/motd | grep Tinux
[TINUX_VFS] Welcome to Tinux! Unmodified Linux BusyBox is alive via CPIO Initramfs!

[TINUX_PIPE] Shell pipeline (pipe2 + dup2 + fork + execve + wait4) verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-008
[HARNESS] SUCCESS: TASK-008 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-008 5` when、 Builder fixloop stop、 `ESCALATIO
```markdown
# Escalation Report: TASK-008
## 1. Failure Summary
* **Failed Stage:** [zig build / /proc Lookup Error / Pipe Read Deadlock (writers > 0) / dup2 Stdout Loss / wait4 Mu
* **Pipe & Task State Dump at Failure:** [ Task of state and 、 Pipe of readers / writers / count of value ]
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
[Relevant code diff for src/fs/pipe.zig, src/fs/vfs.zig, src/proc/task.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
