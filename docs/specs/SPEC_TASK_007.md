# Tinux Implementation Specification: TASK-007
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-006` Passed (`./scripts/verify_qemu.sh TASK-006 5` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition `Task` struct、 `syscall_entry.S` of frameswitch、 `vmm.cloneUserPml4` of pagestableduplicated
2. **Strict Zig Version Idioms:**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
3. **Context Switch Stack Discipline （stackswitch of strictly adhere） :**
 processswitchmust `proc.activateTask(target)` 、 `CR3` （pagestable）、 `MSR_FS_BASE` （ TLS ）、 `sys
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-007 5` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |

| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| return value of | `@bitCast(u64, ret_isize)` | `@as(u64, @bitCast(ret_isize))` |
| struct of zero‧initialized | `std.mem.zeroes(T)` (⾮ extern with) | ⽰valuedefinition `.{}` |
| column | loop⼿ | `@memcpy(dst, src)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-007`
* **Title:** `Multi-Process Management (Task Table & Address Space Isolation), sys_fork / sys_clone / sys_execve / s
* **Target Subsystem:** `proc`, `mm`, `fs`, `syscall`, `arch/x86_64`
* **Target Files to Create / Modify:**
  * `src/arch/x86_64/syscall_entry.S` (Modify: support context switching by setting `%rsp = %rax` returned from `sys
  * `src/mm/vmm.zig` (Modify: add `cloneUserPml4` and `createFreshUserPml4`)
  * `src/fs/vfs.zig` (Modify: support per-task `fd_table` cloning and `fcntl` / `dup2` FD duplication)
  * `src/proc/task.zig` (Create: `Task` struct, process table `MAX_TASKS = 16`, `activateTask`, `forkCurrentTask`)
  * `src/syscall/dispatch.zig` (Modify: implement `fork`/`vfork`/`clone`, `execve`, `wait4`, `fcntl`, `dup2`, `getcw
  * `src/main.zig` (Modify: initialize PID 1 via `task.zig` and launch `/bin/busybox sh /etc/rc.sh`)
  * `scripts/verify_qemu.sh` (Modify: add `/etc/rc.sh` and `/bin/sh` to `initramfs.cpio`)
---
## 3. Process Architecture & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 Context-Switching `syscallEntry` Mechanism
`fork`, `execve`, `wait4`, `exit` process of switch of ⾏、 `syscallDisp
```zig
export fn syscallDispatch(frame: *SyscallFrame) callconv(.C) *SyscallFrame
```
1. **Entry (`syscallEntry`):**
 * of `RSP` save、 of task of stack（ `syscall_kernel_rsp` ） switch `SyscallFrame`
 * `current_task.saved_frame = frame` and 。
2. **Return Value Slot (`frame.rax`):**
 * `SyscallFrame` of `96` （ `syscall_num` and with ）、⼊ Syscall Number preserve、
 * `syscall_entry.S` of with 、 `call syscallDispatch` of return value（switchtask of `*SyscallFrame` ） `movq %rax
### 3.2 Address Space Isolation & Fast `cloneUserPml4` Contract
process⾃ of `pml4_phys` 。 `fork` / `clone` `vmm.cloneUserPml4(src_pml4_phys)` of 
1. `dst_pml4_phys` （ and `dst_pdpt_phys`, `dst_pd_phys` ） `pmm.allocZeroedPage()` with 。
2. `src` of `PD` （ `0..512` 、 2 MiB region） ⾛：
 * **`(pde & PTE_PRESENT) == 0` of when :** 。
 * **`(pde & PTE_USER) == 0` of when（ Identity Map / heapregion） :**
 `PT` 、 `dst_pd.entries[pdi] = pde` and ** of pagestable（ `PT` ） of shared ** （
 * **`(pde & PTE_USER) != 0` of when（user spacepages 2 MiB region） :**
 `dst_pt_phys = pmm.allocZeroedPage()` 、 `dst_pd.entries[pdi] = dst_pt_phys | (pde & 0xFFF)` 
 * `(pte & PTE_PRESENT) == 0`: 。
 * `(pte & PTE_USER) == 0`: `dst_pt.entries[pti] = pte` （⼀ 2 MiB pagesframe shared）。
 * `(pte & PTE_USER) != 0`: ** user spacepages ** 、 `new_page = pmm.allocZeroedPage()` allocated、 `old_page
### 3.3 Multi-Process & Shell Syscalls Contract
BusyBox `ash` （ `/bin/busybox sh /etc/rc.sh` ） read、⼦process（） `fork` + `execve` + `wa
| Syscall | Num | Arguments | Exact Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_clone`** | `56` | `flags, child_stack, ptid, ctid, newtls` | `forkCurrentTask(frame, child_stack)` execute。parent
| **`sys_fork` / `vfork`** | `57` / `58` | (none) | `forkCurrentTask(frame, 0)` execute、 ⼦process to switch `
| **`sys_execve`** | `59` | `path_ptr, argv_ptr, envp_ptr` | of user space from and `argv` column buffer
| **`sys_wait4`** | `61` | `pid, wstatus_ptr, options, rusage` | ⼦task 。 `.ZOMBIE` of ⼦exit
| **`sys_exit` / `exit_group`** | `60` / `231` | `status` | ‧ `current.pid == 1` of when：test and PASS output
| **`sys_fcntl`** | `72` | `fd, cmd, arg` | ** 【 BusyBox `ash` mandatory】 ** `cmd == 0` (`F_DUPFD`) or `cmd == 1030` (`F
| **`sys_dup` / `dup2` / `dup3`** | `32, 33, 292` | `oldfd, newfd,...` | FD duplicated FD 。 |
| **`sys_getcwd`** | `79` | `buf_ptr, size` | buffer `"/"\x00` (2 bytes) write、 `2` 。 |
| **`sys_access` / `faccessat` / `faccessat2`** | `21, 269, 439` | `(dirfd,) path_ptr, mode` | `"/"` or `vf
| **Signal & Pgrp Stubs** | Misc | `13, 14, 15, 34, 80, 109, 111, 112, 121, 228, 318` | `rt_sigaction(13)=0`, `rt_si
---
## 4. Exact Data Structures & Signatures

### 4.1 `src/arch/x86_64/syscall_entry.S` (Context-Switch Capable Version)
`syscall_entry.S` of `syscallEntry` of update（ `enterUserMode` of ）：
```asm
.global syscallEntry
.extern syscallDispatch
.align 16
syscallEntry:
    /* 1. Save User RSP and switch to current task's Kernel Syscall Stack */
    movq %rsp, syscall_user_rsp_scratch(%rip)
    movq syscall_kernel_rsp(%rip), %rsp
    /* 2. Build 128-byte SyscallFrame on current Kernel Stack */
    pushq syscall_user_rsp_scratch(%rip) /* offset 120: user_rsp */
    pushq %rcx                           /* offset 112: user_rip */
    pushq %r11                           /* offset 104: user_rflags */
    pushq %rax                           /* offset 96:  rax (syscall_num on entry, return val on exit) */
    pushq %rdi                           /* offset 88:  rdi (arg1) */
    pushq %rsi                           /* offset 80:  rsi (arg2) */
    pushq %rdx                           /* offset 72:  rdx (arg3) */
    pushq %r10                           /* offset 64:  r10 (arg4) */
    pushq %r8                            /* offset 56:  r8  (arg5) */
    pushq %r9                            /* offset 48:  r9  (arg6) */
    pushq %rbx                           /* offset 40:  rbx */
    pushq %rbp                           /* offset 32:  rbp */
    pushq %r12                           /* offset 24:  r12 */
    pushq %r13                           /* offset 16:  r13 */
    pushq %r14                           /* offset 8:   r14 */
    pushq %r15                           /* offset 0:   r15 */
    /* 3. Call Zig dispatcher: rdi = *SyscallFrame, returns target *SyscallFrame in rax */
    movq %rsp, %rdi
    call syscallDispatch
    /* 4. Switch RSP to returned *SyscallFrame (supports fork/wait4/exit context switch!) */
    movq %rax, %rsp
    /* 5. Restore all registers including return value in %rax */
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    popq %r9
    popq %r8
    popq %r10
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rax                            /* restore return value from frame.rax */
    popq %r11                            /* restore user_rflags */
    popq %rcx                            /* restore user_rip */
    popq %rsp                            /* restore user_rsp */
    sysretq
```
### 4.2 `src/mm/vmm.zig` Additions
 of `src/mm/vmm.zig` of 2 of function add：
```zig
/// Creates a fresh user PML4 that shares kernel mappings (non-PTE_USER PDEs)
/// and has an empty user address space ready for sys_execve.
pub fn createFreshUserPml4() ?usize {
    const src_pml4 = @as(*PageTable, @ptrFromInt(kernel_pml4_phys));
    const src_pdpt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(src_pml4.entries[0] & PTE_ADDR_MASK))));
    const src_pd = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(src_pdpt.entries[0] & PTE_ADDR_MASK))));
    const dst_pml4_phys = pmm.allocZeroedPage() orelse return null;
    const dst_pdpt_phys = pmm.allocZeroedPage() orelse return null;
    const dst_pd_phys = pmm.allocZeroedPage() orelse return null;
    const dst_pml4 = @as(*PageTable, @ptrFromInt(dst_pml4_phys));
    const dst_pdpt = @as(*PageTable, @ptrFromInt(dst_pdpt_phys));
    const dst_pd = @as(*PageTable, @ptrFromInt(dst_pd_phys));
    dst_pml4.entries[0] = dst_pdpt_phys | PTE_PRESENT | PTE_WRITABLE | PTE_USER;
    dst_pdpt.entries[0] = dst_pd_phys | PTE_PRESENT | PTE_WRITABLE | PTE_USER;

    // Share all kernel PDEs (first 128 MiB = 64 PDEs, plus kernel heap PDE at 256 MiB = index 128)
    for (0..512) |pdi| {
        const pde = src_pd.entries[pdi];
        if ((pde & PTE_PRESENT) != 0 and (pde & PTE_USER) == 0) {
            dst_pd.entries[pdi] = pde;
        } else if ((pde & PTE_PRESENT) != 0 and (pde & PTE_USER) != 0) {
            // Contains mixed kernel identity map and user pages: copy only kernel PTEs
            const src_pt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pde & PTE_ADDR_MASK))));
            const dst_pt_phys = pmm.allocZeroedPage() orelse return null;
            const dst_pt = @as(*PageTable, @ptrFromInt(dst_pt_phys));
            for (0..512) |pti| {
                const pte = src_pt.entries[pti];
                if ((pte & PTE_PRESENT) != 0 and (pte & PTE_USER) == 0) {
                    dst_pt.entries[pti] = pte;
                }
            }
            dst_pd.entries[pdi] = dst_pt_phys | PTE_PRESENT | PTE_WRITABLE;
        }
    }
    return dst_pml4_phys;
}
/// Deep-copies all PTE_USER pages from src_pml4_phys into a new PML4 for fork/clone.
pub fn cloneUserPml4(src_pml4_phys: usize) ?usize {
    // Builder implements deep copy of PTE_USER pages while sharing kernel PDEs/PTEs per Section 3.2
}
```
### 4.3 `src/proc/task.zig`
```zig
const std = @import("std");
const vmm = @import("../mm/vmm.zig");
const vfs = @import("../fs/vfs.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const syscall_arch = @import("../arch/x86_64/syscall.zig");
const SyscallFrame = syscall_arch.SyscallFrame;
pub const MAX_TASKS: usize = 16;
pub const KSTACK_SIZE: usize = 16384;
pub const TaskState = enum(u8) {
    UNUSED = 0,
    RUNNING = 1,
    READY = 2,
    WAITING = 3,
    ZOMBIE = 4,
};
pub const Task = struct {
    state: TaskState = .UNUSED,
    pid: usize = 0,
    parent_pid: usize = 0,
    pml4_phys: usize = 0,
    saved_frame: *SyscallFrame = undefined,
    fs_base: usize = 0,
    initial_brk: usize = 0,
    current_brk: usize = 0,
    mmap_next: usize = 0x4000_0000,
    exit_status: usize = 0,
    wait_wstatus_ptr: usize = 0,
    fd_table: [vfs.MAX_OPEN_FILES]vfs.OpenFile = [_]vfs.OpenFile{.{}} ** vfs.MAX_OPEN_FILES,
    kstack: [KSTACK_SIZE]u8 align(16) = undefined,
    pub fn kstackTop(self: *Task) usize {
        return @intFromPtr(&self.kstack) + KSTACK_SIZE;
    }
};
extern var syscall_kernel_rsp: u64;
pub var tasks: [MAX_TASKS]Task = [_]Task{.{}} ** MAX_TASKS;
pub var current_task_idx: usize = 0;
var next_pid: usize = 1;
pub fn currentTask() *Task {
    return &tasks[current_task_idx];
}
pub fn initPid1(pml4_phys: usize, initial_brk: usize) *Task {

    // Builder initializes tasks[0] as PID 1 (state = .RUNNING) and activates its kernel stack & CR3
}
pub fn activateTask(task_idx: usize) void {
    // Builder updates current_task_idx, syscall_kernel_rsp, gdt.setKernelStack, wrmsr(MSR_FS_BASE), and vmm.loadCr3
}
pub fn forkCurrentTask(parent_frame: *SyscallFrame, child_user_rsp_override: usize) ?usize {
    // Builder allocates free task slot, clones PML4, copies fd_table/brk/fs_base, places cloned SyscallFrame at top
}
pub fn findNextRunnable() ?usize {
    // Builder finds a task in .READY or .RUNNING state
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/vfs.zig` of process & **
 * `vfs.lookup(raw_path)` 、 `"bin/sh"`, `"bin/echo"`, `"bin/cat"`, `"bin/uname"`, `"sh"`, `"echo
 * task and of `fd_table` （ or `task.currentTask().fd_table` ） `open`, `getFile`, `close` 、
 * `dupFd`: `old_fd` `0, 1, 2` or verify、 `min_new_fd.. MAX_OPEN_FILES` of 
2. **Step 2: `src/proc/task.zig` Implementation **
   * `activateTask(task_idx: usize)`:
     1. `current_task_idx = task_idx;`
     2. `const t = &tasks[task_idx];`
     3. `t.state = .RUNNING;`
     4. `const ktop = t.kstackTop();`
     5. `syscall_kernel_rsp = ktop;`
     6. `gdt.setKernelStack(ktop);`
     7. `syscall_arch.wrmsr(0xC0000100, t.fs_base);` (`MSR_FS_BASE`)
     8. `vmm.loadCr3(t.pml4_phys);`
   * `forkCurrentTask(parent_frame: *SyscallFrame, child_user_rsp_override: usize) ?usize`:
 1. `tasks` from `.UNUSED` of `child_idx` （ `return null` ）。
     2. `const parent = currentTask();`
     3. `parent.saved_frame = parent_frame;`
     4. `const child_pml4 = vmm.cloneUserPml4(parent.pml4_phys) orelse return null;`
     5. `const child = &tasks[child_idx];`
     6. `next_pid += 1; child.pid = next_pid;`
     7. `child.parent_pid = parent.pid; child.state = .READY; child.pml4_phys = child_pml4;`
     8. `child.fs_base = parent.fs_base; child.initial_brk = parent.initial_brk; child.current_brk = parent.current_
     9. `child.fd_table = parent.fd_table;`
 10. ⼦ of stack `child_frame_addr = child.kstackTop() - @sizeOf(SyscallFrame)` `*SyscallFrame` 
     11. `child.saved_frame.* = parent_frame.*;`
 12. `child.saved_frame.rax = 0;` （⼦process of return value `0` ）。
     13. `if (child_user_rsp_override != 0) child.saved_frame.user_rsp = child_user_rsp_override;`
 14. `parent_frame.rax = child.pid;` （parentprocess of return value⼦ of PID ）。
     15. `parent.state = .READY;`
     16. `return child_idx;`
3. **Step 3: `src/syscall/dispatch.zig` of process **
 * `SyscallFrame` of `96` of `rax: u64` （ or `syscall_num` `rax` and referenced） 、 of 
 * `sysBrk`, `sysMmap`, `sysArchPrctl` of state `task.currentTask()` of （ `current_brk`, `mmap_next
   * **`sysExecve(frame: *SyscallFrame, path_ptr: usize, argv_ptr: usize, envp_ptr: usize) *SyscallFrame`:**
 1. of empty from execute `path_buf` and 、 `argv_ptr` （ NULL of `[*]const usize` column、⼤ 16 、⽂
 2. `vfs.lookup(path)` with node （⾒ from `frame.rax = @bitCast(errno_mod.toReturn(.ENOENT)); 
 3. of first `"#!"` （ Shebang 、e.g.： `#!/bin/sh\n` ） with 、 1 ⾏⽬ of ⾏ with of （e.g.： `
     4. `const new_pml4 = vmm.createFreshUserPml4() orelse ...;`
     5. `const image = elf.loadStaticElf(new_pml4, elf_node.data, argv_slices) catch ...;`
     6. `const cur = task.currentTask();`
     7. `cur.pml4_phys = new_pml4; cur.initial_brk = image.initial_brk; cur.current_brk = image.initial_brk; cur.mma
     8. `frame.* = .{ .r15 = 0, .r14 = 0, .r13 = 0, .r12 = 0, .rbp = 0, .rbx = 0, .r9 = 0, .r8 = 0, .r10 = 0, .rdx =
     9. `task.activateTask(task.current_task_idx);`
     10. `return frame;`
4. **Step 4: `scripts/verify_qemu.sh` and `src/main.zig` of update **
 * `scripts/verify_qemu.sh` with `.cache/initramfs_root/etc/rc.sh` of with create、 `chmod +x` `initramfs.c
     ```sh
     #!/bin/sh
     echo "[TINUX_SH] BusyBox ash shell script started (PID $$)"
     /bin/cat /etc/motd
     /bin/echo "[TINUX_SH] Subprocess fork+execve+wait4 pipeline succeeded!"

     exit 0
     ```
 * 、 `.cache/initramfs_root/bin/` `busybox` from `sh`, `cat`, `echo` to of or create
 * `src/main.zig` of `kmain()` with ：
     1. `serial.writeString("[TINUX_TEST] START: TASK-007\n");`
     2. `vfs.init();` / `cpio.mountInitramfs(initramfs_bytes);`
     3. `const bb_node = vfs.lookup("/bin/busybox") orelse @panic("busybox missing");`
     4. `const init_pml4 = vmm.createFreshUserPml4() orelse @panic("OOM init_pml4");`
     5. `const argv = [_][]const u8{ "/bin/sh", "/etc/rc.sh" };`
     6. `const image = elf.loadStaticElf(init_pml4, bb_node.data, &argv) catch @panic("ELF load failed");`
     7. `_ = task.initPid1(init_pml4, image.initial_brk);`
     8. `serial.writeString("[TINUX_INIT] Spawning PID 1 (/bin/sh /etc/rc.sh)...\n");`
     9. `syscall.enterUserMode(image.entry_rip, image.user_rsp);`
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-007 5
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-007
[TINUX_INIT] Spawning PID 1 (/bin/sh /etc/rc.sh)...
[TINUX_SH] BusyBox ash shell script started (PID 1)
[TINUX_VFS] Welcome to Tinux! Unmodified Linux BusyBox is alive via CPIO Initramfs!
[TINUX_SH] Subprocess fork+execve+wait4 pipeline succeeded!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-007
[HARNESS] SUCCESS: TASK-007 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-007 5` when、 Builder fixloop stop、 `ESCALATIO
```markdown
# Escalation Report: TASK-007
## 1. Failure Summary
* **Failed Stage:** [zig build / cloneUserPml4 #PF / fork Return Hang / execve Crash / wait4 Deadlock / BusyBox ash 
* **Active PID & Last Syscall Before Failure:** [PID, Syscall Num (rax), rdi, rsi, rdx]
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
[Relevant code diff for src/proc/task.zig, src/mm/vmm.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
