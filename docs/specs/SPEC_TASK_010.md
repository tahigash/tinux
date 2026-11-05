# Tinux Implementation Specification: TASK-010
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** AI System Architect
> * **Auditor (Low-Level & ABI Contract):** AI Code Auditor
> * **Target Builder:** Autonomous AI Builder Agent
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter 8259A PIC remapped vectors (`0x20..0x2F`), 8254 PIT 100Hz frequency divisors, `LinuxTimespec` layouts, or `/proc/[pid]/stat` field positions.
2. **Interrupt Safety Discipline:**
   When executing kernel syscall routines (`syscallEntry`), `IA32_FMASK` clears `RFLAGS.IF` to prevent nested interrupts. Re-enable interrupts only when explicitly returning to user space or halting in the idle loop.
3. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet".
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-010 10` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Atomic tick access | Non-atomic memory read | `@atomicLoad(u64, &ticks, .seq_cst)` |
| String formatting | Heap `allocPrint` | `std.fmt.bufPrint(&buf, fmt, args) catch unreachable` |
| Truncate integer | `@truncate(u32, val)` | `@as(u32, @truncate(val))` |
| Array fill | Manual loop | `@memset(slice, 0)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-010`
* **Title:** `Hardware Timer Interrupts (8259A PIC & 8254 PIT), Time Management (clock_gettime / nanosleep), Dynamic /proc/[pid]/stat Pseudo-FS, and Process Control (sys_kill / ps)`
* **Target Subsystem:** `drivers`, `arch/x86_64`, `proc`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/drivers/timer.zig` (Create: 8259A PIC initialization, 8254 PIT channel 0 at 100 Hz, tick counter)
  * `src/arch/x86_64/isr.S` (Modify: add IRQ0 interrupt handler vector 32)
  * `src/arch/x86_64/idt.zig` (Modify: configure IDT gate 32 for timer ticks)
  * `src/proc/task.zig` (Modify: add `WAITING_SLEEP` state, `wake_tick` tracking, `tickSleepWaiters`)
  * `src/fs/procfs.zig` (Modify: dynamically generate `/proc/[pid]/stat`, `/proc/[pid]/cmdline`, `/proc/uptime`)
  * `src/syscall/dispatch.zig` (Modify: implement `nanosleep`, `clock_gettime`, `gettimeofday`, `kill`, `WNOHANG` in `wait4`)
  * `src/main.zig` (Modify: initialize timer and launch multi-process test)
  * `scripts/verify_qemu.sh` (Modify: test background jobs, ps, kill, and uptime using the in-tree Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`))
---
## 3. Hardware Timer & Process Scanning Contract (AI Audited)
### 3.1 8259A PIC & 8254 PIT Register Interface
On x86 PCs, legacy BIOS configurations place Master PIC IRQs (`0..7`) on vectors `0x08..0x0F`, colliding with CPU exceptions (#DF, #GP). They must be remapped to `0x20..0x2F`:
| Device | I/O Ports | Configuration Protocol |
| :--- | :--- | :--- |
| **8259A PIC (Master/Slave)** | Master: `0x20` (Cmd), `0x21` (Data)<br>Slave: `0xA0` (Cmd), `0xA1` (Data) | ICW1 (`0x11`), ICW2 (Master vector `0x20`, Slave vector `0x28`), ICW3 (`0x04` / `0x02`), ICW4 (`0x01`). Masks: unmask IRQ0 on Master (`0xFE`), mask all on Slave (`0xFF`). |
| **8254 PIT (Timer Channel 0)** | Data: `0x40`, Cmd: `0x43` | Square wave mode 3 (`0x36`). Base clock `1,193,182 Hz / 100 Hz = 11931` (`0x2E9B`). Emits 100 interrupts per second (1 tick = 10 ms). |
### 3.2 `/proc/[pid]/stat` Format Contract
Userland process viewers (such as `ps`) scan `/proc` to enumerate active processes:
1. Opens `/proc`, traverses entries via `getdents64`, identifying numerical directories (`"1"`, `"2"`, etc.).
2. Reads `/proc/[pid]/stat` containing 24 space-separated tokens:
   ```text
   {pid} ({comm}) {state} {ppid} {pgrp} 1 0 1 0 0 0 0 0 1 1 0 0 20 0 1 0 1 409600 100
   ```
   * Token 1: Process ID (`t.pid`)
   * Token 2: Executable name in parentheses (e.g. `(sh)`, `(sleep)`, `(ps)`)
   * Token 3: Single-character state: `'R'` (`.RUNNING` / `.READY`), `'S'` (`.WAITING` / `.WAITING_PIPE` / `.WAITING_SLEEP`), `'Z'` (`.ZOMBIE`)
   * Token 4: Parent PID (`t.parent_pid`)
   * Token 5: Process group ID (`t.pid`)
   * Token 23: Virtual memory size (`409600`)
   * Token 24: Resident set size in pages (`100`)
3. Reads `/proc/[pid]/cmdline` (`comm` + `\0`) and `/proc/uptime` (`{uptime_sec}.{uptime_centisec} 0.00\n`).
### 3.3 Time, Sleep, Signal & Non-Blocking `wait4` Contract
| Syscall Name | Num | Arguments | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_nanosleep`** | `35` | `req_ptr, rem_ptr` | Reads requested `LinuxTimespec` (`tv_sec, tv_nsec`). Converts duration to ticks: `ticks = tv_sec * 100 + (tv_nsec + 9_999_999) / 10_000_000`. Sets task to `.WAITING_SLEEP` with `wake_tick = timer.getTicks() + ticks`, yields CPU, and returns 0 upon wake. |
| **`sys_clock_nanosleep`** | `230` | `clk_id, flags, req_ptr, rem_ptr` | Delegates to `sysNanosleep(req_ptr, rem_ptr)`. |
| **`sys_clock_gettime`** | `228` | `clk_id, tp_ptr` | Reads `timer.getTicks()`. Populates `LinuxTimespec` with `tv_sec = ticks / 100` and `tv_nsec = (ticks % 100) * 10_000_000`, returning 0. |
| **`sys_gettimeofday`** | `96` | `tv_ptr, tz_ptr` | Populates `timeval` with `tv_sec = ticks / 100` and `tv_usec = (ticks % 100) * 10_000`, returning 0. |
| **`sys_kill`** | `62` | `pid_arg, sig` | Locates target task by PID. If not found, returns `-ESRCH (-3)`. If `sig == 0`, checks existence and returns 0. If `sig == 9 (SIGKILL)` or `sig == 15 (SIGTERM)`, marks target `.ZOMBIE`, saves exit status, wakes parent, and returns 0. |
| **`sys_wait4` (`WNOHANG`)** | `61` | `pid, wstatus_ptr, options, rusage` | If `options & 1 != 0` (`WNOHANG`) and active children exist without zombies, returns 0 immediately without blocking. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/drivers/timer.zig`
```zig
const io = @import("../arch/x86_64/io.zig");

pub const PIT_FREQ_HZ: u64 = 100;
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
    io.outb(PIC1_CMD, 0x11);
    io.outb(PIC2_CMD, 0x11);
    io.outb(PIC1_DATA, 0x20); // Remap Master to 0x20 (32)
    io.outb(PIC2_DATA, 0x28); // Remap Slave to 0x28 (40)
    io.outb(PIC1_DATA, 0x04);
    io.outb(PIC2_DATA, 0x02);
    io.outb(PIC1_DATA, 0x01);
    io.outb(PIC2_DATA, 0x01);

    io.outb(PIC1_DATA, 0xFE); // Unmask IRQ0
    io.outb(PIC2_DATA, 0xFF); // Mask all Slave IRQs

    io.outb(PIT_CMD, 0x36); // Channel 0, lobyte/hibyte, rate generator
    io.outb(PIT_CH0_DATA, @truncate(PIT_DIVISOR));
    io.outb(PIT_CH0_DATA, @truncate(PIT_DIVISOR >> 8));
}

pub fn onTick() void {
    _ = @atomicRmw(u64, &ticks, .Add, 1, .seq_cst);
    io.outb(PIC1_CMD, 0x20); // EOI to Master PIC
}

pub fn getTicks() u64 {
    return @atomicLoad(u64, &ticks, .seq_cst);
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Timer Hardware Setup and IRQ0**
   * Remap 8259A PIC to interrupt vectors `0x20..0x2F`.
   * Configure 8254 PIT Channel 0 for 100 Hz.
   * Add vector 32 (`isr32`) to `isr_stub_table` and register it in `idt.zig` with `type_attr = 0x8E`.
   * In `isrDispatch`, when `frame.vector == 32`, call `timer.onTick()`, call `task.tickSleepWaiters()`, and send PIC EOI (`0x20`).
2. **Step 2: Task Sleep and Procfs Dynamic Generation**
   * Add `WAITING_SLEEP = 6` to `TaskState`.
   * In `tickSleepWaiters()`:
     * Compare current ticks with `task.wake_tick`.
     * Wake expired tasks from `.WAITING_SLEEP` to `.READY`.
   * In `procfs.syncProcessNodes()`:
     * Unregister old process entries under `"proc"`.
     * Iterate over active tasks in `task.tasks`.
     * Format 24-field stat string: `std.fmt.bufPrint(&buf, "{d} ({s}) {c} {d} {d} ...", .{...})`.
     * Register `"proc/{d}/stat"` and `"proc/{d}/cmdline"`.
     * Register `"proc/uptime"` with formatted `{sec}.{centisec} 0.00\n`.
3. **Step 3: Syscall Implementation in `dispatch.zig`**
   * In `sysNanosleep(req_ptr, rem_ptr)`:
     * Read requested `LinuxTimespec`. Convert seconds and nanoseconds to 100Hz ticks.
     * Put current task to sleep: `cur.state = .WAITING_SLEEP`, `cur.wake_tick = timer.getTicks() + duration_ticks`.
     * Context-switch to next runnable task.
   * In `sysClockGettime(clk_id, tp_ptr)`:
     * Populate `tv_sec = ticks / 100` and `tv_nsec = (ticks % 100) * 10_000_000`.
   * In `sysKill(pid, sig)`:
     * Find task matching PID. If not found, return `-ESRCH`.
     * If `sig == 9` or `sig == 15`, transition task to `.ZOMBIE`, store exit status, and wake parent.
   * In `sysWait4(pid, wstatus_ptr, options, rusage)`:
     * If `options & 1 != 0` (`WNOHANG`) and matching active child exists without zombies, return 0 immediately.
4. **Step 4: Harness Script and rc.sh Updates**
   * In `scripts/verify_qemu.sh`, provision `/etc/rc.sh` using the in-tree Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`) to test timer, background processes, ps, and kill:
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
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-010 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-010
[TINUX_INIT] Spawning PID 1 (/bin/sh /etc/rc.sh)...
[TINUX_SH] Testing hardware timer (PIT 100Hz) and nanosleep...
[TINUX_TIMER] Uptime after 1s sleep:
1.00 0.00
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
If `zig build` or `./scripts/verify_qemu.sh TASK-010 10` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-010
## 1. Failure Summary
* **Failed Stage:** [zig build / PIC Remap Double Fault / PIT IRQ0 Not Firing / Background Sleep Hang / ps /proc Parse Error / kill Signal Failure]
* **Timer Ticks & Active Tasks Dump:** [Current timer ticks and task list]
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
[Relevant code diff for src/drivers/timer.zig, src/proc/task.zig, src/fs/procfs.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For AI Architect / Auditor Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
