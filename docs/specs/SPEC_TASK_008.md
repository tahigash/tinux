# Tinux Implementation Specification: TASK-008
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** AI System Architect
> * **Auditor (Low-Level & ABI Contract):** AI Code Auditor
> * **Target Builder:** Autonomous AI Builder Agent
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter the `Pipe` struct, `FdEntry` / `FdKind` enum definitions, pipe reference counting rules, or `/proc` virtual file generation contracts.
2. **Strict Pipe Reference Counting:**
   When executing pipelines like `cmd1 | cmd2`, `cmd2` (e.g. `grep`) receives EOF (`read == 0`) only when all write ends across parent and child processes are closed via `fork`, `dup`, and `close`.
3. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet".
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-008 5` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Bitwise enum cast | `@intCast(u32, @enumToInt(kind))` | `@as(u32, @intFromEnum(kind))` |
| Buffer copy | Manual loop | `@memcpy(dst, src)` |
| Buffer fill | Manual loop | `@memset(slice, 0)` |
| Truncate integer | `@truncate(u32, val)` | `@as(u32, @truncate(val))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-008`
* **Title:** `IPC Pipes (sys_pipe / sys_pipe2), Standard I/O Redirection (sys_dup2 / O_CLOEXEC), /proc Pseudo-Filesystem (/proc/version, /proc/meminfo), and Shell Pipeline`
* **Target Subsystem:** `fs`, `proc`, `syscall`
* **Target Files to Create / Modify:**
  * `src/fs/pipe.zig` (Create: pipe ring buffer, reader/writer reference counting, block on read)
  * `src/fs/procfs.zig` (Create: pseudo-filesystem generator for `/proc/version` and `/proc/meminfo`)
  * `src/fs/vfs.zig` (Modify: integrate `FdKind` into file descriptor table, support `pipe` and `proc` nodes)
  * `src/proc/task.zig` (Modify: add `WAITING_PIPE` task state, wake pipe waiters on write/close)
  * `src/syscall/dispatch.zig` (Modify: implement `pipe`/`pipe2`, `dup`/`dup2`/`dup3`, close-on-exec)
  * `src/main.zig` (Modify: register procfs, launch pipeline test in the in-tree Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`))
  * `scripts/verify_qemu.sh` (Modify: add `/etc/rc.sh` pipeline test and ensure `/bin/grep` utility exists)
---
## 3. IPC & Pseudo-Filesystem Contract (AI Audited)
### 3.1 File Descriptor Kind (`FdKind`) Architecture
Extend the file descriptor table so that descriptors dispatch to appropriate subsystem handlers:
| Descriptor Kind | Read Behavior (`sys_read`) | Write Behavior (`sys_write`) | Close Behavior (`sys_close`) |
| :--- | :--- | :--- | :--- |
| **`.CONSOLE_IN`** | Reads from UART buffer; returns EOF or bytes read. | Returns `-EBADF`. | Retains slot. |
| **`.CONSOLE_OUT`** | Returns `-EBADF`. | Writes to COM1 serial console. | Retains slot. |
| **`.VFS_FILE`** | Reads from `VfsNode` payload and advances offset. | Writes to writable node or returns `-EBADF`. | Clears descriptor entry. |
| **`.PIPE_READ`** | Calls `pipe.read()`; blocks task if buffer empty and `writers > 0`. | Returns `-EBADF`. | Calls `pipe.closeRead()`. |
| **`.PIPE_WRITE`** | Returns `-EBADF`. | Calls `pipe.write()`; returns `-EPIPE` if `readers == 0`. | Calls `pipe.closeWrite()`. |
### 3.2 Pipe Lifecycle & Reference Counting Contract
When executing `cat /etc/motd | grep Tinux`, pipe file descriptors are duplicated across processes:
1. **`pipe.allocPipe(cloexec)`:**
   Allocates an unused `Pipe`, initializing `readers = 1`, `writers = 1`, `read_pos = 0`, `write_pos = 0`, `count = 0`.
2. **`task.forkCurrentTask`:**
   Copies parent descriptors to child. For each `.PIPE_READ`, calls `pipe.retainRead()` (`readers += 1`). For each `.PIPE_WRITE`, calls `pipe.retainWrite()` (`writers += 1`).
3. **`sys_dup2(oldfd, newfd)`:**
   If `oldfd == newfd`, returns `newfd` immediately. If `newfd` is open, closes it first. Copies descriptor entry to `newfd` and increments reference count. Clears `cloexec` flag on duplicated descriptor per POSIX rules.
4. **`closeCloexecFds` on `sys_execve`:**
   Closes all descriptors where `cloexec == true`.
5. **`closeAllFds` on `sys_exit`:**
   Closes all open descriptors for the exiting task, decrementing pipe reader/writer counts and waking pending waiters.
### 3.3 Cooperative Blocking on Pipe Read (`WAITING_PIPE`)
When a child reader (`grep`) reads from an empty pipe while writers exist:
1. If `pipe.read` returns `would_block`:
   * Rewinds user RIP: `frame.user_rip -= 2` (points back to `syscall` instruction `0F 05`).
   * Sets `frame.rax = 0` (sys_read syscall number).
   * Sets `cur.state = .WAITING_PIPE` and `cur.wait_pipe_idx = pipe_idx`.
   * Calls `task.findNextRunnable()` and context-switches to the writer process.
2. When writer writes data or closes the last write descriptor:
   * Calls `task.wakePipeWaiters(pipe_idx)`.
   * Changes matching tasks from `.WAITING_PIPE` to `.READY`.
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

pub fn allocPipe() ?usize {
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
    if (idx < MAX_PIPES and pipes[idx].in_use) pipes[idx].readers += 1;
}

pub fn retainWrite(idx: usize) void {
    if (idx < MAX_PIPES and pipes[idx].in_use) pipes[idx].writers += 1;
}

pub fn closeRead(idx: usize) bool {
    if (idx >= MAX_PIPES or !pipes[idx].in_use) return false;
    if (pipes[idx].readers > 0) pipes[idx].readers -= 1;
    if (pipes[idx].readers == 0 and pipes[idx].writers == 0) pipes[idx].in_use = false;
    return true;
}

pub fn closeWrite(idx: usize) bool {
    if (idx >= MAX_PIPES or !pipes[idx].in_use) return false;
    if (pipes[idx].writers > 0) pipes[idx].writers -= 1;
    const last_writer = (pipes[idx].writers == 0);
    if (pipes[idx].readers == 0 and pipes[idx].writers == 0) pipes[idx].in_use = false;
    return last_writer;
}

pub fn read(idx: usize, dst: []u8) PipeReadResult {
    if (idx >= MAX_PIPES or !pipes[idx].in_use) return .eof;
    var p = &pipes[idx];
    if (p.count == 0) {
        if (p.writers == 0) return .eof;
        return .would_block;
    }
    const to_read = @min(dst.len, p.count);
    var i: usize = 0;
    while (i < to_read) : (i += 1) {
        dst[i] = p.buf[p.read_pos];
        p.read_pos = (p.read_pos + 1) % PIPE_BUF_SIZE;
    }
    p.count -= to_read;
    return .{ .bytes = to_read };
}

pub fn write(idx: usize, src: []const u8) ?usize {
    if (idx >= MAX_PIPES or !pipes[idx].in_use) return null;
    var p = &pipes[idx];
    if (p.readers == 0) return null; // EPIPE
    const avail = PIPE_BUF_SIZE - p.count;
    if (avail == 0) return 0;
    const to_write = @min(src.len, avail);
    var i: usize = 0;
    while (i < to_write) : (i += 1) {
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
const vfs = @import("vfs.zig");

var version_buf: [128]u8 = [_]u8{0} ** 128;
var meminfo_buf: [256]u8 = [_]u8{0} ** 256;

pub fn initAndRegister() void {
    const ver = "Linux version 6.6.0-tinux (zig@tinux) #1 SMP PREEMPT Tinux 2026\n";
    @memcpy(version_buf[0..ver.len], ver);
    _ = vfs.registerNode("proc/version", vfs.S_IFREG | 0o444, version_buf[0..ver.len]);

    const mem = "MemTotal:         131072 kB\nMemFree:          120000 kB\nMemAvailable:     120000 kB\n";
    @memcpy(meminfo_buf[0..mem.len], mem);
    _ = vfs.registerNode("proc/meminfo", vfs.S_IFREG | 0o444, meminfo_buf[0..mem.len]);
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/pipe.zig` and `src/fs/procfs.zig` Implementation**
   * Implement pipe ring buffer functions with reader/writer reference counters.
   * In `procfs.initAndRegister()`, register `"proc/version"` and `"proc/meminfo"` with accurate diagnostic strings.
2. **Step 2: `src/proc/task.zig` Updates for Blocking Pipe Readers**
   * Add `WAITING_PIPE = 5` to `TaskState`.
   * Add `wait_pipe_idx: usize = 0` to `Task` struct.
   * Implement `wakePipeWaiters(pipe_idx: usize)`: search `tasks` and change tasks with `state == .WAITING_PIPE and wait_pipe_idx == pipe_idx` to `.READY`.
   * Implement `closeCloexecFds(t: *Task)` and `closeAllFds(t: *Task)`.
3. **Step 3: `src/syscall/dispatch.zig` System Calls**
   * In `sysPipe2(pipefd_ptr, flags)`:
     * Allocate pipe with `pipe.allocPipe()`.
     * Allocate two file descriptors in current task table: read end (`.PIPE_READ`) and write end (`.PIPE_WRITE`).
     * Set `cloexec = ((flags & 0o2000000) != 0)`.
     * Write descriptors into user pointer `pipefd_ptr[0..2]`.
   * In `sysDup2(oldfd, newfd)`:
     * Check bounds and validity. If `oldfd == newfd`, return `newfd`.
     * Close existing `newfd` if open.
     * Duplicate descriptor entry, increment reader/writer reference counts, clear `cloexec` flag, and return `newfd`.
4. **Step 4: Script & Harness Integration in `verify_qemu.sh`**
   * In `scripts/verify_qemu.sh`, provision `/etc/rc.sh` using the in-tree Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`) to test pipeline execution:
     ```sh
     #!/bin/sh
     echo "[TINUX_SH] Testing shell pipeline (cat /etc/motd | grep Tinux)..."
     /bin/cat /etc/motd | /bin/grep Tinux
     echo "[TINUX_SH] Inspecting /proc/version and /proc/meminfo:"
     /bin/cat /proc/version
     /bin/cat /proc/meminfo
     echo "[TINUX_PIPE] Multi-process pipe2, dup2 redirection, and /proc verified!"
     exit 0
     ```
   * In `src/main.zig`, ensure `vfs.init()`, `pipe_mod.init()`, and `procfs.initAndRegister()` are called before user space execution.
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
[TINUX_SH] Testing shell pipeline (cat /etc/motd | grep Tinux)...
Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!
[TINUX_SH] Inspecting /proc/version and /proc/meminfo:
Linux version 6.6.0-tinux (zig@tinux) #1 SMP PREEMPT Tinux 2026
MemTotal:         131072 kB
[TINUX_PIPE] Multi-process pipe2, dup2 redirection, and /proc verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-008
[HARNESS] SUCCESS: TASK-008 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-008 5` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-008
## 1. Failure Summary
* **Failed Stage:** [zig build / /proc Lookup Error / Pipe Read Deadlock (writers > 0) / dup2 Stdout Loss / wait4 Multiprocess Hang]
* **Pipe & Task State Dump at Failure:** [Task states and Pipe readers/writers/count values]
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
[Relevant code diff for src/fs/pipe.zig, src/fs/vfs.zig, src/proc/task.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For AI Architect / Auditor Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
