# Tinux In-Kernel Syscall Tracing Guide (`strace` mode)

> **Purpose:** Trace and format Linux syscall numbers, argument registers, and return values directly over serial COM1.

---

## 1. How strace Mode Works

* **In-kernel tracer:** Formats argument registers (`RDI`, `RSI`, `RDX`, `R10`, `R8`, `R9`) and return values (`RAX`) directly to COM1 around `syscallDispatch` without external ptrace dependencies.
* **Zero overhead when disabled:** When tracing is off, calls bypass formatting entirely with a single branch check.
* **ANSI color formatting:** Highlights PIDs, syscall names, arguments, and error codes in the terminal.

---

## 2. Implementation (`src/syscall/strace.zig`)

Confirm that `src/syscall/strace.zig` contains the following implementation:

```zig
const std = @import("std");
const serial = @import("../drivers/serial.zig");
const SyscallFrame = @import("../arch/x86_64/syscall.zig").SyscallFrame;

pub var enabled: bool = false;

pub fn init(enable: bool) void {
    enabled = enable;
}

pub fn logSyscallEnter(pid: usize, nr: usize, frame: *const SyscallFrame) void {
    if (!enabled) return;
    serial.writeString("\x1b[36m[strace pid=");
    writeUsize(pid);
    serial.writeString("] \x1b[32m");
    writeSyscallName(nr);
    serial.writeString("\x1b[0m(");
    writeHex(frame.rdi);
    serial.writeString(", ");
    writeHex(frame.rsi);
    serial.writeString(", ");
    writeHex(frame.rdx);
    serial.writeString(", ");
    writeHex(frame.r10);
    serial.writeString(", ");
    writeHex(frame.r8);
    serial.writeString(", ");
    writeHex(frame.r9);
    serial.writeString(")");
}

pub fn logSyscallExit(ret: isize) void {
    if (!enabled) return;
    serial.writeString(" = ");
    if (ret < 0) {
        serial.writeString("\x1b[31m");
        writeIsize(ret);
        serial.writeString("\x1b[0m\n");
    } else {
        serial.writeString("\x1b[33m");
        writeIsize(ret);
        serial.writeString("\x1b[0m\n");
    }
}

fn writeSyscallName(nr: usize) void {
    switch (nr) {
        0 => serial.writeString("read"),
        1 => serial.writeString("write"),
        2 => serial.writeString("open"),
        3 => serial.writeString("close"),
        4 => serial.writeString("stat"),
        5 => serial.writeString("fstat"),
        9 => serial.writeString("mmap"),
        10 => serial.writeString("mprotect"),
        11 => serial.writeString("munmap"),
        12 => serial.writeString("brk"),
        13 => serial.writeString("rt_sigaction"),
        14 => serial.writeString("rt_sigprocmask"),
        15 => serial.writeString("rt_sigreturn"),
        21 => serial.writeString("access"),
        22 => serial.writeString("pipe"),
        39 => serial.writeString("getpid"),
        56 => serial.writeString("clone"),
        57 => serial.writeString("fork"),
        58 => serial.writeString("vfork"),
        59 => serial.writeString("execve"),
        60 => serial.writeString("exit"),
        61 => serial.writeString("wait4"),
        62 => serial.writeString("kill"),
        72 => serial.writeString("fcntl"),
        79 => serial.writeString("getcwd"),
        80 => serial.writeString("chdir"),
        83 => serial.writeString("mkdir"),
        84 => serial.writeString("rmdir"),
        87 => serial.writeString("unlink"),
        158 => serial.writeString("arch_prctl"),
        202 => serial.writeString("futex"),
        217 => serial.writeString("getdents64"),
        231 => serial.writeString("exit_group"),
        232 => serial.writeString("epoll_wait"),
        233 => serial.writeString("epoll_ctl"),
        291 => serial.writeString("epoll_create1"),
        293 => serial.writeString("pipe2"),
        else => {
            serial.writeString("sys_");
            writeUsize(nr);
        },
    }
}

fn writeUsize(val: usize) void {
    var buf: [20]u8 = undefined;
    var v = val;
    var i: usize = 0;
    if (v == 0) {
        serial.writeByte('0');
        return;
    }
    while (v > 0) : (v /= 10) {
        buf[i] = @intCast((v % 10) + '0');
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        serial.writeByte(buf[i]);
    }
}

fn writeIsize(val: isize) void {
    if (val < 0) {
        serial.writeByte('-');
        writeUsize(@intCast(-val));
    } else {
        writeUsize(@intCast(val));
    }
}

fn writeHex(val: u64) void {
    const hex = "0123456789abcdef";
    serial.writeString("0x");
    var i: u6 = 60;
    while (true) : (i -%= 4) {
        serial.writeByte(hex[@intCast((val >> i) & 0xf)]);
        if (i == 0) break;
    }
}
```

---

## 3. Integration & Configuration

### 3.1 `src/syscall/dispatch.zig` Integration

Import `strace.zig` and call enter/exit hooks around `syscallDispatch`:

```zig
const strace = @import("strace.zig");

pub fn syscallDispatch(frame: *SyscallFrame) *SyscallFrame {
    const cur = task.current orelse return frame;
    strace.logSyscallEnter(cur.pid, frame.rax, frame);

    // ... (execute syscall) ...

    strace.logSyscallExit(ret);
    return out_frame;
}
```

### 3.2 Enabling Tracing

To enable tracing during kernel initialization, call `strace.init(true)` in `src/main.zig`. To trace interactive sessions on demand, pass `-append "tinux.strace=1"` in QEMU arguments.

---

## 4. Sample Output

Running `ls /tmp` in BusyBox `/bin/sh` produces:

```text
[strace pid=2] execve(0x00807000, 0x00807200, 0x00807400, 0x0, 0x0, 0x0) = 0
[strace pid=2] brk(0x0) = 0x00810000
[strace pid=2] open(0x00405020, 0x0, 0x0, 0x0, 0x0, 0x0) = 3
[strace pid=2] getdents64(0x3, 0x00811000, 0x800, 0x0, 0x0, 0x0) = 48
[strace pid=2] close(0x3, 0x0, 0x0, 0x0, 0x0, 0x0) = 0
[strace pid=2] write(0x1, 0x00812000, 0x14, 0x0, 0x0, 0x0) = 20
[strace pid=2] exit_group(0x0, 0x0, 0x0, 0x0, 0x0, 0x0) = 0
```
