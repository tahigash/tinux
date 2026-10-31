# Tinux Implementation Specification: TASK-001
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter file layouts, linker scripts, assembly labels, function signatures, or I/O port assignments specified here.
2. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1's "Zig Idiom Cheat Sheet".
3. **Pre-Flight Environment Check:**
 ⽣ 、 with `zig version` and `qemu-system-x86_64 --version` execute、exists verify
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh` fails **3 consecutive times**, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Bit cast | `@bitCast(DestType, val)` | `@as(DestType, @bitCast(val))` |
| Alignment cast | `@alignCast(4096, ptr)` | `@as(*align(4096) T, @alignCast(ptr))` |
| Enum to integer | `@enumToInt(e)` | `@intFromEnum(e)` |
| C ABI struct | `struct { ... }` | `extern struct { ... }` |
| Packed struct | `packed struct { ... }` ( unspecified width ) | `packed struct(u8) { ... }` |
| Build API path | `.{ .path = "src/main.zig" }` | `b.path("src/main.zig")` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-001`
* **Title:** `x86_64 Minimal Kernel Boot, Serial Console (COM1), and QEMU Auto-Verification Harness`
* **Target Subsystem:** `arch/x86_64`, `drivers/serial`, `scripts`
* **Target Files to Create:**
  * `build.zig` (Create)
  * `linker.ld` (Create)
  * `src/arch/x86_64/boot.S` (Create)
  * `src/arch/x86_64/io.zig` (Create)
  * `src/drivers/serial.zig` (Create)
  * `src/main.zig` (Create)
  * `scripts/verify_qemu.sh` (Create & `chmod +x`)
---
## 3. Hardware & Boot ABI Contract (Opus 5.5 Audited)
### 3.1 Boot Protocol (QEMU Direct `-kernel` via PVH ELF Note)
QEMU of `qemu-system-x86_64 -kernel` of 64-bit ELF (`ELFCLASS64`) of Multiboot1 。 of times、

1. **Initial CPU State at `_start32`:**
 * 32-bit Flat Protected Mode （pages、interrupt）。
 * : `0x0010_0000` (1 MiB) 。
2. **Trampoline Transition (`_start32` -> `_start64`):**
 * pagestable（ `boot_pml4`, `boot_pdpt`, `boot_pd` ） 、 `0x0000_0000` 〜 `0x3FFF_FFFF` （first 1 GiB ） 
 * `CR4.PAE` (Bit 5) enabled → `CR3` `boot_pml4` → `IA32_EFER` (`0xC0000080`) of `LME` (Bit 8) enabled → `CR
 * 64-bit GDT 、 Code Segment `0x08` (`_start64`) to Far Jump 。
 * `rsp` `stack_top` （ 16 of 64 KiB stack） 、 Zig of `kmain()` 。
### 3.2 I/O Port Contract (x86_64 Port-Mapped I/O)
| Device  | Base Port  | Register Offset  | Configuration / Protocol Spec  |
| :--- | :--- | :--- | :--- |
| **COM1 UART (16550A)** | `0x03F8` | `+1` (IER), `+3` (LCR), `+0` (DLL), `+1` (DLM), `+2` (FCR), `+4` (MCR), `+5` (
| **QEMU Debug Exit** | `0x00F4` | `+0` (Exit Port) | QEMU arguments `-device isa-debug-exit,iobase=0xf4,iosize=0x04` 
---
## 4. Exact Data Structures & Signatures
Builder must implement the following file contents and signatures accurately:
### 4.1 `linker.ld`
```ld
ENTRY(_start32)
SECTIONS
{
    . = 1M;
    .text BLOCK(4K) : ALIGN(4K)
    {
        KEEP(*(.note.Xen))
        *(.boot.text)
        *(.text .text.*)
    }
    .rodata BLOCK(4K) : ALIGN(4K)
    {
        *(.rodata .rodata.*)
    }
    .data BLOCK(4K) : ALIGN(4K)
    {
        *(.data .data.*)
    }
    .bss BLOCK(4K) : ALIGN(4K)
    {
        *(COMMON)
        *(.bss .bss.*)
        . = ALIGN(4K);
        *(.boot.bss)
    }
}
```
### 4.2 `src/arch/x86_64/boot.S`
```asm
/* Xen PVH ELF Note: Allows QEMU -kernel to boot 64-bit ELF directly */
.section .note.Xen, "a", @note
.align 4
.long 4                  /* namesz */
.long 4                  /* descsz */
.long 0x12               /* type: XEN_ELFNOTE_PHYS32_ENTRY */
.asciz "Xen"
.align 4
.long _start32           /* 32-bit physical entry point */
.section .boot.text, "ax", @progbits
.code32
.global _start32
_start32:
    cli
    cld
    /* 1. Build identity-mapped page tables for first 1 GiB using 2 MiB pages */

    /* Linker maps boot_pml4[0] -> boot_pdpt */
    movl $boot_pdpt, %eax
    orl  $0x03, %eax             /* Present + Writable */
    movl %eax, boot_pml4
    /* Link boot_pdpt[0] -> boot_pd */
    movl $boot_pd, %eax
    orl  $0x03, %eax             /* Present + Writable */
    movl %eax, boot_pdpt
    /* Fill 512 entries in boot_pd (512 * 2 MiB = 1 GiB) */
    movl $0, %ecx
.map_pd_loop:
    movl %ecx, %eax
    shll $21, %eax               /* ecx * 2 MiB */
    orl  $0x83, %eax             /* Present + Writable + HugePage (PS) */
    movl %eax, boot_pd(,%ecx,8)
    movl $0, boot_pd+4(,%ecx,8)
    incl %ecx
    cmpl $512, %ecx
    jne  .map_pd_loop
    /* 2. Enable PAE in CR4 (Bit 5) */
    movl %cr4, %eax
    orl  $(1 << 5), %eax
    movl %eax, %cr4
    /* 3. Load PML4 physical address into CR3 */
    movl $boot_pml4, %eax
    movl %eax, %cr3
    /* 4. Enable Long Mode in IA32_EFER MSR (0xC0000080, Bit 8) */
    movl $0xC0000080, %ecx
    rdmsr
    orl  $(1 << 8), %eax
    wrmsr
    /* 5. Enable Paging (Bit 31) and Protected Mode (Bit 0) in CR0 */
    movl %cr0, %eax
    orl  $((1 << 31) | 1), %eax
    movl %eax, %cr0
    /* 6. Load 64-bit GDT and far jump to 64-bit code segment (0x08) */
    lgdt gdt64_ptr
    ljmpl $0x08,$_start64
.code64
.global _start64
_start64:
    /* Clear data segment registers */
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    movw %ax, %ss
    /* Set up 16-byte aligned 64 KiB stack */
    movabsq $stack_top, %rsp
    xorq %rbp, %rbp
    /* Jump into Zig kernel entry */
    call kmain
.halt_loop:
    cli
    hlt
    jmp .halt_loop
.align 16
gdt64:
    .quad 0x0000000000000000     /* 0x00: Null descriptor */
    .quad 0x00209a0000000000     /* 0x08: 64-bit Kernel Code (Exec/Read, L=1, DPL=0) */
    .quad 0x0000920000000000     /* 0x10: 64-bit Kernel Data (Read/Write, DPL=0) */
gdt64_ptr:
    .word . - gdt64 - 1
    .quad gdt64
.section .boot.bss, "aw", @nobits

.align 4096
boot_pml4:
    .skip 4096
boot_pdpt:
    .skip 4096
boot_pd:
    .skip 4096
.align 16
stack_bottom:
    .skip 65536
stack_top:
```
### 4.3 `src/arch/x86_64/io.zig`
```zig
pub const QemuExitCode = enum(u8) {
    success = 0x10, // QEMU exit status: (0x10 << 1) | 1 = 33
    failure = 0x11, // QEMU exit status: (0x11 << 1) | 1 = 35
};
pub inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
        : "memory"
    );
}
pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "N{dx}" (port),
        : "memory"
    );
}
pub fn qemuExit(code: QemuExitCode) noreturn {
    outb(0x00F4, @intFromEnum(code));
    while (true) {
        asm volatile ("cli; hlt");
    }
}
```
### 4.4 `src/drivers/serial.zig`
```zig
const io = @import("../arch/x86_64/io.zig");
pub const COM1_PORT: u16 = 0x03F8;
pub fn init() void {
    // Builder implements 16550A initialization sequence according to Section 5
}
pub fn writeByte(b: u8) void {
    // Builder implements LSR polling and byte output according to Section 5
}
pub fn writeString(s: []const u8) void {
    for (s) |b| {
        if (b == '\n') {
            writeByte('\r');
        }
        writeByte(b);
    }
}
```
### 4.5 `src/main.zig`
```zig
const std = @import("std");
const io = @import("arch/x86_64/io.zig");
const serial = @import("drivers/serial.zig");
export fn kmain() callconv(.C) noreturn {
    serial.init();
    serial.writeString("[TINUX_BOOT] Zig x86_64 Kernel Initialized\n");
    serial.writeString("[TINUX_TEST] START: TASK-001\n");

    serial.writeString("[TINUX_TEST] PASS: TASK-001\n");
    io.qemuExit(.success);
}
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    serial.writeString("\n[TINUX_PANIC] ");
    serial.writeString(msg);
    serial.writeString("\n");
    io.qemuExit(.failure);
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
Implement according to the following step-by-step logic:
1. **Step 1: `build.zig` Implementation **
   * Configure target to `.cpu_arch = .x86_64`, `.os_tag = .freestanding`, `.abi = .none`.
   * Define kernel executable `"tinux"` with `src/main.zig` as the root source file.
 * `exe.addAssemblyFile(b.path("src/arch/x86_64/boot.S"))` with add、 `exe.setLinkerScript(b.path(
   * Note: Adapt `b.addExecutable` syntax to match your active Zig version (0.13 / 0.14 / 0.15).
2. **Step 2: `src/drivers/serial.zig` Implementation **
 * `init()` with of with `io.outb` ：
 1. `COM1_PORT + 1` `0x00` （interruptdisabled）
 2. `COM1_PORT + 3` `0x80` （ DLAB enabled）
 3. `COM1_PORT + 0` `0x03` （ Divisor : 38400 baud ）
 4. `COM1_PORT + 1` `0x00` （ Divisor ）
 5. `COM1_PORT + 3` `0x03` （ DLAB disabled、 8 bits, no parity, 1 stop bit ）
 6. `COM1_PORT + 2` `0xC7` （ FIFO enabled‧cleared、 14-byte threshold ）
 7. `COM1_PORT + 4` `0x0B` （ IRQs enabled, RTS/DSR set ）
 * `writeByte(b: u8)` with ：
 * `(io.inb(COM1_PORT + 5) & 0x20) == 0` of loop with waiting、empty `io.outb(COM1_PORT, b)` execute。
3. **Step 3: `scripts/verify_qemu.sh` Creation **
 * 6.1 of create、 `chmod +x scripts/verify_qemu.sh` with executepermission 。
---
## 6. Verification Harness & Pass Criteria
### 6.1 `scripts/verify_qemu.sh` Implementation
Builder of `scripts/verify_qemu.sh` of output。
```bash
#!/usr/bin/env bash
set -u
TEST_CASE="${1:-TASK-001}"
TIMEOUT_SEC="${2:-5}"
KERNEL_BIN="zig-out/bin/tinux"
LOG_FILE="/tmp/tinux_qemu_${TEST_CASE}.log"
echo "[HARNESS] Building Tinux kernel..."
if ! zig build; then
    echo "[HARNESS] FAIL: zig build failed."
    exit 1
fi
if [ ! -f "$KERNEL_BIN" ]; then
    echo "[HARNESS] FAIL: Kernel binary not found at $KERNEL_BIN"
    exit 1
fi
echo "[HARNESS] Booting QEMU (timeout=${TIMEOUT_SEC}s)..."
rm -f "$LOG_FILE"
timeout "$TIMEOUT_SEC" qemu-system-x86_64 \
    -kernel "$KERNEL_BIN" \
    -nographic \
    -no-reboot \
    -serial stdio \
    -monitor none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \

    > "$LOG_FILE" 2>&1
QEMU_EXIT=$?
cat "$LOG_FILE"
# isa-debug-exit with 0x10 yields exit code (0x10 << 1) | 1 = 33
if [ "$QEMU_EXIT" -ne 33 ]; then
    echo "[HARNESS] FAIL: Unexpected QEMU exit code $QEMU_EXIT (expected 33)."
    exit 1
fi
if grep -q "\[TINUX_TEST\] PASS: ${TEST_CASE}" "$LOG_FILE"; then
    echo "[HARNESS] SUCCESS: ${TEST_CASE} verified cleanly!"
    exit 0
else
    echo "[HARNESS] FAIL: PASS marker not found in serial output."
    exit 1
fi
```
### 6.2 Verification Command & Pass Criteria
Execute the following command to verify pass criteria:
```bash
./scripts/verify_qemu.sh TASK-001 5
```
* **Pass Criteria:**
  1. `zig build` completes with zero errors.
  2. The serial output displays expected boot markers and the pass banner.
  3. QEMU exits cleanly with code 33, and the harness reports verification success.
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh` when、 Builder fixloop stop、 `ESCALATION_REPORT.md
```markdown
# Escalation Report: TASK-001
## 1. Failure Summary
* **Failed Stage:** [zig build / QEMU PVH Load / 64-bit Trampoline Triple Fault / Serial Output Missing]
* **Zig & QEMU Versions:** [Output of `zig version` and `qemu-system-x86_64 --version`]
* **Attempt History:**
  * Attempt 1: [Changes attempted and observed outcome]
  * Attempt 2: [Changes attempted and observed outcome]
  * Attempt 3: [Changes attempted and observed outcome]
## 2. Exact Error / Serial Log Output
```text
[Full build error output, or full contents of /tmp/tinux_qemu_*.log]
```
## 3. Current `build.zig` & Code Diff
```zig
[Full contents of current build.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
