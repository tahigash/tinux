# Tinux Implementation Specification: TASK-020
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-019` Passed (`./scripts/verify_qemu.sh TASK-019 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition Local APIC (`0xFEE0_0000`) / IOAPIC (`0xFEC0_0000`) of MMIO 、 AP placed
2. **MMIO Cache-Disable & User PML4 Sharing Discipline （ MMIO shared of strictly adhere） :**
 Local APIC (`0xFEE0_0000`) and IOAPIC (`0xFEC0_0000`) 3..4 GiB region（ `pdptIndex == 3` ） 。must `PTE_PRESE
3. **Relocation-Free 16-Bit AP Trampoline （placed of strictly adhere） :**
 `src/arch/x86_64/ap_trampoline.S` with 、 of 64-bit placed complete 、 4.1 with definition
4. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
5. **3-Strike Escalation Protocol （ 3 timeson failure of stop） :**
 * or `./scripts/verify_qemu.sh TASK-020 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
 * 3 times⽬ of `./scripts/triage_crash.py --out ESCALATION_REPORT.md` execute、 7 of 
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| MMIO 32bit | of referenced（ with ） | `@as(*volatile u32, @ptrFromInt(mmio_addr)).*` |
| MMIO 32bit write | of ⼊（） | `@as(*volatile u32, @ptrFromInt(mmio_addr)).* = val;` |
| | ⾮ with of waitingloop | `@atomicLoad(u32, ptr,.seq_cst)` / `@atomicStore` |
| memory | with of write | `asm volatile ("mfence" ::: "memory");` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-020`
* **Title:** `Local APIC / IOAPIC Initialization, SMP Multi-Core (Application Processor) Boot via INIT-SIPI-SIPI Pro
* **Target Subsystem:** `arch/x86_64`, `mm`, `fs`, `syscall`, `user`

* **Target Files to Create / Modify:**
  * `build.zig` (Modify: add `src/arch/x86_64/ap_trampoline.S`)
  * `src/arch/x86_64/ap_trampoline.S` (Create: 16-bit Real Mode -> 32-bit Protected Mode -> 64-bit Long Mode AP star
  * `src/arch/x86_64/apic.zig` (Create: Local APIC & IOAPIC MMIO driver, `INIT-SIPI-SIPI` SMP boot controller, and `
  * `src/arch/x86_64/idt.zig` (Modify: add `loadIdtOnAp()` helper to load `idtr` on Application Processors)
  * `src/mm/vmm.zig` (Modify: map `0xFEC0_0000` and `0xFEE0_0000` in `vmm.init()`, and share `pdpt.entries[3]` in `c
  * `src/fs/procfs.zig` (Modify: dynamically generate multi-core `/proc/cpuinfo` and per-core `/proc/stat` based on 
  * `src/syscall/dispatch.zig` (Modify: implement `sys_sched_getaffinity(204)`, `sys_sched_setaffinity(203)`, `sys_g
  * `src/user/smp_test.zig` (Create: standalone Linux `x86_64` SMP verification binary testing `sched_getaffinity`, 
  * `src/main.zig` (Modify: call `apic.initAndBootSmp(2)` and update test markers to `TASK-020`)
  * `scripts/verify_qemu.sh` (Modify: pass `-smp 2` to QEMU, compile `/bin/smp_test`, and verify 2-core SMP boot)
* **Read-Only Reference Files:**
  * `src/arch/x86_64/gdt.zig`
  * `src/drivers/timer.zig`
---
## 3. Hardware, Protocol & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 Local APIC (`0xFEE0_0000`) & IOAPIC (`0xFEC0_0000`) MMIO Contract
| Register / Port / Field | Address / Offset | Width | Access | Exact Hardware / Protocol Behavior |
| :--- | :--- | :--- | :--- | :--- |
| **`IA32_APIC_BASE` MSR** | MSR `0x0000_001B` | `u64` | `RW` | Bit 11 (`0x800`: APIC Global Enable) `1` 。 B
| **`LAPIC_ID`** | `0xFEE0_0020` | `u32` | `RO` | Bits `31..24` (`val >> 24`) of CPU of Local APIC ID (`0` =
| **`LAPIC_VER`** | `0xFEE0_0030` | `u32` | `RO` | Bits `7..0` （ `0x14` ）、 Bits `23..16` ⼤ LVT 
| **`LAPIC_TPR`** | `0xFEE0_0080` | `u32` | `RW` | Task Priority Register 。 `0x0000_0000` with of interrupt
| **`LAPIC_EOI`** | `0xFEE0_00B0` | `u32` | `WO` | `0x0000_0000` with Local APIC interrupt of EOI notified。
| **`LAPIC_SVR`** | `0xFEE0_00F0` | `u32` | `RW` | Spurious Interrupt Vector Register 。 **`0x0000_01FF`** （ Bit 8 APIC 
| **`LAPIC_ICR_LOW`** | `0xFEE0_0300` | `u32` | `RW` | write IPI transmit。 Bit 12 (`1 << 12`) `0` 
| **`LAPIC_ICR_HIGH`** | `0xFEE0_0310` | `u32` | `RW` | Bits `31..24` transmit APIC ID （ `@as(u32, target_apic_id) << 
| **`IOAPIC_REGSEL` / `WIN`** | `0xFEC0_0000` / `+0x10` | `u32` | `RW` | `0xFEC0_0000` registernumber `0x01` (`IOAPICV
### 3.2 AP Trampoline (`0x0000_8000`) & Mailbox (`0x0000_8F00`) Layout Contract
BSP `SIPI` （ Startup IPI, Vector `0x08` ） transmit and 、 AP （ Application Processor ） 16-bit Real Mode （ `CS 
| Region / Mailbox Slot | Physical / Virtual Address | Size & Type | Usage & Lifetime |
| :--- | :--- | :--- | :--- |
| **AP Trampoline Code** | `0x0000_8000.. 0x0000_81FF` | `<= 512 B` | `ap_trampoline_start.. ap_trampoline_end` 
| **`MAILBOX_CR3`** | `0x0000_8F00` | `u64` (8B) | BSP `vmm.getKernelPml4Phys()` 。 AP 32-bit with 
| **`MAILBOX_RSP`** | `0x0000_8F08` | `u64` (8B) | BSP AP ⽤ 16 KiB stack of （ 16 
| **`MAILBOX_ENTRY`** | `0x0000_8F10` | `u64` (8B) | 64-bit AP `call *%rax` with Zig function `@
| **`MAILBOX_READY`** | `0x0000_8F18` | `u32` (4B) | BSP `0` cleared、 AP `apMain` with initialized `
| **`MAILBOX_CPU_ID`** | `0x0000_8F1C` | `u32` (4B) | AP ⾃⾝ of `readLapicId()` verify⽤。 |
### 3.3 Linux x86_64 SMP System Calls & `/proc/cpuinfo` Contract
| Syscall / File | Number / Path | Arguments / Format | Exact Return Value & `-Errno` Edge Cases |
| :--- | :--- | :--- | :--- |
| **`sys_sched_yield`** | `24` | (none) | of 、 `0` 。 |
| **`sys_sched_setaffinity`**| `203` | `pid, cpusetsize, mask_ptr` | `mask_ptr` verification、 `0` (Success) 。 |
| **`sys_sched_getaffinity`**| `204` | `pid, cpusetsize, mask_ptr` | `cpusetsize < 8` `-EINVAL (-22)` 。 `validate
| **`sys_getcpu`** | `309` | `cpu_ptr, node_ptr, tcache` | `cpu_ptr != 0` of `apic.readLapicId()` (`u32`) 
| **`/proc/cpuinfo`** | `/proc/cpuinfo` | Text Pseudo-File | `0.. apic.getOnlineCpuCount()` of `i` 、 `p
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/arch/x86_64/ap_trampoline.S`
Builder of `src/arch/x86_64/ap_trampoline.S` and of create、 `build.zig` `exe.addAssemblyFile(b
```asm
.section .text
.code16
.global ap_trampoline_start
.global ap_trampoline_end
/* Physical base address where BSP copies this trampoline (Vector 0x08 -> 0x00008000) */
.equ TRAMPOLINE_BASE, 0x8000
.equ MAILBOX_CR3,     0x8F00
.equ MAILBOX_RSP,     0x8F08
.equ MAILBOX_ENTRY,   0x8F10

.align 16
ap_trampoline_start:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    /* 1. Load temporary 32/64-bit GDT from fixed physical address inside 0x8000 page */
    lgdt (TRAMPOLINE_BASE + (.Lap_gdtr - ap_trampoline_start))
    /* 2. Enable Protected Mode (CR0.PE = Bit 0) */
    movl %cr0, %eax
    orl  $0x00000001, %eax
    movl %eax, %cr0
    /* 3. Far jump to 32-bit Protected Mode (CS = 0x08) */
    ljmpl $0x08, $(TRAMPOLINE_BASE + (.Lap_mode32 - ap_trampoline_start))
.code32
.align 16
.Lap_mode32:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    /* 4. Enable PAE (Bit 5) + OSFXSR (Bit 9) + OSXMMEXCPT (Bit 10) in CR4 */
    movl %cr4, %eax
    orl  $0x00000620, %eax
    movl %eax, %cr4
    /* 5. Load Kernel PML4 physical address from MAILBOX_CR3 (0x8F00) into CR3 */
    movl (MAILBOX_CR3), %eax
    movl %eax, %cr3
    /* 6. Enable Long Mode (LME = Bit 8) in IA32_EFER MSR (0xC0000080) */
    movl $0xC0000080, %ecx
    rdmsr
    orl  $0x00000100, %eax
    wrmsr
    /* 7. Enable Paging (PG=Bit 31), Write Protect (WP=Bit 16), FPU/SSE (MP=Bit 1, clear EM=Bit 2) */
    movl %cr0, %eax
    andl $0xFFFFFFFB, %eax
    orl  $0x80010002, %eax
    movl %eax, %cr0
    /* 8. Far jump to 64-bit Long Mode (CS = 0x18) */
    ljmpl $0x18, $(TRAMPOLINE_BASE + (.Lap_mode64 - ap_trampoline_start))
.code64
.align 16
.Lap_mode64:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs
    /* 9. Load per-AP 64-bit stack pointer from MAILBOX_RSP (0x8F08) */
    movabsq $MAILBOX_RSP, %rax
    movq (%rax), %rsp
    xorq %rbp, %rbp
    /* 10. Jump to Zig apMain() stored at MAILBOX_ENTRY (0x8F10) */
    movabsq $MAILBOX_ENTRY, %rax
    movq (%rax), %rax
    call *%rax
.Lap_halt:
    cli
    hlt
    jmp .Lap_halt
.align 16

.Lap_gdt:
    .quad 0x0000000000000000    /* 0x00: Null descriptor */
    .quad 0x00CF9A000000FFFF    /* 0x08: 32-bit Kernel Code (DPL=0) */
    .quad 0x00CF92000000FFFF    /* 0x10: 32/64-bit Kernel Data (DPL=0) */
    .quad 0x00AF9A000000FFFF    /* 0x18: 64-bit Kernel Code (DPL=0, L=1) */
.Lap_gdt_end:
.Lap_gdtr:
    .word .Lap_gdt_end - .Lap_gdt - 1
    .long TRAMPOLINE_BASE + (.Lap_gdt - ap_trampoline_start)
ap_trampoline_end:
```
### 4.2 `src/arch/x86_64/apic.zig`
```zig
const std = @import("std");
const io = @import("io.zig");
const idt = @import("idt.zig");
const syscall_arch = @import("syscall.zig");
const vmm = @import("../../mm/vmm.zig");
const serial = @import("../../drivers/serial.zig");
pub const MAX_CPUS: usize = 8;
pub const AP_STACK_SIZE: usize = 16384;
pub const LAPIC_PHYS_BASE: usize = 0xFEE0_0000;
pub const IOAPIC_PHYS_BASE: usize = 0xFEC0_0000;
pub const LAPIC_REG_ID: usize = 0x0020;
pub const LAPIC_REG_VER: usize = 0x0030;
pub const LAPIC_REG_TPR: usize = 0x0080;
pub const LAPIC_REG_EOI: usize = 0x00B0;
pub const LAPIC_REG_SVR: usize = 0x00F0;
pub const LAPIC_REG_ICR_LOW: usize = 0x0300;
pub const LAPIC_REG_ICR_HIGH: usize = 0x0310;
pub const TRAMPOLINE_ADDR: usize = 0x0000_8000;
pub const TRAMPOLINE_VECTOR: u8 = 0x08; // 0x08 * 0x1000 = 0x8000
pub const MAILBOX_CR3: usize = 0x0000_8F00;
pub const MAILBOX_RSP: usize = 0x0000_8F08;
pub const MAILBOX_ENTRY: usize = 0x0000_8F10;
pub const MAILBOX_READY: usize = 0x0000_8F18;
pub const MAILBOX_CPU_ID: usize = 0x0000_8F1C;
extern const ap_trampoline_start: u8;
extern const ap_trampoline_end: u8;
var ap_stacks: [MAX_CPUS][AP_STACK_SIZE]u8 align(16) = undefined;
var online_cpus: usize = 1;
var ioapic_max_entries: u32 = 0;
pub inline fn lapicRead(reg_offset: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(LAPIC_PHYS_BASE + reg_offset)).*;
}
pub inline fn lapicWrite(reg_offset: usize, val: u32) void {
    @as(*volatile u32, @ptrFromInt(LAPIC_PHYS_BASE + reg_offset)).* = val;
}
pub inline fn ioapicRead(reg: u8) u32 {
    @as(*volatile u32, @ptrFromInt(IOAPIC_PHYS_BASE)).* = reg;
    return @as(*volatile u32, @ptrFromInt(IOAPIC_PHYS_BASE + 0x10)).*;
}
pub fn readLapicId() u32 {
    return lapicRead(LAPIC_REG_ID) >> 24;
}
pub fn getOnlineCpuCount() usize {
    return @atomicLoad(usize, &online_cpus, .seq_cst);
}
pub fn getIoapicRedirCount() u32 {
    return ioapic_max_entries;
}
pub export fn apMain() callconv(.C) noreturn {

    // Builder implements AP 64-bit initialization, LAPIC enable, and atomic handshake
}
pub fn initAndBootSmp(target_cpus: usize) usize {
    // Builder initializes BSP Local APIC + IOAPIC, copies trampoline to 0x8000,
    // and wakes APs 1..(target_cpus-1) via INIT-SIPI-SIPI protocol
}
```
### 4.3 `src/user/smp_test.zig` (Standalone Linux `x86_64` SMP Verification Binary)
Create `src/user/smp_test.zig` with the following implementation:
```zig
const std = @import("std");
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call smpTestMain
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
fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}
fn failExit(code: usize) noreturn {
    _ = syscall1(231, code);
    unreachable;
}
export fn smpTestMain() callconv(.C) noreturn {
    // 1. Query online CPU affinity mask via sys_sched_getaffinity(204)
    var cpu_mask: u64 = 0;
    const aff_rc = syscall3(204, 0, @sizeOf(u64), @intFromPtr(&cpu_mask));
    if (aff_rc < 8) failExit(10);
    const num_cpus: usize = @popCount(cpu_mask);
    if (num_cpus < 2 or cpu_mask != 0x03) failExit(11); // Expect 2 CPUs (mask 0b11 == 3)
    // 2. Query active CPU and NUMA node via sys_getcpu(309)
    var cur_cpu: u32 = 999;
    var cur_node: u32 = 999;
    if (syscall3(309, @intFromPtr(&cur_cpu), @intFromPtr(&cur_node), 0) != 0) failExit(12);
    if (cur_cpu >= 2 or cur_node != 0) failExit(13);
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "[TINUX_SMP] sched_getaffinity mask=0x{X:0>2} ({d} CPUs online), running on CPU {d} (node {d})!\n",
        .{ cpu_mask, num_cpus, cur_cpu, cur_node },
    ) catch unreachable;
    writeStdout(msg);
    _ = syscall1(231, 0);
    unreachable;
}
```
---

## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/mm/vmm.zig` APIC / IOAPIC MMIO and shared **
 * `vmm.init()` （ `loadCr3(kernel_pml4_phys)` of ） with 、 of 2 of MMIO pages Identity Map ：
     ```zig
     _ = mapPage(kernel_pml4_phys, 0xFEC0_0000, 0xFEC0_0000, PTE_PRESENT | PTE_WRITABLE | PTE_CACHE_DISABLE);
     _ = mapPage(kernel_pml4_phys, 0xFEE0_0000, 0xFEE0_0000, PTE_PRESENT | PTE_WRITABLE | PTE_CACHE_DISABLE);
     ```
 * ** 【important】 ** `0xFEC0_0000` and `0xFEE0_0000` `pdptIndex == 3` （ 3..4 GiB region） 。process of pages
     ```zig
     dst_pdpt.entries[3] = src_pdpt.entries[3]; // Share 3..4 GiB Kernel MMIO (LAPIC/IOAPIC)
     ```
2. **Step 2: `src/arch/x86_64/idt.zig` and `src/arch/x86_64/apic.zig` Implementation **
 * `idt.zig` `pub fn loadIdtOnAp() void` add、 `asm volatile ("lidt (%[p])" : : [p] "r" (&idtr) : "memory");
 * `apic.zig` of `apMain() callconv(.C) noreturn`:
 1. `idt.loadIdtOnAp();` with IDT 。
     2. `lapicWrite(LAPIC_REG_TPR, 0x00);`
 3. `lapicWrite(LAPIC_REG_SVR, 0x0000_01FF);` （ AP of Local APIC enabled）。
     4. `const my_id = readLapicId();`
     5. `@atomicStore(u32, @as(*u32, @ptrFromInt(MAILBOX_CPU_ID)), my_id, .seq_cst);`
     6. `_ = @atomicRmw(usize, &online_cpus, .Add, 1, .seq_cst);`
 7. `@atomicStore(u32, @as(*u32, @ptrFromInt(MAILBOX_READY)), 1,.seq_cst);` （ BSP to notified）。
     8. `while (true) { asm volatile ("hlt"); }`
 * `apic.zig` of `initAndBootSmp(target_cpus: usize) usize`:
 1. MSR `0x1B` (`IA32_APIC_BASE`) `syscall_arch.rdmsr(0x1B)` with 、 Bit 11 (`0x800`) ⽴ `wrmsr` 。
     2. `lapicWrite(LAPIC_REG_TPR, 0x00);`
 3. `lapicWrite(LAPIC_REG_SVR, 0x0000_01FF);` （ BSP of Local APIC enabled）。
 4. `const ver_reg = ioapicRead(0x01);` 、 `ioapic_max_entries = ((ver_reg >> 16) & 0xFF) + 1;` 
 5. **AP of placed (`0x0000_8000`):**
        * `const tramp_len = @intFromPtr(&ap_trampoline_end) - @intFromPtr(&ap_trampoline_start);`
        * `const src = @as([*]const u8, @ptrFromInt(@intFromPtr(&ap_trampoline_start)))[0..tramp_len];`
        * `const dst = @as([*]u8, @ptrFromInt(TRAMPOLINE_ADDR))[0..tramp_len];`
        * `@memcpy(dst, src);`
 6. ** AP (`apic_id = 1.. target_cpus`) of loop :**
        * `@as(*volatile u64, @ptrFromInt(MAILBOX_CR3)).* = vmm.getKernelPml4Phys();`
        * `@as(*volatile u64, @ptrFromInt(MAILBOX_RSP)).* = @intFromPtr(&ap_stacks[apic_id]) + AP_STACK_SIZE;`
        * `@as(*volatile u64, @ptrFromInt(MAILBOX_ENTRY)).* = @intFromPtr(&apMain);`
        * `@atomicStore(u32, @as(*u32, @ptrFromInt(MAILBOX_READY)), 0, .seq_cst);`
        * `asm volatile ("mfence" ::: "memory");`
        * **Send INIT IPI:**
          `lapicWrite(LAPIC_REG_ICR_HIGH, @as(u32, @intCast(apic_id)) << 24);`
          `lapicWrite(LAPIC_REG_ICR_LOW, 0x0000_4500);`
 `for (0..10_000) |_| io.ioWait();` （ 10ms ）
        * **Send SIPI #1 (Vector `0x08` -> `0x8000`):**
          `lapicWrite(LAPIC_REG_ICR_HIGH, @as(u32, @intCast(apic_id)) << 24);`
          `lapicWrite(LAPIC_REG_ICR_LOW, 0x0000_4600 | @as(u32, TRAMPOLINE_VECTOR));`
 * ⼤ `100_000` of loop with `@atomicLoad(u32, @as(*u32, @ptrFromInt(MAILBOX_READY)),.seq_cst) ==
 * wokenverify with `serial.print("[TINUX_SMP] Application Processor (APIC ID {d}) booted into 64-bit Long Mo
     7. `return getOnlineCpuCount();`
3. **Step 3: `/proc/cpuinfo` and `/proc/stat` of (`src/fs/procfs.zig`)**
 * `cpuinfo_buf` of `[512]u8` 。
 * `procfs.syncProcessNodes()` （ and `initAndRegister` ） with 、 `0..apic.getOnlineCpuCount()` of loop times
 * `"proc/stat"` `cpu0`, `cpu1` of ⽅ of ⾏output update。
4. **Step 4: `src/syscall/dispatch.zig`, `src/main.zig`, `scripts/verify_qemu.sh` of update **
 * `dispatch.zig` `SYS_SCHED_YIELD (24)`, `SYS_SCHED_SETAFFINITY (203)`, `SYS_SCHED_GETAFFINITY (204)`, `SYS_GET
 * `src/main.zig` of `kmain()` with `vmm.init()` and `heap.init()` of `const cpus = apic.initAndBootSmp(2);` 
 * `scripts/verify_qemu.sh` with ：
     1. `zig build-exe src/user/smp_test.zig -target x86_64-linux-none -O ReleaseSmall -fno-pie -femit-bin=.cache/in
 2. QEMU of **`-smp 2`** add。
 3. type（ `/bin/sh` ） to of column ⼊：
        ```sh
        echo "[TINUX_SH] Running SMP multi-core affinity & getcpu verification..."
        /bin/smp_test
        echo "[TINUX_SH] Inspecting multi-core /proc/cpuinfo:"
        /bin/cat /proc/cpuinfo
        echo "[TINUX_SMP_DONE] Local APIC, IOAPIC, INIT-SIPI-SIPI AP boot, and SMP syscalls verified!"
        exit 0
        ```

---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-020 10
```
### 6.2 Expected Output (Pass Criteria)
QEMU output of （ APIC ID 1 of 64-bit 、 2 of mask `0x03` 、 and `/proc/cpuinfo` of `p
```text
[TINUX_TEST] START: TASK-020
[TINUX_SMP] Application Processor (APIC ID 1) booted into 64-bit Long Mode!
[TINUX_APIC] Local APIC & IOAPIC initialized (2 CPUs online, IOAPIC redir=24)
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Running SMP multi-core affinity & getcpu verification...
[TINUX_SMP] sched_getaffinity mask=0x03 (2 CPUs online), running on CPU 0 (node 0)!
[TINUX_SH] Inspecting multi-core /proc/cpuinfo:
processor : 0
vendor_id : TinuxZig
model name : Tinux Virtual SMP x86_64 CPU
cpu MHz : 3000.000
apicid : 0
processor : 1
vendor_id : TinuxZig
model name : Tinux Virtual SMP x86_64 CPU
cpu MHz : 3000.000
apicid : 1
[TINUX_SMP_DONE] Local APIC, IOAPIC, INIT-SIPI-SIPI AP boot, and SMP syscalls verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-020
[HARNESS] SUCCESS: TASK-020 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-020 10` when、 Builder fixloop stop、 `./script
```markdown
# Escalation Report: TASK-020
## 1. Failure Summary
* **Failed Stage:** [zig build / LAPIC MMIO #PF (0xFEE00000 Unmapped in User CR3) / AP Trampoline Triple Fault / MAI
* **APIC & SMP Mailbox Dump:** [online_cpus, MAILBOX_CR3, MAILBOX_RSP, MAILBOX_READY, MAILBOX_CPU_ID]
* **Attempt History:**
  * Attempt 1: [Changes attempted and observed outcome]
  * Attempt 2: [Changes attempted and observed outcome]
  * Attempt 3: [Changes attempted and observed outcome]
## 2. Automated Crash Triage & Serial Log Output
```text
[scripts/triage_crash.py of output and /tmp/tinux_qemu_TASK-020.log of ⽂ ]
```
## 3. Current Code Diff
```diff
[Relevant code diff for src/arch/x86_64/ap_trampoline.S, src/arch/x86_64/apic.zig, src/mm/vmm.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
