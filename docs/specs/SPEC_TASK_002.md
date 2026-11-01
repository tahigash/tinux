# Tinux Implementation Specification: TASK-002
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter the specified GDT layout, `TrapFrame` struct layout, IDT gate configurations, or PMM bitmap allocation policies.
2. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet".
3. **Preserve Existing Boot Flow:**
   Do not modify `src/arch/x86_64/boot.S` or `src/drivers/serial.zig` logic established in TASK-001, except where explicitly instructed.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-002 5` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Bit cast | `@bitCast(DestType, val)` | `@as(DestType, @bitCast(val))` |
| Symbol address | `extern var __kernel_end: u8;` (dereferencing value) | `@intFromPtr(&__kernel_end)` |
| LGDT / LIDT descriptor | `extern struct { limit: u16, base: u64 }` (unaligned) | `[10]u8 align(16)` descriptor buffer |
| Memory zero fill | Manual loop | `@memset(slice, 0)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-002`
* **Title:** `x86_64 GDT/TSS Reconstruction, IDT Exception Handlers (Page Fault / Register Dump), and Physical Page Frame Allocator (PMM)`
* **Target Subsystem:** `arch/x86_64`, `mm`, `drivers/serial`
* **Target Files to Create / Modify:**
  * `linker.ld` (Modify: export `__kernel_start` and `__kernel_end`)
  * `build.zig` (Modify: add `src/arch/x86_64/isr.S`)
  * `src/drivers/serial.zig` (Modify: add `writeHex` for register dumps)
  * `src/arch/x86_64/gdt.zig` (Create)
  * `src/arch/x86_64/isr.S` (Create)
  * `src/arch/x86_64/idt.zig` (Create)
  * `src/mm/pmm.zig` (Create)
  * `src/main.zig` (Modify: run TASK-002 verification suite)
---
## 3. Hardware & Low-Level Contract (Opus 5.5 Audited)
### 3.1 GDT Layout (Future `SYSCALL` / `SYSRET` Ready)
To ensure compatibility with subsequent `SYSRET` instructions, user segment descriptors must follow kernel selectors in the order required by `IA32_STAR`:
| Index | Selector | Segment Role | Descriptor Value (`u64`) |
| :--- | :--- | :--- | :--- |
| `0` | `0x00` | Null Descriptor | `0x0000000000000000` |
| `1` | `0x08` | Kernel Code (64-bit, DPL=0) | `0x00209A0000000000` |
| `2` | `0x10` | Kernel Data (DPL=0) | `0x0000920000000000` |
| `3` | `0x18` | User Data (DPL=3) | `0x0000F20000000000` |
| `4` | `0x20` | User Code (64-bit, DPL=3) | `0x0020FA0000000000` |
| `5..6` | `0x28` | 64-bit TSS Descriptor (16 bytes) | Dynamic (Base = `&tss`, Limit = `103`, Type = `0x89`) |
### 3.2 CPU Exception Stack Frame & 16-Byte Alignment Contract
When an x86_64 CPU exception occurs, the hardware automatically pushes `SS, RSP, RFLAGS, CS, RIP` (5 * 8 = 40 bytes) onto the target stack.
* **Exceptions with an error code pushed automatically:** `8 (#DF)`, `10 (#TS)`, `11 (#NP)`, `12 (#SS)`, `13 (#GP)`, `14 (#PF)`, `17 (#AC)`, `21 (#CP)`, `29 (#VC)`, `30 (#SX)`.
* **Exceptions without an error code (`0..31`):** `isr.S` executes `pushq $0` so the stack frame remains uniform across all vectors.
* **16-byte alignment calculation:** Hardware frame (40 bytes) + error_code & vector (16 bytes) + 15 general-purpose registers (120 bytes) = 176 bytes (`@sizeOf(TrapFrame) == 176`). Because 176 is divisible by 16, this preserves the 16-byte stack alignment required by the System V AMD64 ABI before calling Zig's `isrDispatch`.
### 3.3 Physical Memory Manager (PMM) Contract
* Page size: `4096` bytes (`0x1000`).
* Physical memory management limit: `128 MiB` (`0x0800_0000` = `32,768` pages), within the initial 1 GiB identity mapping from `boot.S`.
* Reserved regions (marked used in bitmap):
  * Physical address `0x0000_0000` up to `std.mem.alignForward(usize, @intFromPtr(&__kernel_end), 4096)` (covers BIOS data area, VGA buffer, and kernel image).
* Free regions:
  * From `std.mem.alignForward(usize, @intFromPtr(&__kernel_end), 4096)` to `0x0800_0000` (128 MiB).
---
## 4. Exact Data Structures & Signatures
### 4.1 `linker.ld` (Updated with Kernel Boundary Symbols)
```ld
ENTRY(_start32)
SECTIONS
{
    . = 1M;
    __kernel_start = .;
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
    . = ALIGN(4K);
    __kernel_end = .;
}
```
### 4.2 `src/drivers/serial.zig` (Add Hex Formatter)
Add the following helper to `serial.zig`:
```zig
pub fn writeHex(val: u64) void {
    const hex_chars = "0123456789ABCDEF";
    writeString("0x");
    var i: u6 = 60;
    while (true) : (i -= 4) {
        const nibble: usize = @intCast((val >> i) & 0xF);
        writeByte(hex_chars[nibble]);
        if (i == 0) break;
    }
}
```
### 4.3 `src/arch/x86_64/gdt.zig`
```zig
const std = @import("std");
pub const KERNEL_CODE_SEL: u16 = 0x08;
pub const KERNEL_DATA_SEL: u16 = 0x10;
pub const USER_DATA_SEL: u16 = 0x18 | 3;
pub const USER_CODE_SEL: u16 = 0x20 | 3;
pub const TSS_SEL: u16 = 0x28;
pub const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iomap_base: u16 align(1) = @sizeOf(Tss),
    comptime {
        std.debug.assert(@sizeOf(Tss) == 104);
    }
};
var gdt_entries: [7]u64 align(16) = .{
    0x0000000000000000, // 0x00: Null
    0x00209A0000000000, // 0x08: Kernel Code 64
    0x0000920000000000, // 0x10: Kernel Data
    0x0000F20000000000, // 0x18: User Data
    0x0020FA0000000000, // 0x20: User Code 64
    0x0000000000000000, // 0x28: TSS Low (Filled at init)
    0x0000000000000000, // 0x30: TSS High (Filled at init)
};
pub var tss: Tss align(16) = .{};
var df_stack: [16384]u8 align(16) = undefined;
pub fn init() void {
    // Builder implements TSS descriptor setup, lgdt, segment reload, and ltr according to Section 5
}
pub fn setKernelStack(rsp0: u64) void {
    tss.rsp0 = rsp0;
}
```
### 4.4 `src/arch/x86_64/isr.S`
```asm
.section .text
.code64
.macro ISR_NOERR vec
.global isr\vec
.align 16
isr\vec:
    pushq $0
    pushq $\vec
    jmp isr_common_stub
.endm
.macro ISR_ERR vec
.global isr\vec
.align 16
isr\vec:
    pushq $\vec
    jmp isr_common_stub
.endm
ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31
.extern isrDispatch
isr_common_stub:
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, %rdi
    call isrDispatch
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
    addq $16, %rsp   /* Pop vector and error_code */
    iretq
.global isr_stub_table
.section .rodata
.align 8
isr_stub_table:
    .quad isr0,  isr1,  isr2,  isr3,  isr4,  isr5,  isr6,  isr7
    .quad isr8,  isr9,  isr10, isr11, isr12, isr13, isr14, isr15
    .quad isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
    .quad isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31
```
### 4.5 `src/arch/x86_64/idt.zig`
```zig
const std = @import("std");
const gdt = @import("gdt.zig");
const serial = @import("../../drivers/serial.zig");
const io = @import("io.zig");
pub const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
    comptime {
        std.debug.assert(@sizeOf(TrapFrame) == 176);
        std.debug.assert(@offsetOf(TrapFrame, "vector") == 120);
        std.debug.assert(@offsetOf(TrapFrame, "rip") == 136);
    }
};
pub const IdtEntry = extern struct {
    offset_low: u16 = 0,
    selector: u16 = 0,
    ist: u8 = 0,
    type_attr: u8 = 0,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,
    comptime {
        std.debug.assert(@sizeOf(IdtEntry) == 16);
    }
};
var idt_entries: [256]IdtEntry align(16) = [_]IdtEntry{.{}} ** 256;
extern const isr_stub_table: [32]usize;
pub var breakpoint_hit_count: usize = 0;
pub fn setGate(vec: u8, handler_addr: usize, ist: u8, type_attr: u8) void {
    idt_entries[vec] = .{
        .offset_low = @truncate(handler_addr),
        .selector = gdt.KERNEL_CODE_SEL,
        .ist = ist & 0x7,
        .type_attr = type_attr,
        .offset_mid = @truncate(handler_addr >> 16),
        .offset_high = @truncate(handler_addr >> 32),
        .reserved = 0,
    };
}
pub fn init() void {
    // Builder populates vectors 0..31 and loads IDTR via lidt
}
export fn isrDispatch(frame: *TrapFrame) callconv(.C) void {
    // Builder handles vector 3 (#BP) for self-test, or dumps registers + CR2 and exits on fatal exceptions
}
```
### 4.6 `src/mm/pmm.zig`
```zig
const std = @import("std");
pub const PAGE_SIZE: usize = 4096;
pub const TOTAL_RAM_BYTES: usize = 128 * 1024 * 1024; // 128 MiB
pub const TOTAL_PAGES: usize = TOTAL_RAM_BYTES / PAGE_SIZE; // 32,768 pages
pub const BITMAP_SIZE: usize = TOTAL_PAGES / 8; // 4,096 bytes
extern const __kernel_start: u8;
extern const __kernel_end: u8;

var bitmap: [BITMAP_SIZE]u8 align(64) = [_]u8{0xFF} ** BITMAP_SIZE;
var free_pages_count: usize = 0;
pub fn init() void {
    // Builder marks pages from alignForward(__kernel_end, 4096) to TOTAL_RAM_BYTES as free
}
pub fn allocPage() ?usize {
    // Builder finds first 0 bit, marks it 1, decrements free_pages_count, returns phys addr
}
pub fn allocZeroedPage() ?usize {
    const addr = allocPage() orelse return null;
    const slice = @as([*]u8, @ptrFromInt(addr))[0..PAGE_SIZE];
    @memset(slice, 0);
    return addr;
}
pub fn freePage(phys_addr: usize) void {
    // Builder validates alignment and bounds, clears bit to 0, increments free_pages_count
}
pub fn getFreePageCount() usize {
    return free_pages_count;
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `gdt.zig` Implementation**
   * Configure IST1 for Double Fault handling: `tss.ist1 = @intFromPtr(&df_stack) + df_stack.len`.
   * Construct 16-byte TSS descriptor from `tss_base = @intFromPtr(&tss)` and `tss_limit = @sizeOf(Tss) - 1` (103):
     * `gdt_entries[5]` (low 64-bit):
       `(tss_limit & 0xFFFF) | ((tss_base & 0xFFFFFF) << 16) | (0x89 << 40) | (((tss_limit >> 16) & 0xF) << 48) | (((tss_base >> 24) & 0xFF) << 56)`
     * `gdt_entries[6]` (high 64-bit):
       `tss_base >> 32`
   * Populate a 10-byte GDTR descriptor buffer aligned to 16 bytes: `limit = @sizeOf(@TypeOf(gdt_entries)) - 1` and `base = @intFromPtr(&gdt_entries)`.
   * Load GDTR using inline assembly `lgdt (%[gdtr])`, reload CS via far return (`pushq $0x08; leaq 1f(%rip), %rax; pushq %rax; lretq; 1:`), reload data segment registers with `0x10`, and load TSS via `ltr %%ax`.
2. **Step 2: `idt.zig` Implementation**
   * In `init()`, iterate over vectors `0..32` and assign addresses from `isr_stub_table[i]`.
   * Configure vector `3` (`#BP`) with `type_attr = 0xEE` (Present, DPL=3, Trap Gate).
   * Configure vector `8` (`#DF`) with `ist = 1` and `type_attr = 0x8E` (Present, DPL=0, Interrupt Gate).
   * Configure all other exception vectors with `ist = 0` and `type_attr = 0x8E`.
   * Load IDTR buffer via `lidt (%[idtr])`.
   * In `isrDispatch(frame: *TrapFrame)`:
     * If `frame.vector == 3`, increment `breakpoint_hit_count` and log `[TINUX_INTR] Handled #BP (Vector 3) cleanly\n`.
     * For fatal exceptions, read CR2 if `frame.vector == 14`, emit diagnostic register dumps via `serial.writeHex`, and exit with `io.qemuExit(.failure)`.
3. **Step 3: `pmm.zig` Implementation**
   * Page tracking: page index `p`, byte offset `p / 8`, bitmask `@as(u8, 1) << @intCast(p % 8)`.
   * In `init()`, initialize all bytes in `bitmap` to `0xFF` (allocated).
   * Calculate `const kernel_end_phys = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), PAGE_SIZE)`.
   * Mark pages from `kernel_end_phys / PAGE_SIZE` up to `TOTAL_PAGES` as free (clearing bits to `0`) and set `free_pages_count`.
   * In `allocPage()`, scan for the first byte not equal to `0xFF`, locate the first zero bit with `@ctz(~byte)`, set the bit to `1`, decrement `free_pages_count`, and return `page_idx * PAGE_SIZE`.
   * In `freePage(phys_addr)`, assert alignment to 4096, clear the corresponding bit to `0`, and increment `free_pages_count`.
4. **Step 4: `src/main.zig` Verification Suite**
   * In `kmain()`, run the sequence:
     1. `serial.init()`
     2. `serial.writeString("[TINUX_TEST] START: TASK-002\n")`
     3. `gdt.init()` followed by `serial.writeString("[TINUX_GDT] GDT & TSS loaded\n")`
     4. `idt.init()` followed by `serial.writeString("[TINUX_IDT] IDT loaded\n")`
     5. Execute `asm volatile ("int3")` and assert `idt.breakpoint_hit_count == 1`.
     6. Execute `pmm.init()` and assert `pmm.getFreePageCount() >= 30000`.
     7. Allocate two pages: `const p1 = pmm.allocZeroedPage().?` and `const p2 = pmm.allocZeroedPage().?`, asserting `p1 != p2`.
     8. Free `p1`, then allocate `const p3 = pmm.allocZeroedPage().?`, asserting `p3 == p1` (LIFO or lowest-first reuse).
     9. Log `[TINUX_TEST] PASS: TASK-002\n` and exit cleanly via `io.qemuExit(.success)`.
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-002 5
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-002
[TINUX_GDT] GDT & TSS loaded
[TINUX_IDT] IDT loaded
[TINUX_INTR] Handled #BP (Vector 3) cleanly
[TINUX_TEST] PASS: TASK-002
[HARNESS] SUCCESS: TASK-002 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-002 5` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-002
## 1. Failure Summary
* **Failed Stage:** [zig build / GDT Reload Triple Fault / IDT int3 Crash / PMM Assertion Failure]
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
