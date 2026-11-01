# Tinux Implementation Specification: TASK-011

> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-010` Passed (`./scripts/verify_qemu.sh TASK-010 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter memory layout addresses (executable at `0x0040_0000`, `INTERP_LOAD_BIAS = 0x1800_0000`, `mmap` region at `0x2000_0000..0x3FFF_FFFF`, stack at `0x0080_0000..0x0080_8000`), linker scripts, or syscall numbers specified here.
2. **Keep User Mappings Within First 1 GiB (`pdpt[0]`):**
   Align with `TASK-007`'s `cloneUserPml4` implementation so all user mappings remain within the first 1 GiB virtual address space managed by `pdpt[0]`.
3. **Strict Zig Version Idioms:**
   Adhere strictly to modern Zig idioms (0.13+) as defined in Section 1. Do not use deprecated functions like `@ptrToInt` or `@intToPtr`.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-011 10` fails 3 consecutive times, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Bit cast | `@bitCast(DestType, val)` | `@as(DestType, @bitCast(val))` |
| Alignment cast | `@alignCast(4096, ptr)` | `@as(*align(4096) T, @alignCast(ptr))` |
| Enum to integer | `@enumToInt(e)` | `@intFromEnum(e)` |
| C ABI struct | `struct { ... }` | `extern struct { ... }` |
| Packed struct | `packed struct { ... }` (unspecified width) | `packed struct(u8) { ... }` |
| Build API path | `.{ .path = "src/main.zig" }` | `b.path("src/main.zig")` |
| NUL-terminated slice | Manual scan loop for 0 byte | `std.mem.sliceTo(raw_slice, 0)` |
| Page align down | `addr & ~0xFFF` | `addr & ~@as(usize, 0xFFF)` |
| Page align up | Manual arithmetic | `std.mem.alignForward(usize, addr, 4096)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-011`
* **Title:** `Dynamic ELF Loader (PT_INTERP / ld-musl-x86_64.so.1 Co-Loading & AT_BASE), Shared Library Mapping (MAP_FIXED / MAP_ANONYMOUS), and Shared Object Resolution`
* **Target Subsystem:** `proc`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/proc/elf.zig` (Modify: detect `PT_INTERP`, load interpreter ELF at `0x1800_0000`, populate `AT_BASE`, `AT_PHDR`, `AT_ENTRY`, and auxiliary vectors)
  * `src/proc/task.zig` (Modify: set default `mmap_next = 0x2000_0000` so `mmap` stays within first 1 GiB `pdpt[0]`)
  * `src/fs/vfs.zig` (Modify: support `/lib/libc.musl-x86_64.so.1` alias to `/lib/ld-musl-x86_64.so.1` as in Alpine Linux rootfs)
  * `src/syscall/dispatch.zig` (Modify: implement `sys_pread64`, `sys_readv`, `sys_readlink`/`sys_readlinkat`, and update `sys_mmap` with `MAP_FIXED`)
  * `src/main.zig` (Modify: update test markers to `TASK-011`)
  * `scripts/verify_qemu.sh` (Modify: package `/lib/ld-musl-x86_64.so.1`, shared library `/lib/libtinux.so`, and dynamic user binary `/bin/dyn_inspect`)
---
## 3. Dynamic Linking (`PT_INTERP`) & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 Dual-ELF Memory Layout & Control Transfer Contract
When executing dynamic Linux binaries (such as those from Alpine Linux), the ELF Program Header table contains an entry of type `PT_INTERP` (`p_type == 3`). The kernel must map both the main executable and the interpreter ELF:
| Memory Region | Virtual Address | Role & Mapping Details |
| :--- | :--- | :--- |
| **Main Executable** | `0x0040_0000` (PIE `ET_DYN`) or `p_vaddr` (`ET_EXEC`) | Executable segments mapped from `PT_LOAD` entries |
| **User Stack** | `0x0080_0000..0x0080_8000` (`32 KiB`, 8 pages) | Downward growing user stack with initial `argc`, `argv`, `envp`, `auxv` |
| **Dynamic Linker (`PT_INTERP`)** | **`0x1800_0000`** (`INTERP_LOAD_BIAS`, 384 MiB) | Dynamic interpreter loaded from VFS path `/lib/ld-musl-x86_64.so.1` |
| **Shared Library `mmap` Pool** | **`0x2000_0000..0x3FFF_FFFF`** (512 MiB..1 GiB) | Virtual memory region allocated for shared library mappings (`DT_NEEDED`) |
### 3.2 Auxiliary Vector (`auxv`) Contract for Dynamic Linker
Dynamic linkers (`ld-musl` / `ld-linux`) inspect the auxiliary vector (`auxv`) placed at the top of the user stack to determine image layout, page size, and execution entry points:
* **`AT_PHDR (3)`:** Virtual address of the main executable's Program Header table in user space.
  * If the Program Header table is covered by a `PT_LOAD` segment, calculate `phdr_vaddr = bias + phdr.p_vaddr`.
  * If the Program Header table is outside all `PT_LOAD` segments, map it at `FALLBACK_PHDR_VADDR = 0x003F_F000`.
* **`AT_PHENT (4)`:** Size of an ELF Program Header entry (`56`, `@sizeOf(Elf64_Phdr)`).
* **`AT_PHNUM (5)`:** Number of Program Header entries (`ehdr.e_phnum`).
* **`AT_PAGESZ (6)`:** Page size in bytes (`4096`).
* **`AT_BASE (7)`:** Base address of the dynamic interpreter (`0x1800_0000` if `PT_INTERP` present, `0` if static).
* **`AT_FLAGS (8)`:** Architectural flags (`0`).
* **`AT_ENTRY (9)`:** Virtual address of the main executable entry point (`main_entry_rip`). Control initially transfers to the interpreter's entry point, which later transfers execution to `AT_ENTRY`.
### 3.3 Dynamic Linker Syscalls Contract (`MAP_FIXED`, `pread64`, `readlinkat`)
When `ld-musl-x86_64.so.1` loads shared libraries (such as `/lib/libtinux.so`), it issues specific system calls:
| Syscall Name | Num | Arguments | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_mmap` (`MAP_FIXED`)** | `9` | `addr, len, prot, flags, fd, off` | Map requested page range at exact virtual address `addr`. Overwrites any prior mapping in range. |
| **`sys_pread64`** | `17` | `fd, buf_ptr, count, pos` | Read `count` bytes from file descriptor `fd` at offset `pos` without modifying file offset. |
| **`sys_readv`** | `19` | `fd, iov_ptr, iovcnt` | Read scatter/gather buffer list (`iovcnt` entries of `iovec`) sequentially via `sysRead`. |
| **`sys_readlink` / `readlinkat`** | `89` / `267` | `(dirfd,) path_ptr, buf_ptr, bufsiz` | Read symlink destination. Resolves `"/proc/self/exe"` to current executable path. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/proc/elf.zig` Upgraded Structures & Functions
```zig
pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_PHDR: u32 = 6;
pub const AT_NULL: u64 = 0;
pub const AT_PHDR: u64 = 3;
pub const AT_PHENT: u64 = 4;
pub const AT_PHNUM: u64 = 5;
pub const AT_PAGESZ: u64 = 6;
pub const AT_BASE: u64 = 7;
pub const AT_FLAGS: u64 = 8;
pub const AT_ENTRY: u64 = 9;
pub const AT_UID: u64 = 11;
pub const AT_EUID: u64 = 12;
pub const AT_GID: u64 = 13;
pub const AT_EGID: u64 = 14;
pub const AT_SECURE: u64 = 23;
pub const AT_RANDOM: u64 = 25;
pub const MAIN_PIE_LOAD_BIAS: usize = 0x0040_0000;
pub const INTERP_LOAD_BIAS: usize = 0x1800_0000;
pub const FALLBACK_PHDR_VADDR: usize = 0x003F_F000;
pub const USER_STACK_BOTTOM: usize = 0x0080_0000;
pub const USER_STACK_PAGES: usize = 8; // 32 KiB (0x0080_0000 .. 0x0080_8000)
pub const USER_STACK_TOP: usize = USER_STACK_BOTTOM + (USER_STACK_PAGES * vmm.PAGE_SIZE);
const SegmentMapResult = struct {
    max_vaddr: usize,
    phdr_vaddr: usize,
    entry_rip: usize,
};
fn mapElfSegments(
    pml4_phys: usize,
    elf_bytes: []const u8,
    pie_load_bias: usize,
) !SegmentMapResult {
    // Builder validates Elf64_Ehdr and maps all PT_LOAD segments with given pie_load_bias
}
pub fn loadStaticElf(
    pml4_phys: usize,
    elf_bytes: []const u8,
    argv: []const []const u8,
) !LoadedImage {
    // Builder maps main ELF, checks PT_INTERP, optionally maps interpreter ELF via vfs.lookup,
    // and constructs initial stack with AT_BASE, AT_PHDR, AT_ENTRY
}
```
### 4.2 `src/syscall/dispatch.zig` Additions
```zig
pub const SYS_PREAD64: u64 = 17;
pub const SYS_READV: u64 = 19;
pub const SYS_READLINK: u64 = 89;
pub const SYS_READLINKAT: u64 = 267;

pub fn sysPread64(fd: usize, buf_ptr: usize, count: usize, pos: usize) isize {
    // Builder reads from VFS_FILE at offset pos without modifying entry.offset
}
pub fn sysReadlinkat(dirfd: isize, path_ptr: usize, buf_ptr: usize, bufsiz: usize) isize {
    // Builder handles "/proc/self/exe" -> writes "/bin/dyn_inspect" and returns length
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Implement `PT_INTERP` detection in `src/proc/elf.zig`:**
   * In `mapElfSegments(pml4_phys: usize, elf_bytes: []const u8, pie_load_bias: usize) !SegmentMapResult`:
     1. Verify ELF magic, `ELFCLASS64`, `e_type == 2 or e_type == 3`, and `e_machine == 62`.
     2. Set `const bias: usize = if (ehdr.e_type == 3) pie_load_bias else 0;`.
     3. Iterate over `Elf64_Phdr` entries:
        * If `phdr.p_type == PT_PHDR`, set `phdr_vaddr = bias + @as(usize, @intCast(phdr.p_vaddr))`.
        * If `phdr.p_type == PT_LOAD and phdr.p_memsz > 0`:
          * Calculate `seg_start = bias + @as(usize, @intCast(phdr.p_vaddr))` and `seg_end = seg_start + @as(usize, @intCast(phdr.p_memsz))`.
          * If `phdr.p_offset <= ehdr.e_phoff and ehdr.e_phoff < phdr.p_offset + phdr.p_filesz`, set `phdr_vaddr = bias + phdr.p_vaddr + (ehdr.e_phoff - phdr.p_offset)`.
          * Allocate physical pages via `pmm.allocZeroedPage()` for each virtual page in `page_start..page_end` if not already mapped.
          * Copy file data from `elf_bytes` into allocated physical pages.
     4. Return `.{ .max_vaddr = max_vaddr, .phdr_vaddr = phdr_vaddr, .entry_rip = bias + @as(usize, @intCast(ehdr.e_entry)) }`.
   * In `loadStaticElf(pml4_phys, elf_bytes, argv)`:
     1. `var main_res = try mapElfSegments(pml4_phys, elf_bytes, MAIN_PIE_LOAD_BIAS);`
     2. If `main_res.phdr_vaddr == 0`:
        * Allocate fallback page at `FALLBACK_PHDR_VADDR = 0x003F_F000`.
        * Map page with `PTE_PRESENT | PTE_WRITABLE | PTE_USER`.
        * Copy program headers from `elf_bytes` into fallback page.
        * Set `main_res.phdr_vaddr = FALLBACK_PHDR_VADDR;`.
     3. Scan program headers for `PT_INTERP`:
        * Set default `var at_base: usize = 0;` and `var start_rip: usize = main_res.entry_rip;`.
        * If `phdr.p_type == PT_INTERP`:
          * Extract interpreter path: `const interp_path = std.mem.sliceTo(raw_interp, 0);`.
          * Lookup interpreter in VFS: `const interp_node = vfs.lookup(interp_path) orelse return error.InterpreterNotFound;`.
          * Map interpreter segments: `const interp_res = try mapElfSegments(pml4_phys, interp_node.slice(), INTERP_LOAD_BIAS);`.
          * Set `at_base = INTERP_LOAD_BIAS;` and `start_rip = interp_res.entry_rip;`.
     4. Construct 32 KiB user stack (`0x0080_0000..0x0080_8000`):
        * Allocate 8 physical pages, map at top page `0x0080_7000`, set stack pointer to `0x0080_7E00` (16-byte aligned).
        * Populate `auxv` entries: `{ AT_PHDR, main_res.phdr_vaddr }`, `{ AT_PHENT, 56 }`, `{ AT_PHNUM, ehdr.e_phnum }`, `{ AT_PAGESZ, 4096 }`, `{ AT_BASE, at_base }`, `{ AT_ENTRY, main_res.entry_rip }`, `{ AT_NULL, 0 }`.
     5. Return `LoadedImage{ .entry_rip = start_rip, .user_rsp = 0x0080_7E00, .initial_brk = std.mem.alignForward(usize, main_res.max_vaddr, 4096) }`.
2. **Step 2: Update `src/fs/vfs.zig` and `src/proc/task.zig`:**
   * In `src/proc/task.zig`, set `mmap_next` initial value to `0x2000_0000` for both new tasks and `sysExecve`.
   * In `src/fs/vfs.zig` `init()`, ensure directories `"lib"`, `"usr"`, and `"usr/lib"` exist.
   * Provide `/lib/libc.musl-x86_64.so.1` as an alias or symlink to `/lib/ld-musl-x86_64.so.1` for musl compatibility.
3. **Step 3: Implement `sys_mmap` (`MAP_FIXED`) and `sys_pread64` in `src/syscall/dispatch.zig`:**
   * In `sysMmap`:
     1. Define `const MAP_FIXED: usize = 0x10;` and `const MAP_ANONYMOUS: usize = 0x20;`.
     2. Calculate `base_vaddr`: if `(flags & MAP_FIXED) != 0 and addr != 0`, use page-aligned `addr`. Otherwise, allocate from `cur.mmap_next`.
     3. For each page in range, allocate physical page if unmapped, or overwrite existing mapping if `MAP_FIXED` is set.
     4. Zero-fill allocated page range.
     5. If `(flags & MAP_ANONYMOUS) == 0`, read data from `fd` node at specified offset into mapped memory.
     6. Return `@as(isize, @intCast(base_vaddr));`.
   * In `sysPread64(fd: usize, buf_ptr: usize, count: usize, pos: usize) isize`:
     1. If `count == 0`, return 0.
     2. Validate user buffer: `if (!validateUserBuffer(buf_ptr, count)) return errno_mod.toReturn(.EFAULT);`.
     3. Validate file descriptor: verify `fd < vfs.MAX_OPEN_FILES` and `cur.fd_table[fd].kind == .VFS_FILE`.
     4. Retrieve file node slice: if `pos >= data.len`, return 0.
     5. Copy `min(count, data.len - pos)` bytes into user buffer without changing `fd_table[fd].offset`.
     6. Return bytes read.
4. **Step 4: Update test harness in `scripts/verify_qemu.sh`:**
   * Package dynamic loader test artifacts into initramfs:
     1. Shared library `/lib/libtinux.so`.
     2. Dynamic interpreter `/lib/ld-musl-x86_64.so.1` (or clean-room micro-loader).
     3. Dynamically linked test executable `/bin/dyn_inspect` built with `PT_INTERP = "/lib/ld-musl-x86_64.so.1"`.
     4. Update `/etc/rc.sh`:
        ```sh
        #!/bin/sh
        echo "[TINUX_SH] Launching dynamically-linked ELF binary (/bin/dyn_inspect)..."
        /bin/dyn_inspect
        echo "[TINUX_ALPINE] Dynamic ELF loader (PT_INTERP + ld-musl + shared library mmap) verified!"
        exit 0
        ```
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-011 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-011
[TINUX_INIT] Spawning PID 1 (/bin/sh /etc/rc.sh)...
[TINUX_SH] Launching dynamically-linked ELF binary (/bin/dyn_inspect)...
[TINUX_DYN] ld-musl-x86_64.so.1 loaded at AT_BASE=0x18000000, mapped /lib/libtinux.so!
[TINUX_DYN] Main dynamic ELF executed via PT_INTERP -> AT_ENTRY transition!
[TINUX_ALPINE] Dynamic ELF loader (PT_INTERP + ld-musl + shared library mmap) verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-011
[HARNESS] SUCCESS: TASK-011 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-011 10` fails 3 consecutive times, stop execution and generate `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-011
## 1. Failure Summary
* **Failed Stage:** [zig build / PT_INTERP Detection / Interpreter Load Fault / Auxv AT_BASE or AT_ENTRY Mismatch]
* **Auxv & ELF Load Dump:** [main_entry_rip, interp_entry_rip, AT_PHDR, AT_BASE values]
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
[Relevant code diff for src/proc/elf.zig or src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
