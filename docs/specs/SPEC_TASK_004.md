# Tinux Implementation Specification: TASK-004
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-003` Passed (`./scripts/verify_qemu.sh TASK-003 5` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)

You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition MSR 、 `SyscallFrame` of 、、Syscall Number、errordefinition 
2. **Strict Zig Version Idioms:**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
3. **No Reserved Bit Violation on PTE （ PTE flags of strictly adhere） :**
 `IA32_EFER.NXE` (Bit 11) ⽰ enabled with 、pagestable `PTE_NO_EXECUTE` (Bit 63) 
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-004 5` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Enum to integer | `@enumToInt(e)` | `@intFromEnum(e)` |
| → | `@bitCast(isize, val)` | `@as(isize, @bitCast(val))` |
| of Errno return value⽣ | `-@enumToInt(err)` | `-@as(isize, @intFromEnum(err))` |
| memory | loop⼿ | `@memcpy(dst_slice, src_slice)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-004`
* **Title:** `x86_64 SYSCALL/SYSRET MSR Setup, Ring 3 Transition, and Minimal Syscall Dispatcher (sys_write / sys_ex
* **Target Subsystem:** `arch/x86_64`, `uapi`, `syscall`
* **Target Files to Create / Modify:**
  * `build.zig` (Modify: add `src/arch/x86_64/syscall_entry.S`)
  * `src/uapi/errno.zig` (Create)
  * `src/arch/x86_64/syscall_entry.S` (Create)
  * `src/arch/x86_64/syscall.zig` (Create)
  * `src/syscall/dispatch.zig` (Create)
  * `src/main.zig` (Modify: map Ring 3 test payload & execute TASK-004 verification)
* **Read-Only Reference Files:**
  * `src/arch/x86_64/gdt.zig`
  * `src/arch/x86_64/idt.zig`
  * `src/mm/pmm.zig`
  * `src/mm/vmm.zig`
---
## 3. Hardware & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 AMD64 `SYSCALL` / `SYSRET` MSR Contract
`TASK-002` with GDT （ `0x08`=Kernel Code, `0x10`=Kernel Data, `0x18`=User Data, `0x20`=User Code 64 ） 、 of 
| MSR Name | MSR Index | value‧ | of |
| :--- | :--- | :--- | :--- |
| **`IA32_EFER`** | `0xC0000080` | value `\| (1 << 0)` (`SCE`) | Bit 0 (`SCE`: System Call Extensions) `1` 
| **`IA32_STAR`** | `0xC0000081` | `(@as(u64, 0x0010) << 48) \| (@as(u64, 0x0008) << 32)` | ‧ Bits `[47:32]` = `0x000
| **`IA32_LSTAR`** | `0xC0000082` | `@intFromPtr(&syscallEntry)` | `syscall` execute 64-bit 
| **`IA32_FMASK`** | `0xC0000084` | `0x0000_0000_0004_0700` | `syscall` ⼊ cleared `RFLAGS` mask： `IF` (Bit 9
### 3.2 Kernel Stack Switch & 16-Byte Alignment in `syscallEntry`
* ** important :** x86_64 of `syscall` `RIP` `RCX` 、 `RFLAGS` `R11` save、 **`RSP` （stack
* of 、 `syscallEntry` of first with user space of `RSP` `syscall_user_rsp_scratch` save、 `syscall_kernel_rs
* `128 bytes` 16 of 、 `call syscallDispatch` execute of `RSP` 16 boundary 。
### 3.3 Linux x86_64 System Call ABI Contract
| Syscall Name | Number (`rax`) | `rdi` (Arg1) | `rsi` (Arg2) | `rdx` (Arg3) | Return (`rax`) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`sys_write`** | `1` | `fd: usize` | `buf_ptr: usize` | `count: usize` | (`isize`) 、 or of `-
| **`sys_exit`** | `60` | `status: usize` | (unused) | (unused) | `noreturn` |
| **`sys_exit_group`** | `231` | `status: usize` | (unused) | (unused) | `noreturn` |

#### Exact Errno Validation Rules for `sys_write`:
1. **`count == 0` of when :** verification ⽴（ or diskverify）、output `0` （ FD 
2. **`-EBADF` (`-9`):** `fd != 1` (stdout) `fd != 2` (stderr) of when、 `-9` 。
3. **`-EFAULT` (`-14`):**
 * `buf_ptr == 0` of when、 or `buf_ptr >= 0x0000_8000_0000_0000` （⾮ Canonical / kernel space） of when。
 * `buf_ptr + count` when、 or upper limit when。
 * `buf_ptr` from `buf_ptr + count - 1` of 4 KiB pages 、 `vmm.translate(vmm.getKernelPml4Phys(), p
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
    ENODEV = 19,
    ENOTDIR = 20,
    EISDIR = 21,
    EINVAL = 22,
    ENFILE = 23,
    EMFILE = 24,
    ENOTTY = 25,
    ENOSPC = 28,
    ESPIPE = 29,
    EPIPE = 32,
    ENOSYS = 38,
};
pub inline fn toReturn(err: Errno) isize {
    return -@as(isize, @intFromEnum(err));
}
```
### 4.2 `src/arch/x86_64/syscall_entry.S`
```asm
.section .bss
.align 16
.global syscall_kernel_stack_bottom
syscall_kernel_stack_bottom:
    .skip 65536
.global syscall_kernel_stack_top
syscall_kernel_stack_top:
.align 8
.global syscall_kernel_rsp
syscall_kernel_rsp:
    .quad 0
.global syscall_user_rsp_scratch
syscall_user_rsp_scratch:
    .quad 0
.section .text
.code64
.global syscallEntry
.extern syscallDispatch
.align 16
syscallEntry:
    /* 1. Switch from User RSP to Kernel Syscall Stack without clobbering registers */
    movq %rsp, syscall_user_rsp_scratch(%rip)
    movq syscall_kernel_rsp(%rip), %rsp

    /* 2. Build 128-byte (16-register) SyscallFrame on Kernel Stack */
    pushq syscall_user_rsp_scratch(%rip) /* offset 120: user_rsp */
    pushq %rcx                           /* offset 112: user_rip */
    pushq %r11                           /* offset 104: user_rflags */
    pushq %rax                           /* offset 96:  syscall_num */
    pushq %rdi                           /* offset 88:  arg1 */
    pushq %rsi                           /* offset 80:  arg2 */
    pushq %rdx                           /* offset 72:  arg3 */
    pushq %r10                           /* offset 64:  arg4 */
    pushq %r8                            /* offset 56:  arg5 */
    pushq %r9                            /* offset 48:  arg6 */
    pushq %rbx                           /* offset 40:  callee-saved rbx */
    pushq %rbp                           /* offset 32:  callee-saved rbp */
    pushq %r12                           /* offset 24:  callee-saved r12 */
    pushq %r13                           /* offset 16:  callee-saved r13 */
    pushq %r14                           /* offset 8:   callee-saved r14 */
    pushq %r15                           /* offset 0:   callee-saved r15 */
    /* 3. Call Zig dispatcher: rdi = *SyscallFrame, returns isize in rax */
    movq %rsp, %rdi
    call syscallDispatch
    /* 4. Restore registers (keep return value in rax) */
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
    addq $8, %rsp                        /* skip saved syscall_num Slot */
    popq %r11                            /* restore user_rflags */
    popq %rcx                            /* restore user_rip */
    popq %rsp                            /* restore user_rsp */
    /* 5. Return to Ring 3 (64-bit mode) */
    sysretq
/* void enterUserMode(usize entry_rip, usize user_rsp) noreturn */
.global enterUserMode
.align 16
enterUserMode:
    cli
    /* Construct IRETQ frame for Ring 3 transition */
    /* rdi = entry_rip, rsi = user_rsp */
    pushq $0x1B                          /* SS: USER_DATA_SEL (0x18 | 3) */
    pushq %rsi                           /* RSP: user_rsp */
    pushq $0x202                         /* RFLAGS: IF=1 (Bit 9) + Reserved Bit 1 */
    pushq $0x23                          /* CS: USER_CODE_SEL (0x20 | 3) */
    pushq %rdi                           /* RIP: entry_rip */
    /* Clear general purpose registers to prevent kernel info leak */
    xorq %rax, %rax
    xorq %rbx, %rbx
    xorq %rcx, %rcx
    xorq %rdx, %rdx
    xorq %rsi, %rsi
    xorq %rdi, %rdi
    xorq %rbp, %rbp
    xorq %r8, %r8
    xorq %r9, %r9
    xorq %r10, %r10
    xorq %r11, %r11
    xorq %r12, %r12
    xorq %r13, %r13
    xorq %r14, %r14
    xorq %r15, %r15
    iretq
/* Position-Independent Ring 3 Test Payload (Copied to 0x0040_0000 at runtime) */
.global user_test_payload_start
.global user_test_payload_end
.align 16

user_test_payload_start:
    /* Test 1: Verify we are actually in Ring 3 (CS & 3 == 3) */
    movq %cs, %rax
    andq $3, %rax
    cmpq $3, %rax
    je 1f
    /* If not Ring 3, exit with status 1 */
    movq $60, %rax
    movq $1, %rdi
    syscall
1:
    /* Test 2: Valid sys_write(1, msg, 43) */
    movq $1, %rax                        /* SYS_write */
    movq $1, %rdi                        /* fd = 1 (stdout) */
    leaq .Luser_msg(%rip), %rsi          /* buf */
    movq $43, %rdx                       /* count = 43 */
    syscall
    cmpq $43, %rax
    jne .Lfail
    /* Test 3: Invalid FD sys_write(99, msg, 5) -> Expect -EBADF (-9) */
    movq $1, %rax
    movq $99, %rdi
    leaq .Luser_msg(%rip), %rsi
    movq $5, %rdx
    syscall
    cmpq $-9, %rax
    jne .Lfail
    /* Test 4: Invalid Buffer Pointer sys_write(1, 0x0, 10) -> Expect -EFAULT (-14) */
    movq $1, %rax
    movq $1, %rdi
    xorq %rsi, %rsi                      /* NULL pointer 0x0 */
    movq $10, %rdx
    syscall
    cmpq $-14, %rax
    jne .Lfail
    /* Test 5: Clean exit via sys_exit(0) */
    movq $60, %rax                       /* SYS_exit */
    xorq %rdi, %rdi                      /* status = 0 */
    syscall
.Lfail:
    movq $60, %rax
    movq $2, %rdi                        /* status = 2 (test failure) */
    syscall
.Luser_msg:
    .ascii "[TINUX_USER] Hello from Ring 3 via SYSCALL!\n"
user_test_payload_end:
```
### 4.3 `src/arch/x86_64/syscall.zig`
```zig
const std = @import("std");
const gdt = @import("gdt.zig");
pub const MSR_EFER: u32 = 0xC0000080;
pub const MSR_STAR: u32 = 0xC0000081;
pub const MSR_LSTAR: u32 = 0xC0000082;
pub const MSR_FMASK: u32 = 0xC0000084;
pub const EFER_SCE: u64 = 1 << 0;
pub const SYSCALL_FMASK: u64 = 0x0000_0000_0004_0700; // Clear TF, IF, DF, AC
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
        std.debug.assert(@offsetOf(SyscallFrame, "syscall_num") == 96);
        std.debug.assert(@offsetOf(SyscallFrame, "user_rsp") == 120);
    }
};
extern fn syscallEntry() callconv(.Naked) void;
pub extern fn enterUserMode(entry_rip: usize, user_rsp: usize) callconv(.C) noreturn;
extern var syscall_kernel_stack_top: u8;
extern var syscall_kernel_rsp: u64;
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
pub fn init() void {
    // Builder sets up TSS rsp0, syscall_kernel_rsp, EFER.SCE, STAR, LSTAR, FMASK according to Section 5
}
```
### 4.4 `src/syscall/dispatch.zig`
```zig
const std = @import("std");
const serial = @import("../drivers/serial.zig");
const io = @import("../arch/x86_64/io.zig");
const vmm = @import("../mm/vmm.zig");
const errno_mod = @import("../uapi/errno.zig");
const Errno = errno_mod.Errno;
const SyscallFrame = @import("../arch/x86_64/syscall.zig").SyscallFrame;
pub const SYS_WRITE: u64 = 1;
pub const SYS_EXIT: u64 = 60;
pub const SYS_EXIT_GROUP: u64 = 231;
pub const USER_ADDR_MAX: usize = 0x0000_8000_0000_0000;
pub fn validateUserBuffer(user_ptr: usize, len: usize) bool {
    // Builder validates user range and page table presence according to Section 5
}
pub fn sysWrite(fd: usize, buf_ptr: usize, count: usize) isize {
    // Builder implements sys_write according to Section 3.3 and Section 5
}
pub fn sysExit(status: usize) noreturn {
    // Builder implements sys_exit according to Section 5
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
1. **Step 1: `build.zig` of update **
 * `exe.addAssemblyFile(b.path("src/arch/x86_64/syscall_entry.S"));` add。
2. **Step 2: `src/arch/x86_64/syscall.zig` of `init()` implement **
 * `const kstack_top = @intFromPtr(&syscall_kernel_stack_top);` 。
 * `syscall_kernel_rsp = kstack_top;` 。
 * Ring 3 execute interruptexception（ `#PF` ）⽣ CPU Ring 0 stack to 、 `gdt
 * `const efer = rdmsr(MSR_EFER); wrmsr(MSR_EFER, efer | EFER_SCE);` with `SCE` enabled。
 * `const star: u64 = (@as(u64, 0x0010) << 48) | (@as(u64, 0x0008) << 32); wrmsr(MSR_STAR, star);` 。
 * `wrmsr(MSR_LSTAR, @intFromPtr(&syscallEntry));` 。
 * `wrmsr(MSR_FMASK, SYSCALL_FMASK);` 。
3. **Step 3: `src/syscall/dispatch.zig` Implementation **
   * `validateUserBuffer(user_ptr: usize, len: usize) bool`:
     1. `if (len == 0) return true;`
     2. `if (user_ptr == 0 or user_ptr >= USER_ADDR_MAX) return false;`
     3. `const end_addr = std.math.add(usize, user_ptr, len - 1) catch return false;`
     4. `if (end_addr >= USER_ADDR_MAX) return false;`
     5. `var page = user_ptr & ~@as(usize, vmm.PAGE_SIZE - 1);`
     6. `const last_page = end_addr & ~@as(usize, vmm.PAGE_SIZE - 1);`
 7. `while (true) : (page += vmm.PAGE_SIZE)` with loop、 `if (vmm.translate(vmm.getKernelPml4Phys(), page) == null
   * `sysWrite(fd: usize, buf_ptr: usize, count: usize) isize`:
     1. `if (fd != 1 and fd != 2) return errno_mod.toReturn(.EBADF);`
     2. `if (count == 0) return 0;`
     3. `if (!validateUserBuffer(buf_ptr, count)) return errno_mod.toReturn(.EFAULT);`
     4. `const slice = @as([*]const u8, @ptrFromInt(buf_ptr))[0..count];`
     5. `serial.writeString(slice);`
     6. `return @as(isize, @intCast(count));`
   * `sysExit(status: usize) noreturn`:
 1. `if (status == 0)` of when：
        * `serial.writeString("[TINUX_SYSCALL] sys_exit(0) received from Ring 3\n");`
        * `serial.writeString("[TINUX_TEST] PASS: TASK-004\n");`
        * `io.qemuExit(.success);`
 2. `status != 0` of when：
        * `serial.writeString("[TINUX_SYSCALL] FAIL: sys_exit called with non-zero status\n");`
        * `io.qemuExit(.failure);`
4. **Step 4: `src/main.zig` with of Ring 3 memory and execute **
 * `extern const user_test_payload_start: u8;` and `extern const user_test_payload_end: u8;` ⾔。
 * `kmain()` with `serial`, `gdt`, `idt`, `pmm`, `vmm`, `heap` initialized、 execute：
     1. `syscall.init();` → `serial.writeString("[TINUX_SYSCALL] MSRs initialized\n");`
 2. **User Code Page (`0x0040_0000`) Creation :**
        * `const user_code_vaddr: usize = 0x0040_0000;`
        * `const code_phys = pmm.allocZeroedPage() orelse @panic("OOM code_phys");`
        * `const payload_len = @intFromPtr(&user_test_payload_end) - @intFromPtr(&user_test_payload_start);`
        * `const src = @as([*]const u8, @ptrFromInt(@intFromPtr(&user_test_payload_start)))[0..payload_len];`
        * `const dst = @as([*]u8, @ptrFromInt(code_phys))[0..payload_len];`
        * `@memcpy(dst, src);`
        * `std.debug.assert(vmm.mapPage(vmm.getKernelPml4Phys(), user_code_vaddr, code_phys, vmm.PTE_PRESENT | vmm.P
 3. **User Stack Pages (`0x0080_0000.. 0x0080_2000`) Creation :**
        * `const user_stack_base: usize = 0x0080_0000;`
 * 2 pages（ `0x0080_0000` and `0x0080_1000` ） of pages `pmm.allocZeroedPage()` with allocated、 `vmm.PTE_PRESENT |
        * `const user_initial_rsp: usize = user_stack_base + (2 * vmm.PAGE_SIZE);` (`0x0080_2000`)
     4. `serial.writeString("[TINUX_USER] Entering Ring 3...\n");`
     5. `syscall.enterUserMode(user_code_vaddr, user_initial_rsp);`
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
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-004 5` when、 Builder fixloop stop、 `ESCALATIO
```markdown
# Escalation Report: TASK-004
## 1. Failure Summary
* **Failed Stage:** [zig build / iretq #GP Fault / syscall #UD Fault / Ring 3 #PF Fault / sysretq Crash / Wrong Errn
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
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
