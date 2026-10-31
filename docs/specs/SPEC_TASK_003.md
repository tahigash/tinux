# Tinux Implementation Specification: TASK-003
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-002` Passed (`./scripts/verify_qemu.sh TASK-002 5` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**

 specification with definitionmemory、 PTE flagsdefinition、 `vmm.zig` and `heap.zig` of functionsignature with 
2. **Strict Zig Version Idioms:**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。、 `std.mem.Allocator.VTable`
3. **Preserve Existing Subsystems （ of ） :**
 `TASK-001` and `TASK-002` with `gdt.zig`, `idt.zig`, `pmm.zig`, `serial.zig` of 
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-003 5` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| ⽣ | `ptr[0..len]` (`*T`) | `@as([*]u8, @ptrFromInt(addr))[0..len]` |
| | ⼿ | `std.mem.alignForward(usize, val, alignment)` |
| TLB (`invlpg`) | `asm volatile ("invlpg %rax")` | `asm volatile ("invlpg (%[v])" : : [v] "r" (vaddr) : "
| `Allocator.VTable` definition | of | `@hasField(std.mem.Allocator.VTable, "remap")` `comptime` 
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-003`
* **Title:** `x86_64 4-Level Page Table Manager (VMM) and std.mem.Allocator Compliant Kernel Heap`
* **Target Subsystem:** `mm`
* **Target Files to Create / Modify:**
  * `src/mm/vmm.zig` (Create)
  * `src/mm/heap.zig` (Create)
  * `src/main.zig` (Modify: add TASK-003 verification suite)
* **Read-Only Reference Files:**
  * `src/mm/pmm.zig`
  * `src/arch/x86_64/idt.zig`
  * `src/arch/x86_64/io.zig`
---
## 3. Virtual Memory & Heap Contract (Opus 5.5 Audited)
### 3.1 Virtual Address Space Layout
`TASK-001` of `boot.S` with 2 MiB Huge Page with first 1 GiB 、 of task with user space（ `0x0040_0000
| Virtual Address Range | Size | Purpose & Protection Flags |
| :--- | :--- | :--- |
| `0x0000_0000_0000_0000.. 0x0000_0000_0000_0FFF` | `4 KiB` | **Unmapped NULL Guard Page** （ NULL referenced 
| `0x0000_0000_0000_1000 .. 0x0000_0000_07FF_FFFF` | `~128 MiB` | **Identity Map (`vaddr == paddr`)** (`PTE_PRESENT 
| `0x0000_0000_1000_0000 .. 0x0000_0000_1003_FFFF` | `256 KiB` | **Kernel Heap Initial Region** (`PTE_PRESENT \| PTE
| `0x0000_0000_2000_0000.. 0x0000_0000_2FFF_FFFF` | `256 MiB` | **Dynamic VMM Test / Scratch Region** （
### 3.2 Page Table Entry (PTE) Propagation Contract
1. ** mask :** frame of must `PTE_ADDR_MASK = 0x000F_FFFF_FFFF_F000` use。
2. ** table of flags（important） :**
 `mapPage(pml4, vaddr, paddr, flags)` 、table（ PML4E, PDPTE, PDE ） createwhen `PTE_PRESENT | PT
### 3.3 Kernel Heap Free-List Contract
* heapregion⽅ or ⽅（ `BlockHeader` ） with 、 `alloc` of block（ Splitting ） and `free` of 
* 、 Zig of `std.ArrayList` allocated‧freed memory and 。
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/mm/vmm.zig`
```zig
const std = @import("std");
const pmm = @import("pmm.zig");
pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;

pub const PTE_PRESENT: u64 = 1 << 0;
pub const PTE_WRITABLE: u64 = 1 << 1;
pub const PTE_USER: u64 = 1 << 2;
pub const PTE_WRITE_THROUGH: u64 = 1 << 3;
pub const PTE_CACHE_DISABLE: u64 = 1 << 4;
pub const PTE_ACCESSED: u64 = 1 << 5;
pub const PTE_DIRTY: u64 = 1 << 6;
pub const PTE_HUGE: u64 = 1 << 7;
pub const PTE_GLOBAL: u64 = 1 << 8;
pub const PTE_NO_EXECUTE: u64 = 1 << 63;
pub const PTE_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
pub const PageTable = extern struct {
    entries: [512]u64 align(4096),
    comptime {
        std.debug.assert(@sizeOf(PageTable) == 4096);
    }
};
var kernel_pml4_phys: usize = 0;
pub inline fn pml4Index(vaddr: usize) usize {
    return (vaddr >> 39) & 0x1FF;
}
pub inline fn pdptIndex(vaddr: usize) usize {
    return (vaddr >> 30) & 0x1FF;
}
pub inline fn pdIndex(vaddr: usize) usize {
    return (vaddr >> 21) & 0x1FF;
}
pub inline fn ptIndex(vaddr: usize) usize {
    return (vaddr >> 12) & 0x1FF;
}
pub inline fn invlpg(vaddr: usize) void {
    asm volatile ("invlpg (%[vaddr])"
        :
        : [vaddr] "r" (vaddr),
        : "memory"
    );
}
pub inline fn loadCr3(pml4_phys: usize) void {
    asm volatile ("mov %[phys], %%cr3"
        :
        : [phys] "r" (pml4_phys),
        : "memory"
    );
}
pub inline fn readCr3() usize {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> usize),
    );
}
pub fn getKernelPml4Phys() usize {
    return kernel_pml4_phys;
}
pub fn init() void {
    // Builder implements 4-level page table construction and CR3 switch according to Section 5
}
pub fn mapPage(pml4_phys: usize, vaddr: usize, paddr: usize, flags: u64) bool {
    // Builder walks/allocates PML4 -> PDPT -> PD -> PT and sets leaf PTE + invlpg
}
pub fn unmapPage(pml4_phys: usize, vaddr: usize) ?usize {
    // Builder clears leaf PTE, executes invlpg(vaddr), and returns previous physical address
}
pub fn translate(pml4_phys: usize, vaddr: usize) ?usize {
    // Builder walks page tables and returns physical address (frame + offset) or null if not present

}
```
### 4.2 `src/mm/heap.zig`
```zig
const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
pub const KERNEL_HEAP_START: usize = 0x1000_0000; // 256 MiB
pub const KERNEL_HEAP_INITIAL_PAGES: usize = 64;  // 256 KiB
pub const KERNEL_HEAP_INITIAL_SIZE: usize = KERNEL_HEAP_INITIAL_PAGES * vmm.PAGE_SIZE;
const BlockHeader = struct {
    size: usize, // Total payload size (excluding BlockHeader)
    is_free: bool,
    next: ?*BlockHeader,
};
const HEADER_SIZE: usize = std.mem.alignForward(usize, @sizeOf(BlockHeader), 16);
var head_block: ?*BlockHeader = null;
pub fn init() void {
    // Builder maps KERNEL_HEAP_INITIAL_PAGES at KERNEL_HEAP_START and initializes head_block
}
pub fn kmallocAligned(size: usize, alignment: usize) ?[*]u8 {
    // Builder implements first-fit search, alignment padding/splitting, and coalesce on free
}
pub fn kfree(ptr: [*]u8) void {
    // Builder marks block free and coalesces adjacent free blocks
}
// --- Comptime Bridge for Zig 0.13 / 0.14 / 0.15+ std.mem.Allocator.VTable ---
const has_remap = @hasField(std.mem.Allocator.VTable, "remap");
const AlignParam = if (@hasDecl(std.mem, "Alignment")) std.mem.Alignment else u8;
inline fn alignParamToBytes(a: AlignParam) usize {
    if (@hasDecl(std.mem, "Alignment")) {
        return a.toByteUnits();
    } else {
        return @as(usize, 1) << @intCast(a);
    }
}
fn vtableAlloc(_: *anyopaque, len: usize, ptr_align: AlignParam, _: usize) ?[*]u8 {
    if (len == 0) return null;
    return kmallocAligned(len, alignParamToBytes(ptr_align));
}
fn vtableResize(_: *anyopaque, _: []u8, _: AlignParam, _: usize, _: usize) bool {
    // Return false to instruct std.mem.Allocator to perform alloc + memcpy + free
    return false;
}
fn vtableRemap(_: *anyopaque, _: []u8, _: AlignParam, _: usize, _: usize) ?[*]u8 {
    return null;
}
fn vtableFree(_: *anyopaque, buf: []u8, _: AlignParam, _: usize) void {
    if (buf.len == 0) return;
    kfree(buf.ptr);
}
const kernel_allocator_vtable: std.mem.Allocator.VTable = if (has_remap) .{
    .alloc = vtableAlloc,
    .resize = vtableResize,
    .remap = vtableRemap,
    .free = vtableFree,
} else .{
    .alloc = vtableAlloc,
    .resize = vtableResize,
    .free = vtableFree,
};
var dummy_ctx: u8 = 0;

pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = @ptrCast(&dummy_ctx),
        .vtable = &kernel_allocator_vtable,
    };
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/mm/vmm.zig` Implementation **
 * Physical address from `*PageTable` `inline fn physToTable(phys: usize) *PageTable` definition、 `@as(*Pa
   * `mapPage(pml4_phys, vaddr, paddr, flags)`:
 1. `vaddr` and `paddr` 4096 boundary `std.debug.assert` with verify。
 2. `const inter_flags: u64 = PTE_PRESENT | PTE_WRITABLE | (flags & PTE_USER);` definition。
 3. `pml4 = physToTable(pml4_phys)` of `entries[pml4Index(vaddr)]` verify。 `PTE_PRESENT` `pmm.allocZ
 4. `PDPT` → `PD` → `PT` with （ ）、 of `pt.entries[ptIndex(vaddr)] = (paddr & PTE_
 5. `invlpg(vaddr);` execute `true` 。
   * `unmapPage(pml4_phys, vaddr)`:
 1. `PML4` → `PDPT` → `PD` → `PT` 、 of `PTE_PRESENT` `return null;` 。
 2. `pt_entry = &pt.entries[ptIndex(vaddr)]` `PTE_PRESENT` `return null;` 。
 3. `const old_phys = @as(usize, @intCast(pt_entry.* & PTE_ADDR_MASK));` 、 `pt_entry.* = 0;` cleared
   * `translate(pml4_phys, vaddr)`:
 1. `PML4` → `PDPT` → `PD` → `PT` 、 with `PTE_PRESENT` `return null;` 。
 2. Leaf PTE `PTE_PRESENT` `@as(usize, @intCast(leaf & PTE_ADDR_MASK)) + (vaddr & 0xFFF)` 。
   * `init()`:
     1. `kernel_pml4_phys = pmm.allocZeroedPage() orelse @panic("VMM: Failed to alloc PML4");`
 2. Physical address `0x0000_1000` （ Page 1 ） from `pmm.TOTAL_RAM_BYTES` （ `0x0800_0000` ） with `PAGE_SIZE` with loop
 3. `loadCr3(kernel_pml4_phys);` execute 4 pagestable to switch。
2. **Step 2: `src/mm/heap.zig` Implementation **
   * `init()`:
 1. `0..KERNEL_HEAP_INITIAL_PAGES` of loop times、times `const phys = pmm.allocZeroedPage() orelse @panic("Heap OO
 2. `head_block = @as(*BlockHeader, @ptrFromInt(KERNEL_HEAP_START));` initialized、 `head_block.?.* =.{.size = KE
   * `kmallocAligned(size, alignment)`:
 1. and of 、 of block of start 16 boundary（ or request 16 of when of 
 2. 、 of `block` of start `payload_addr = @intFromPtr(block) + HEADER_SIZE` 
 3. `block.size >= aligned_size + HEADER_SIZE + 32` with 、 `BlockHeader` （ `is_free = true` ）
 4. `block.is_free = false;` `@as([*]u8, @ptrFromInt(payload_addr))` 。
   * `kfree(ptr)`:
 1. `const block = @as(*BlockHeader, @ptrFromInt(@intFromPtr(ptr) - HEADER_SIZE));` 、 `block.is_free = tr
 2. `head_block` from ⾛、 `curr.is_free` `curr.next` exists `curr.next.?.is_free` with 、 `@int
3. **Step 3: `src/main.zig` of update and testimplement **
 * `kmain()` with of with initialized and test execute：
     1. `serial.init();`
     2. `serial.writeString("[TINUX_TEST] START: TASK-003\n");`
     3. `gdt.init();` / `idt.init();` / `pmm.init();`
     4. `vmm.init();` → `serial.writeString("[TINUX_VMM] 4-level paging active (CR3 switched)\n");`
 5. **VMM verification :**
 * `std.debug.assert(vmm.translate(vmm.getKernelPml4Phys(), 0x0000_0000) == null);` (Page 0 Guard Page verify)
 * `std.debug.assert(vmm.translate(vmm.getKernelPml4Phys(), 0x0010_0000).? == 0x0010_0000);` (Identity Map verify
        * `const test_phys = pmm.allocZeroedPage().?;`
        * `const test_virt: usize = 0x2000_0000;`
        * `std.debug.assert(vmm.mapPage(vmm.getKernelPml4Phys(), test_virt, test_phys, vmm.PTE_PRESENT | vmm.PTE_WRI
        * `@as(*volatile u64, @ptrFromInt(test_virt)).* = 0xCAFE_BABE_DEAD_BEEF;`
        * `std.debug.assert(@as(*volatile u64, @ptrFromInt(test_phys)).* == 0xCAFE_BABE_DEAD_BEEF);`
        * `std.debug.assert(vmm.unmapPage(vmm.getKernelPml4Phys(), test_virt).? == test_phys);`
        * `std.debug.assert(vmm.translate(vmm.getKernelPml4Phys(), test_virt) == null);`
        * `pmm.freePage(test_phys);`
 6. **Heap & `std.mem.Allocator` verification :**
        * `heap.init();` → `serial.writeString("[TINUX_HEAP] Kernel heap initialized\n");`
        * `const gpa = heap.allocator();`
        * `const slice1 = gpa.alloc(u64, 32) catch @panic("alloc failed");`
        * `for (slice1, 0..) |*item, idx| item.* = idx * 10;`
        * `std.debug.assert(slice1[31] == 310);`
        * `const ptr1_addr = @intFromPtr(slice1.ptr);`
        * `gpa.free(slice1);`
        * `const slice2 = gpa.alloc(u64, 32) catch @panic("alloc2 failed");`

 * `std.debug.assert(@intFromPtr(slice2.ptr) == ptr1_addr);` (Free-list Coalesce & Reuse verification)
        * `gpa.free(slice2);`
     7. `serial.writeString("[TINUX_TEST] PASS: TASK-003\n");`
     8. `io.qemuExit(.success);`
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-003 5
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-003
[TINUX_VMM] 4-level paging active (CR3 switched)
[TINUX_HEAP] Kernel heap initialized
[TINUX_TEST] PASS: TASK-003
[HARNESS] SUCCESS: TASK-003 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-003 5` when、 Builder fixloop stop、 `ESCALATIO
```markdown
# Escalation Report: TASK-003
## 1. Failure Summary
* **Failed Stage:** [zig build / CR3 Switch Page Fault / VMM Map-Unmap Assertion / Allocator VTable Compile Error / 
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
[ src/mm/vmm.zig or src/mm/heap.zig of ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
