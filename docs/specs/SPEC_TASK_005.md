# Tinux Implementation Specification: TASK-005
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-004` Passed (`./scripts/verify_qemu.sh TASK-004 5` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition `Elf64_Ehdr` / `Elf64_Phdr` struct、stack of 、 `sys_brk` / `sys_arch_p
2. **Strict Zig Version Idioms:**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
3. **Compile-Time ABI Assertions （ ABI structverification） :**

 ELF and Auxiliary Vector struct of `comptime` ‧。
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-005 5` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| column → struct | `@ptrCast(*const Elf64_Ehdr, bytes.ptr)` | `@as(*align(1) const Elf64_Ehdr, @ptrCast(byt
| pages | `addr & ~0xFFF` (typeerror) | `addr & ~@as(usize, 0xFFF)` |
| pages | ⼿ | `std.mem.alignForward(usize, addr, 4096)` |
| | read | `@embedFile("...")` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-005`
* **Title:** `Linux x86_64 Static ELF Loader, System V AMD64 Initial Stack (argc/argv/envp/auxv), and sys_arch_prctl
* **Target Subsystem:** `proc`, `syscall`, `user`
* **Target Files to Create / Modify:**
  * `src/proc/elf.zig` (Create)
  * `src/user/init_test.zig` (Create: standalone Linux `x86_64` ELF test binary source)
  * `src/syscall/dispatch.zig` (Modify: add `sys_brk`, `sys_arch_prctl`, `sys_set_tid_address`)
  * `src/main.zig` (Modify: load embedded Linux ELF binary and jump to `_start`)
  * `scripts/verify_qemu.sh` (Modify: compile `src/user/init_test.zig` into `src/proc/init_test.elf` before building
* **Read-Only Reference Files:**
  * `src/mm/pmm.zig`
  * `src/mm/vmm.zig`
  * `src/arch/x86_64/syscall.zig`
  * `src/uapi/errno.zig`
---
## 3. Linux ELF64, Initial Stack & Syscall Contract (Opus 5.5 Audited)
### 3.1 ELF64 Header & `PT_LOAD` Mapping Contract
1. **Header Validation:**
 * `e_ident[0..4]` `\x7FELF` 。
   * `e_ident[4] == 2` (`ELFCLASS64`) 、 `e_ident[5] == 1` (`ELFDATA2LSB` Little Endian) 。
 * `e_type == 2` (`ET_EXEC`) 、 `e_machine == 62` (`EM_X86_64`) 。
2. **Non-Page-Aligned Segment Handling （important） :**
 output `PT_LOAD` (`p_type == 1`) of `p_vaddr` 、must 4096 boundary ⼀（e.g.： `p_vadd
 * startpages： `seg_page_start = phdr.p_vaddr & ~@as(usize, 0xFFF)`
 * exitpages： `seg_page_end = std.mem.alignForward(usize, phdr.p_vaddr + phdr.p_memsz, 4096)`
 * pages `page_vaddr` 、 `vmm.translate(pml4, page_vaddr)` verify：
 * ** of when :** `pmm.allocZeroedPage()` with pages allocated、 `vmm.mapPage(pml4, page_vaddr, phys, PTE_PRESEN
 * ** of when :** of pages of ⽤（ with ）。
 * ： Identity Map 、pages Physical address `phys_page = vmm.translate(pml4, page_v
3. **Initial Program Break (`brk`) Calculation:**
 of `PT_LOAD` of ⼤ of `p_vaddr + p_memsz` 、 `initial_brk = std.mem.alignForward(usize, max_
### 3.2 System V AMD64 ABI Initial Process Stack Layout
Linux of （ musl / glibc / Zig Linux runtime ）、 `_start` of `RSP` **16 boundary（ `rsp & 
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
| argc      : 1 (u64)                                      [8 bytes]| <--- Initial User RSP (16-byte aligned!)
+-------------------------------------------------------------------+
Low Address (0x0080_0000 : Bottom of User Stack)
```
### 3.3 New System Calls Contract (x86_64)
| Syscall Name | Number (`rax`) | `rdi` (Arg1) | `rsi` (Arg2) | Behavior & Return (`rax`) |
| :--- | :--- | :--- | :--- | :--- |
| **`sys_brk`** | `12` | `new_brk: usize` | - | ‧ `new_brk < initial_brk` of when： of `current_brk` of 。
| **`sys_arch_prctl`** | `158` | `code: usize` | `addr: usize` | ‧ `code == 0x1002` (`ARCH_SET_FS`): `addr >= USER_AD
| **`sys_set_tid_address`** | `218` | `tidptr: usize` | - | of thread ID `1` (`isize`) （ musl TLS initialized with mandatory
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
pub const AuxvEntry = extern struct {

    a_type: u64,
    a_val: u64,
    comptime {
        std.debug.assert(@sizeOf(AuxvEntry) == 16);
    }
};
pub const LoadedImage = struct {
    entry_rip: usize,
    user_rsp: usize,
    initial_brk: usize,
};
pub const USER_STACK_BOTTOM: usize = 0x0080_0000;
pub const USER_STACK_PAGES: usize = 4; // 16 KiB (0x0080_0000 .. 0x0080_4000)
pub const USER_STACK_TOP: usize = USER_STACK_BOTTOM + (USER_STACK_PAGES * vmm.PAGE_SIZE);
pub fn loadStaticElf(pml4_phys: usize, elf_bytes: []const u8) !LoadedImage {
    // Builder implements ELF parsing, PT_LOAD mapping, and initial stack construction according to Section 5
}
```
### 4.2 `src/syscall/dispatch.zig` (Additions)
 of `src/syscall/dispatch.zig` of constants‧state‧function add、 `syscallDispatch` of `switch` ⽂ ：
```zig
const syscall_arch = @import("../arch/x86_64/syscall.zig");
pub const SYS_BRK: u64 = 12;
pub const SYS_ARCH_PRCTL: u64 = 158;
pub const SYS_SET_TID_ADDRESS: u64 = 218;
pub const ARCH_SET_GS: usize = 0x1001;
pub const ARCH_SET_FS: usize = 0x1002;
pub const ARCH_GET_FS: usize = 0x1003;
pub const ARCH_GET_GS: usize = 0x1004;
pub const MSR_FS_BASE: u32 = 0xC0000100;
var initial_brk: usize = 0;
var current_brk: usize = 0;
var current_fs_base: usize = 0;
pub fn initBrk(start_brk: usize) void {
    initial_brk = start_brk;
    current_brk = start_brk;
}
pub fn sysBrk(new_brk: usize) isize {
    // Builder implements dynamic heap page mapping according to Section 3.3 and Section 5
}
pub fn sysArchPrctl(code: usize, addr: usize) isize {
    // Builder implements ARCH_SET_FS (MSR 0xC0000100) and ARCH_GET_FS according to Section 3.3 and Section 5
}
pub fn sysSetTidAddress(_: usize) isize {
    return 1; // Return PID/TID 1 for init process
}
```
### 4.3 `src/user/init_test.zig` (Standalone Linux `x86_64` Static ELF Binary)
Create `src/user/init_test.zig` with the following implementation: `scripts/verify_qemu.sh` 
```zig
const std = @import("std");
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call userMain
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
inline fn syscall2(num: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> isize),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
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
    _ = syscall1(60, code);
    unreachable;
}
var global_bss_counter: u64 = 0;
var tls_area: [8]u64 align(16) = .{ 0x1122334455667788, 0, 0, 0, 0, 0, 0, 0 };
export fn userMain(initial_rsp: [*]const u64) callconv(.C) noreturn {
    // 1. Verify 16-byte stack alignment at _start
    if ((@intFromPtr(initial_rsp) & 0xF) != 0) failExit(10);
    // 2. Verify argc == 1 and argv[0] starts with "/sbin/init"
    const argc = initial_rsp[0];
    if (argc != 1) failExit(11);
    const argv0 = @as([*]const u8, @ptrFromInt(initial_rsp[1]));
    if (argv0[0] != '/' or argv0[1] != 's' or argv0[6] != 'i') failExit(12);
    if (initial_rsp[2] != 0) failExit(13); // argv[1] == NULL
    // 3. Walk past envp to locate Auxiliary Vector (auxv)
    var idx: usize = 3;
    while (initial_rsp[idx] != 0) : (idx += 1) {}
    idx += 1; // Skip envp NULL terminator
    var found_pagesz: bool = false;
    var found_random: bool = false;
    while (initial_rsp[idx] != 0) : (idx += 2) {
        const a_type = initial_rsp[idx];
        const a_val = initial_rsp[idx + 1];
        if (a_type == 6 and a_val == 4096) found_pagesz = true; // AT_PAGESZ
        if (a_type == 25 and a_val != 0) { // AT_RANDOM
            const rnd = @as(*const u64, @ptrFromInt(a_val)).*;
            if (rnd != 0) found_random = true;
        }
    }
    if (!found_pagesz or !found_random) failExit(14);
    // 4. Verify .bss zero-initialization
    if (global_bss_counter != 0) failExit(15);
    global_bss_counter = 42;
    // 5. Verify sys_arch_prctl(ARCH_SET_FS = 0x1002) and hardware %fs:0 memory read
    const rc_prctl = syscall2(158, 0x1002, @intFromPtr(&tls_area));
    if (rc_prctl != 0) failExit(16);
    const fs_val = asm volatile ("movq %%fs:0, %[ret]"
        : [ret] "=r" (-> u64),
    );
    if (fs_val != 0x1122334455667788) failExit(17);

    // 6. Verify sys_brk(0) query and sys_brk(base + 8192) dynamic allocation
    const brk_base = syscall1(12, 0);
    if (brk_base <= 0) failExit(18);
    const new_brk = @as(usize, @intCast(brk_base)) + 8192;
    const brk_res = syscall1(12, new_brk);
    if (brk_res != @as(isize, @intCast(new_brk))) failExit(19);
    // Write and read back at newly allocated heap memory
    const heap_ptr = @as(*volatile u64, @ptrFromInt(@as(usize, @intCast(brk_base)) + 4096));
    heap_ptr.* = 0xCAFE_F00D_1234_5678;
    if (heap_ptr.* != 0xCAFE_F00D_1234_5678) failExit(20);
    // 7. Output success message via sys_write and exit(0)
    writeStdout("[TINUX_ELF] Static ELF64 binary executed (Stack/Auxv/TLS/Brk verified)!\n");
    _ = syscall1(60, 0);
    unreachable;
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/proc/elf.zig` Implementation **
   * `loadStaticElf(pml4_phys: usize, elf_bytes: []const u8) !LoadedImage`:
     1. `if (elf_bytes.len < @sizeOf(Elf64_Ehdr)) return error.InvalidElf;`
     2. `const ehdr = @as(*align(1) const Elf64_Ehdr, @ptrCast(elf_bytes.ptr));`
 3. （ `0x7F, 'E', 'L', 'F'` ）、 `e_ident[4] == 2` 、 `e_ident[5] == 1` 、 `e_type == 2` 、 `e_machine == 62` 
 4. `var max_vaddr: usize = 0;` 、 `var phdr_vaddr: usize = 0;` initialized。
 5. `0..ehdr.e_phnum` of loop with `Elf64_Phdr` （ `ehdr.e_phoff + i * ehdr.e_phentsize` ）：
        * `if (phdr.p_type != PT_LOAD or phdr.p_memsz == 0) continue;`
        * `const seg_start = @as(usize, @intCast(phdr.p_vaddr));`
        * `const seg_end = seg_start + @as(usize, @intCast(phdr.p_memsz));`
        * `if (seg_end > max_vaddr) max_vaddr = seg_end;`
 * `if (phdr.p_offset <= ehdr.e_phoff and ehdr.e_phoff < phdr.p_offset + phdr.p_filesz)` of when、 `phdr_vaddr =
        * `const page_start = seg_start & ~@as(usize, vmm.PAGE_SIZE - 1);`
        * `const page_end = std.mem.alignForward(usize, seg_end, vmm.PAGE_SIZE);`
 * `var page_addr = page_start; while (page_addr < page_end) : (page_addr += vmm.PAGE_SIZE)` with loop、 `vmm.t
 * ** of :** `0..@as(usize, @intCast(phdr.p_filesz))` of 。pagesboundary with 
 6. ** stack（ `0x0080_0000.. 0x0080_4000` ） of and :**
 * `0..USER_STACK_PAGES` of loop with pages 、 `USER_STACK_BOTTOM + i * 4096` `PTE_PRESENT | PTE_WRI
 * of stackpages（virtual address `USER_STACK_TOP - 4096` ＝ `0x0080_3000` ） of Physical address `top_page_phys = vm
 * of pages of 、 of （virtual address `vaddr` write `t
 * `0x0080_3F00`: ⽂column `"/sbin/init\x00"` (11 bytes)
 * `0x0080_3F20`: ⽂column `"PATH=/bin:/usr/bin\x00"` (19 bytes)
 * `0x0080_3F40`: 16 （ `u64` with `0xA5A5_5A5A_DEAD_BEEF`, `0x0123_4567_89AB_CDEF` ）
 * `0x0080_3E00` （ **16 boundary！ ** ） `user_rsp` and 、 `[*]u64` and ：
            * `slot[0]` = `1` (`argc`)
            * `slot[1]` = `0x0080_3F00` (`argv[0]`)
            * `slot[2]` = `0` (`argv[1] = NULL`)
            * `slot[3]` = `0x0080_3F20` (`envp[0]`)
            * `slot[4]` = `0` (`envp[1] = NULL`)
            * `slot[5..7]` = `AT_PAGESZ (6)`, `4096`
            * `slot[7..9]` = `AT_PHDR (3)`, `phdr_vaddr`
            * `slot[9..11]` = `AT_PHENT (4)`, `@sizeOf(Elf64_Phdr)` (`56`)
            * `slot[11..13]` = `AT_PHNUM (5)`, `ehdr.e_phnum`
            * `slot[13..15]` = `AT_ENTRY (9)`, `ehdr.e_entry`
            * `slot[15..17]` = `AT_RANDOM (25)`, `0x0080_3F40`
            * `slot[17..19]` = `AT_SECURE (23)`, `0`
            * `slot[19..21]` = `AT_NULL (0)`, `0`
     7. `LoadedImage{ .entry_rip = @intCast(ehdr.e_entry), .user_rsp = 0x0080_3E00, .initial_brk = std.mem.alignForw
2. **Step 2: `src/syscall/dispatch.zig` Implementation **
   * `sysBrk(new_brk: usize) isize`:
     1. `if (new_brk < initial_brk) return @as(isize, @intCast(current_brk));`
     2. `if (new_brk > initial_brk + 16 * 1024 * 1024) return @as(isize, @intCast(current_brk));`
     3. `const old_page_end = std.mem.alignForward(usize, current_brk, vmm.PAGE_SIZE);`
     4. `const new_page_end = std.mem.alignForward(usize, new_brk, vmm.PAGE_SIZE);`
     5. `if (new_page_end > old_page_end)`:
 * `var page = old_page_end; while (page < new_page_end) : (page += vmm.PAGE_SIZE)` with loop、 `vmm.translate
     6. `current_brk = new_brk;`
     7. `return @as(isize, @intCast(current_brk));`
   * `sysArchPrctl(code: usize, addr: usize) isize`:
     1. `if (code == ARCH_SET_FS)`:

        * `if (addr >= USER_ADDR_MAX) return errno_mod.toReturn(.EINVAL);`
        * `syscall_arch.wrmsr(MSR_FS_BASE, addr);`
        * `current_fs_base = addr;`
        * `return 0;`
     2. `if (code == ARCH_GET_FS)`:
        * `if (!validateUserBuffer(addr, @sizeOf(u64))) return errno_mod.toReturn(.EFAULT);`
        * `@as(*align(1) u64, @ptrFromInt(addr)).* = current_fs_base;`
        * `return 0;`
 3. `return errno_mod.toReturn(.EINVAL);` 。
3. **Step 3: `src/main.zig` of update **
 * `const elf = @import("proc/elf.zig");` and `const dispatch = @import("syscall/dispatch.zig");` port。
 * `const init_elf_bytes = @embedFile("proc/init_test.elf");` with test⽤ Linux ELF 。
 * `kmain()` with `serial`, `gdt`, `idt`, `pmm`, `vmm`, `heap`, `syscall` initialized：
     1. `serial.writeString("[TINUX_TEST] START: TASK-005\n");`
     2. `const image = elf.loadStaticElf(vmm.getKernelPml4Phys(), init_elf_bytes) catch @panic("ELF load failed");`
     3. `dispatch.initBrk(image.initial_brk);`
     4. `serial.writeString("[TINUX_ELF] Loaded static ELF64 image, jumping to _start...\n");`
     5. `syscall.enterUserMode(image.entry_rip, image.user_rsp);`
 * 、 `src/syscall/dispatch.zig` of `sysExit(0)` of PASS output `[TINUX_TEST] PASS: TASK-005\n` update（
4. **Step 4: `scripts/verify_qemu.sh` of update **
 * `zig build` execute 、 of with `src/user/init_test.zig` Linux `x86_64` ELF and 
     ```bash
     echo "[HARNESS] Compiling standalone Linux x86_64 ELF test binary..."
     if ! zig build-exe src/user/init_test.zig -target x86_64-linux-none -O ReleaseSmall -fno-pie -femit-bin=src/pro
         echo "[HARNESS] FAIL: Failed to build init_test.elf"
         exit 1
     fi
     ```
 * ※ use of Zig with `-fno-pie` or ⾮ of when、 `-fno-pie` 、 `elf.zig`
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
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-005 5` when、 Builder fixloop stop、 `ESCALATIO
```markdown
# Escalation Report: TASK-005
## 1. Failure Summary
* **Failed Stage:** [init_test.elf Build / ELF Header Validation / PT_LOAD Mapping Fault / User Stack Alignment Faul
* **Exit Status from init_test.zig (if applicable):** [10..20 of of with ]
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
[ src/proc/elf.zig or src/syscall/dispatch.zig of ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
