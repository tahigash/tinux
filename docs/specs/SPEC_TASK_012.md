# Tinux Implementation Specification: TASK-012
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-011` Passed (`./scripts/verify_qemu.sh TASK-011 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition COM1 RX interruptvector（ Vector 36 / IRQ4 ）、 `KernelTermios` struct（ 36 bytes ）、 TTY 
2. **Dual RX Ingestion Guarantee （ IRQ4 ＋ ring of ⼆） :**
 QEMU of `-serial stdio` pipe⼊⼒ with 、 PIC of interruptmaskunlocked of UART FIFO 
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-012 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| ⾮ 32bit write | `@ptrCast(*i32, ptr).* = v` | `std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(ptr)), v,.li
| ⾮ 32bit | `@ptrCast(*const i32, ptr).*` | `std.mem.readInt(i32, @as(*const [4]u8, @ptrFromInt(ptr)),
| structverification | execute | `comptime { std.debug.assert(@sizeOf(T) == N); }` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-012`
* **Title:** `Bidirectional TTY Console (UART IRQ4 + Line Discipline + termios/pgrp ioctls), Interactive Shell via S
* **Target Subsystem:** `drivers`, `arch/x86_64`, `proc`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/drivers/serial.zig` (Modify: enable UART RX interrupt `IER = 0x01` and add non-blocking `readByteNonBlockin
  * `src/drivers/tty.zig` (Create: TTY RX ring buffer, canonical/echo line discipline, `KernelTermios`, foreground `
  * `src/drivers/timer.zig` (Modify: unmask IRQ4 on Master PIC `0xEE` and call `tty.pollSerialRx()` inside `onTick()
  * `src/arch/x86_64/isr.S` (Modify: add `ISR_NOERR 33..36` so Vector 36 = IRQ4 COM1 is handled cleanly)
  * `src/arch/x86_64/idt.zig` (Modify: register vectors `32..36` and dispatch Vector 36 to `tty.onIrq4()`)
  * `src/proc/task.zig` (Modify: add `pgid: usize` and `WAITING_TTY = 7` state, wake TTY waiters on input)
  * `src/fs/vfs.zig` (Modify: register `/dev/tty` and `/dev/console` mapped to `CONSOLE_IN` / `CONSOLE_OUT`)
  * `src/syscall/dispatch.zig` (Modify: connect `CONSOLE_IN` in `sysRead` to `tty.read()`, expand `sysIoctl` with `T
  * `src/main.zig` (Modify: initialize `tty.init()` and spawn interactive `/bin/sh` reading commands from standard i
  * `scripts/verify_qemu.sh` (Modify: pipe an interactive multi-command operator session into QEMU stdin and verify 

---
## 3. UART RX, TTY Line Discipline & `ioctl` ABI Contract (Opus 5.5 Audited)
### 3.1 UART COM1 RX (`0x3F8`, IRQ4 = Vector 36) Contract
1. **UART Initialization (`serial.init`):**
 * （ DLAB unlocked `LCR = 0x03` ）、 `COM1_PORT + 1` (`IER`) **`0x01`** （ Received Data Available Inte
 * `COM1_PORT + 2` (`FCR`) initialized ⼀enabled、 from first 。
2. **Non-Blocking Byte Read (`serial.readByteNonBlocking() ?u8`):**
 * `LSR` (`COM1_PORT + 5` = `0x3FD`) of Bit 0 (`0x01`: Data Ready) 。
 * `(io.inb(COM1_PORT + 5) & 0x01) != 0` with `io.inb(COM1_PORT)` 、 `0` with `null` 。
3. **8259A Master PIC Unmasking (`0x21`):**
 * Master PIC of IMR （port `0x21` ） **`0xEE`** （ `~((1 << 0) | (1 << 4))` ） write、 **IRQ0 （ PIT Timer = Vecto
 * Vector 36 of interrupt Master PIC to `io.outb(0x20, 0x20)` (EOI) transmit。
### 3.2 TTY Line Discipline & `KernelTermios` Contract (`src/drivers/tty.zig`)
Linux of x86_64 `struct ktermios` **36 bytes** 。 `musl` and `glibc` of `tcgetattr()` / `tcsetattr()
| `ioctl` Name | Request Code | Argument (`argp`) | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`TCGETS`** | `0x5401` | `*KernelTermios` (36B) | of `current_termios` (36 bytes) `argp` `0` 
| **`TCSETS` / `TCSETSW` / `TCSETSF`** | `0x5402` / `0x5403` / `0x5404` | `*const KernelTermios` | `argp` from 36 byt
| **`TIOCSCTTY`** | `0x540E` | `arg: usize` | of 。 `0` (Success) 。 |
| **`TIOCGPGRP`** | `0x540F` | `*i32` (4B) | processloop ID (`fg_pgid`) `i32` and `argp` 
| **`TIOCSPGRP`** | `0x5410` | `*const i32` (4B) | `argp` from `i32` 、 `fg_pgid` update `0` 。 |
| **`TIOCGWINSZ`** | `0x5413` | `*Winsize` (8B) | `ws_row = 24, ws_col = 80, ws_xpixel = 0, ws_ypixel = 0` 
| **`TIOCSWINSZ`** | `0x5414` | `*const Winsize` (8B) | update ⼊、 `0` 。 |
#### Line Discipline Input Rules (`tty.onCharReceived(ch: u8)`):
1. **CR-to-NL Translation (`ICRNL = 0x0100`):**
 receive `'\r'` (`0x0D`) with 、 `(termios.c_iflag & 0x0100) != 0` of when、 `'\n'` (`0x0A`) 。
2. **Ctrl+C (`0x03`, `VINTR`) Handling:**
 receive `0x03` with `(termios.c_lflag & 0x0001) != 0` (`ISIG`) of when、 `"^C\n"` output、 `fg_
3. **Ctrl+D (`0x04`, `VEOF`) Handling:**
 receive `0x04` of when、 `eof_pending = true` flags ⽴waitingtask（ `.WAITING_TTY` ） woken。
4. **Backspace (`0x08` or `0x7F`, `VERASE`) Handling:**
 （ `ICANON = 0x0002` ） 、 of ⾏ ⽂ringbuffer 1 ⽂、 `ECHO` 
5. **Echo & Buffering (`ECHO = 0x0008`):**
 of ⽂ or `'\n'` receiveringbuffer（ `rx_buf: [4096]u8` ） 、 `(termios.c_lflag & 0x0008) !
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/drivers/tty.zig`
```zig
const std = @import("std");
const serial = @import("serial.zig");
const io = @import("../arch/x86_64/io.zig");
const Errno = @import("../uapi/errno.zig").Errno;
pub const TTY_BUF_SIZE: usize = 4096;
pub const TCGETS: usize = 0x5401;
pub const TCSETS: usize = 0x5402;
pub const TCSETSW: usize = 0x5403;
pub const TCSETSF: usize = 0x5404;
pub const TIOCSCTTY: usize = 0x540E;
pub const TIOCGPGRP: usize = 0x540F;
pub const TIOCSPGRP: usize = 0x5410;
pub const TIOCGWINSZ: usize = 0x5413;
pub const TIOCSWINSZ: usize = 0x5414;
pub const ICRNL: u32 = 0o000400;
pub const ISIG: u32 = 0o000001;
pub const ICANON: u32 = 0o000002;
pub const ECHO: u32 = 0o000010;
pub const KernelTermios = extern struct {
    c_iflag: u32 = 0x0500, // ICRNL | IXON
    c_oflag: u32 = 0x0005, // OPOST | ONLCR
    c_cflag: u32 = 0x00BF, // B38400 | CS8 | CREAD | HUPCL
    c_lflag: u32 = 0x8A3B, // ISIG | ICANON | ECHO | ECHOE | ECHOK | IEXTEN

    c_line: u8 = 0,
    c_cc: [19]u8 = .{
        3,   // VINTR (^C)
        28,  // VQUIT (^\)
        127, // VERASE (DEL)
        21,  // VKILL (^U)
        4,   // VEOF (^D)
        0,   // VTIME
        1,   // VMIN
        0, 17, 19, 26, 0, 18, 15, 23, 22, 0, 0, 0,
    },
    comptime {
        std.debug.assert(@sizeOf(KernelTermios) == 36);
    }
};
pub const TtyReadResult = union(enum) {
    bytes: usize,
    eof: void,
    would_block: void,
};
var termios: KernelTermios = .{};
var fg_pgid: i32 = 1;
var rx_buf: [TTY_BUF_SIZE]u8 = [_]u8{0} ** TTY_BUF_SIZE;
var read_pos: usize = 0;
var write_pos: usize = 0;
var count: usize = 0;
var newline_count: usize = 0;
var eof_pending: bool = false;
pub fn init() void {
    termios = .{};
    fg_pgid = 1;
    read_pos = 0;
    write_pos = 0;
    count = 0;
    newline_count = 0;
    eof_pending = false;
    pollSerialRx();
}
pub fn pollSerialRx() void {
    // Builder drains serial.readByteNonBlocking() in a loop and feeds onCharReceived()
}
pub fn onIrq4() void {
    pollSerialRx();
    io.outb(0x20, 0x20); // Send EOI to Master PIC
}
pub fn hasReadableData() bool {
    pollSerialRx();
    if (eof_pending) return true;
    if ((termios.c_lflag & ICANON) != 0) {
        return newline_count > 0 or count >= TTY_BUF_SIZE / 2;
    }
    return count > 0;
}
pub fn read(dst: []u8) TtyReadResult {
    // Builder implements canonical line-by-line or raw read from rx_buf
}
pub fn handleIoctl(req: usize, argp: usize, is_valid_buf_fn: *const fn (usize, usize) bool) Errno!isize {
    // Builder handles TCGETS, TCSETS*, TIOCSCTTY, TIOCGPGRP, TIOCSPGRP, TIOCGWINSZ, TIOCSWINSZ
}
```
### 4.2 `src/arch/x86_64/isr.S` & `src/arch/x86_64/idt.zig` Extensions
1. **`src/arch/x86_64/isr.S`:**
 `ISR_NOERR 32` add、 `isr_stub_table` 37 （ `0..36` ） ：
   ```asm
   ISR_NOERR 33
   ISR_NOERR 34
   ISR_NOERR 35
   ISR_NOERR 36

   ```
2. **`src/arch/x86_64/idt.zig`:**
 * `extern const isr_stub_table: [37]usize;` update、 `0..37` `setGate` with 。
 * `isrDispatch(frame: *TrapFrame)` with ：
     * `frame.vector == 32` → `timer.onTick(); return;`
     * `frame.vector == 36` → `tty.onIrq4(); return;`
 * `frame.vector >= 32 and frame.vector < 48` （ of of IRQ ） → `io.outb(0x20, 0x20); return;`
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/drivers/serial.zig` and `src/drivers/timer.zig` of update **
 * `serial.init()` with （ `LCR = 0x03` ） and FIFO of 、 `io.outb(COM1_PORT + 1, 0x01);` execute R
 * `serial.zig` of ⾮blockingfunction add：
     ```zig
     pub fn readByteNonBlocking() ?u8 {
         if ((io.inb(COM1_PORT + 5) & 0x01) == 0) return null;
         return io.inb(COM1_PORT);
     }
     ```
 * `timer.init()` of Master PIC mask `io.outb(PIC1_DATA, 0xEE);` （ IRQ0 and IRQ4 mask） update。
 * `timer.onTick()` with `tty.pollSerialRx();` 。
2. **Step 2: `src/drivers/tty.zig` Implementation **
 * `pollSerialRx()` ：
 `while (serial.readByteNonBlocking()) |raw_b|` with loop：
     1. `var b = raw_b;`
     2. `if (b == '\r' and (termios.c_iflag & ICRNL) != 0) b = '\n';`
     3. `if (b == 0x04 and (termios.c_lflag & ICANON) != 0) { eof_pending = true; task.wakeTtyWaiters(); continue; }
     4. `if ((b == 0x08 or b == 0x7F) and (termios.c_lflag & ICANON) != 0)`:
 of ⽂ `'\n'` with `count > 0` with `write_pos = (write_pos + TTY_BUF_SIZE - 1) % TTY_BUF_SIZE; cou
     5. `if (count < TTY_BUF_SIZE)`:
        `rx_buf[write_pos] = b; write_pos = (write_pos + 1) % TTY_BUF_SIZE; count += 1;`
        `if (b == '\n') newline_count += 1;`
        `if ((termios.c_lflag & ECHO) != 0)`:
          `if (b == '\n') serial.writeString("\r\n") else serial.writeByte(b);`
        `task.wakeTtyWaiters();`
   * `read(dst: []u8) TtyReadResult`:
     1. `pollSerialRx();`
     2. `if (!hasReadableData()) return .would_block;`
     3. `if (count == 0 and eof_pending) { eof_pending = false; return .eof; }`
     4. `var n: usize = 0;`
     5. `while (n < dst.len and count > 0)`:
        * `const b = rx_buf[read_pos];`
        * `read_pos = (read_pos + 1) % TTY_BUF_SIZE;`
        * `count -= 1;`
        * `dst[n] = b; n += 1;`
        * `if (b == '\n')`:
          `if (newline_count > 0) newline_count -= 1;`
 `if ((termios.c_lflag & ICANON) != 0) break;` （ with 1 ⾏ with ！）
     6. `return .{ .bytes = n };`
3. **Step 3: `src/proc/task.zig` and `src/fs/vfs.zig` of update **
 * `TaskState` `WAITING_TTY = 7` add、 `Task` struct `pgid: usize = 1` add（ `initPid1` with `pgid = 1` 、
 * `task.zig` `pub fn wakeTtyWaiters() void` add、 `t.state ==.WAITING_TTY` of task `t.state =.READY` 
 * `task.scheduleNextOrWait()` ：
 `wakeSleepingTasks(timer.getTicks());` `if (tty.hasReadableData()) wakeTtyWaiters();` 。、
 * `vfs.init()` with `"dev/tty"` and `"dev/console"` `S_IFCHR | 0o666` and 。 `vfs.open` with `"de
4. **Step 4: `src/syscall/dispatch.zig` of update **
 * ** ⽅ :**
 * `sysWrite` / `sysWritev` 、 `entry.kind ==.CONSOLE_OUT or entry.kind ==.CONSOLE_IN` of with 
 * `sysRead` 、 `entry.kind ==.CONSOLE_IN or entry.kind ==.CONSOLE_OUT` of when、 `tty.read(temp_slice)` 
 * `.bytes => |n|` buffer `n` 。
 * `.eof` `0` 。
 * `.would_block` ： `frame.user_rip -= 2; frame.rax = 0; cur.state =.WAITING_TTY; cur.saved_frame = frame;
 * **`sysIoctl` (16) of :**
 FD （ or Device） of when、 `tty.handleIoctl(req, argp, &validateUserBuffer)` 。
 * ** processloop & ring Syscalls:**
 * `sysSetpgid(pid_arg, pgid_arg)` (109): `target = if (pid_arg == 0) cur else findByPid(pid_arg)` of `pgid = if 

 * `sysGetpgrp()` (111) / `sysGetpgid(pid_arg)` (121): `cur.pgid` 。
 * `sysPoll(fds_ptr, nfds, timeout)` (7) & `sysPpoll` (271): `nfds > 0` of `struct pollfd { fd: i32, events: i1
5. **Step 5: `src/main.zig` and `scripts/verify_qemu.sh` of update（typeverification） **
 * `src/main.zig` of `kmain()` with ：
     1. `serial.writeString("[TINUX_TEST] START: TASK-012\n");`
 2. `tty.init();` initialized add。
 3. PID 1 of arguments of **`const argv = [_][]const u8{ "/bin/sh" };`** （ 
     4. `serial.writeString("[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...\n");`
 * `scripts/verify_qemu.sh` of update：
 * `/bin/sh` and arguments with when、 FD 0 from 1 ⾏ `sys_read` with 
 * `verify_qemu.sh` with QEMU 、 `/bin/sh` ⼊⼒ from ⼊⼒ to column 
       ```bash
       (
           sleep 0.4
           cat << 'EOF'
       export TINUX_STAGE="Interactive-TTY-Ready"
       echo "[TINUX_TTY] Operator session active: $TINUX_STAGE"
       /bin/mkdir /tmp/ops
       echo "Linux asset compatibility verified on Tinux!" > /tmp/ops/report.txt
       /bin/cat /tmp/ops/report.txt | /bin/grep Tinux
       /bin/dyn_inspect
       /bin/ps
       echo "[TINUX_OPS] All interactive Linux operations completed successfully!"
       exit 0
       EOF
       ) | timeout "$TIMEOUT_SEC" qemu-system-x86_64 \
           -kernel "$KERNEL_BIN" \
           -nographic \
           -no-reboot \
           -serial stdio \
           -monitor none \
           -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
           > "$LOG_FILE" 2>&1
       ```
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-012 10
```
### 6.2 Expected Output (Pass Criteria)
QEMU output of and of executeoutput、 `verify_qemu.sh` Exit Code `0` with ：
```text
[TINUX_TEST] START: TASK-012
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_TTY] Operator session active: Interactive-TTY-Ready
Linux asset compatibility verified on Tinux!
[TINUX_DYN] ld-musl-x86_64.so.1 loaded at AT_BASE=0x18000000, mapped /lib/libtinux.so!
[TINUX_DYN] Main dynamic ELF executed via PT_INTERP -> AT_ENTRY transition!
[TINUX_OPS] All interactive Linux operations completed successfully!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-012
[HARNESS] SUCCESS: TASK-012 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-012 10` when、 Builder fixloop stop、 `ESCALATI
```markdown
# Escalation Report: TASK-012
## 1. Failure Summary
* **Failed Stage:** [zig build / IRQ4 Vector 36 Fault / TTY Read Deadlock / termios ioctl EFAULT / Interactive Stdin
* **TTY & Task State Dump:** [tty.count, tty.newline_count, fg_pgid, and Task of pid, state, comm]
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
[Relevant code diff for src/drivers/tty.zig, src/proc/task.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
