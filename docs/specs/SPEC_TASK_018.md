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
 specification with definition `KernelSigAction` （ 32 bytes ）、 `SignalFrame` （ 160 bytes ）、signalcolumn、 and `del
2. **Critical x86_64 Signal Handler Stack Alignment & Red Zone Rule （important ABI contract） :**
 System V AMD64 ABI with 、function（ `push %rbp` of execute） of `%rsp` must **`(rsp & 0xF) == 8`** （ 16 of − 8
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **Compile-Time ABI & Hardware Invariants （ `comptime` of strictly adhere） :**
 4 with `KernelSigAction` （ 32B ）、 `SignalFrame` （ 160B ）、 `LinuxItimerval` （ 32B ） of `comptime` ‧
5. **3-Strike Escalation Protocol （ 3 timeson failure of stop） :**
 * or `./scripts/verify_qemu.sh TASK-018 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
 * 3 times⽬ of `./scripts/triage_crash.py --out ESCALATION_REPORT.md` execute、 7 of 
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| | ⼿loop | `@ctz(mask)` |
| signal | `1 << (sig - 1)` (typeerror) | `@as(u64, 1) << @intCast(sig - 1)` |
| ⾮ 64bit | `@ptrCast(*u64, p).*` (`#GP`/Panic) | `std.mem.readInt(u64, @as(*const [8]u8, @ptrFromInt(
| ↔ | `@bitCast(isize, val)` | `@as(isize, @bitCast(val))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-018`
* **Title:** `User-Space Signal Delivery Mechanism (Signal Trampoline, rt_sigaction, rt_sigprocmask, rt_sigreturn, S
* **Target Subsystem:** `proc`, `drivers`, `syscall`, `user`

* **Target Files to Create / Modify:**
  * `src/proc/signal.zig` (Create: signal constants, `KernelSigAction`, `SignalFrame`, `sendSignal`, and `deliverPen
  * `src/proc/task.zig` (Modify: add `WAITING_SIGNAL = 12`, per-task `sigactions`, `pending_signals`, `sig_mask`, `a
  * `src/drivers/timer.zig` (Modify: check `alarm_wake_tick` on each tick to queue `SIGALRM`)
  * `src/drivers/tty.zig` (Modify: send `SIGINT (2)` to foreground process group on `Ctrl+C` `0x03`)
  * `src/syscall/dispatch.zig` (Modify: implement real `sys_rt_sigaction(13)`, `sys_rt_sigprocmask(14)`, `sys_rt_sig
  * `src/user/sig_test.zig` (Create: standalone Linux `x86_64` verification binary testing `rt_sigaction`, `rt_sigpr
  * `src/main.zig` (Modify: update test markers to `TASK-018`)
  * `scripts/verify_qemu.sh` (Modify: compile `/bin/sig_test`, package into `initramfs.cpio`, and execute via intera
* **Read-Only Reference Files:**
  * `src/arch/x86_64/syscall_entry.S`
  * `src/arch/x86_64/syscall.zig`
  * `src/mm/vmm.zig`
---
## 3. Hardware, Protocol & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 Linux x86_64 `struct k_sigaction` & Signal Numbers Contract
Linux x86_64 of `sys_rt_sigaction(sig, act, oact, sigsetsize)` `sigsetsize == 8` （ 64 mask） request、
| Field Name | Byte Offset | Size | Description & Flags |
| :--- | :--- | :--- | :--- |
| **`sa_handler`** | `0` | `8 B` (`usize`) | `0` = `SIG_DFL` （）、 `1` = `SIG_IGN` （）、 = Ring 3
| **`sa_flags`** | `8` | `8 B` (`u64`) | `SA_RESTORER = 0x04000000` 、 `SA_SIGINFO = 0x00000004` 、 `SA_RESTART = 0x10000
| **`sa_restorer`** | `16` | `8 B` (`usize`) | `SA_RESTORER` handler from of `retq` and function
| **`sa_mask`** | `24` | `8 B` (`u64`) | handlerexecute add with blocksignal of mask（ Bit `sig - 1` ）。 |
* ** signalnumber and (`SIG_DFL`):**
  * `SIGINT (2)`, `SIGQUIT (3)`, `SIGILL (4)`, `SIGABRT (6)`, `SIGFPE (8)`, `SIGKILL (9)`, `SIGSEGV (11)`, `SIGPIPE 
 * `SIGCHLD (17)`, `SIGURG (23)`, `SIGWINCH (28)`: **Ignore （） ** 。
### 3.2 User Stack `SignalFrame` Layout & Built-In Trampoline Contract
signalhandler `sa_handler(signum)` Ring 3 with execute、 of 160 of `SignalFrame` stack
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
 、 `sigframe_vaddr` must `16n - 8` （ `sigframe_vaddr & 0xF == 8` ） and 、handlerfunction of `push %rbp` 
2. **Trampoline Selection (`pretcode`):**
 * `sig_frame.trampoline` （virtual address `sigframe_vaddr + 8` ） 、 `48 c7 c0 0f 00 00 00 0f 05` （ `movq $1
 * `(act.sa_flags & SA_RESTORER) != 0 and act.sa_restorer != 0` with `sig_frame.pretcode = act.sa_restorer
 * taskstruct of `cur.last_sigframe_vaddr = sigframe_vaddr` 、 `sys_rt_sigreturn(15)` `cur
### 3.3 Signal System Calls Contract
| Syscall Name | Num | Arguments | Exact Return Value & `-Errno` Edge Cases |
| :--- | :--- | :--- | :--- |
| **`sys_rt_sigaction`** | `13` | `sig, act_ptr, oact_ptr, sigsetsize` | `sig == 0 or sig > 64 or sig == 9 or sig ==
| **`sys_rt_sigprocmask`** | `14` | `how, set_ptr, oset_ptr, sigsetsize` | `sigsetsize != 8` `-EINVAL` 。 `oset_pt
| **`sys_rt_sigreturn`** | `15` | (none) | `cur.last_sigframe_vaddr` from `SignalFrame` 、 `cur.sig_mask = sf
| **`sys_pause`** | `34` | (none) | mask of signal `frame.rax = @bitCast(toReturn(.EINTR))` and 
| **`sys_alarm`** | `37` | `seconds: usize` | `seconds == 0` `cur.alarm_wake_tick = 0` 。 `seconds > 0` `cur.
| **`sys_setitimer`** | `38` | `which, new_val_ptr, old_val_ptr` | `new_val_ptr` (`LinuxItimerval`, 32B: `it_interva

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

// x86_64 machine code: movq $15, %rax ; syscall ; nop...
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
### 4.2 `src/user/sig_test.zig` (Standalone Linux `x86_64` Signal Verification Binary)
Create `src/user/sig_test.zig` with the following implementation:
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
    // Verify 16-byte stack alignment inside C signal handler
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
    // 1. Register handlers for SIGUSR1 (10), SIGALRM (14), SIGCHLD (17)
    if (syscall4(13, SIGUSR1, @intFromPtr(&act), 0, 8) != 0) failExit(10);
    if (syscall4(13, SIGALRM, @intFromPtr(&act), 0, 8) != 0) failExit(11);
    if (syscall4(13, SIGCHLD, @intFromPtr(&act), 0, 8) != 0) failExit(12);
    // 2. Test sigprocmask (SIG_BLOCK -> kill -> verify blocked -> SIG_UNBLOCK -> delivered!)

    var mask: u64 = (@as(u64, 1) << (SIGUSR1 - 1));
    if (syscall4(14, SIG_BLOCK, @intFromPtr(&mask), 0, 8) != 0) failExit(13);
    const pid = syscall0(39); // getpid
    if (syscall2(62, @intCast(pid), SIGUSR1) != 0) failExit(14);
    if (@atomicLoad(usize, &usr1_count, .seq_cst) != 0) failExit(15); // Must still be blocked!
    if (syscall4(14, SIG_UNBLOCK, @intFromPtr(&mask), 0, 8) != 0) failExit(16);
    if (@atomicLoad(usize, &usr1_count, .seq_cst) != 1) failExit(17); // Must have fired on unblock!
    // 3. Test setitimer(ITIMER_REAL) + pause() -> SIGALRM delivery -> rt_sigreturn -> -EINTR
    var itimer = LinuxItimerval{};
    if (syscall3(38, 0, @intFromPtr(&itimer), 0) != 0) failExit(18);
    const pause_rc = syscall0(34); // sys_pause()
    if (pause_rc != -4) failExit(19); // Expect -EINTR (-4)
    if (@atomicLoad(usize, &alrm_count, .seq_cst) != 1) failExit(20);
    // 4. Test SIGCHLD delivery on child process exit
    const child_pid = syscall0(57); // sys_fork()
    if (child_pid == 0) {
        _ = syscall1(60, 0); // Child exits immediately
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
1. **Step 1: `src/proc/task.zig` of signalstate **
 * `TaskState` `WAITING_SIGNAL = 12` add。
 * `Task` struct of add：
     * `sigactions: [65]signal.KernelSigAction = [_]signal.KernelSigAction{.{}} ** 65`
     * `pending_signals: u64 = 0`
     * `sig_mask: u64 = 0`
     * `in_signal_handler: bool = false`
     * `last_sigframe_vaddr: usize = 0`
     * `alarm_wake_tick: u64 = 0`
 * `forkCurrentTask` / `cloneCurrentTask` 、⼦taskparent of `sigactions` and `sig_mask` 、 `pending_signa
 * `sysExecve` 、 POSIX contract 、handler `sigactions` `SIG_DFL` 
 * `task.wakeSleepingTasks(now_ticks: u64)` （ or `timer.onTick()` ）：
 * task `t` 、 `t.state !=.UNUSED and t.alarm_wake_tick != 0 and now_ticks >= t.alarm_wake_tick` with 
 * `task.scheduleNextOrWait()` ：
 * `.WAITING_SLEEP` `.WAITING_TTY` and 、 `.WAITING_SIGNAL` （ or `alarm_wake_tick != 0` ） of taskexists
2. **Step 2: `src/proc/signal.zig` Implementation **
   * `sendSignalToTask(t: *task.Task, sig: usize) void`:
     1. `if (sig == 0 or sig > 64 or t.state == .UNUSED or t.state == .ZOMBIE) return;`
     2. `const bit = @as(u64, 1) << @intCast(sig - 1);`
     3. `t.pending_signals |= bit;`
 4. `(bit & ~t.sig_mask) != 0` with 、 `t.state ==.WAITING_SIGNAL or t.state ==.WAITING_SLEEP` with 
   * `deliverPendingSignals(frame: *SyscallFrame) *SyscallFrame`:
     1. `const cur = task.currentTask();`
 2. `if (cur.in_signal_handler) return frame;` （⽌）。
     3. `while (true)`:
        * `const deliverable = cur.pending_signals & ~cur.sig_mask;`
        * `if (deliverable == 0) return frame;`
        * `const bit_idx: usize = @ctz(deliverable);`
        * `const sig: usize = bit_idx + 1;`
        * `cur.pending_signals &= ~(@as(u64, 1) << @intCast(bit_idx));`
        * `const act = cur.sigactions[sig];`
        * `if (act.sa_handler == SIG_IGN) continue;`
        * `if (act.sa_handler == SIG_DFL)`:
 * `if (sig == SIGCHLD or sig == SIGCONT or sig == 23 or sig == 28) continue;` （）。
 * of exitsignal（ `SIGINT`, `SIGTERM`, `SIGKILL`, `SIGALRM`, `SIGUSR1` ） with `cur.pid > 1` 
 * ** handler（ `act.sa_handler > 1` ） of delivery :**
          1. `const raw_top = frame.user_rsp - 128 - @sizeOf(SignalFrame);`

          2. `const sigframe_vaddr = (raw_top & ~@as(usize, 0xF)) - 8;`
          3. `const restorer = if ((act.sa_flags & SA_RESTORER) != 0 and act.sa_restorer != 0) act.sa_restorer else 
          4. `var sf = SignalFrame{ .pretcode = restorer, .trampoline = TRAMPOLINE_BYTES, .saved_sigmask = cur.sig_m
 5. stack（ `sigframe_vaddr` ） of `vmm.translate(cur.pml4_phys,...)` （ or Identity M
          6. `cur.last_sigframe_vaddr = sigframe_vaddr;`
          7. `cur.in_signal_handler = true;`
          8. `if ((act.sa_flags & SA_NODEFER) == 0) cur.sig_mask |= (@as(u64, 1) << @intCast(bit_idx));`
          9. `cur.sig_mask |= (act.sa_mask & ~UNMASKABLE_SIGNALS);`
          10. `frame.user_rip = act.sa_handler;`
          11. `frame.user_rsp = sigframe_vaddr;`
 12. `frame.rdi = sig;` （ 1 arguments `signum` ）
          13. `frame.rsi = 0;`
          14. `frame.rdx = 0;`
          15. `return frame;`
   * `restoreSignalFrame(frame: *SyscallFrame) *SyscallFrame`:
     1. `const cur = task.currentTask();`
     2. `const sf_vaddr = if (cur.last_sigframe_vaddr != 0) cur.last_sigframe_vaddr else (frame.user_rsp - 8);`
     3. `const sf = @as(*align(1) const SignalFrame, @ptrFromInt(sf_vaddr)).*;`
     4. `cur.sig_mask = sf.saved_sigmask & ~UNMASKABLE_SIGNALS;`
     5. `cur.in_signal_handler = false;`
     6. `cur.last_sigframe_vaddr = 0;`
     7. `frame.* = sf.saved_regs;`
     8. `return frame;`
3. **Step 3: `src/syscall/dispatch.zig` and `SIGCHLD` / `Ctrl+C` of **
 * `sysExit` / `sysExitGroup` 、⼦process（ `cur.pid > 1 and !cur.is_thread` ）exit `.ZOMBIE` 、parent
 * `sysKill` (62) / `sysTkill` (200) / `sysTgkill` (234) ：
 * `sig == 9 (SIGKILL)` of when exit。
 * of `sig >= 1 and sig <= 64` 、task `sigactions[sig].sa_handler > 1` （
 * `syscallDispatch(frame: *SyscallFrame) callconv(.C) *SyscallFrame` of with 、must **`return signal.del
4. **Step 4: `src/main.zig` and `scripts/verify_qemu.sh` of update **
 * `src/main.zig` of start `[TINUX_TEST] START: TASK-018\n` 、 PASS `[TINUX_TEST] PASS: TASK-018\n` 
 * `scripts/verify_qemu.sh` with ：
     1. `zig build-exe src/user/sig_test.zig -target x86_64-linux-none -O ReleaseSmall -fno-pie -femit-bin=.cache/in
 2. type（ `/bin/sh` ） to of column ⼊：
        ```sh
        echo "[TINUX_SH] Running user-space signal delivery & rt_sigreturn test suite..."
        /bin/sig_test
        echo "[TINUX_SIGNAL] POSIX signal delivery (rt_sigaction/sigprocmask/setitimer/SIGCHLD/rt_sigreturn) verifie
        exit 0
        ```
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
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-018 10` when、 Builder fixloop stop、 `./script
```markdown

# Escalation Report: TASK-018
## 1. Failure Summary
* **Failed Stage:** [zig build / Signal Handler #GP (16B Alignment Error) / Trampoline #PF / rt_sigreturn Frame Rest
* **Signal & Task State Dump:** [pending_signals, sig_mask, last_sigframe_vaddr, alarm_wake_tick, sig_test exit code
* **Attempt History:**
  * Attempt 1: [Changes attempted and observed outcome]
  * Attempt 2: [Changes attempted and observed outcome]
  * Attempt 3: [Changes attempted and observed outcome]
## 2. Automated Crash Triage & Serial Log Output
```text
[scripts/triage_crash.py of output and /tmp/tinux_qemu_TASK-018.log of ⽂ ]
```
## 3. Current Code Diff
```diff
[Relevant code diff for src/proc/signal.zig, src/proc/task.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
