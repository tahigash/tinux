# Tinux Implementation Specification: TASK-007
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** AI System Architect
> * **Auditor (Low-Level & ABI Contract):** AI Code Auditor
> * **Target Builder:** Autonomous AI Builder Agent
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter `Task` struct layouts, `syscall_entry.S` context-switch conventions, `cloneUserPml4` page duplication rules, or process table sizing (`MAX_TASKS = 16`).
2. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet".
3. **Context Switch Stack Discipline:**
   Process switches must execute through `proc.activateTask(target)`, loading `CR3`, setting `MSR_FS_BASE`, updating `syscall_kernel_rsp`, and programming TSS `rsp0`.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-007 5` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Zero-initialize struct | `std.mem.zeroes(T)` (on non-extern) | Default values via `.{}` |
| Slice copy | Manual loop | `@memcpy(dst, src)` |
| Array fill | Manual loop | `@memset(slice, 0)` |
| Truncate integer | `@truncate(u32, val)` | `@as(u32, @truncate(val))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-007`
* **Title:** `Multi-Process Management (Task Table & Address Space Isolation), sys_fork / sys_clone / sys_execve / sys_wait4, and Shell Execution`
* **Target Subsystem:** `proc`, `mm`, `fs`, `syscall`, `arch/x86_64`
* **Target Files to Create / Modify:**
  * `src/arch/x86_64/syscall_entry.S` (Modify: support context switching by setting `%rsp = %rax` returned from `syscallDispatch`)
  * `src/mm/vmm.zig` (Modify: add `cloneUserPml4` and `createFreshUserPml4`)
  * `src/fs/vfs.zig` (Modify: support per-task `fd_table` cloning and `fcntl` / `dup2` FD duplication)
  * `src/proc/task.zig` (Create: `Task` struct, process table `MAX_TASKS = 16`, `activateTask`, `forkCurrentTask`)
  * `src/syscall/dispatch.zig` (Modify: implement `fork`/`vfork`/`clone`, `execve`, `wait4`, `fcntl`, `dup2`, `getcwd`)
  * `src/main.zig` (Modify: initialize PID 1 via `task.zig` and launch the in-tree clean-room Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`))
  * `scripts/verify_qemu.sh` (Modify: add `/etc/rc.sh` and `/bin/sh` to `initramfs.cpio`)
---
## 3. Process Architecture & Linux ABI Contract (AI Audited)
### 3.1 Context-Switching `syscallEntry` Mechanism
To implement context switching during `fork`, `execve`, `wait4`, and `exit`, `syscallDispatch` returns a pointer to the target `SyscallFrame`:
```zig
export fn syscallDispatch(frame: *SyscallFrame) callconv(.C) *SyscallFrame
```
1. **Entry (`syscallEntry`):**
   * Saves user `%rsp` into `user_rsp_scratch`.
   * Switches `%rsp` to the current task kernel stack (`syscall_kernel_rsp`).
   * Pushes the 16-register `SyscallFrame`.
   * Stores `current_task.saved_frame = frame`.
2. **Return Value Slot (`frame.rax`):**
   * `syscallDispatch` records the syscall return value directly into `frame.rax`.
   * The dispatcher returns the target task's `*SyscallFrame` in `%rax`.
   * Assembly sets `%rsp = %rax`, restoring all registers and executing `sysretq` to the scheduled process.
### 3.2 Address Space Isolation & Fast `cloneUserPml4` Contract
Each task maintains an independent `pml4_phys`. During `fork` / `clone`, `vmm.cloneUserPml4(src_pml4_phys)`:
1. Allocates zeroed physical pages for `dst_pml4_phys`, `dst_pdpt_phys`, and `dst_pd_phys`.
2. Iterates over 512 entries in `src_pd`:
   * Entries with `(pde & PTE_PRESENT) == 0` are skipped.
   * Kernel entries with `(pde & PTE_USER) == 0` (identity map and kernel heap) are shared directly (`dst_pd.entries[pdi] = pde`).
   * User entries with `(pde & PTE_USER) != 0` allocate a fresh page table `dst_pt_phys`, link it into `dst_pd`, and clone individual user pages:
     * Non-present or kernel entries are copied directly.
     * Present user pages allocate a fresh zeroed physical frame via `pmm.allocZeroedPage()`, copy 4096 bytes from source page, and install the new entry with identical PTE flags.
### 3.3 Multi-Process & Shell Syscalls Contract
The in-tree clean-room shell (`/bin/sh /etc/rc.sh`) requires standard process lifecycle syscalls:
| Syscall | Num | Arguments | Exact Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_clone`** | `56` | `flags, child_stack, ptid, ctid, newtls` | Delegates to `forkCurrentTask(frame, child_stack)`. In parent, returns child PID; in child, returns 0. |
| **`sys_fork` / `vfork`** | `57` / `58` | (none) | Delegates to `forkCurrentTask(frame, 0)`. |
| **`sys_execve`** | `59` | `path_ptr, argv_ptr, envp_ptr` | Resolves executable path, parses Shebang (`#!`) if present, builds fresh user PML4, loads ELF image, resets user stack, and returns frame. |
| **`sys_wait4`** | `61` | `pid, wstatus_ptr, options, rusage` | Scans for terminated child tasks. Reaps zombie children, populates status, and returns child PID. Blocks parent if child is active and `WNOHANG` is not set. |
| **`sys_exit` / `exit_group`** | `60` / `231` | `status` | If PID 1 exits: logs verification pass and shuts down QEMU. Otherwise marks task zombie, wakes waiting parent, and schedules next runnable task. |
| **`sys_fcntl`** | `72` | `fd, cmd, arg` | If `cmd == 0 (F_DUPFD)` or `cmd == 1030 (F_DUPFD_CLOEXEC)`: duplicates fd starting from arg. If `cmd == 1 (F_GETFD)`: returns 0 or FD_CLOEXEC. If `cmd == 2 (F_SETFD)`: updates cloexec flag. If `cmd == 3 (F_GETFL)`: returns O_RDWR (2). If `cmd == 4 (F_SETFL)`: returns 0. |
| **`sys_dup` / `dup2` / `dup3`** | `32, 33, 292` | `oldfd, newfd,...` | Duplicates file descriptor table entries. |
| **`sys_getcwd`** | `79` | `buf_ptr, size` | Writes `"/\0"` to user buffer and returns 2. |
| **`sys_access` / `faccessat` / `faccessat2`** | `21, 269, 439` | `(dirfd,) path_ptr, mode` | Returns 0 if path exists in VFS, or `-ENOENT`. |
| **Signal & Pgrp Stubs** | Misc | `13, 14, 15, 34, 80, 109, 111, 112, 121, 228, 318` | Stubs returning standard success codes: `rt_sigaction(13)=0`, `rt_sigprocmask(14)=0`, `rt_sigreturn(15)=0`, `pause(34)=0`, `chdir(80)=0`, `setpgid(109)=0`, `getpgrp(111)=1`, `setsid(112)=1`, `getpgid(121)=1`, `clock_getres(228)=0`, `getrandom(318)=len`. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/arch/x86_64/syscall_entry.S`
```asm
.global syscallEntry
.extern syscallDispatch
.extern kernel_rsp_scratch
.extern user_rsp_scratch
.align 16
syscallEntry:
    /* 1. Save User RSP and switch to current task's Kernel Syscall Stack */
    movq %rsp, user_rsp_scratch(%rip)
    movq kernel_rsp_scratch(%rip), %rsp

    /* 2. Build 128-byte SyscallFrame on current Kernel Stack */
    pushq user_rsp_scratch(%rip) /* offset 120: user_rsp */
    pushq %rcx                   /* offset 112: user_rip */
    pushq %r11                   /* offset 104: user_rflags */
    pushq %rax                   /* offset 96:  rax (syscall_num on entry, return val on exit) */
    pushq %rdi                   /* offset 88:  rdi (arg1) */
    pushq %rsi                   /* offset 80:  rsi (arg2) */
    pushq %rdx                   /* offset 72:  rdx (arg3) */
    pushq %r10                   /* offset 64:  r10 (arg4) */
    pushq %r8                    /* offset 56:  r8  (arg5) */
    pushq %r9                    /* offset 48:  r9  (arg6) */
    pushq %rbx                   /* offset 40:  rbx */
    pushq %rbp                   /* offset 32:  rbp */
    pushq %r12                   /* offset 24:  r12 */
    pushq %r13                   /* offset 16:  r13 */
    pushq %r14                   /* offset 8:   r14 */
    pushq %r15                   /* offset 0:   r15 */

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
    popq %rax                    /* restore return value from frame.rax */
    popq %r11                    /* restore user_rflags */
    popq %rcx                    /* restore user_rip */
    popq %rsp                    /* restore user_rsp */
    sysretq
```
### 4.2 `src/mm/vmm.zig` Additions
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

    for (0..512) |pdi| {
        const pde = src_pd.entries[pdi];
        if ((pde & PTE_PRESENT) != 0 and (pde & PTE_USER) == 0) {
            dst_pd.entries[pdi] = pde;
        }
    }
    return dst_pml4_phys;
}

pub fn cloneUserPml4(src_pml4_phys: usize) ?usize {
    const dst_pml4_phys = createFreshUserPml4() orelse return null;
    const src_pml4 = @as(*PageTable, @ptrFromInt(src_pml4_phys));
    const src_pdpt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(src_pml4.entries[0] & PTE_ADDR_MASK))));
    const src_pd = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(src_pdpt.entries[0] & PTE_ADDR_MASK))));
    const dst_pml4 = @as(*PageTable, @ptrFromInt(dst_pml4_phys));
    const dst_pdpt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(dst_pml4.entries[0] & PTE_ADDR_MASK))));
    const dst_pd = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(dst_pdpt.entries[0] & PTE_ADDR_MASK))));

    for (0..512) |pdi| {
        const pde = src_pd.entries[pdi];
        if ((pde & PTE_PRESENT) == 0 or (pde & PTE_USER) == 0) continue;
        const src_pt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pde & PTE_ADDR_MASK))));
        const dst_pt_phys = pmm.allocZeroedPage() orelse return null;
        const dst_pt = @as(*PageTable, @ptrFromInt(dst_pt_phys));
        dst_pd.entries[pdi] = dst_pt_phys | (pde & 0xFFF);

        for (0..512) |pti| {
            const pte = src_pt.entries[pti];
            if ((pte & PTE_PRESENT) == 0) continue;
            if ((pte & PTE_USER) == 0) {
                dst_pt.entries[pti] = pte;
            } else {
                const new_frame = pmm.allocZeroedPage() orelse return null;
                const old_frame = @as(usize, @intCast(pte & PTE_ADDR_MASK));
                const src_slice = @as([*]const u8, @ptrFromInt(old_frame))[0..PAGE_SIZE];
                const dst_slice = @as([*]u8, @ptrFromInt(new_frame))[0..PAGE_SIZE];
                @memcpy(dst_slice, src_slice);
                dst_pt.entries[pti] = new_frame | (pte & 0xFFF);
            }
        }
    }
    return dst_pml4_phys;
}
```
### 4.3 `src/proc/task.zig`
```zig
const std = @import("std");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const syscall_arch = @import("../arch/x86_64/syscall.zig");
const SyscallFrame = syscall_arch.SyscallFrame;
const vfs = @import("../fs/vfs.zig");

pub const MAX_TASKS: usize = 16;
pub const KSTACK_SIZE: usize = 16384;

pub const TaskState = enum {
    UNUSED,
    READY,
    RUNNING,
    WAITING,
    ZOMBIE,
};

pub const Task = struct {
    pid: usize = 0,
    parent_pid: usize = 0,
    state: TaskState = .UNUSED,
    exit_status: i32 = 0,
    pml4_phys: usize = 0,
    fs_base: usize = 0,
    initial_brk: usize = 0,
    current_brk: usize = 0,
    next_mmap_vaddr: usize = 0x4000_0000,
    fd_table: [vfs.MAX_OPEN_FILES]vfs.OpenFile = [_]vfs.OpenFile{.{}} ** vfs.MAX_OPEN_FILES,
    saved_frame: *SyscallFrame = undefined,
    kstack: [KSTACK_SIZE]u8 align(16) = undefined,

    pub fn kstackTop(self: *Task) usize {
        return @intFromPtr(&self.kstack) + KSTACK_SIZE;
    }
};

pub var tasks: [MAX_TASKS]Task = [_]Task{.{}} ** MAX_TASKS;
pub var current_task_idx: usize = 0;
var next_pid: usize = 1;

pub fn currentTask() *Task {
    return &tasks[current_task_idx];
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Process Table and Context Switching**
   * Initialize PID 1 task structure with fresh PML4 and kernel stack.
   * In `activateTask(task_idx)`:
     * Set `current_task_idx = task_idx`.
     * Update `kernel_rsp_scratch` and TSS `rsp0` to point to `task.kstackTop()`.
     * Set `MSR_FS_BASE` to `task.fs_base`.
     * Load `CR3` with `task.pml4_phys`.
2. **Step 2: Process Creation via `forkCurrentTask`**
   * Locate an unused task slot in `tasks`.
   * Clone parent address space with `vmm.cloneUserPml4(parent.pml4_phys)`.
   * Duplicate file descriptor table and state variables (`fs_base`, `brk`, `mmap`).
   * Copy `SyscallFrame` to child's kernel stack top. Set `child.saved_frame.rax = 0` (child return value).
   * In parent frame, set return value to child's PID.
3. **Step 3: Executing Programs via `sysExecve`**
   * Parse user-space path and argument strings. Check for Shebang (`#!/bin/sh`).
   * Allocate fresh user PML4 (`vmm.createFreshUserPml4`).
   * Load static ELF image and construct initial user stack.
   * Reset frame registers, update task `pml4_phys`, `brk`, and call `task.activateTask`.
4. **Step 4: Clean-Room Shell & Script Provisioning in `verify_qemu.sh`**
   * Provide the in-tree clean-room Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`).
   * Provide `/etc/rc.sh`:
     ```sh
     #!/bin/sh
     echo "[TINUX_SH] /bin/sh started (PID $$)"
     /bin/cat /etc/motd
     echo "[TINUX_SH] Child process /bin/cat completed and reaped via wait4!"
     exit 0
     ```
   * Set execution permissions and package into `initramfs.cpio`.
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
[TINUX_SH] /bin/sh started (PID 1)
Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!
[TINUX_SH] Child process /bin/cat completed and reaped via wait4!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-007
[HARNESS] SUCCESS: TASK-007 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-007 5` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-007
## 1. Failure Summary
* **Failed Stage:** [zig build / cloneUserPml4 #PF / fork Return Hang / execve Crash / wait4 Deadlock / Shell Script Failure]
* **Active PID & Last Syscall Before Failure:** [PID, Syscall Num (rax), arguments rdi, rsi, rdx]
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
[Relevant code diff for src/proc/task.zig, src/mm/vmm.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For AI Architect / Auditor Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
