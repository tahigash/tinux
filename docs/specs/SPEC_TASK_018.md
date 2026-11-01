# Tinux Implementation Specification: TASK-018

> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-017` Passed (`./scripts/verify_qemu.sh TASK-017 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter the `KernelSigAction` struct (32 bytes), `SignalFrame` struct (160 bytes), signal numbers, or delivery trampoline byte sequences.
2. **Critical x86_64 Signal Handler Stack Alignment & Red Zone Rule:**
   Under the System V AMD64 ABI, user stack frames must preserve the 128-byte red zone beneath `%rsp` and satisfy `(rsp & 0xF) == 8` immediately before the handler's entry `push %rbp`.
3. **Strict Zig Version Idioms:**
   Adhere strictly to modern Zig idioms (0.13+) as defined in Section 1. Do not use deprecated functions like `@ptrToInt` or `@intToPtr`.
4. **Compile-Time ABI & Hardware Invariants:**
   Assert exact sizes at compile time for `KernelSigAction` (32 bytes), `SignalFrame` (160 bytes), and `LinuxItimerval` (32 bytes).
5. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-018 10` fails 3 consecutive times, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Count trailing zeros | Manual bit scanning | `@ctz(mask)` |
| Signal bit mask | `1 << (sig - 1)` | `@as(u64, 1) << @intCast(sig - 1)` |
| Unaligned 64-bit read | `@ptrCast(*u64, p).*` | `std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(p)), .little)` |
| Bit cast signed/unsigned | `@bitCast(isize, val)` | `@as(isize, @bitCast(val))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-018`
* **Title:** `User-Space Signal Delivery Mechanism (Signal Trampoline, rt_sigaction, rt_sigprocmask, rt_sigreturn, SIGALRM/SIGCHLD, and Signal Frame Stack Alignment)`
* **Target Subsystem:** `proc`, `drivers`, `syscall`, `user`
* **Target Files to Create / Modify:**
  * `src/proc/signal.zig` (Create: signal constants, `KernelSigAction`, `SignalFrame`, `sendSignalToTask`, and `deliverPendingSignals`)
  * `src/proc/task.zig` (Modify: add `WAITING_SIGNAL = 12`, per-task `sigactions`, `pending_signals`, `sig_mask`, `alarm_wake_tick`)
  * `src/drivers/timer.zig` (Modify: check `alarm_wake_tick` on each tick to queue `SIGALRM`)
  * `src/drivers/tty.zig` (Modify: send `SIGINT (2)` to foreground process group on `Ctrl+C` `0x03`)
  * `src/syscall/dispatch.zig` (Modify: implement `sys_rt_sigaction(13)`, `sys_rt_sigprocmask(14)`, `sys_rt_sigreturn(15)`, `sys_pause(34)`, `sys_alarm(37)`, `sys_setitimer(38)`)
  * `src/user/sig_test.zig` (Create: standalone Linux `x86_64` verification binary testing `rt_sigaction`, `rt_sigprocmask`, timers, and signal returns)
  * `src/main.zig` (Modify: update test markers to `TASK-018`)
  * `scripts/verify_qemu.sh` (Modify: compile `/bin/sig_test`, package into `initramfs.cpio`, and execute via interactive shell)
* **Read-Only Reference Files:**
  * `src/arch/x86_64/syscall_entry.S`
  * `src/arch/x86_64/syscall.zig`
  * `src/mm/vmm.zig`
---
## 3. Hardware, Protocol & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 Linux x86_64 `struct k_sigaction` & Signal Numbers Contract
The Linux x86_64 `sys_rt_sigaction(sig, act, oact, sigsetsize)` syscall requires `sigsetsize == 8` (64-bit signal mask):
| Field Name | Byte Offset | Size | Description & Flags |
| :--- | :--- | :--- | :--- |
| **`sa_handler`** | `0` | `8 B` (`usize`) | `0` = `SIG_DFL` (default), `1` = `SIG_IGN` (ignore), or Ring 3 function pointer. |
| **`sa_flags`** | `8` | `8 B` (`u64`) | `SA_RESTORER = 0x04000000`, `SA_SIGINFO = 0x00000004`, `SA_RESTART = 0x10000000`, `SA_NODEFER = 0x40000000`. |
| **`sa_restorer`** | `16` | `8 B` (`usize`) | User-space restorer trampoline address called upon signal return when `SA_RESTORER` is set. |
| **`sa_mask`** | `24` | `8 B` (`u64`) | Additional signals to block during handler execution (bit `sig - 1`). |
* **Standard Signal Dispositions (`SIG_DFL`):**
  * `SIGINT (2)`, `SIGQUIT (3)`, `SIGILL (4)`, `SIGABRT (6)`, `SIGFPE (8)`, `SIGKILL (9)`, `SIGSEGV (11)`, `SIGPIPE (13)`, `SIGALRM (14)`, `SIGTERM (15)`, `SIGUSR1 (10)`, `SIGUSR2 (12)`: Terminate process.
  * `SIGCHLD (17)`, `SIGURG (23)`, `SIGWINCH (28)`: Ignored by default.
### 3.2 User Stack `SignalFrame` Layout & Built-In Trampoline Contract
When delivering a signal to a user handler `sa_handler(signum)` in Ring 3, the kernel constructs a 160-byte `SignalFrame` on the user stack:
```text
High Address (Interrupted User RSP)
+-------------------------------------------------------------------+
| Interrupted User Stack Frame                                      |
+-------------------------------------------------------------------+
| 128-Byte Red Zone (Preserved untouched: user_rsp - 128 .. user_rsp)|
+-------------------------------------------------------------------+
| Alignment Padding (0..15 bytes)                                   |
+-------------------------------------------------------------------+ <--- sigframe_vaddr + 160
| saved_regs     : SyscallFrame (128 bytes)  [offset 32..160]       |
| saved_sigmask  : u64          (8 bytes)    [offset 24..32]        |
| trampoline     : [16]u8       (16 bytes)   [offset 8..24]         | <--- Self-contained restorer:
|                  [48 c7 c0 0f 00 00 00 0f 05 = mov $15,%rax;syscall]
| pretcode       : u64          (8 bytes)    [offset 0..8]          | <--- New User RSP ((rsp & 0xF) == 8!)
+-------------------------------------------------------------------+
Low Address
```
1. **Exact Address Calculation (`sigframe_vaddr`):**
   ```zig
   const raw_top = frame.user_rsp - 128 - @sizeOf(SignalFrame);
   const sigframe_vaddr = (raw_top & ~@as(usize, 0xF)) - 8;
   ```
   This ensures `sigframe_vaddr` satisfies `(sigframe_vaddr & 0xF) == 8`, meeting System V AMD64 ABI alignment rules after the handler executes `push %rbp`.
2. **Trampoline Selection (`pretcode`):**
   * If `(act.sa_flags & SA_RESTORER) != 0 and act.sa_restorer != 0`, set `pretcode = act.sa_restorer`.
   * Otherwise, set `pretcode = sigframe_vaddr + 8`, pointing directly to the self-contained restorer code in `trampoline`.
   * Record `cur.last_sigframe_vaddr = sigframe_vaddr` so `sys_rt_sigreturn(15)` knows where to unpack the saved state.
### 3.3 Signal System Calls Contract
| Syscall Name | Num | Arguments | Exact Return Value & `-Errno` Edge Cases |
| :--- | :--- | :--- | :--- |
| **`sys_rt_sigaction`** | `13` | `sig, act_ptr, oact_ptr, sigsetsize` | If `sig == 0 or sig > 64 or sig == 9 or sig == 19`, return `-EINVAL`. If `sigsetsize != 8`, return `-EINVAL`. If `oact_ptr != 0`, write current action. If `act_ptr != 0`, set action. Returns 0. |
| **`sys_rt_sigprocmask`** | `14` | `how, set_ptr, oset_ptr, sigsetsize` | If `sigsetsize != 8`, return `-EINVAL`. If `oset_ptr != 0`, write old mask. Modify `cur.sig_mask` according to `SIG_BLOCK`, `SIG_UNBLOCK`, `SIG_SETMASK`. Preserves unmaskable signals (`SIGKILL`, `SIGSTOP`). Returns 0. |
| **`sys_rt_sigreturn`** | `15` | (none) | Restore `SyscallFrame` and signal mask from `cur.last_sigframe_vaddr`. Returns restored register state. |
| **`sys_pause`** | `34` | (none) | Suspend task until an unmasked signal arrives. Returns `-EINTR (-4)`. |
| **`sys_alarm`** | `37` | `seconds: usize` | If `seconds == 0`, cancel alarm. If `seconds > 0`, set `cur.alarm_wake_tick = timer.getTicks() + seconds * 100`. Returns remaining seconds from previous alarm. |
| **`sys_setitimer`** | `38` | `which, new_val_ptr, old_val_ptr` | Configure interval timer from `LinuxItimerval` (32 bytes: `it_interval` and `it_value`). Returns 0. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/proc/signal.zig`
```zig
const std = @import("std");
const task = @import("task.zig");
const vmm = @import("../mm/vmm.zig");
const syscall_arch = @import("../arch/x86_64/syscall.zig");
const SyscallFrame = syscall_arch.SyscallFrame;
const errno_mod = @import("../uapi/errno.zig");
pub const SIGHUP: usize = 1;
pub const SIGINT: usize = 2;
pub const SIGQUIT: usize = 3;
pub const SIGILL: usize = 4;
pub const SIGABRT: usize = 6;
pub const SIGKILL: usize = 9;
pub const SIGUSR1: usize = 10;
pub const SIGSEGV: usize = 11;
pub const SIGUSR2: usize = 12;
pub const SIGPIPE: usize = 13;
pub const SIGALRM: usize = 14;
pub const SIGTERM: usize = 15;
pub const SIGCHLD: usize = 17;
pub const SIGCONT: usize = 18;
pub const SIGSTOP: usize = 19;
pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;
pub const SA_SIGINFO: u64 = 0x0000_0004;
pub const SA_RESTORER: u64 = 0x0400_0000;
pub const SA_RESTART: u64 = 0x1000_0000;
pub const SA_NODEFER: u64 = 0x4000_0000;
pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;
pub const UNMASKABLE_SIGNALS: u64 = (@as(u64, 1) << (SIGKILL - 1)) | (@as(u64, 1) << (SIGSTOP - 1));
pub const KernelSigAction = extern struct {
    sa_handler: usize align(1) = SIG_DFL,
    sa_flags: u64 align(1) = 0,
    sa_restorer: usize align(1) = 0,
    sa_mask: u64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(KernelSigAction) == 32);
        std.debug.assert(@offsetOf(KernelSigAction, "sa_restorer") == 16);
    }
};
pub const SignalFrame = extern struct {
    pretcode: u64 align(1),
    trampoline: [16]u8 align(1),
    saved_sigmask: u64 align(1),
    saved_regs: SyscallFrame align(1),
    comptime {
        std.debug.assert(@sizeOf(SignalFrame) == 160);
        std.debug.assert(@offsetOf(SignalFrame, "trampoline") == 8);
        std.debug.assert(@offsetOf(SignalFrame, "saved_sigmask") == 24);
        std.debug.assert(@offsetOf(SignalFrame, "saved_regs") == 32);
    }
};
pub const LinuxItimerval = extern struct {
    it_interval_sec: i64 align(1) = 0,
    it_interval_usec: i64 align(1) = 0,
    it_value_sec: i64 align(1) = 0,
    it_value_usec: i64 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(LinuxItimerval) == 32);
    }
};
pub const TRAMPOLINE_BYTES: [16]u8 = .{
    0x48, 0xC7, 0xC0, 0x0F, 0x00, 0x00, 0x00, // movq $15, %rax (SYS_rt_sigreturn)
    0x0F, 0x05,                               // syscall
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, // nop padding
};
pub fn sendSignalToTask(t: *task.Task, sig: usize) void {
    // Builder sets bit (sig - 1) in t.pending_signals and wakes t if in .WAITING_SIGNAL / .WAITING_SLEEP
}
pub fn deliverPendingSignals(frame: *SyscallFrame) *SyscallFrame {
    // Builder checks deliverable signals on task.currentTask(), builds SignalFrame on user stack
    // if a custom user handler is registered, and redirects frame.user_rip / frame.user_rsp / frame.rdi
}
pub fn restoreSignalFrame(frame: *SyscallFrame) *SyscallFrame {
    // Builder restores SyscallFrame and sig_mask from cur.last_sigframe_vaddr
}
```
### 4.2 `src/user/sig_test.zig` (Verification Binary)
Create `src/user/sig_test.zig`:
```zig
const std = @import("std");
const SIGUSR1: usize = 10;
const SIGALRM: usize = 14;
const SIGCHLD: usize = 17;
const SIG_BLOCK: usize = 0;
const SIG_UNBLOCK: usize = 1;
const SA_RESTORER: u64 = 0x0400_0000;
const KernelSigAction = extern struct {
    sa_handler: usize align(1) = 0,
    sa_flags: u64 align(1) = 0,
    sa_restorer: usize align(1) = 0,
    sa_mask: u64 align(1) = 0,
};
const LinuxItimerval = extern struct {
    it_interval_sec: i64 align(1) = 0,
    it_interval_usec: i64 align(1) = 0,
    it_value_sec: i64 align(1) = 0,
    it_value_usec: i64 align(1) = 30_000, // 30ms timer
};
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call sigTestMain
    );
}
export fn sigRestorer() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq $15, %rax
        \\ syscall
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
inline fn syscall2(num: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
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
    _ = syscall1(231, code);
    unreachable;
}
var usr1_count: usize = 0;
var alrm_count: usize = 0;
var chld_count: usize = 0;
export fn signalHandler(signum: usize) callconv(.C) void {
    var local_aligned: [16]u8 align(16) = [_]u8{0} ** 16;
    local_aligned[0] = @truncate(signum);
    if ((@intFromPtr(&local_aligned) & 0xF) != 0) failExit(99);
    if (signum == SIGUSR1) {
        usr1_count += 1;
        writeStdout("[TINUX_SIG] Custom SIGUSR1 handler invoked in Ring 3!\n");
    } else if (signum == SIGALRM) {
        alrm_count += 1;
        writeStdout("[TINUX_SIG] Custom SIGALRM timer handler invoked & waking pause()!\n");
    } else if (signum == SIGCHLD) {
        chld_count += 1;
        writeStdout("[TINUX_SIG] Custom SIGCHLD handler invoked on child exit!\n");
    }
}
export fn sigTestMain() callconv(.C) noreturn {
    const act = KernelSigAction{
        .sa_handler = @intFromPtr(&signalHandler),
        .sa_flags = SA_RESTORER,
        .sa_restorer = @intFromPtr(&sigRestorer),
        .sa_mask = 0,
    };
    if (syscall4(13, SIGUSR1, @intFromPtr(&act), 0, 8) != 0) failExit(10);
    if (syscall4(13, SIGALRM, @intFromPtr(&act), 0, 8) != 0) failExit(11);
    if (syscall4(13, SIGCHLD, @intFromPtr(&act), 0, 8) != 0) failExit(12);
    var mask: u64 = (@as(u64, 1) << (SIGUSR1 - 1));
    if (syscall4(14, SIG_BLOCK, @intFromPtr(&mask), 0, 8) != 0) failExit(13);
    const pid = syscall0(39); // getpid
    if (syscall2(62, @intCast(pid), SIGUSR1) != 0) failExit(14);
    if (@atomicLoad(usize, &usr1_count, .seq_cst) != 0) failExit(15);
    if (syscall4(14, SIG_UNBLOCK, @intFromPtr(&mask), 0, 8) != 0) failExit(16);
    if (@atomicLoad(usize, &usr1_count, .seq_cst) != 1) failExit(17);
    var itimer = LinuxItimerval{};
    if (syscall3(38, 0, @intFromPtr(&itimer), 0) != 0) failExit(18);
    const pause_rc = syscall0(34); // sys_pause()
    if (pause_rc != -4) failExit(19);
    if (@atomicLoad(usize, &alrm_count, .seq_cst) != 1) failExit(20);
    const child_pid = syscall0(57); // sys_fork()
    if (child_pid == 0) {
        _ = syscall1(60, 0);
        unreachable;
    }
    var status: i32 = 0;
    _ = syscall4(61, @intCast(child_pid), @intFromPtr(&status), 0, 0);
    if (@atomicLoad(usize, &chld_count, .seq_cst) != 1) failExit(21);
    writeStdout("[TINUX_SIG] All signal delivery, masking, timer, and rt_sigreturn checks passed!\n");
    _ = syscall1(231, 0);
    unreachable;
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Add Signal State to `src/proc/task.zig`:**
   * Add `WAITING_SIGNAL = 12` to `TaskState`.
   * Add fields to `Task` struct:
     * `sigactions: [65]signal.KernelSigAction = [_]signal.KernelSigAction{.{}} ** 65`
     * `pending_signals: u64 = 0`
     * `sig_mask: u64 = 0`
     * `in_signal_handler: bool = false`
     * `last_sigframe_vaddr: usize = 0`
     * `alarm_wake_tick: u64 = 0`
   * In `forkCurrentTask` / `cloneCurrentTask`, inherit parent's `sigactions` and `sig_mask`. Clear `pending_signals`.
   * In `sysExecve`, reset custom signal handlers to `SIG_DFL`.
   * In `timer.onTick()`, check if `now_ticks >= t.alarm_wake_tick` and queue `SIGALRM` via `signal.sendSignalToTask(t, signal.SIGALRM)`.
2. **Step 2: Implement Signal Delivery in `src/proc/signal.zig`:**
   * In `sendSignalToTask(t, sig)`:
     1. Validate signal: if `sig == 0 or sig > 64`, return.
     2. Set bit: `t.pending_signals |= (@as(u64, 1) << @intCast(sig - 1));`.
     3. If signal is unmasked and task is in `.WAITING_SIGNAL` or `.WAITING_SLEEP`, transition task to `.READY`.
   * In `deliverPendingSignals(frame)`:
     1. If `cur.in_signal_handler`, return frame immediately to prevent reentrant handler recursion.
     2. Calculate deliverable signals: `const deliverable = cur.pending_signals & ~cur.sig_mask;`. If 0, return frame.
     3. Identify lowest pending signal via `@ctz(deliverable)`. Clear pending bit.
     4. Retrieve registered action: `const act = cur.sigactions[sig];`.
     5. If `act.sa_handler == SIG_IGN`, continue to next signal.
     6. If `act.sa_handler == SIG_DFL`: terminate task if default action is terminate; ignore if default is ignore (`SIGCHLD`, `SIGWINCH`).
     7. If `act.sa_handler > 1` (custom user handler):
        * Compute aligned frame address: `const sigframe_vaddr = ((frame.user_rsp - 128 - @sizeOf(SignalFrame)) & ~@as(usize, 0xF)) - 8;`.
        * Build `SignalFrame` on user stack containing `pretcode`, `trampoline` bytes, `cur.sig_mask`, and saved `frame.*`.
        * Set `cur.last_sigframe_vaddr = sigframe_vaddr; cur.in_signal_handler = true;`.
        * Apply `act.sa_mask` to `cur.sig_mask`.
        * Set `frame.user_rip = act.sa_handler; frame.user_rsp = sigframe_vaddr; frame.rdi = sig;`.
        * Return updated frame.
   * In `restoreSignalFrame(frame)`:
     1. Retrieve `SignalFrame` from `cur.last_sigframe_vaddr`.
     2. Restore `cur.sig_mask` from `sf.saved_sigmask`.
     3. Set `cur.in_signal_handler = false; cur.last_sigframe_vaddr = 0;`.
     4. Restore `frame.* = sf.saved_regs; return frame;`.
3. **Step 3: Wire Signals in `src/syscall/dispatch.zig`:**
   * On child process exit in `sysExit` / `sysExitGroup`, queue `SIGCHLD` to parent task via `signal.sendSignalToTask(parent, signal.SIGCHLD)`.
   * In `sysKill(62)`, find target process and dispatch signal.
   * In `syscallDispatch(frame)`, before returning to Ring 3, call `return signal.deliverPendingSignals(frame);`.
4. **Step 4: Update `src/main.zig` and `scripts/verify_qemu.sh`:**
   * In `scripts/verify_qemu.sh`, compile `sig_test.zig`, package into initramfs, and run verification.
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-018 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-018
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Running user-space signal delivery & rt_sigreturn test suite...
[TINUX_SIG] Custom SIGUSR1 handler invoked in Ring 3!
[TINUX_SIG] Custom SIGALRM timer handler invoked & waking pause()!
[TINUX_SIG] Custom SIGCHLD handler invoked on child exit!
[TINUX_SIG] All signal delivery, masking, timer, and rt_sigreturn checks passed!
[TINUX_SIGNAL] POSIX signal delivery (rt_sigaction/sigprocmask/setitimer/SIGCHLD/rt_sigreturn) verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-018
[HARNESS] SUCCESS: TASK-018 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-018 10` fails 3 consecutive times, stop execution and generate `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-018
## 1. Failure Summary
* **Failed Stage:** [zig build / Signal Handler #GP (16B Alignment Error) / Trampoline #PF / rt_sigreturn Frame Restore Error]
* **Signal & Task State Dump:** [pending_signals, sig_mask, last_sigframe_vaddr, alarm_wake_tick, sig_test exit code]
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
[Relevant code diff for src/proc/signal.zig, src/proc/task.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
