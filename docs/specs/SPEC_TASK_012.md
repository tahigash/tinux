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
   Do not alter COM1 RX interrupt vector assignments (Vector 36 / IRQ4), `KernelTermios` struct layout (36 bytes), TTY buffer sizes (`TTY_BUF_SIZE = 4096`), or I/O port assignments (`0x03F8`).
2. **Dual RX Ingestion Guarantee (IRQ4 + Polling):**
   Because QEMU stdio pipes may buffer input, combine both the IRQ4 interrupt handler and timer tick polling (`tty.pollSerialRx()`) to guarantee serial bytes are ingested into the TTY line buffer.
3. **Strict Zig Version Idioms:**
   Adhere strictly to modern Zig idioms (0.13+) as defined in Section 1. Do not use deprecated functions like `@ptrToInt` or `@intToPtr`.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-012 10` fails 3 consecutive times, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Unaligned 32-bit write | `@ptrCast(*i32, ptr).* = v` | `std.mem.writeInt(i32, @as(*[4]u8, @ptrFromInt(ptr)), v, .little)` |
| Unaligned 32-bit read | `@ptrCast(*const i32, ptr).*` | `std.mem.readInt(i32, @as(*const [4]u8, @ptrFromInt(ptr)), .little)` |
| Struct size verification | Runtime check | `comptime { std.debug.assert(@sizeOf(T) == N); }` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-012`
* **Title:** `Bidirectional TTY Console (UART IRQ4 + Line Discipline + termios/pgrp ioctls), Interactive Shell via Stdin`
* **Target Subsystem:** `drivers`, `arch/x86_64`, `proc`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/drivers/serial.zig` (Modify: enable UART RX interrupt `IER = 0x01` and add non-blocking `readByteNonBlocking()`)
  * `src/drivers/tty.zig` (Create: TTY RX ring buffer, canonical/echo line discipline, `KernelTermios`, foreground process group)
  * `src/drivers/timer.zig` (Modify: unmask IRQ4 on Master PIC `0xEE` and call `tty.pollSerialRx()` inside `onTick()`)
  * `src/arch/x86_64/isr.S` (Modify: add `ISR_NOERR 33..36` so Vector 36 = IRQ4 COM1 is handled cleanly)
  * `src/arch/x86_64/idt.zig` (Modify: register vectors `32..36` and dispatch Vector 36 to `tty.onIrq4()`)
  * `src/proc/task.zig` (Modify: add `pgid: usize` and `WAITING_TTY = 7` state, wake TTY waiters on input)
  * `src/fs/vfs.zig` (Modify: register `/dev/tty` and `/dev/console` mapped to `CONSOLE_IN` / `CONSOLE_OUT`)
  * `src/syscall/dispatch.zig` (Modify: connect `CONSOLE_IN` in `sysRead` to `tty.read()`, expand `sysIoctl` with termios commands)
  * `src/main.zig` (Modify: initialize `tty.init()` and spawn interactive `/bin/sh` reading commands from standard input)
  * `scripts/verify_qemu.sh` (Modify: pipe an interactive multi-command operator session into QEMU stdin and verify execution)
---
## 3. UART RX, TTY Line Discipline & `ioctl` ABI Contract (Opus 5.5 Audited)
### 3.1 UART COM1 RX (`0x3F8`, IRQ4 = Vector 36) Contract
1. **UART Initialization (`serial.init`):**
   * After baud configuration (DLAB unlocked, `LCR = 0x03`), write `0x01` to `COM1_PORT + 1` (`IER`) to enable Received Data Available Interrupts.
   * Configure `COM1_PORT + 2` (`FCR`) with `0xC7` (enable FIFO, clear TX/RX FIFO, 14-byte trigger threshold).
2. **Non-Blocking Byte Read (`serial.readByteNonBlocking() ?u8`):**
   * Read Line Status Register `LSR` (`COM1_PORT + 5` = `0x3FD`).
   * If `(io.inb(COM1_PORT + 5) & 0x01) != 0`, read and return `io.inb(COM1_PORT)`. Otherwise, return `null`.
3. **8259A Master PIC Unmasking (`0x21`):**
   * Write `0xEE` (`~((1 << 0) | (1 << 4))`) to Master PIC IMR (port `0x21`) to unmask IRQ0 (PIT Timer = Vector 32) and IRQ4 (COM1 Serial = Vector 36).
   * In Vector 36 interrupt handler, send EOI (`0x20`) to Master PIC via `io.outb(0x20, 0x20)`.
### 3.2 TTY Line Discipline & `KernelTermios` Contract (`src/drivers/tty.zig`)
The Linux x86_64 `struct ktermios` occupies exactly 36 bytes. It is required by `tcgetattr()` and `tcsetattr()` in musl and glibc:
| `ioctl` Name | Request Code | Argument (`argp`) | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`TCGETS`** | `0x5401` | `*KernelTermios` (36B) | Copy `current_termios` (36 bytes) to user buffer `argp`. Returns 0. |
| **`TCSETS` / `TCSETSW` / `TCSETSF`** | `0x5402` / `0x5403` / `0x5404` | `*const KernelTermios` | Copy 36 bytes from user buffer `argp` into `current_termios`. Returns 0. |
| **`TIOCSCTTY`** | `0x540E` | `arg: usize` | Make current terminal controlling terminal. Returns 0 on success. |
| **`TIOCGPGRP`** | `0x540F` | `*i32` (4B) | Write foreground process group ID (`fg_pgid`) as 32-bit integer to `argp`. Returns 0. |
| **`TIOCSPGRP`** | `0x5410` | `*const i32` (4B) | Read 32-bit integer from `argp` and update `fg_pgid`. Returns 0. |
| **`TIOCGWINSZ`** | `0x5413` | `*Winsize` (8B) | Return window size: `ws_row = 24, ws_col = 80, ws_xpixel = 0, ws_ypixel = 0`. Returns 0. |
| **`TIOCSWINSZ`** | `0x5414` | `*const Winsize` (8B) | Accept window size update from user. Returns 0. |
#### Line Discipline Input Rules (`tty.onCharReceived(ch: u8)`):
1. **CR-to-NL Translation (`ICRNL = 0x0100`):**
   When `\r` (`0x0D`) is received and `(termios.c_iflag & 0x0100) != 0`, translate byte to `\n` (`0x0A`).
2. **Ctrl+C (`0x03`, `VINTR`) Handling:**
   When `0x03` is received and `(termios.c_lflag & 0x0001) != 0` (`ISIG`), echo `^C\n` and deliver `SIGINT` to `fg_pgid`.
3. **Ctrl+D (`0x04`, `VEOF`) Handling:**
   When `0x04` is received, set `eof_pending = true` and wake any tasks waiting in `.WAITING_TTY`.
4. **Backspace (`0x08` or `0x7F`, `VERASE`) Handling:**
   In canonical mode (`ICANON = 0x0002`), if previous character is not `\n` and `count > 0`, decrement write index, decrement buffer count, and erase character visually with `\x08 \x08`.
5. **Echo & Buffering (`ECHO = 0x0008`):**
   Store received byte in `rx_buf: [4096]u8`. If `(termios.c_lflag & 0x0008) != 0`, echo byte back to UART (converting `\n` to `\r\n`).
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
   After `ISR_NOERR 32`, add stubs for vectors 33 through 36:
   ```asm
   ISR_NOERR 33
   ISR_NOERR 34
   ISR_NOERR 35
   ISR_NOERR 36
   ```
2. **`src/arch/x86_64/idt.zig`:**
   * Update `extern const isr_stub_table: [37]usize;` to register gates `0..36`.
   * In `isrDispatch(frame: *TrapFrame)`:
     * `if (frame.vector == 32) { timer.onTick(); return; }`
     * `if (frame.vector == 36) { tty.onIrq4(); return; }`
     * `if (frame.vector >= 32 and frame.vector < 48) { io.outb(0x20, 0x20); return; }`
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Update `src/drivers/serial.zig` and `src/drivers/timer.zig`:**
   * In `serial.init()`, enable RX interrupt by writing `0x01` to `COM1_PORT + 1`.
   * Add non-blocking read function in `src/drivers/serial.zig`:
     ```zig
     pub fn readByteNonBlocking() ?u8 {
         if ((io.inb(COM1_PORT + 5) & 0x01) == 0) return null;
         return io.inb(COM1_PORT);
     }
     ```
   * In `timer.init()`, configure Master PIC mask with `io.outb(PIC1_DATA, 0xEE);` to unmask IRQ0 and IRQ4.
   * In `timer.onTick()`, call `tty.pollSerialRx();`.
2. **Step 2: Implement `src/drivers/tty.zig`:**
   * In `pollSerialRx()`:
     Drain bytes while `serial.readByteNonBlocking()` returns data:
     1. Translate `\r` to `\n` if `ICRNL` flag is active.
     2. If `b == 0x04` and `ICANON` is active, set `eof_pending = true` and call `task.wakeTtyWaiters()`.
     3. If `b == 0x08` or `b == 0x7F` in canonical mode, delete previous character if buffer has content.
     4. Append byte to `rx_buf` circular buffer and echo to serial console if `ECHO` flag is active.
     5. Call `task.wakeTtyWaiters()`.
   * In `read(dst: []u8) TtyReadResult`:
     1. Call `pollSerialRx()`.
     2. If `!hasReadableData()`, return `.would_block`.
     3. If `count == 0 and eof_pending`, clear flag and return `.eof`.
     4. Consume bytes from `rx_buf` into `dst` up to newline in canonical mode, or up to `dst.len` in raw mode.
     5. Return `.{ .bytes = n }`.
3. **Step 3: Update `src/proc/task.zig` and `src/fs/vfs.zig`:**
   * Add `WAITING_TTY = 7` to `TaskState`.
   * Add `pgid: usize = 1` field to `Task` struct.
   * Add `wakeTtyWaiters()` function in `src/proc/task.zig` to transition tasks in `WAITING_TTY` to `READY`.
   * In `task.scheduleNextOrWait()`, wake sleeping tasks and TTY waiters when readable data is available.
   * In `src/fs/vfs.zig` `init()`, register `/dev/tty` and `/dev/console` with `S_IFCHR | 0o666`.
4. **Step 4: Update `src/syscall/dispatch.zig`:**
   * In `sysRead`, if file descriptor is `CONSOLE_IN` or `CONSOLE_OUT`, invoke `tty.read()`:
     * On `.bytes => |n|`, return `n`.
     * On `.eof`, return 0.
     * On `.would_block`, rewind instruction pointer (`frame.user_rip -= 2`), set `cur.state = .WAITING_TTY`, save frame, and switch tasks.
   * In `sysIoctl(16)`, dispatch TTY file descriptors to `tty.handleIoctl(req, argp, &validateUserBuffer)`.
   * Implement process group syscalls: `sysSetpgid(109)`, `sysGetpgrp(111)`, `sysGetpgid(121)`.
   * Implement `sysPoll(7)` and `sysPpoll(271)` for TTY polling.
5. **Step 5: Update `src/main.zig` and `scripts/verify_qemu.sh`:**
   * In `src/main.zig` `kmain()`:
     1. Emit `[TINUX_TEST] START: TASK-012\n`.
     2. Initialize TTY subsystem via `tty.init();`.
     3. Spawn interactive shell: `const argv = [_][]const u8{ "/bin/sh" };`.
     4. Log `[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...\n`.
   * In `scripts/verify_qemu.sh`, pipe interactive shell session into QEMU stdin:
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
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
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
If `zig build` or `./scripts/verify_qemu.sh TASK-012 10` fails 3 consecutive times, stop execution and generate `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-012
## 1. Failure Summary
* **Failed Stage:** [zig build / IRQ4 Vector 36 Fault / TTY Read Deadlock / termios ioctl EFAULT / Interactive Stdin]
* **TTY & Task State Dump:** [tty.count, tty.newline_count, fg_pgid, and Task pid, state, comm]
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
[Relevant code diff for src/drivers/tty.zig, src/proc/task.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
