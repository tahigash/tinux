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
 specification with definitionmemoryplaced（execute `0x0040_0000` 、 `INTERP_LOAD_BIAS = 0x1800_0000` 、 `mmap
2. **Keep User Mappings Within First 1 GiB (`pdpt[0]`):**
 `TASK-007` of `cloneUserPml4` （ `fork` of pagestableduplicated） and of complete 、 of （ `0x
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-011 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| NUL | ⼿loop with of boundary | `std.mem.sliceTo(raw_slice, 0)` |
| pages | `addr & ~0xFFF` | `addr & ~@as(usize, 0xFFF)` |
| pages | ⼿ | `std.mem.alignForward(usize, addr, 4096)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-011`
* **Title:** `Dynamic ELF Loader (PT_INTERP / ld-musl-x86_64.so.1 Co-Loading & AT_BASE), Shared Library Mapping (MAP
* **Target Subsystem:** `proc`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/proc/elf.zig` (Modify: detect `PT_INTERP`, load interpreter ELF at `0x1800_0000`, populate `AT_BASE`, `AT_P
  * `src/proc/task.zig` (Modify: set default `mmap_next = 0x2000_0000` so `mmap` stays within first 1 GiB `pdpt[0]`)
  * `src/fs/vfs.zig` (Modify: support `/lib/libc.musl-x86_64.so.1` alias to `/lib/ld-musl-x86_64.so.1` as in Alpine 
  * `src/syscall/dispatch.zig` (Modify: implement `sys_pread64`, `sys_readv`, `sys_readlink`/`sys_readlinkat`, and u
  * `src/main.zig` (Modify: update test markers to `TASK-011`)
  * `scripts/verify_qemu.sh` (Modify: package `/lib/ld-musl-x86_64.so.1`, shared library `/lib/libtinux.so`, and dyn
---
## 3. Dynamic Linking (`PT_INTERP`) & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 Dual-ELF Memory Layout & Control Transfer Contract
 Linux execute（ Alpine Linux of ）、 ELF Program Header **`PT_INTERP` (`p_type == 3`)**
| Memory Region | Virtual Address | Role & Mapping Details |
| :--- | :--- | :--- |
| **Main Executable** | `0x0040_0000` (PIE `ET_DYN`) or `p_vaddr` (`ET_EXEC`) | execute of `PT_LOAD` 
| **User Stack** | `0x0080_0000.. 0x0080_8000` (`32 KiB`, 8 pages) | of ‧placed with stack
| **Dynamic Linker (`PT_INTERP`)** | **`0x1800_0000`** (`INTERP_LOAD_BIAS`, 384 MiB) | VFS from `/lib/ld-musl
| **Shared Library `mmap` Pool** | **`0x2000_0000.. 0x3FFF_FFFF`** (512 MiB.. 1 GiB) | `DT_NEEDED` of 
### 3.2 Auxiliary Vector (`auxv`) Contract for Dynamic Linker
（ `ld-musl` / `ld-linux` ） stack of `auxv` ⾛、 of value ⾃⾝ of and 
* **`AT_PHDR (3)`:** execute of Program Header table of user spacevirtual address。
 * ** important :** execute of of `PT_LOAD` `ehdr.e_phoff` with when（ `phdr
* **`AT_PHENT (4)`:** `56` (`@sizeOf(Elf64_Phdr)`) 。
* **`AT_PHNUM (5)`:** execute of `ehdr.e_phnum` 。
* **`AT_PAGESZ (6)`:** `4096` 。
* **`AT_BASE (7)`:** `PT_INTERP` when **`0x1800_0000`** （ `INTERP_LOAD_BIAS` ）、 of when **`0`** 。
* **`AT_FLAGS (8)`:** `0` 。

* **`AT_ENTRY (9)`:** execute of virtual address（ `main_entry_rip` ）。 ※ of `.so` of 
### 3.3 Dynamic Linker Syscalls Contract (`MAP_FIXED`, `pread64`, `readlinkat`)
`ld-musl-x86_64.so.1` shared（ `/lib/libtinux.so` ） of ：
| Syscall Name | Num | Arguments | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_mmap` (`MAP_FIXED`)** | `9` | `addr, len, prot, flags, fd, off` | `ld-musl` `mmap(NULL, total_si
| **`sys_pread64`** | `17` | `fd, buf_ptr, count, pos` | ** 【mandatory】 ** disk `fd` of of `off
| **`sys_readv`** | `19` | `fd, iov_ptr, iovcnt` | `iovcnt` of `IoVec` ⾛、 `sysRead` and 
| **`sys_readlink` / `readlinkat`** | `89` / `267` | `(dirfd,) path_ptr, buf_ptr, bufsiz` | `"/proc/self/exe"`
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
    // Builder reads from VFS_FILE at offset `pos` without modifying `entry.offset`
}
pub fn sysReadlinkat(dirfd: isize, path_ptr: usize, buf_ptr: usize, bufsiz: usize) isize {
    // Builder handles "/proc/self/exe" -> writes "/bin/dyn_inspect" and returns length
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/proc/elf.zig` of `PT_INTERP` implement **
   * `mapElfSegments(pml4_phys: usize, elf_bytes: []const u8, pie_load_bias: usize) !SegmentMapResult`:
 1. `ehdr` of 、 `ELFCLASS64` 、 `e_type == 2 or e_type == 3` 、 `e_machine == 62` verification。
     2. `const bias: usize = if (ehdr.e_type == 3) pie_load_bias else 0;`
 3. `Elf64_Phdr` ⾛：
 * `phdr.p_type == PT_PHDR` 、 `phdr_vaddr = bias + @as(usize, @intCast(phdr.p_vaddr))` 。
 * `phdr.p_type == PT_LOAD and phdr.p_memsz > 0` of when：
          * `seg_start = bias + @as(usize, @intCast(phdr.p_vaddr))`
          * `seg_end = seg_start + @as(usize, @intCast(phdr.p_memsz))`
 * `if (phdr.p_offset <= ehdr.e_phoff and ehdr.e_phoff < phdr.p_offset + phdr.p_filesz)` `phdr_vaddr = 
 * `page_start.. page_end` of pages 、 `!vmm.isUserPageMapped(pml4_phys, page_addr)` `pmm.allocZ
 * `0..@as(usize, @intCast(phdr.p_filesz))` of Physical address to 。
     4. `return .{ .max_vaddr = max_vaddr, .phdr_vaddr = phdr_vaddr, .entry_rip = bias + @as(usize, @intCast(ehdr.e_
 * `loadStaticElf(pml4_phys, elf_bytes, argv)` （‧） Implementation：
     1. `var main_res = try mapElfSegments(pml4_phys, elf_bytes, MAIN_PIE_LOAD_BIAS);`
 2. `main_res.phdr_vaddr == 0` of when：
        `const ph_phys = pmm.allocZeroedPage() orelse return error.OutOfMemory;`
        `_ = vmm.mapPage(pml4_phys, FALLBACK_PHDR_VADDR, ph_phys, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER)
        `const ph_total = @as(usize, ehdr.e_phnum) * @as(usize, ehdr.e_phentsize);`
        `@memcpy(@as([*]u8, @ptrFromInt(ph_phys))[0..ph_total], elf_bytes[@intCast(ehdr.e_phoff) .. @intCast(ehdr.e_
        `main_res.phdr_vaddr = FALLBACK_PHDR_VADDR;`
 3. ** （ `PT_INTERP` ） of :**
        * `var at_base: usize = 0;`
        * `var start_rip: usize = main_res.entry_rip;`
 * `0..ehdr.e_phnum` ⾛、 `phdr.p_type == PT_INTERP` ⾒when：
          * `const raw_interp = elf_bytes[@intCast(phdr.p_offset) .. @intCast(phdr.p_offset + phdr.p_filesz)];`
          * `const interp_path = std.mem.sliceTo(raw_interp, 0);`
          * `const interp_node = vfs.lookup(interp_path) orelse return error.InterpreterNotFound;`
          * `const interp_res = try mapElfSegments(pml4_phys, interp_node.slice(), INTERP_LOAD_BIAS);`
          * `at_base = INTERP_LOAD_BIAS;`
          * `start_rip = interp_res.entry_rip;`
 4. **32 KiB stack（ `0x0080_0000.. 0x0080_8000` ） of :**
 * 8 pages allocated‧、pages（ `USER_STACK_TOP - 4096` = `0x0080_7000` ） of `0x0080_7E00` （ 16 boundary
 * `auxv` must `{ AT_PHDR, main_res.phdr_vaddr }`, `{ AT_PHENT, 56 }`, `{ AT_PHNUM, ehdr.e_phnum }`, `{ AT
     5. `LoadedImage{ .entry_rip = start_rip, .user_rsp = 0x0080_7E00, .initial_brk = std.mem.alignForward(usize, ma
2. **Step 2: `src/fs/vfs.zig` and `src/proc/task.zig` of update **
 * `src/proc/task.zig` of `Task` struct of `mmap_next` value、 and `sysExecve` of `cur.mmap_next` value **`
 * `src/fs/vfs.zig` of `init()` `"lib"` and `"usr"`, `"usr/lib"` add。
 * Alpine Linux with `/lib/libc.musl-x86_64.so.1` `/lib/ld-musl-x86_64.so.1` to of （⼀）
3. **Step 3: `src/syscall/dispatch.zig` of `sys_mmap` (`MAP_FIXED`) and `sys_pread64` implement **
 * **`sysMmap` of update :**
     1. `const MAP_FIXED: usize = 0x10;` 、 `const MAP_ANONYMOUS: usize = 0x20;` 。
     2. `const base_vaddr = if ((flags & MAP_FIXED) != 0 and addr != 0) (addr & ~@as(usize, vmm.PAGE_SIZE - 1)) else
 3. `base_vaddr.. base_vaddr + aligned_len` of pages 、 `!vmm.isUserPageMapped(cur.pml4_phys, page_vaddr)
 4. ** 【important】 ** of region `base_vaddr.. base_vaddr + aligned_len` 、pages and `vmm.translate(cur.p
 5. `(flags & MAP_ANONYMOUS) == 0` （） with 、 `fd` from `VfsNode` 、 `offset` （ `r9` ）
     6. `return @as(isize, @intCast(base_vaddr));`
   * **`sysPread64(fd: usize, buf_ptr: usize, count: usize, pos: usize) isize` (17):**
     1. `if (count == 0) return 0;`
     2. `if (!validateUserBuffer(buf_ptr, count)) return errno_mod.toReturn(.EFAULT);`
     3. `const cur = task.currentTask();`
     4. `if (fd >= vfs.MAX_OPEN_FILES or cur.fd_table[fd].kind != .VFS_FILE) return errno_mod.toReturn(.EBADF);`
     5. `const node = vfs.getNodeByIndex(cur.fd_table[fd].node_idx);`
     6. `const data = node.slice();`
     7. `if (pos >= data.len) return 0;`
     8. `const to_read = @min(count, data.len - pos);`
     9. `@memcpy(@as([*]u8, @ptrFromInt(buf_ptr))[0..to_read], data[pos .. pos + to_read]);`

     10. `return @as(isize, @intCast(to_read));`
4. **Step 4: `scripts/verify_qemu.sh` with of and verification **
 * `scripts/verify_qemu.sh` with 、‧ 100% `PT_INTERP` and shared 
 1. ** shared `/lib/libtinux.so`:**
 and preserve ELF （ or shared） `.cache/initramfs_root/lib/libt
 2. ** `/lib/ld-musl-x86_64.so.1`:**
 * or cache Alpine Linux of `ld-musl-x86_64.so.1` and exists use、exists
 * `_start` from stack of `auxv` ⾛、 `AT_BASE == 0x1800_0000` 、 `AT_PHDR != 0` 、 `AT_ENTRY != 0` 
 * `sys_openat` with `/lib/libtinux.so` 、 `sys_pread64` with 、 `sys_mmap` （＋ `
 * `[TINUX_DYN] ld-musl-x86_64.so.1 loaded at AT_BASE=0x18000000, mapped /lib/libtinux.so!` output。
 * stack `rsp` restore with 、 `AT_ENTRY` （execute of `_start` ） to 
 3. **`PT_INTERP` execute `/bin/dyn_inspect`:**
 * execute（ `ET_DYN` or `ET_EXEC` ） 、 ELF of Program Header `PT_INTERP` (`p_type = 3`,
 * execute of `_start` from 、 `0x2000_0000` `/lib/
 4. `.cache/initramfs_root/etc/rc.sh` of update：
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
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-011 10` when、 Builder fixloop stop、 `ESCALATI
```markdown
# Escalation Report: TASK-011
## 1. Failure Summary
* **Failed Stage:** [zig build / PT_INTERP Detection / Interpreter Load Fault / Auxv AT_BASE or AT_ENTRY Mismatch / 
* **Auxv & ELF Load Dump:** [main_entry_rip, interp_entry_rip, AT_PHDR, AT_BASE of value ]
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
[Relevant code diff for src/proc/elf.zig or src/syscall/dispatch.zig ]
```

## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
