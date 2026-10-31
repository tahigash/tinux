# Tinux Implementation Specification: TASK-010
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-009` Passed (`./scripts/verify_qemu.sh TASK-009 5` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition 8259A PIC of vector（ `0x20..0x2F` ）、 PIT 100Hz 、 `LinuxTimespec` struct、 `/proc/[pid]/s
2. **Interrupt Safety Discipline （interrupt of strictly adhere） :**
 kernel space（ `syscallEntry` execute） with `IA32_FMASK` `RFLAGS.IF = 0` （interrupt⽌） and 。 with 
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-010 5` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.

---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| of | of ⾮ to of IRQ | `@atomicLoad(u64, &ticks,.seq_cst)` / `@atomicRmw` |
| ⽂column⽣ | heap `allocPrint` | `std.fmt.bufPrint(&buf, fmt, args) catch unreachable` |
| | `@intCast(i32, val)` | `@as(i32, @intCast(val))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-010`
* **Title:** `Hardware Timer Interrupts (8259A PIC & 8254 PIT), Time Management (clock_gettime / nanosleep), Dynamic
* **Target Subsystem:** `drivers`, `arch/x86_64`, `proc`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/drivers/timer.zig` (Create: 8259A PIC remap, 8254 PIT 100Hz init, tick counter & EOI)
  * `src/arch/x86_64/isr.S` (Modify: add `ISR_NOERR 32` for IRQ0 timer interrupt and extend `isr_stub_table` to 33 e
  * `src/arch/x86_64/idt.zig` (Modify: register vector 32 and call `timer.onTick()` in `isrDispatch`)
  * `src/proc/task.zig` (Modify: add `WAITING_SLEEP`, `comm_buf`, `wake_tick`, `term_sig`, `wakeSleepingTasks`, and 
  * `src/fs/procfs.zig` (Modify: dynamically generate `/proc/uptime`, `/proc/stat`, `/proc/[pid]/stat`, `/proc/[pid]
  * `src/fs/vfs.zig` (Modify: add `unregisterNode` and trigger `procfs.syncProcessNodes()` on `/proc` access)
  * `src/syscall/dispatch.zig` (Modify: implement `nanosleep`/`clock_nanosleep`, `clock_gettime`/`gettimeofday`, `ki
  * `src/main.zig` (Modify: initialize `timer.init()` and update test markers to `TASK-010`)
  * `scripts/verify_qemu.sh` (Modify: update `/etc/rc.sh` to verify `sleep`, background `&`, `ps`, and `kill`)
---
## 3. Hardware Timer, `/proc/[pid]` & Signal ABI Contract (Opus 5.5 Audited)
### 3.1 8259A PIC & 8254 PIT Hardware Contract
x86 PC with 、 BIOS state of Master PIC (`IRQ 0..7`) CPU exceptionvector `0x08..0x0F` （ Double Fault `#DF` ） and 
| Device | I/O port | ⼿‧protocol |
| :--- | :--- | :--- |
| **8259A Master/Slave PIC** | Master: `0x20` (Cmd), `0x21` (Data)<br>Slave: `0xA0` (Cmd), `0xA1` (Data) | 1. ICW1 (
| **8254 PIT (Timer)** | Ch0 Data: `0x40`<br>Command: `0x43` | lock `1,193,182 Hz` `100 Hz` （ 1 tick = `10
### 3.2 BusyBox `ps` & `/proc/[pid]/stat` Format Contract
BusyBox of `ps` （ `libbb/procps.c` of `procps_scan` ） of ⼿ with process⼀ ：
1. `/proc` `openat` + `getdents64` with ⾛、 of of （ `"1"`, `"2"`,... ） ⾒。
2. PID `/proc/[pid]/stat` 。
 * ** （ 24 mandatory） :**
     ```text
     {pid} ({comm}) {state} {ppid} {pgrp} 1 0 1 0 0 0 0 0 1 1 0 0 20 0 1 0 1 409600 100
     ```
 * `pid`: process ID (`t.pid`)
 * `({comm})`: execute（ with 、e.g.： `(sh)`, `(sleep)`, `(ps)` ）
     * `{state}`: `'R'` (`.RUNNING` / `.READY`), `'S'` (`.WAITING` / `.WAITING_PIPE` / `.WAITING_SLEEP`), `'Z'` (`.Z
 * `{ppid}`: parentprocess ID (`t.parent_pid`)
 * `{pgrp}`: processloop ID (`t.pid`)
 * 23 `vsize`: `409600` (400 KiB displayed⽤)
 * 24 `rss`: `100` (100 pages RSS displayed⽤)
3. `/proc/[pid]/cmdline` （ `comm` + `\x00` ） and `/proc/[pid]/status` ⽣。
### 3.3 Time, Sleep, Signal & Non-Blocking `wait4` Contract
| Syscall Name | Num | Arguments | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_nanosleep`** | `35` | `req_ptr, rem_ptr` | `req` (`LinuxTimespec`: `tv_sec: i64, tv_nsec: i64`) 、
| **`sys_clock_nanosleep`** | `230` | `clk_id, flags, req_ptr, rem_ptr` | `sysNanosleep(req_ptr, rem_ptr)` and 
| **`sys_clock_gettime`** | `228` | `clk_id, tp_ptr` | `ticks = timer.getTicks()` from `tv_sec = ticks / 100` 、 `tv_ns
| **`sys_gettimeofday`** | `96` | `tv_ptr, tz_ptr` | `tv_ptr != 0` `tv_sec = ticks / 100`, `tv_usec = (ticks % 1
| **`sys_kill`** | `62` | `pid_arg, sig` | task `t` (`t.pid == pid`) （ `-ESRCH (-3)` ）。 `sig == 0` 
| **`sys_wait4` (`WNOHANG`)** | `61` | `pid, wstatus_ptr, options, rusage` | ** 【important】 ** state of ⼦times
---
## 4. Exact Data Structures & Signatures

### 4.1 `src/drivers/timer.zig`
```zig
const io = @import("../arch/x86_64/io.zig");
pub const PIT_FREQ_HZ: u64 = 100; // 10ms per tick
const PIT_BASE_HZ: u32 = 1193182;
const PIT_DIVISOR: u16 = @intCast(PIT_BASE_HZ / PIT_FREQ_HZ);
const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;
const PIT_CH0_DATA: u16 = 0x40;
const PIT_CMD: u16 = 0x43;
var ticks: u64 = 0;
pub fn init() void {
    // 1. Remap 8259A PIC to vectors 0x20..0x2F (32..47)
    io.outb(PIC1_CMD, 0x11);
    io.outb(PIC2_CMD, 0x11);
    io.outb(PIC1_DATA, 0x20); // Master offset 32
    io.outb(PIC2_DATA, 0x28); // Slave offset 40
    io.outb(PIC1_DATA, 0x04);
    io.outb(PIC2_DATA, 0x02);
    io.outb(PIC1_DATA, 0x01);
    io.outb(PIC2_DATA, 0x01);
    // Mask all IRQs except IRQ0 (Timer) on Master PIC
    io.outb(PIC1_DATA, 0xFE);
    io.outb(PIC2_DATA, 0xFF);
    // 2. Configure 8254 PIT Channel 0 for 100 Hz square wave
    io.outb(PIT_CMD, 0x36);
    io.outb(PIT_CH0_DATA, @truncate(PIT_DIVISOR & 0xFF));
    io.outb(PIT_CH0_DATA, @truncate((PIT_DIVISOR >> 8) & 0xFF));
}
pub fn onTick() void {
    _ = @atomicRmw(u64, &ticks, .Add, 1, .seq_cst);
    io.outb(PIC1_CMD, 0x20); // Send EOI to Master PIC
}
pub fn getTicks() u64 {
    return @atomicLoad(u64, &ticks, .seq_cst);
}
pub fn waitForNextTick() void {
    const start = getTicks();
    while (getTicks() == start) {
        asm volatile ("sti; hlt; cli" ::: "memory");
    }
}
```
### 4.2 `src/arch/x86_64/isr.S` & `src/arch/x86_64/idt.zig` Updates
1. **`src/arch/x86_64/isr.S`:**
 `ISR_NOERR 31` of `ISR_NOERR 32` add、 `isr_stub_table` of `.quad isr32` add（ 33 ）。
2. **`src/arch/x86_64/idt.zig`:**
 * `extern const isr_stub_table: [33]usize;` 、 `init()` with vector `32` `setGate(32, isr_stub_table[32], 
 * `isrDispatch(frame: *TrapFrame)` of first add：
     ```zig
     if (frame.vector == 32) {
         timer.onTick();
         return;
     }
     ```
### 4.3 `src/proc/task.zig` Additions
`TaskState` `WAITING_SLEEP = 6` add、 `Task` struct of add：
```zig
    comm_buf: [16]u8 = [_]u8{'s', 'h'} ++ [_]u8{0} ** 14,
    comm_len: usize = 2,
    wake_tick: u64 = 0,
    term_sig: usize = 0,

    pub fn setComm(self: *Task, raw_path: []const u8) void {
        // Extract basename after last '/'
        var base = raw_path;
        if (std.mem.lastIndexOfScalar(u8, raw_path, '/')) |idx| {
            if (idx + 1 < raw_path.len) base = raw_path[idx + 1 ..];
        }
        const n = @min(base.len, 15);
        @memset(&self.comm_buf, 0);
        @memcpy(self.comm_buf[0..n], base[0..n]);
        self.comm_len = n;
    }
    pub fn comm(self: *const Task) []const u8 {
        return self.comm_buf[0..self.comm_len];
    }
```
、woken and waiting function `src/proc/task.zig` implement：
```zig
pub fn wakeSleepingTasks(now_ticks: u64) void {
    for (&tasks) |*t| {
        if (t.state == .WAITING_SLEEP and now_ticks >= t.wake_tick) {
            t.state = .READY;
        }
    }
}
/// Finds next .READY or .RUNNING task. If none is immediately runnable because
/// tasks are in .WAITING_SLEEP, waits for hardware timer ticks until one wakes up.
pub fn scheduleNextOrWait() usize {
    while (true) {
        wakeSleepingTasks(timer.getTicks());
        // Prefer another .READY task first
        for (0..MAX_TASKS) |offset| {
            const idx = (current_task_idx + 1 + offset) % MAX_TASKS;
            if (tasks[idx].state == .READY or tasks[idx].state == .RUNNING) {
                return idx;
            }
        }
        // Check if any task is sleeping on timer
        var any_sleeping = false;
        for (&tasks) |*t| {
            if (t.state == .WAITING_SLEEP) {
                any_sleeping = true;
                break;
            }
        }
        if (any_sleeping) {
            timer.waitForNextTick();
            continue;
        }
        @panic("TINUX_SCHED: No runnable or sleeping tasks remaining!");
    }
}
```
### 4.4 `src/fs/procfs.zig` Dynamic `/proc/[pid]` Generator
```zig
pub const MAX_TASKS = task.MAX_TASKS;
var stat_bufs: [MAX_TASKS][160]u8 = undefined;
var status_bufs: [MAX_TASKS][192]u8 = undefined;
var cmdline_bufs: [MAX_TASKS][32]u8 = undefined;
var uptime_buf: [64]u8 = undefined;
var global_stat_buf: [128]u8 = undefined;
pub fn syncProcessNodes() void {
    // Builder updates /proc/uptime, /proc/stat, and per-task /proc/[pid]/{stat,status,cmdline}
    // and unregisters stale /proc/[pid]* nodes for .UNUSED task slots
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/vfs.zig` and `src/fs/procfs.zig` of processsynchronizationimplement **
 * `vfs.zig` `pub fn unregisterPrefix(prefix: []const u8) void` add、 `node.in_use` `std.mem.eql(u8, nod

 * `procfs.syncProcessNodes()` Implementation：
     1. `const tks = timer.getTicks();`
     2. `const sec = tks / 100; const centi = tks % 100;`
     3. `uptime_slice = std.fmt.bufPrint(&uptime_buf, "{d}.{d:0>2} {d}.{d:0>2}\n", .{ sec, centi, sec, centi }) catc
 4. `"proc/stat"` `"cpu 10 0 10 {d} 0 0 0 0 0 0\ncpu0 10 0 10 {d} 0 0 0 0 0 0\n"` 。
 5. `0..task.MAX_TASKS` of `i` ⾛：
        * `const t = &task.tasks[i];`
 * `t.state !=.UNUSED` with ：
          * `const st_char: u8 = switch (t.state) { .RUNNING, .READY => 'R', .ZOMBIE => 'Z', else => 'S' };`
 * `"proc/{d}"` (`S_IFDIR | 0o555`) and 。
          * `stat_slice = std.fmt.bufPrint(&stat_bufs[i], "{d} ({s}) {c} {d} {d} 1 0 1 0 0 0 0 0 1 1 0 0 20 0 1 0 1 
          * `status_slice = std.fmt.bufPrint(&status_bufs[i], "Name:\t{s}\nState:\t{c}\nPid:\t{d}\nPPid:\t{d}\nUid:\
 * `cmdline_slice` （ `t.comm()` + `\x00` ） `"proc/{d}/cmdline"` and 。
 * 、taskexit `.UNUSED` times（ `sys_wait4` with of times）、 `vfs.unregisterPrefix("proc/{d}")` with 
 * `vfs.open` and `vfs.lookup` with `"proc"` with when（ or `"proc/self"` of PID with ）、
 * `vfs.lookup` of BusyBox `"bin/ps"`, `"ps"`, `"bin/sleep"`, `"sleep"`, `"bin/kill"`,
2. **Step 2: `src/syscall/dispatch.zig` of ‧‧signal‧ `WNOHANG` implement **
 * `sysExecve` with process 、 `cur.setComm(if (argv_slices.len >= 2 and std.mem.endsWith(u8
   * **`sysNanosleep(frame: *SyscallFrame, req_ptr: usize) *SyscallFrame` (35 & 230):**
     1. `if (!validateUserBuffer(req_ptr, 16)) { frame.rax = @bitCast(errno_mod.toReturn(.EFAULT)); return frame; }`
     2. `const sec = std.mem.readInt(i64, @as(*const [8]u8, @ptrFromInt(req_ptr)), .little);`
     3. `const nsec = std.mem.readInt(i64, @as(*const [8]u8, @ptrFromInt(req_ptr + 8)), .little);`
     4. `if (sec < 0 or nsec < 0) { frame.rax = @bitCast(errno_mod.toReturn(.EINVAL)); return frame; }`
     5. `const total_ms: u64 = @as(u64, @intCast(sec)) * 1000 + (@as(u64, @intCast(nsec)) + 999_999) / 1_000_000;`
     6. `const wait_ticks: u64 = @max((total_ms + 9) / 10, 1);`
     7. `const cur = task.currentTask();`
 8. `frame.rax = 0;` （woken of return value `0` ）。
     9. `cur.saved_frame = frame;`
     10. `cur.wake_tick = timer.getTicks() + wait_ticks;`
     11. `cur.state = .WAITING_SLEEP;`
     12. `const next_idx = task.scheduleNextOrWait();`
     13. `task.activateTask(next_idx);`
     14. `return task.currentTask().saved_frame;`
   * **`sysKill(frame: *SyscallFrame, pid_arg: isize, sig: usize) *SyscallFrame` (62, 200, 234):**
     1. `if (pid_arg <= 0) { frame.rax = 0; return frame; }`
     2. `const target_pid: usize = @intCast(pid_arg);`
 3. `tasks` from `t.state !=.UNUSED and t.pid == target_pid` （⾒ from `-ESRCH` ）。
     4. `if (sig == 0) { frame.rax = 0; return frame; }`
     5. `if ((sig == 9 or sig == 15 or sig == 2) and target_pid > 1)`:
        * `task.closeAllFds(target);`
        * `target.state = .ZOMBIE;`
        * `target.term_sig = sig;`
 * parenttask `.WAITING` with 、parent of `wait_wstatus_ptr` `@intCast(sig & 0x7F)` write、 times
     6. `frame.rax = 0; return frame;`
 * **`sysWait4` of `WNOHANG` :**
 * ⼦processexists `.ZOMBIE` with when：
 * `if ((options & 1) != 0) { frame.rax = 0; return frame; }` (`WNOHANG` block `0`) 。
 * blockwhen `cur.state =.WAITING` 、 `task.scheduleNextOrWait()` with of executetask（ or 
3. **Step 3: `scripts/verify_qemu.sh` and `src/main.zig` of update **
 * `scripts/verify_qemu.sh` of `.cache/initramfs_root/etc/rc.sh` of update：
     ```sh
     #!/bin/sh
     echo "[TINUX_SH] Testing hardware timer (PIT 100Hz) and nanosleep..."
     /bin/sleep 1
     echo "[TINUX_TIMER] Uptime after 1s sleep:"
     /bin/cat /proc/uptime
     echo "[TINUX_SH] Spawning background job: /bin/sleep 5 &"
     /bin/sleep 5 &
     BG_PID=$!
     echo "[TINUX_PS] Process table while background job is sleeping:"
     /bin/ps
     echo "[TINUX_KILL] Sending SIGKILL to background process..."
     kill -9 $BG_PID
     wait $BG_PID 2>/dev/null
     echo "[TINUX_PROC] Hardware timer, nanosleep, /proc/[pid]/stat (ps), and kill verified!"
     exit 0
     ```
 * `.cache/initramfs_root/bin/` `ps`, `sleep`, `kill` of （ or ） add（
 * `src/main.zig` of `kmain()` with `idt.init()` of `timer.init()` 、start `[TINUX_TEST] START: T
---

## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-010 10
```
### 6.2 Expected Output (Pass Criteria)
QEMU output of （ `ps` `sh` and `sleep` of processdisplayed ）output、 `verify_qemu.sh` Exit Code 
```text
[TINUX_TEST] START: TASK-010
[TINUX_INIT] Spawning PID 1 (/bin/sh /etc/rc.sh)...
[TINUX_SH] Testing hardware timer (PIT 100Hz) and nanosleep...
[TINUX_TIMER] Uptime after 1s sleep:
1.00 1.00
[TINUX_SH] Spawning background job: /bin/sleep 5 &
[TINUX_PS] Process table while background job is sleeping:
  PID USER       VSZ STAT COMMAND
    1 0          400 R    /bin/sh /etc/rc.sh
    3 0          400 S    /bin/sleep 5
    4 0          400 R    /bin/ps
[TINUX_KILL] Sending SIGKILL to background process...
[TINUX_PROC] Hardware timer, nanosleep, /proc/[pid]/stat (ps), and kill verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-010
[HARNESS] SUCCESS: TASK-010 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-010 10` when、 Builder fixloop stop、 `ESCALATI
```markdown
# Escalation Report: TASK-010
## 1. Failure Summary
* **Failed Stage:** [zig build / PIC Remap Double Fault / PIT IRQ0 Not Firing (Hang in waitForNextTick) / Background
* **Timer Ticks & Active Tasks Dump:** [timer.getTicks() of value and 、 Task of pid, state, comm, wake_tick of ⼀ ]
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
[Relevant code diff for src/drivers/timer.zig, src/proc/task.zig, src/fs/procfs.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
