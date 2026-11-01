# Tinux Implementation Specification: TASK-005
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter `Elf64_Ehdr` / `Elf64_Phdr` struct definitions, initial stack layouts, `sys_brk` / `sys_arch_prctl` calling contracts, or auxiliary vector tag assignments.
2. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet".
3. **Compile-Time ABI Assertions:**
   Assert exact struct sizes and field offsets for ELF and Auxiliary Vector types using `comptime` checks to guarantee System V AMD64 ABI parity.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-005 5` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Byte slice to struct pointer | `@ptrCast(*const Elf64_Ehdr, bytes.ptr)` | `@as(*align(1) const Elf64_Ehdr, @ptrCast(bytes.ptr))` |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Page alignment | Manual bitwise arithmetic | `std.mem.alignForward(usize, addr, 4096)` |
| Errno return encoding | `-@enumToInt(err)` | `-@as(isize, @intFromEnum(err))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-005`
* **Title:** `Linux x86_64 Static ELF Loader, System V AMD64 Initial Stack (argc/argv/envp/auxv), and sys_arch_prctl / sys_brk`
* **Target Subsystem:** `proc`, `syscall`, `user`
* **Target Files to Create / Modify:**
  * `src/proc/elf.zig` (Create)
  * `src/user/init_test.zig` (Create: standalone Linux `x86_64` ELF test binary source)
  * `src/syscall/dispatch.zig` (Modify: add `sys_brk`, `sys_arch_prctl`, `sys_set_tid_address`)
  * `src/main.zig` (Modify: load embedded Linux ELF binary and jump to `_start`)
  * `scripts/verify_qemu.sh` (Modify: compile `src/user/init_test.zig` into `src/proc/init_test.elf` before building)
* **Read-Only Reference Files:**
  * `src/mm/pmm.zig`
  * `src/mm/vmm.zig`
  * `src/arch/x86_64/syscall.zig`
  * `src/uapi/errno.zig`
---
## 3. ELF & System V ABI Contract (Opus 5.5 Audited)
### 3.1 ELF64 Binary & Segment Contract
1. **ELF Header (`Elf64_Ehdr`) Validation:**
   * `e_ident[0..4]` equals `\x7FELF`.
   * `e_ident[4] == 2` (`ELFCLASS64`), `e_ident[5] == 1` (`ELFDATA2LSB` Little Endian).
   * `e_type == 2` (`ET_EXEC`), `e_machine == 62` (`EM_X86_64`).
2. **Non-Page-Aligned Segment Handling:**
   Linker output for `PT_LOAD` (`p_type == 1`) segments may have `p_vaddr` values that are not 4096-byte aligned:
   * Start page: `seg_page_start = phdr.p_vaddr & ~@as(usize, 0xFFF)`.
   * End page: `seg_page_end = std.mem.alignForward(usize, phdr.p_vaddr + phdr.p_memsz, 4096)`.
   * For each page `page_vaddr` in `[seg_page_start, seg_page_end)`:
     * If not mapped: allocate zeroed physical page via `pmm.allocZeroedPage()` and map with `PTE_PRESENT | PTE_WRITABLE | PTE_USER`.
     * If already mapped: retain existing page (e.g. shared across overlapping segments).
     * Copy segment payload bytes from ELF image to target physical page offset.
3. **Initial Program Break (`brk`) Calculation:**
   Find the maximum `p_vaddr + p_memsz` among all `PT_LOAD` program headers:
   `initial_brk = std.mem.alignForward(usize, max_vaddr, 4096)`.
### 3.2 System V AMD64 ABI Initial Process Stack Layout
In accordance with Linux x86_64 ABI conventions, `%rsp` at user `_start` must be 16-byte aligned:
```text
High Address (0x0080_4000 : Top of 16 KiB User Stack)
+-------------------------------------------------------------------+
| String & Data Area (env strings, argv strings, 16-byte AT_RANDOM) |
| Padding to align stack so final RSP is 16-byte aligned            |
+-------------------------------------------------------------------+
| auxv[N]   : AT_NULL (a_type = 0, a_val = 0)             [16 bytes]|
| ...       : AT_RANDOM (25), AT_SECURE (23), AT_UID (11)..         |
| auxv[0]   : AT_PAGESZ (6), AT_PHDR (3), AT_PHENT (4), AT_PHNUM(5) |
+-------------------------------------------------------------------+
| envp[1]   : NULL (0x0000000000000000)                    [8 bytes]|
| envp[0]   : Pointer to "PATH=/bin:/usr/bin\0"            [8 bytes]|
+-------------------------------------------------------------------+
| argv[1]   : NULL (0x0000000000000000)                    [8 bytes]|
| argv[0]   : Pointer to "/sbin/init\0"                    [8 bytes]|
+-------------------------------------------------------------------+
| argc      : 1 (u64)                                      [8 bytes]| <--- Initial User RSP (16-byte aligned)
+-------------------------------------------------------------------+
Low Address (0x0080_0000 : Bottom of User Stack)
```
### 3.3 New System Calls Contract (x86_64)
| Syscall Name | Number (`rax`) | `rdi` (Arg1) | `rsi` (Arg2) | Behavior & Return (`rax`) |
| :--- | :--- | :--- | :--- | :--- |
| **`sys_brk`** | `12` | `new_brk: usize` | - | If new_brk == 0 or new_brk < initial_brk, returns current_brk without allocating. If new_brk > current_brk and new_brk <= USER_ADDR_MAX, maps zeroed pages at `[current_brk, new_brk)` with `PTE_PRESENT \| PTE_WRITABLE \| PTE_USER`, updates current_brk = new_brk, and returns new_brk. |
| **`sys_arch_prctl`** | `158` | `code: usize` | `addr: usize` | If code == 0x1002 (`ARCH_SET_FS`): validates addr < USER_ADDR_MAX (returns `-EINVAL` if invalid), writes addr to `MSR_FS_BASE` (`0xC0000100`), and returns 0. If code == 0x1003 (`ARCH_GET_FS`): writes current `fs_base` to user pointer addr and returns 0. Otherwise returns `-EINVAL`. |
| **`sys_set_tid_address`** | `218` | `tidptr: usize` | - | Stores tidptr into the task struct for child exit notification (`CLONE_CHILD_CLEARTID`), and returns the current thread ID (1). Required by musl libc and glibc TLS initialization. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/proc/elf.zig`
```zig
const std = @import("std");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");

pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const AT_NULL: u64 = 0;
pub const AT_PHDR: u64 = 3;
pub const AT_PHENT: u64 = 4;
pub const AT_PHNUM: u64 = 5;
pub const AT_PAGESZ: u64 = 6;
pub const AT_ENTRY: u64 = 9;
pub const AT_UID: u64 = 11;
pub const AT_EUID: u64 = 12;
pub const AT_GID: u64 = 13;
pub const AT_EGID: u64 = 14;
pub const AT_SECURE: u64 = 23;
pub const AT_RANDOM: u64 = 25;

pub const Elf64_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,

    comptime {
        std.debug.assert(@sizeOf(Elf64_Ehdr) == 64);
    }
};

pub const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,

    comptime {
        std.debug.assert(@sizeOf(Elf64_Phdr) == 56);
    }
};

pub const Elf64_Auxv = extern struct {
    a_type: u64,
    a_val: u64,

    comptime {
        std.debug.assert(@sizeOf(Elf64_Auxv) == 16);
    }
};

pub const LoadedImage = struct {
    entry_rip: usize,
    user_rsp: usize,
    initial_brk: usize,
};

pub const USER_STACK_TOP: usize = 0x0080_4000;
pub const USER_STACK_PAGES: usize = 4; // 16 KiB
pub const USER_STACK_BOTTOM: usize = USER_STACK_TOP - (USER_STACK_PAGES * vmm.PAGE_SIZE);

pub fn loadStaticElf(pml4_phys: usize, elf_bytes: []const u8) !LoadedImage {
    // Builder implements ELF parsing, segment mapping, and stack construction according to Section 5
}
```
### 4.2 `src/user/init_test.zig`
```zig
const std = @import("std");
const ARCH_SET_FS: usize = 0x1002;

inline fn syscall1(number: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
        : "rcx", "r11", "memory"
    );
}
inline fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
        : "rcx", "r11", "memory"
    );
}
inline fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [num] "{rax}" (number),
          [a1] "{rdi}" (arg1),
          [a2] "{rsi}" (arg2),
          [a3] "{rdx}" (arg3),
        : "rcx", "r11", "memory"
    );
}
fn writeStdout(msg: []const u8) void {
    _ = syscall3(1, 1, @intFromPtr(msg.ptr), msg.len);
}
fn failExit(code: usize) noreturn {
    _ = syscall1(60, code);
    while (true) {}
}

const TlsBlock = extern struct {
    self_ptr: usize,
    magic: u64,
};
var tls_block: TlsBlock = .{
    .self_ptr = 0,
    .magic = 0xBEEF_CAFE_FEED_FACE,
};

export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call initMain
    );
    while (true) {}
}

export fn initMain(initial_rsp: [*]const usize) void {
    const argc = initial_rsp[0];
    if (argc != 1) failExit(10);
    const argv0 = @as([*:0]const u8, @ptrFromInt(initial_rsp[1]));
    if (!std.mem.eql(u8, std.mem.span(argv0), "/sbin/init")) failExit(11);
    const envp0 = @as([*:0]const u8, @ptrFromInt(initial_rsp[3]));
    if (!std.mem.eql(u8, std.mem.span(envp0), "PATH=/bin:/usr/bin")) failExit(12);

    tls_block.self_ptr = @intFromPtr(&tls_block);
    if (syscall2(158, ARCH_SET_FS, @intFromPtr(&tls_block)) != 0) failExit(14);

    const fs_magic = asm volatile ("movq %%fs:8, %[res]"
        : [res] "=r" (-> u64),
    );
    if (fs_magic != 0xBEEF_CAFE_FEED_FACE) failExit(15);

    const cur_brk = syscall1(12, 0);
    const new_brk = syscall1(12, cur_brk + 4096);
    if (new_brk <= cur_brk) failExit(16);

    const brk_slice = @as([*]volatile u8, @ptrFromInt(cur_brk))[0..4096];
    brk_slice[0] = 0xAA;
    brk_slice[4095] = 0x55;
    if (brk_slice[0] != 0xAA or brk_slice[4095] != 0x55) failExit(17);

    writeStdout("[TINUX_ELF] Static ELF64 binary executed (Stack/Auxv/TLS/Brk verified)!\n");
    _ = syscall1(60, 0);
}
```
### 4.3 `src/syscall/dispatch.zig` Updates
Add the following functions and state to `src/syscall/dispatch.zig`:
```zig
pub const SYS_BRK: usize = 12;
pub const SYS_ARCH_PRCTL: usize = 158;
pub const SYS_SET_TID_ADDRESS: usize = 218;
pub const ARCH_SET_FS: usize = 0x1002;
pub const ARCH_GET_FS: usize = 0x1003;

var current_brk: usize = 0;
var initial_brk: usize = 0;
var current_fs_base: usize = 0;

pub fn initBrk(base: usize) void {
    initial_brk = base;
    current_brk = base;
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/proc/elf.zig` Implementation**
   * Validate ELF header: check magic bytes `\x7FELF`, 64-bit format, little endian, executable type (`ET_EXEC`), and machine `x86_64`.
   * Iterate across `ehdr.e_phnum` program headers. For each `PT_LOAD` segment:
     * Compute `seg_start = @as(usize, @intCast(phdr.p_vaddr))` and `seg_end = seg_start + @as(usize, @intCast(phdr.p_memsz))`.
     * Update `max_vaddr = @max(max_vaddr, seg_end)`.
     * If program headers are contained in this segment, store `phdr_vaddr = seg_start + (ehdr.e_phoff - phdr.p_offset)`.
     * Map pages spanning `[seg_start, seg_end)` with `PTE_PRESENT | PTE_WRITABLE | PTE_USER`.
     * Copy `phdr.p_filesz` bytes from image to mapped virtual address pages.
   * Allocate and map 4 user stack pages (`0x0080_0000` to `0x0080_4000`) with `PTE_PRESENT | PTE_WRITABLE | PTE_USER`.
   * Lay out System V initial stack data at `0x0080_3F00`:
     * `0x0080_3F00`: `"/sbin/init\x00"`
     * `0x0080_3F20`: `"PATH=/bin:/usr/bin\x00"`
     * `0x0080_3F40`: 16 random bytes for `AT_RANDOM`
   * Place stack slots starting at 16-byte aligned `0x0080_3E00`:
     * `slot[0]` = `1` (`argc`)
     * `slot[1]` = `0x0080_3F00` (`argv[0]`)
     * `slot[2]` = `0` (`argv[1]` = NULL)
     * `slot[3]` = `0x0080_3F20` (`envp[0]`)
     * `slot[4]` = `0` (`envp[1]` = NULL)
     * Auxiliary vector pairs: `AT_PAGESZ` (4096), `AT_PHDR` (`phdr_vaddr`), `AT_PHENT` (56), `AT_PHNUM` (`ehdr.e_phnum`), `AT_ENTRY` (`ehdr.e_entry`), `AT_RANDOM` (`0x0080_3F40`), `AT_SECURE` (0), and `AT_NULL` (0, 0).
   * Return `LoadedImage{ .entry_rip = @intCast(ehdr.e_entry), .user_rsp = 0x0080_3E00, .initial_brk = std.mem.alignForward(usize, max_vaddr, vmm.PAGE_SIZE) }`.
2. **Step 2: `src/syscall/dispatch.zig` Implementation**
   * In `sysBrk(new_brk)`:
     * If `new_brk == 0` or `new_brk < initial_brk`, return `current_brk`.
     * If `new_brk > initial_brk + 16 * 1024 * 1024` or `new_brk >= USER_ADDR_MAX`, return `current_brk`.
     * If expanding heap: allocate and map zeroed physical pages from `alignForward(current_brk, PAGE_SIZE)` up to `alignForward(new_brk, PAGE_SIZE)` with `PTE_PRESENT | PTE_WRITABLE | PTE_USER`.
     * Update `current_brk = new_brk` and return `new_brk`.
   * In `sysArchPrctl(code, addr)`:
     * If `code == ARCH_SET_FS`: if `addr >= USER_ADDR_MAX`, return `-EINVAL`; set `current_fs_base = addr`, write to `MSR_FS_BASE` via `wrmsr`, and return `0`.
     * If `code == ARCH_GET_FS`: if `!validateUserBuffer(addr, 8)`, return `-EFAULT`; store `current_fs_base` into user pointer, and return `0`.
     * Otherwise return `-EINVAL`.
3. **Step 3: `src/main.zig` Updates**
   * Embed `init_test.elf` using `@embedFile("proc/init_test.elf")`.
   * In `kmain()`, initialize kernel, parse ELF via `elf.loadStaticElf`, initialize heap break via `dispatch.initBrk`, and jump to user space via `syscall.enterUserMode(image.entry_rip, image.user_rsp)`.
4. **Step 4: `scripts/verify_qemu.sh` Updates**
   * Compile `src/user/init_test.zig` to `src/proc/init_test.elf` before kernel compilation using `zig build-exe -target x86_64-linux-none -O ReleaseSmall -fno-pie`.
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-005 5
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-005
[TINUX_ELF] Loaded static ELF64 image, jumping to _start...
[TINUX_ELF] Static ELF64 binary executed (Stack/Auxv/TLS/Brk verified)!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-005
[HARNESS] SUCCESS: TASK-005 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-005 5` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-005
## 1. Failure Summary
* **Failed Stage:** [init_test.elf Build / ELF Header Validation / PT_LOAD Mapping Fault / User Stack Alignment Fault / TLS %fs:0 Read Fault / sys_brk Memory Fault]
* **Exit Status from init_test.zig (if applicable):** [Exit code 10..20 indicating assertion failure]
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
[Code diff of src/proc/elf.zig or src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
