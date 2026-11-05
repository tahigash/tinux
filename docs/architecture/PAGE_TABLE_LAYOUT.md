# Tinux Virtual Memory and Page Table Layout

> **Purpose:**
> Documents the 4-level paging architecture, canonical virtual memory layout, and address translation structures for the Tinux x86_64 kernel.

---

## 1. Overview of 4-Level Paging Architecture

Tinux implements standard x86_64 4-level paging with 48-bit linear addresses and 4096-byte (4 KiB) pages. Addresses are sign-extended from bit 47 across bits 48..63 to maintain canonical form.

### Virtual Address Translation Breakdown

```text
 63       48 47   39 38   30 29   21 20   12 11        0
+-----------+-------+-------+-------+-------+-----------+
| Sign Ext. | PML4  | PDPT  |  PD   |  PT   | Offset    |
| (16 bits) |(9 bits|(9 bits|(9 bits|(9 bits| (12 bits) |
+-----------+-------+-------+-------+-------+-----------+
```

* **PML4 Index (bits 39..47):** Selects one of 512 Page Map Level 4 entries.
* **PDPT Index (bits 30..38):** Selects one of 512 Page Directory Pointer Table entries.
* **PD Index (bits 21..29):** Selects one of 512 Page Directory entries.
* **PT Index (bits 12..20):** Selects one of 512 Page Table entries.
* **Page Offset (bits 0..11):** Byte offset within the 4 KiB physical page frame.

---

## 2. Page Table Entry (PTE) Flags and Layout

Each page table entry occupies 64 bits (8 bytes). The structure and flags defined in `src/mm/vmm.zig` are:

```zig
pub const PTE_PRESENT: u64 = 1 << 0;
pub const PTE_WRITABLE: u64 = 1 << 1;
pub const PTE_USER: u64 = 1 << 2;
pub const PTE_WRITE_THROUGH: u64 = 1 << 3;
pub const PTE_CACHE_DISABLE: u64 = 1 << 4;
pub const PTE_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
```

| Bit | Name | Description | Value in Tinux |
| :---: | :---: | :--- | :--- |
| 0 | `P` | Present | 1 if page is resident in physical memory |
| 1 | `R/W`| Read / Write | 1 for read-write access; 0 for read-only |
| 2 | `U/S`| User / Supervisor | 1 allows Ring 3 access; 0 restricts to Ring 0 |
| 3 | `PWT`| Page-level Write-Through | 1 enables write-through caching; 0 write-back |
| 4 | `PCD`| Page-level Cache Disable | 1 disables caching; required for MMIO frames |
| 5 | `A` | Accessed | Set by processor when page is read or written |
| 6 | `D` | Dirty | Set by processor when page is written |
| 7 | `PS` | Page Size | 1 in PD indicates 2 MiB huge page; 0 for 4 KiB |
| 8 | `G` | Global | 1 prevents TLB invalidation on CR3 reload |
| 9..11 | - | Available for OS | Used for internal bookkeeping and COW tracking |
| 12..51| - | Physical Address Frame | Base physical address aligned to 4 KiB |
| 52..62| - | Available for OS | Unused |
| 63 | `NX`| No-Execute | 1 prevents instruction execution on page |

---

## 3. Canonical Virtual Memory Map

The 64-bit address space is partitioned into a lower half (user space, PML4 entries 0..255) and an upper half (kernel space, PML4 entries 256..511), separated by an unmapped non-canonical hole.

```text
0x0000_0000_0000_0000  +----------------------------------------------+
                       | Null Pointer Guard Region (Unmapped, 4 MiB)  |
0x0000_0000_0040_0000  +----------------------------------------------+
                       | User ELF Text, Rodata, Data, BSS             |
                       +----------------------------------------------+
                       | Process Program Break Heap (sys_brk)         |
                       | (Grows upward)                               |
                       +----------------------------------------------+
                       | Dynamic Mappings / Shared Libraries (sys_mmap|
0x0000_7000_0000_0000  +----------------------------------------------+
                       | User Stack Region (Grows downward)           |
0x0000_7FFF_FFFF_0000  +----------------------------------------------+
                       | User Space Boundary (128 TiB Lower Half)     |
0x0000_7FFF_FFFF_FFFF  +----------------------------------------------+
                       |                                              |
                       | Non-Canonical Address Hole                   |
                       | (Accesses generate General Protection #GP)   |
                       |                                              |
0xFFFF_8000_0000_0000  +----------------------------------------------+
                       | Kernel Space Boundary (128 TiB Upper Half)   |
0xFFFF_8880_0000_0000  +----------------------------------------------+
                       | Higher-Half Physical Direct Map (HHDM)       |
                       | 1:1 identity map of all physical RAM         |
0xFFFF_C000_0000_0000  +----------------------------------------------+
                       | Kernel Heap & Dynamic Allocator (vmalloc)    |
0xFFFF_FFFF_8000_0000  +----------------------------------------------+
                       | Kernel Text, Static Data, and BSS            |
                       +----------------------------------------------+
                       | Memory-Mapped I/O (LAPIC, I/O APIC, PCI)     |
0xFFFF_FFFF_FFFF_FFFF  +----------------------------------------------+
```

### 3.1 Tinux Compact 1 GiB Lower-Half Virtual Memory Map

During initial boot and staging across TASK-001 through TASK-020, the Tinux kernel and its userland runtime operate within a compact 1 GiB lower-half virtual memory map rooted in PML4 entry 0 (single PDPT entry). This predictable layout simplifies early identity translation and demand paging before full 128 TiB sparse userland expansion:

```text
0x0000_0000  +----------------------------------------------------------------+
             | Null Pointer Guard Region (Unmapped, 4 MiB)                    |
0x0040_0000  +----------------------------------------------------------------+
             | User ELF Text / PIE Load Bias (MAIN_PIE_LOAD_BIAS)             |
             +----------------------------------------------------------------+
             | User Execution Stack (USER_STACK_BOTTOM, 32 KiB downward)      |
0x0080_0000  +----------------------------------------------------------------+
             | Reserved / Unmapped Virtual Memory Gap                         |
0x1000_0000  +----------------------------------------------------------------+
             | Kernel Dynamic Heap (KERNEL_HEAP_START, 256 KiB initial)       |
             +----------------------------------------------------------------+
             | Reserved / Unmapped Virtual Memory Gap                         |
0x1800_0000  +----------------------------------------------------------------+
             | Dynamic Linker Interpreter Bias (INTERP_LOAD_BIAS)             |
             +----------------------------------------------------------------+
             | Reserved / Unmapped Virtual Memory Gap                         |
0x2000_0000  +----------------------------------------------------------------+
             | User Dynamic Memory Mappings (DEFAULT_MMAP_BASE, sys_mmap)     |
             | (Allocates upward or downward within PML4 entry 0)             |
0x4000_0000  +----------------------------------------------------------------+
             | 1 GiB Lower-Half Identity Boundary (Single PDPT Entry)         |
```

---

## 4. User Space Memory Regions

### Null Pointer Guard (`0x0000_0000_0000_0000` .. `0x0000_0000_003F_FFFF`)
The first 4 MiB of the virtual address space is intentionally left unmapped. Any read, write, or instruction fetch addressing this range immediately causes a Page Fault (`#PF`) with address `0x0`, detecting null pointer dereferences.

### User ELF Binary (`0x0040_0000` .. `0x007F_FFFF`)
Standard static and dynamic Linux userland executables are loaded at base address `0x0040_0000` (`MAIN_PIE_LOAD_BIAS`):
* Text segment: Mapped with `PTE_PRESENT | PTE_USER`.
* Rodata segment: Mapped with `PTE_PRESENT | PTE_USER | PTE_NX`.
* Data and BSS: Mapped with `PTE_PRESENT | PTE_WRITABLE | PTE_USER | PTE_NX`.

### User Execution Stack (`0x0080_0000` .. `0x0080_8000`)
In the compact 1 GiB layout, the initial user execution stack is configured at base `0x0080_0000` (`USER_STACK_BOTTOM`) with 8 pages (32 KiB). The initial stack pointer is set to `0x0080_8000` (`USER_STACK_TOP`) and grows downward toward lower memory. At process initialization, the kernel constructs the System V AMD64 ABI layout containing `argc`, `argv` string pointers, `envp` environment variables, and `auxv` auxiliary vectors.

### Process Heap (`sys_brk`)
The process program break heap starts immediately after the ELF BSS segment. The `sys_brk` system call adjusts the program break pointer:
* Expanding `brk` allocates physical frames from the PMM and maps them with `PTE_PRESENT | PTE_WRITABLE | PTE_USER | PTE_NX`.
* Shrinking `brk` unmaps the corresponding virtual pages, returns physical frames to the free list, and flushes the TLB via `invlpg`.

### Kernel Dynamic Heap (`0x1000_0000`)
The kernel dynamic memory allocator manages dynamic allocations starting at `KERNEL_HEAP_START` (`0x1000_0000`) with an initial 64-page (256 KiB) pool mapped in the kernel PML4 table.

### Dynamic Linker Interpreter (`0x1800_0000`)
When co-loading dynamic ELF binaries containing a `PT_INTERP` program header, the kernel maps the dynamic linker interpreter (`ld-musl-x86_64.so.1`) starting at `INTERP_LOAD_BIAS` (`0x1800_0000`) and passes `AT_BASE` in the auxiliary vector.

### Dynamic Memory Mappings (`DEFAULT_MMAP_BASE`: `0x2000_0000`)
Memory mapped regions allocate starting at `DEFAULT_MMAP_BASE` (`0x2000_0000`) for `sys_mmap` allocations within the lower-half pool, or at `0x7000_0000_0000` when addressing full canonical 48-bit address space:
* Anonymous private mappings (`MAP_PRIVATE | MAP_ANONYMOUS`) provide zeroed memory pages.
* File-backed mappings read data directly from VFS inode caches.

---

## 5. Process Address Space Isolation

Each user process owns an independent PML4 page table structure created via `vmm.createFreshUserPml4()`:
* **Lower Half (Entries 0..255):** Private to each process. Provides hardware-enforced memory isolation between tasks.
* **Upper Half (Entries 256..511):** Cloned directly from the kernel master PML4. Ensures that kernel code, interrupt handlers, and physical direct mappings remain accessible during syscall entries without changing CR3.

During a task context switch, the kernel writes the new process PML4 physical address into `CR3`:
```zig
pub inline fn loadCr3(pml4_phys: usize) void {
    asm volatile ("mov %[phys], %%cr3"
        :
        : [phys] "r" (pml4_phys),
        : "memory"
    );
}
```

---

## 6. Page Fault Handling and Demand Paging

When a memory access violates permissions or references an unmapped address, the CPU raises exception 14 (`#PF`):
1. Hardware saves the faulting linear address into control register `CR2`.
2. Hardware pushes the Page Fault Error Code onto the stack:
   * Bit 0 (`P`): 0 = non-present page; 1 = protection violation.
   * Bit 1 (`W/R`): 0 = read access; 1 = write access.
   * Bit 2 (`U/S`): 0 = supervisor access; 1 = user access.
   * Bit 4 (`I/D`): 1 = instruction fetch violation (NX).
3. The kernel handler inspects `CR2`:
   * If the address is within valid stack or heap boundaries, a physical frame is allocated and mapped dynamically.
   * If the fault represents an illegal access (such as writing to read-only text or referencing unmapped memory), the kernel delivers `SIGSEGV` to the process.
