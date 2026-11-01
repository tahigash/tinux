# Tinux Implementation Specification: TASK-004
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** AI System Architect
> * **Auditor (Low-Level & ABI Contract):** AI Code Auditor
> * **Target Builder:** Autonomous AI Builder Agent
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter MSR configurations, `SyscallFrame` struct layouts, calling conventions, syscall numbers, or error return encodings.
2. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet".
3. **No Reserved Bit Violation on PTE:**
   Until `IA32_EFER.NXE` (Bit 11) is explicitly enabled, page table entries must not set `PTE_NO_EXECUTE` (Bit 63), or CPU page translation will generate a reserved-bit page fault.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-004 5` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Bit cast | `@bitCast(DestType, val)` | `@as(DestType, @bitCast(val))` |
| Cast integer to isize | `@bitCast(isize, val)` | `@as(isize, @bitCast(val))` |
| Errno return encoding | `-@enumToInt(err)` | `-@as(isize, @intFromEnum(err))` |
| Memory copy | Manual loop | `@memcpy(dst_slice, src_slice)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-004`
* **Title:** `x86_64 SYSCALL/SYSRET MSR Setup, Ring 3 Transition, and Minimal Syscall Dispatcher (sys_write / sys_exit)`
* **Target Subsystem:** `arch/x86_64`, `uapi`, `syscall`
* **Target Files to Create / Modify:**
  * `build.zig` (Modify: add `src/arch/x86_64/syscall_entry.S`)
  * `src/uapi/errno.zig` (Create: Linux POSIX errno definitions)
  * `src/arch/x86_64/syscall_entry.S` (Create: naked assembly entry point for `syscall` instruction)
  * `src/arch/x86_64/syscall.zig` (Create: MSR initialization, `enterUserMode` trampoline)
  * `src/syscall/dispatch.zig` (Create: `syscallDispatch`, `sys_write`, `sys_exit`, `validateUserBuffer`)
  * `src/main.zig` (Modify: map user test page and enter Ring 3)
---
## 3. Hardware & Syscall ABI Contract (AI Audited)
### 3.1 Model Specific Register (MSR) Configuration
Using the GDT selectors defined in TASK-002 (`0x08` = Kernel Code, `0x10` = Kernel Data, `0x18` = User Data, `0x20` = User Code 64), configure x86_64 syscall MSRs:
| MSR Name | MSR Index | Value | Register Field & Purpose Specification |
| :--- | :--- | :--- | :--- |
| **`IA32_EFER`** | `0xC0000080` | Current value `\| (1 << 0)` (`SCE`) | Bit 0 (`SCE`: System Call Extensions) enables `syscall` and `sysret` instructions |
| **`IA32_STAR`** | `0xC0000081` | `0x0000000000000000` / `0x0023001000000000` | Bits `[47:32]` = `0x0008` (Kernel CS=0x08, SS=0x10); Bits `[63:48]` = `0x0010` (SYSRET user SS=(0x10+8)\|3=0x1B, CS=(0x10+16)\|3=0x23) |
| **`IA32_LSTAR`** | `0xC0000082` | `@intFromPtr(&syscallEntry)` | Target 64-bit rip jumped to upon executing `syscall` |
| **`IA32_FMASK`** | `0xC0000084` | `0x0000_0000_0004_0700` | Flags cleared in `RFLAGS` on syscall entry: `IF` (Bit 9), `DF` (Bit 10), `TF` (Bit 8), `AC` (Bit 18) |
### 3.2 Kernel Stack Switch & 16-Byte Alignment in `syscallEntry`
* The x86_64 `syscall` instruction saves user `RIP` in `%rcx` and `RFLAGS` in `%r11`, but does not switch `%rsp`. The CPU continues executing on the user stack with CPL=0.
* Therefore, `syscallEntry` must immediately save user `%rsp` into scratch storage (`user_rsp_scratch`), load `%rsp` with the dedicated kernel syscall stack (`kernel_rsp_scratch`), push saved registers, and call `syscallDispatch`.
* The `SyscallFrame` is 128 bytes in size (16 * 8-byte slots), maintaining 16-byte stack alignment for C ABI dispatch calls.
### 3.3 Linux x86_64 System Call ABI Contract
| Syscall Name | Number (`rax`) | `rdi` (Arg1) | `rsi` (Arg2) | `rdx` (Arg3) | Return (`rax`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`sys_write`** | `1` | `fd: usize` | `buf_ptr: usize` | `count: usize` | Written bytes (`isize`), or negative errno (`-EBADF`, `-EFAULT`) |
| **`sys_exit`** | `60` | `status: usize` | (unused) | (unused) | `noreturn` |
| **`sys_exit_group`** | `231` | `status: usize` | (unused) | (unused) | `noreturn` |

#### Exact Errno Validation Rules for `sys_write`:
1. **`count == 0` Handling:** Return `0` immediately without performing I/O if valid.
2. **`-EBADF` (`-9`):** If `fd != 1` (stdout) and `fd != 2` (stderr), return `-9`.
3. **`-EFAULT` (`-14`):**
   * If `buf_ptr == 0` or `buf_ptr >= 0x0000_8000_0000_0000` (non-canonical or kernel space).
   * If `buf_ptr + count` overflows or reaches into kernel space.
   * If any 4 KiB page spanning `buf_ptr` to `buf_ptr + count - 1` is not mapped with `PTE_PRESENT | PTE_USER` in the current page table.
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/uapi/errno.zig`
```zig
pub const Errno = enum(u16) {
    EPERM = 1,
    ENOENT = 2,
    ESRCH = 3,
    EINTR = 4,
    EIO = 5,
    ENXIO = 6,
    E2BIG = 7,
    ENOEXEC = 8,
    EBADF = 9,
    ECHILD = 10,
    EAGAIN = 11,
    ENOMEM = 12,
    EACCES = 13,
    EFAULT = 14,
    EBUSY = 16,
    EEXIST = 17,
    EXDEV = 18,
    ENODEV = 19,
    ENOTDIR = 20,
    EISDIR = 21,
    EINVAL = 22,
    ENFILE = 23,
    EMFILE = 24,
    ENOTTY = 25,
    EFBIG = 27,
    ENOSPC = 28,
    ESPIPE = 29,
    EROFS = 30,
    EMLINK = 31,
    EPIPE = 32,
    ERANGE = 34,
    ENOSYS = 38,
};
pub inline fn toReturn(err: Errno) isize {
    return -@as(isize, @intCast(@intFromEnum(err)));
}
```
### 4.2 `src/arch/x86_64/syscall_entry.S`
```asm
.section .text
.code64
.global syscallEntry
.extern syscallDispatch
.extern kernel_rsp_scratch
.extern user_rsp_scratch

syscallEntry:
    /* 1. Swap user stack pointer with kernel stack pointer */
    movq %rsp, user_rsp_scratch(%rip)
    movq kernel_rsp_scratch(%rip), %rsp

    /* 2. Push 16-register SyscallFrame (128 bytes total, aligned to 16 bytes) */
    pushq user_rsp_scratch(%rip) /* [120]: user_rsp */
    pushq %rcx                   /* [112]: user_rip (saved by syscall) */
    pushq %r11                   /* [104]: user_rflags (saved by syscall) */
    pushq %rax                   /* [96]:  syscall_num / rax */
    pushq %rdi                   /* [88]:  arg1 / rdi */
    pushq %rsi                   /* [80]:  arg2 / rsi */
    pushq %rdx                   /* [72]:  arg3 / rdx */
    pushq %r10                   /* [64]:  arg4 / r10 (Linux x86_64 ABI replaces rcx with r10) */
    pushq %r8                    /* [56]:  arg5 / r8 */
    pushq %r9                    /* [48]:  arg6 / r9 */
    pushq %rbx                   /* [40]:  callee-saved rbx */
    pushq %rbp                   /* [32]:  callee-saved rbp */
    pushq %r12                   /* [24]:  callee-saved r12 */
    pushq %r13                   /* [16]:  callee-saved r13 */
    pushq %r14                   /* [8]:   callee-saved r14 */
    pushq %r15                   /* [0]:   callee-saved r15 */

    /* 3. Pass pointer to SyscallFrame in %rdi and call dispatcher */
    movq %rsp, %rdi
    call syscallDispatch

    /* 4. Restore return value into frame rax slot */
    movq %rax, 96(%rsp)

    /* 5. Pop registers */
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    popq %r9
    popq %r8
    popq %r10
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rax                    /* Restores return value */
    popq %r11                    /* Restores user_rflags */
    popq %rcx                    /* Restores user_rip */
    popq %rsp                    /* Restores user_rsp */

    /* 6. Return to Ring 3 */
    sysretq
```
### 4.3 `src/arch/x86_64/syscall.zig`
```zig
const std = @import("std");
const gdt = @import("gdt.zig");

pub const MSR_EFER: u32 = 0xC000_0080;
pub const MSR_STAR: u32 = 0xC000_0081;
pub const MSR_LSTAR: u32 = 0xC000_0082;
pub const MSR_FMASK: u32 = 0xC000_0084;
pub const EFER_SCE: u64 = 1 << 0;

pub const SyscallFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r9: u64,
    r8: u64,
    r10: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    syscall_num: u64,
    user_rflags: u64,
    user_rip: u64,
    user_rsp: u64,

    comptime {
        std.debug.assert(@sizeOf(SyscallFrame) == 128);
    }
};

extern fn syscallEntry() callconv(.C) void;
pub export var kernel_rsp_scratch: usize = 0;
pub export var user_rsp_scratch: usize = 0;
var default_syscall_stack: [16384]u8 align(16) = undefined;

pub inline fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}
pub inline fn wrmsr(msr: u32, val: u64) void {
    const low: u32 = @truncate(val);
    const high: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
        : "memory"
    );
}
pub fn setKernelRsp(rsp: usize) void {
    kernel_rsp_scratch = rsp;
    gdt.setKernelStack(rsp);
}
pub fn init() void {
    const top = @intFromPtr(&default_syscall_stack) + default_syscall_stack.len;
    setKernelRsp(top);

    const efer = rdmsr(MSR_EFER);
    wrmsr(MSR_EFER, efer | EFER_SCE);

    const star: u64 = (@as(u64, 0x0010) << 48) | (@as(u64, 0x0008) << 32);
    wrmsr(MSR_STAR, star);
    wrmsr(MSR_LSTAR, @intFromPtr(&syscallEntry));
    wrmsr(MSR_FMASK, 0x0000_0300);
}
pub fn enterUserMode(entry_rip: usize, user_rsp: usize) noreturn {
    asm volatile (
        \\ movw $0x1B, %ax
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %fs
        \\ movw %ax, %gs
        \\ pushq $0x1B
        \\ pushq %[user_rsp]
        \\ pushfq
        \\ popq %rax
        \\ orq $0x200, %rax
        \\ pushq %rax
        \\ pushq $0x23
        \\ pushq %[entry_rip]
        \\ iretq
        :
        : [user_rsp] "r" (user_rsp),
          [entry_rip] "r" (entry_rip),
        : "rax", "memory"
    );
    unreachable;
}
```
### 4.4 `src/syscall/dispatch.zig`
```zig
const std = @import("std");
const serial = @import("../drivers/serial.zig");
const vmm = @import("../mm/vmm.zig");
const io = @import("../arch/x86_64/io.zig");
const syscall_arch = @import("../arch/x86_64/syscall.zig");
const errno_mod = @import("../uapi/errno.zig");
const SyscallFrame = syscall_arch.SyscallFrame;

pub const SYS_WRITE: usize = 1;
pub const SYS_EXIT: usize = 60;
pub const SYS_EXIT_GROUP: usize = 231;
pub const USER_ADDR_MAX: usize = 0x0000_8000_0000_0000;

pub fn validateUserBuffer(user_ptr: usize, len: usize) bool {
    if (len == 0) return true;
    if (user_ptr == 0 or user_ptr >= USER_ADDR_MAX) return false;
    const end_addr = std.math.add(usize, user_ptr, len - 1) catch return false;
    if (end_addr >= USER_ADDR_MAX) return false;
    const pml4 = vmm.readCr3();
    var page = user_ptr & ~@as(usize, vmm.PAGE_SIZE - 1);
    const last_page = end_addr & ~@as(usize, vmm.PAGE_SIZE - 1);
    while (true) {
        if (vmm.translate(pml4, page) == null) return false;
        if (page == last_page) break;
        page += vmm.PAGE_SIZE;
    }
    return true;
}
pub fn sysWrite(fd: usize, buf_ptr: usize, count: usize) isize {
    if (fd != 1 and fd != 2) return errno_mod.toReturn(.EBADF);
    if (count == 0) return 0;
    if (!validateUserBuffer(buf_ptr, count)) return errno_mod.toReturn(.EFAULT);
    const slice = @as([*]const u8, @ptrFromInt(buf_ptr))[0..count];
    serial.writeString(slice);
    return @as(isize, @intCast(count));
}
pub fn sysExit(status: usize) noreturn {
    if (status == 0) {
        serial.writeString("[TINUX_SYSCALL] sys_exit(0) received from Ring 3\n");
        serial.writeString("[TINUX_TEST] PASS: TASK-004\n");
        io.qemuExit(.success);
    } else {
        serial.writeString("[TINUX_SYSCALL] FAIL: sys_exit called with non-zero status\n");
        io.qemuExit(.failure);
    }
}
export fn syscallDispatch(frame: *SyscallFrame) callconv(.C) isize {
    return switch (frame.syscall_num) {
        SYS_WRITE => sysWrite(frame.rdi, frame.rsi, frame.rdx),
        SYS_EXIT, SYS_EXIT_GROUP => sysExit(frame.rdi),
        else => errno_mod.toReturn(.ENOSYS),
    };
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `build.zig` Update**
   * Add assembly source: `exe.addAssemblyFile(b.path("src/arch/x86_64/syscall_entry.S"))`.
2. **Step 2: `src/arch/x86_64/syscall.zig` Implementation**
   * Compute kernel stack top: `const kstack_top = @intFromPtr(&default_syscall_stack) + default_syscall_stack.len`.
   * Set `setKernelRsp(kstack_top)`.
   * Read `MSR_EFER`, bitwise OR with `EFER_SCE` (Bit 0), and write back with `wrmsr`.
   * Set `MSR_STAR` with `(@as(u64, 0x0010) << 48) | (@as(u64, 0x0008) << 32)`.
   * Set `MSR_LSTAR` with `@intFromPtr(&syscallEntry)`.
   * Set `MSR_FMASK` with `0x0000_0300`.
3. **Step 3: `src/syscall/dispatch.zig` Implementation**
   * In `validateUserBuffer(user_ptr, len)`:
     1. If `len == 0`, return `true`.
     2. If `user_ptr == 0` or `user_ptr >= USER_ADDR_MAX`, return `false`.
     3. Check for integer overflow on `user_ptr + len - 1`.
     4. Iterate across all 4 KiB pages spanning `[user_ptr, user_ptr + len - 1]`. If `vmm.translate(pml4, page) == null`, return `false`.
   * In `sysWrite(fd, buf_ptr, count)`:
     1. If `fd != 1` and `fd != 2`, return `-EBADF`.
     2. If `count == 0`, return `0`.
     3. If `!validateUserBuffer(buf_ptr, count)`, return `-EFAULT`.
     4. Transmit buffer contents via `serial.writeString` and return `count` as `isize`.
   * In `sysExit(status)`:
     1. If `status == 0`, log success and exit QEMU with code 33 (`.success`).
     2. Otherwise log failure and exit QEMU with failure code (`.failure`).
4. **Step 4: `src/main.zig` Ring 3 Execution**
   * In `kmain()`, initialize kernel subsystems: `serial`, `gdt`, `idt`, `pmm`, `vmm`, `heap`, `syscall`.
   * Allocate and map user code page (`0x0040_0000`) with `PTE_PRESENT | PTE_WRITABLE | PTE_USER`.
   * Copy user test payload into code page.
   * Allocate and map 2 user stack pages (`0x0080_0000` to `0x0080_2000`) with `PTE_PRESENT | PTE_WRITABLE | PTE_USER`.
   * Log `[TINUX_USER] Entering Ring 3...\n` and jump via `syscall.enterUserMode(0x0040_0000, 0x0080_2000)`.
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-004 5
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-004
[TINUX_SYSCALL] MSRs initialized
[TINUX_USER] Entering Ring 3...
[TINUX_USER] Hello from Ring 3 via SYSCALL!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-004
[HARNESS] SUCCESS: TASK-004 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-004 5` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-004
## 1. Failure Summary
* **Failed Stage:** [zig build / iretq #GP Fault / syscall #UD Fault / Ring 3 #PF Fault / sysretq Crash / Wrong Errno]
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
[Code diff or relevant source snippet of failed component]
```
## 4. Suspected Root Cause (For AI Architect / Auditor Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
