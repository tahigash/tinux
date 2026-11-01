# Tinux Implementation Specification: TASK-003
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** AI System Architect
> * **Auditor (Low-Level & ABI Contract):** AI Code Auditor
> * **Target Builder:** Autonomous AI Builder Agent
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter virtual memory regions, page table entry bitmask flags, `vmm.zig` and `heap.zig` function signatures, or allocator interfaces.
2. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet", particularly for `std.mem.Allocator.VTable`.
3. **Preserve Existing Subsystems:**
   Do not modify `src/arch/x86_64/gdt.zig`, `idt.zig`, `isr.S`, or `src/mm/pmm.zig` established in prior tasks, except where explicitly instructed.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-003 5` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Bit cast | `@bitCast(DestType, val)` | `@as(DestType, @bitCast(val))` |
| Pointer to slice | `ptr[0..len]` on single-item pointer | `@as([*]u8, @ptrFromInt(addr))[0..len]` |
| Memory alignment | Manual bitwise arithmetic | `std.mem.alignForward(usize, val, alignment)` |
| Allocator VTable | Hardcoding 0.10 / 0.11 signatures | Use comptime feature detection in Section 4.2 |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-003`
* **Title:** `x86_64 4-Level Page Table Manager (VMM) and std.mem.Allocator Compliant Kernel Heap`
* **Target Subsystem:** `mm`
* **Target Files to Create / Modify:**
  * `src/mm/vmm.zig` (Create: 4-level paging, PML4 allocation, map/unmap/translate)
  * `src/mm/heap.zig` (Create: coalescing intrusive free-list allocator with `std.mem.Allocator` interface)
  * `src/main.zig` (Modify: run TASK-003 verification suite)
---
## 3. Virtual Memory & Heap ABI Contract (AI Audited)
### 3.1 Virtual Address Space Layout
While `boot.S` in TASK-001 initially set up 2 MiB large pages for the first 1 GiB, this task constructs fine-grained 4 KiB paging to support user space isolation and dynamic heap growth:
| Virtual Address Range | Size | Purpose & Protection Flags |
| :--- | :--- | :--- |
| `0x0000_0000_0000_0000 .. 0x0000_0000_0000_0FFF` | `4 KiB` | **Unmapped NULL Guard Page** (catches NULL pointer dereferences via `#PF`) |
| `0x0000_0000_0000_1000 .. 0x0000_0000_07FF_FFFF` | `~128 MiB` | **Identity Map (`vaddr == paddr`)** (`PTE_PRESENT \| PTE_WRITABLE`) |
| `0x0000_0000_1000_0000 .. 0x0000_0000_1003_FFFF` | `256 KiB` | **Kernel Heap Initial Region** (`PTE_PRESENT \| PTE_WRITABLE`) |
| `0x0000_0000_2000_0000 .. 0x0000_0000_2FFF_FFFF` | `256 MiB` | **Dynamic VMM Test / Scratch Region** (demand-mapped user/kernel scratch buffer) |
### 3.2 Page Table Entry (PTE) Propagation Contract
1. **Physical Address Mask:** When masking page frames in table entries, use `PTE_ADDR_MASK = 0x000F_FFFF_FFFF_F000`.
2. **Intermediate Table Flags:**
   When allocating intermediate page tables (PML4E, PDPTE, PDE) in `mapPage(pml4, vaddr, paddr, flags)`, set intermediate flags to `PTE_PRESENT | PTE_WRITABLE | (flags & PTE_USER)` so that leaf permissions are not prematurely restricted.
### 3.3 Kernel Heap Free-List Contract
* The heap allocator manages a linked list of free blocks using intrusive `BlockHeader` structures. It supports block splitting on allocation and coalescing of adjacent free blocks on deallocation.
* It exposes a standard `std.mem.Allocator` interface, enabling Zig standard containers like `std.ArrayList` to allocate and free heap memory.
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

fn allocFn(_: *anyopaque, len: usize, ptr_align: AlignParam, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const a: usize = if (@TypeOf(ptr_align) == u8) (@as(usize, 1) << @as(u6, @truncate(ptr_align))) else ptr_align.toByteUnits();
    return kmallocAligned(len, a);
}
fn resizeFn(_: *anyopaque, buf: []u8, buf_align: AlignParam, new_len: usize, ret_addr: usize) bool {
    _ = buf; _ = buf_align; _ = new_len; _ = ret_addr;
    return false;
}
fn freeFn(_: *anyopaque, buf: []u8, buf_align: AlignParam, ret_addr: usize) void {
    _ = buf_align; _ = ret_addr;
    kfree(buf.ptr);
}
fn remapFn(_: *anyopaque, memory: []u8, alignment: AlignParam, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = memory; _ = alignment; _ = new_len; _ = ret_addr;
    return null;
}
const heap_vtable: std.mem.Allocator.VTable = if (has_remap) .{
    .alloc = allocFn,
    .resize = resizeFn,
    .remap = remapFn,
    .free = freeFn,
} else .{
    .alloc = allocFn,
    .resize = resizeFn,
    .free = freeFn,
};
pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &heap_vtable,
    };
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/mm/vmm.zig` Implementation**
   * Define `inline fn physToTable(phys: usize) *PageTable` returning `@as(*PageTable, @ptrFromInt(phys))`.
   * In `mapPage(pml4_phys, vaddr, paddr, flags)`:
     1. Assert that `vaddr` and `paddr` are 4096-byte aligned.
     2. Calculate intermediate flags: `const inter_flags: u64 = PTE_PRESENT | PTE_WRITABLE | (flags & PTE_USER)`.
     3. Walk PML4 -> PDPT -> PD -> PT, allocating zeroed pages via `pmm.allocZeroedPage()` whenever an intermediate entry is not present.
     4. Set leaf entry: `pt.entries[ptIndex(vaddr)] = (paddr & PTE_ADDR_MASK) | flags`.
     5. Invalidate TLB via `invlpg(vaddr)` and return `true`.
   * In `unmapPage(pml4_phys, vaddr)`:
     1. Walk PML4 -> PDPT -> PD -> PT. Return `null` if any intermediate table is missing.
     2. Obtain pointer to leaf PTE: `const pt_entry = &pt.entries[ptIndex(vaddr)]`.
     3. If `(pt_entry.* & PTE_PRESENT) == 0`, return `null`.
     4. Extract old physical frame: `const old_phys = @as(usize, @intCast(pt_entry.* & PTE_ADDR_MASK))`.
     5. Clear entry (`pt_entry.* = 0`), invalidate TLB (`invlpg(vaddr)`), and return `old_phys`.
   * In `translate(pml4_phys, vaddr)`:
     1. Walk PML4 -> PDPT -> PD -> PT. Return `null` if any entry is not present.
     2. Return `@as(usize, @intCast(leaf & PTE_ADDR_MASK)) + (vaddr & 0xFFF)`.
   * In `init()`:
     1. Allocate kernel PML4: `kernel_pml4_phys = pmm.allocZeroedPage() orelse @panic("VMM: Failed to alloc PML4")`.
     2. Iterate from `0x0000_1000` (Page 1) to `pmm.TOTAL_RAM_BYTES` (128 MiB) with step `PAGE_SIZE`, mapping `vaddr == paddr` with `PTE_PRESENT | PTE_WRITABLE`. (Page 0 remains unmapped as a NULL guard page).
     3. Load `kernel_pml4_phys` into CR3 via `loadCr3` to activate fine-grained 4-level paging.
2. **Step 2: `src/mm/heap.zig` Implementation**
   * In `init()`:
     1. Map `KERNEL_HEAP_INITIAL_PAGES` starting at `KERNEL_HEAP_START` using newly allocated physical pages.
     2. Initialize `head_block` at `KERNEL_HEAP_START`: `.size = KERNEL_HEAP_INITIAL_SIZE - HEADER_SIZE`, `.is_free = true`, `.next = null`.
   * In `kmallocAligned(size, alignment)`:
     1. Walk free-list blocks starting from `head_block`.
     2. If block is free and payload satisfies `size` plus alignment padding, split the block if remaining space exceeds `HEADER_SIZE + 32`.
     3. Mark block as not free (`is_free = false`) and return pointer to payload.
   * In `kfree(ptr)`:
     1. Obtain block header pointer: `@as(*BlockHeader, @ptrFromInt(@intFromPtr(ptr) - HEADER_SIZE))`.
     2. Set `block.is_free = true`.
     3. Walk free-list from `head_block` and coalesce any adjacent free blocks into contiguous free spans.
3. **Step 3: `src/main.zig` Verification Suite**
   * In `kmain()`, execute:
     1. `serial.init()`
     2. `serial.writeString("[TINUX_TEST] START: TASK-003\n")`
     3. `gdt.init()`, `idt.init()`, `pmm.init()`
     4. `vmm.init()`, followed by `serial.writeString("[TINUX_VMM] 4-level paging active (CR3 switched)\n")`
     5. Verify VMM behavior:
        * Assert `vmm.translate(vmm.getKernelPml4Phys(), 0x0000_0000) == null` (NULL guard page).
        * Assert `vmm.translate(vmm.getKernelPml4Phys(), 0x0010_0000).? == 0x0010_0000` (Identity map).
        * Map scratch test address `0x2000_0000` to a fresh physical page, write test signature `0xCAFE_BABE_DEAD_BEEF`, verify physical read, unmap, assert translation returns `null`, and free physical page.
     6. Verify Heap & Allocator behavior:
        * `heap.init()`, followed by `serial.writeString("[TINUX_HEAP] Kernel heap initialized\n")`
        * Allocate via `heap.allocator().alloc(u64, 32)`, verify data read/write, free slice, allocate again, and assert address reuse.
     7. Log `[TINUX_TEST] PASS: TASK-003\n` and exit cleanly via `io.qemuExit(.success)`.
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
If `zig build` or `./scripts/verify_qemu.sh TASK-003 5` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-003
## 1. Failure Summary
* **Failed Stage:** [zig build / CR3 Switch Page Fault / VMM Map-Unmap Assertion / Allocator VTable Compile Error / Heap Overwrite]
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
[Code diff of src/mm/vmm.zig or src/mm/heap.zig]
```
## 4. Suspected Root Cause (For AI Architect / Auditor Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
