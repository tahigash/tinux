# Tinux Boot Flow Architecture

> **Purpose:**
> Documents the complete boot sequence of the Tinux kernel from firmware handoff to userland process initialization.

---

## 1. Overview and Boot Protocol

Tinux boots as a freestanding 64-bit operating system kernel on the x86_64 architecture. The kernel binary is structured as a 64-bit ELF executable (`ELFCLASS64`) containing a Xen PVH direct boot ELF note (`XEN_ELFNOTE_PHYS32_ENTRY = 0x12`) and standard Multiboot-compatible entry points.

When QEMU or a compatible virtual machine monitor boots the kernel, execution begins at physical address `0x0010_0000` (1 MiB mark). The boot protocol passes control to the kernel with interrupts disabled (`cli`) and direction flag cleared (`cld`).

All initial userland binaries, shell environments, and test suites are from-scratch implementations (such as the in-tree Zig micro-userland), without requiring external GPL-licensed BusyBox or GNU coreutils.

---

## 2. 32-Bit Protected Mode Boot Stage (`src/arch/x86_64/boot.S`)

Initial execution starts at the 32-bit entry symbol `_start32`. This stage builds the minimal paging structures necessary to enter 64-bit Long Mode.

### Step 1: Early Identity Page Tables

The bootloader constructs three 4096-byte page tables in the `.bss` section:
* `boot_pml4`: Page Map Level 4 table.
* `boot_pdpt`: Page Directory Pointer Table.
* `boot_pd`: Page Directory table.

The first entry of `boot_pml4` points to `boot_pdpt` with flags `Present | Writable` (`0x03`). The first entry of `boot_pdpt` points to `boot_pd` with flags `Present | Writable` (`0x03`).

The `boot_pd` table maps the first 1 GiB of physical memory using 512 two-megabyte huge pages (`0x00000083` = `Present | Writable | Huge Page 2MiB`). Each entry increments the physical frame base by `0x0020_0000` (2 MiB), establishing a 1:1 identity mapping from `0x0000_0000` to `0x3FFF_FFFF`.

### Step 2: Load Page Table Base (`CR3`)

The physical address of `boot_pml4` is loaded into control register `CR3`:
```asm
movl $boot_pml4, %eax
movl %eax, %cr3
```

### Step 3: Enable PAE and SSE Support (`CR4`)

Physical Address Extension (bit 5) and SSE OS support flags are enabled in `CR4`:
* Bit 5 (`PAE`): Enables 64-bit 4-level paging translations.
* Bit 9 (`OSFXSR`): Enables OS support for FXSAVE and FXRSTOR instructions.
* Bit 10 (`OSXMMEXCPT`): Enables unmasked SIMD floating-point exceptions.

```asm
movl %cr4, %eax
orl  $0x00000620, %eax
movl %eax, %cr4
```

### Step 4: Enable Long Mode (`IA32_EFER`)

Long Mode Enable (bit 8, `LME`) is activated in the Extended Feature Enable Register (`IA32_EFER`, MSR `0xC0000080`):
```asm
movl $0xC0000080, %ecx
rdmsr
orl  $0x00000100, %eax
wrmsr
```

### Step 5: Enable Paging and Memory Protection (`CR0`)

Paging and memory protections are enabled in `CR0`:
* Bit 31 (`PG`): Enables paging unit.
* Bit 16 (`WP`): Enables kernel write protection against user read-only pages.
* Bit 1 (`MP`): Sets monitor coprocessor flag.
* Bit 2 (`EM`): Cleared to disable emulation and allow hardware SSE execution.

```asm
movl %cr0, %eax
andl $0xFFFFFFFB, %eax
orl  $0x80010002, %eax
movl %eax, %cr0
```

### Step 6: Load 64-Bit GDT and Far Jump

The boot code loads a temporary 64-bit Global Descriptor Table (`boot_gdtr`) with a 64-bit code segment descriptor (selector `0x08`, base 0, limit 0, flags `0xA09B`) and executes a far jump to Long Mode:
```asm
lgdt boot_gdtr
ljmp $0x08, $_start64
```

---

## 3. 64-Bit Long Mode Initialization (`_start64`)

At `_start64`, CPU execution operates in 64-bit Long Mode:

1. **Segment Registers:** Data segments (`DS`, `ES`, `SS`) are loaded with kernel data selector `0x10`. Thread-local segments (`FS`, `GS`) are zeroed until configured by `arch_prctl`.
2. **Stack Setup:** The stack pointer `RSP` is loaded with `boot_stack_top`, which is aligned to a 16-byte boundary.
3. **Frame Pointer:** `RBP` is zeroed to terminate backtraces.
4. **Kernel Entry:** Execution transitions into Zig code by calling `kmain()`.

```asm
.code64
_start64:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs
    leaq boot_stack_top(%rip), %rsp
    xorq %rbp, %rbp
    call kmain
```

---

## 4. Kernel Subsystem Initialization Sequence (`src/main.zig`)

The Zig entry point `kmain()` initializes kernel subsystems in strict dependency order:

1. **Serial Console (`serial.init`):**
   Configures UART 16550A at I/O port `0x3F8` (COM1) to 115200 baud, 8N1 format. Provides early diagnostic output.

2. **Global Descriptor Table (`gdt.init`):**
   Installs the production 64-bit GDT containing null selector (`0x00`), kernel code (`0x08`), kernel data (`0x10`), user code (`0x18` / `0x23`), user data (`0x20` / `0x1B`), and a 16-byte Task State Segment (TSS) descriptor at selector `0x28`. Loads the TSS via `ltr`.

3. **Interrupt Descriptor Table (`idt.init`):**
   Initializes 256 interrupt gates. Installs low-level ISR handlers for CPU exceptions (vectors 0 to 31) and hardware IRQs. Loads `IDTR` via `lidt`.

4. **Physical Memory Manager (`pmm.init`):**
   Detects usable RAM frames using bitmap tracking. Reserves memory occupied by the kernel ELF, early page tables, and serial I/O buffers.

5. **Virtual Memory Manager (`vmm.init`):**
   Initializes the 4-level paging manager. Replaces temporary boot page tables with production kernel PML4, creating higher-half mappings and validating virtual address permissions.

6. **Kernel Heap Allocator (`heap.init`):**
   Initializes the dynamic slab and block heap allocator backed by physical memory frames. Implements standard `std.mem.Allocator` interfaces.

7. **Fast System Call MSRs (`syscall_arch.init`):**
   Configures Model-Specific Registers for the `SYSCALL` and `SYSRET` instructions:
   * `IA32_EFER.SCE` (bit 0): System Call Extension enable.
   * `IA32_STAR` (`0xC0000081`): Sets kernel CS `0x08`, kernel SS `0x10`, user CS `0x18`, and user SS `0x20`.
   * `IA32_LSTAR` (`0xC0000082`): Sets target address to `syscallEntry` assembly stub.
   * `IA32_FMASK` (`0xC0000084`): Clears `RFLAGS.IF` (bit 9), masking interrupts during syscall entry.

8. **Timers and PIC (`timer.init`):**
   Remaps the dual 8259A PIC vectors to 32..47 and masks unused lines. Programs the 8254 PIT to generate a 100 Hz timer tick on IRQ0.

9. **Virtual File System (`vfs.init`, `pipe_mod.init`, `procfs.initAndRegister`):**
   Initializes root VFS structures, anonymous pipes, and `/proc` filesystem nodes (`/proc/version`, `/proc/meminfo`, `/proc/uptime`).

10. **Terminal Subsystem (`tty.init`):**
    Attaches serial COM1 to the TTY driver, enabling interrupt-driven line discipline (IRQ4) and echo handling.

11. **Network Stack (`socket.init`):**
    Initializes loopback sockets (`127.0.0.1`) and Unix domain sockets (`AF_UNIX`).

---

## 5. CPIO Initramfs Unpacking and Userland Launch

### Initramfs Loading (`src/fs/cpio.zig`)

The kernel unpacks the embedded or loaded CPIO archive (`initramfs.cpio`). It traverses the SVR4 newc header structures and extracts:
* `/bin/`: Directory for executable binaries.
* `/etc/`: Configuration files and motd banner.
* `/dev/`: Device character nodes (`null`, `zero`, `tty`).
* `/proc/`: Mount point for process information pseudo-filesystem.
* `/tmp/`: Temporary read-write storage.

### Spawning PID 1

1. The kernel looks up `/bin/sh` or test entry points in the VFS:
   ```zig
   if (vfs.lookup("bin/sh")) |idx| {
       init_binary_data = vfs.getNode(idx).slice();
       init_binary_name = "/bin/sh";
   }
   ```
2. It creates an isolated user PML4 page table using `vmm.createFreshUserPml4()`.
3. The ELF loader (`elf.loadStaticElf`) parses the in-tree static binary, maps `LOAD` segments with user permissions (`PTE_USER`), and constructs the initial System V ABI stack (`argc`, `argv`, `envp`, `auxv`).
4. The kernel switches `CR3` to the user page directory and enters user space (Ring 3) via `enterUserMode` using `IRETQ` or `SYSRET`.

---

## 6. Licensing & Independence Compliance

Tinux enforces source independence across the entire boot sequence:
* The bootloader and kernel entry stubs are written from scratch in x86_64 assembly and Zig.
* Userland utilities and default shell environments use from-scratch implementations (including the in-tree Zig micro-userland), without bundling GPL-licensed BusyBox or external proprietary binaries.
