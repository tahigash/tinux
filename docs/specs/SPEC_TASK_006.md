# Tinux Implementation Specification: TASK-006
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter CPIO header offsets, VFS node data structures, file descriptor table boundaries, `LinuxStat` memory layouts, or syscall error returns.
2. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet".
3. **User Page Remapping Safety:**
   Maintain separation between kernel identity mapping and user space virtual pages (`0x0040_0000`, `PTE_USER`).
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-006 5` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Hex ASCII string parse | Manual character loop | `std.fmt.parseInt(u32, hex_slice, 16)` |
| String equality check | `a == b` (pointer comparison) | `std.mem.eql(u8, a, b)` |
| Truncate integer | `@truncate(u32, val)` | `@as(u32, @truncate(val))` |
| Copy slice to buffer | Manual loop | `@memcpy(dst[0..src.len], src)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-006`
* **Title:** `In-Memory VFS, Initramfs (newc CPIO) Unpacker, File I/O Syscalls (openat/read/writev/close/fstat/ioctl), sys_uname, sys_stat, sys_fstat, and Micro-Userland Execution`
* **Target Subsystem:** `fs`, `proc`, `mm`, `syscall`
* **Target Files to Create / Modify:**
  * `src/mm/pmm.zig` (Modify: reserve first 16 MiB so kernel and embedded initramfs do not collide with user space)
  * `src/mm/vmm.zig` (Modify: add `isUserPageMapped` helper checking `PTE_PRESENT | PTE_USER`)
  * `src/fs/vfs.zig` (Create: in-memory VFS node table and File Descriptor table)
  * `src/fs/cpio.zig` (Create: SVR4 `newc` `070701` / `070702` CPIO archive unpacker)
  * `src/proc/elf.zig` (Modify: support `ET_EXEC` and `ET_DYN` Static-PIE with dynamic `argv` slices)
  * `src/syscall/dispatch.zig` (Modify: add VFS I/O, `writev`, `fstat`/`newfstatat`, `ioctl`, `uname`, `mmap`, ID stubs)
  * `src/main.zig` (Modify: mount `initramfs.cpio` and boot the in-tree clean-room Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`))
  * `scripts/verify_qemu.sh` (Modify: synthesize clean-room userland and `/etc/motd` into `initramfs.cpio`)
---
## 3. VFS, CPIO & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 SVR4 `newc` CPIO Format Contract (`070701` / `070702`)
The Linux initramfs uses the SVR4 `newc` CPIO format:
1. **Header (110 bytes fixed ASCII):**
   * `c_magic` (`[6]u8`): `"070701"` or `"070702"`.
   * Followed by 13 fields of 8-character hex strings: `c_ino`, `c_mode`, `c_uid`, `c_gid`, `c_nlink`, `c_mtime`, `c_filesize`, `c_devmajor`, `c_devminor`, `c_rdevmajor`, `c_rdevminor`, `c_namesize`, `c_check`.
2. **Filename & 4-Byte Alignment:**
   * Filename starts at `offset + 110` with length `namesize` (including trailing NUL).
   * A filename of `"TRAILER!!!"` marks archive termination.
   * File payload data starts at `std.mem.alignForward(usize, header_offset + 110 + namesize, 4)`.
   * Next header offset is `std.mem.alignForward(usize, data_offset + filesize, 4)`.
3. **Path Normalization Rule:**
   * Leading `./` or `/` prefixes are stripped (e.g. `"./etc/motd"` and `"/etc/motd"` normalize to `"etc/motd"`).
### 3.2 Linux x86_64 File & Runtime Syscalls Contract
| Syscall | Num | Arguments | Exact Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_read`** | `0` | `fd, buf, count` | For `fd == 0`, returns 0 (EOF) in non-interactive tests. For `fd >= 3`, reads from file node offset, updates offset, and returns bytes read. |
| **`sys_open`** | `2` | `path_ptr, flags, mode` | Delegates to `sysOpenat(AT_FDCWD, path_ptr, flags, mode)`. |
| **`sys_close`** | `3` | `fd` | Closes fd >= 3 and releases descriptor slot, returning 0. Returns `-EBADF` if invalid. |
| **`sys_stat` / `sys_lstat`** | `4` / `6` | `path_ptr, statbuf` | Delegates to `sysNewfstatat(AT_FDCWD, path_ptr, statbuf, 0)`. |
| **`sys_fstat`** | `5` | `fd, statbuf` | Populates `LinuxStat` for stdout/stderr (`S_IFCHR | 0o666`) or regular file (`S_IFREG | mode`), returning 0. |
| **`sys_lseek`** | `8` | `fd, offset, whence` | Updates file offset for `SEEK_SET (0)`, `SEEK_CUR (1)`, or `SEEK_END (2)`. Returns new offset. |
| **`sys_mmap`** | `9` | `addr, len, prot, flags, fd, off` | Allocates virtual memory starting from `0x4000_0000` (or `MAP_FIXED` target), zero-fills pages, and returns base virtual address. |
| **`sys_mprotect` / `munmap`**| `10` / `11` | `addr, len,...` | Validates range and returns 0. |
| **`sys_ioctl`** | `16` | `fd, req, argp` | For `TIOCGWINSZ (0x5413)`, populates `LinuxWinsize` (25 rows, 80 cols) and returns 0. |
| **`sys_writev`** | `20` | `fd, iov_ptr, iovcnt` | Iterates through `iovcnt` `IoVec` buffers and writes contents to `fd`, returning total bytes written. |
| **`sys_uname`** | `63` | `buf_ptr` | Populates `LinuxUtsname` (390 bytes: `sysname="Linux"`, `nodename="tinux"`, `release="6.6.0-tinux"`, `version="#1 SMP PREEMPT Tinux 2026"`, `machine="x86_64"`, `domainname="(none)"`) and returns 0. |
| **`sys_openat`** | `257` | `dirfd, path_ptr, flags, mode` | Resolves path relative to dirfd/CWD, allocates descriptor from `3..63`, and returns new fd or `-ENOENT`. |
| **`sys_newfstatat`** | `262` | `dirfd, path_ptr, statbuf, flag`| Resolves path (supporting `AT_EMPTY_PATH = 0x1000`), fills `LinuxStat` (144 bytes), and returns 0 on success. |
| **ID / Stub Syscalls** | Misc | `39, 102, 104, 107, 108, 110, 273, 302` | Returns expected IDs: `getpid(39)=1`, `getuid(102)=0`, `getgid(104)=0`, `geteuid(107)=0`, `getegid(108)=0`, `getppid(110)=0`, `set_robust_list(273)=0`, `prlimit64(302)=0`. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/mm/pmm.zig` & `src/mm/vmm.zig` Updates
1. **`src/mm/pmm.zig`:**
   Reserve memory below 16 MiB so user code and heap never conflict with kernel image and embedded initramfs:
   ```zig
   const kernel_end_phys = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), PAGE_SIZE);
   const safe_start_phys = @max(kernel_end_phys, 0x0100_0000); // Dynamic allocations >= 16 MiB
   const start_page = safe_start_phys / PAGE_SIZE;
   ```
2. **`src/mm/vmm.zig`:**
   Add user-page verification helper:
   ```zig
   pub fn isUserPageMapped(pml4_phys: usize, vaddr: usize) bool {
       const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
       const pml4e = pml4.entries[pml4Index(vaddr)];
       if ((pml4e & PTE_PRESENT) == 0 or (pml4e & PTE_USER) == 0) return false;
       const pdpt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pml4e & PTE_ADDR_MASK))));
       const pdpte = pdpt.entries[pdptIndex(vaddr)];
       if ((pdpte & PTE_PRESENT) == 0 or (pdpte & PTE_USER) == 0) return false;
       const pd = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pdpte & PTE_ADDR_MASK))));
       const pde = pd.entries[pdIndex(vaddr)];
       if ((pde & PTE_PRESENT) == 0 or (pde & PTE_USER) == 0) return false;
       const pt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pde & PTE_ADDR_MASK))));
       const pte = pt.entries[ptIndex(vaddr)];
       return (pte & PTE_PRESENT) != 0 and (pte & PTE_USER) != 0;
   }
   ```
### 4.2 `src/fs/vfs.zig`
```zig
const std = @import("std");
const Errno = @import("../uapi/errno.zig").Errno;

pub const MAX_VFS_NODES: usize = 128;
pub const MAX_OPEN_FILES: usize = 64;
pub const MAX_PATH_LEN: usize = 128;

pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFREG: u32 = 0o100000;

pub const VfsNode = struct {
    in_use: bool = false,
    name_buf: [MAX_PATH_LEN]u8 = [_]u8{0} ** MAX_PATH_LEN,
    name_len: usize = 0,
    mode: u32 = 0,
    data: []const u8 = "",
    size: usize = 0,
};

pub const OpenFile = struct {
    in_use: bool = false,
    node_idx: usize = 0,
    offset: usize = 0,
    flags: u32 = 0,
};

pub const LinuxStat = extern struct {
    st_dev: u64 = 0,
    st_ino: u64 = 0,
    st_nlink: u64 = 1,
    st_mode: u32 = 0,
    st_uid: u32 = 0,
    st_gid: u32 = 0,
    __pad0: u32 = 0,
    st_rdev: u64 = 0,
    st_size: i64 = 0,
    st_blksize: i64 = 4096,
    st_blocks: i64 = 0,
    st_atime: i64 = 0,
    st_atime_nsec: i64 = 0,
    st_mtime: i64 = 0,
    st_mtime_nsec: i64 = 0,
    st_ctime: i64 = 0,
    st_ctime_nsec: i64 = 0,
    __reserved: [3]i64 = [_]i64{0} ** 3,

    comptime {
        std.debug.assert(@sizeOf(LinuxStat) == 144);
    }
};

pub fn normalizePath(raw: []const u8) []const u8 {
    var p = raw;
    while (p.len > 0 and (p[0] == '/' or p[0] == '.')) {
        if (p.len >= 2 and p[0] == '.' and p[1] == '/') {
            p = p[2..];
        } else if (p[0] == '/') {
            p = p[1..];
        } else {
            break;
        }
    }
    return p;
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/vfs.zig` and `src/fs/cpio.zig` Implementation**
   * In `vfs.init()`, register base root directories `"."`, `"bin"`, `"etc"`, `"tmp"`, and character device `"dev/null"`.
   * In `cpio.unpackInitramfs(archive)`:
     * Parse 110-byte `CpioNewcHeader`. Validate magic `"070701"` or `"070702"`.
     * Extract `filesize`, `namesize`, and filename. Stop at `"TRAILER!!!"`.
     * Normalize path via `vfs.normalizePath`.
     * Register node via `vfs.registerNode(norm_name, mode, file_data)`.
2. **Step 2: `src/proc/elf.zig` Updates for Dynamic `argv`**
   * Support both static executable (`e_type == 2`) and static position-independent executable (`e_type == 3`).
   * When `e_type == 3`, compute `load_bias = 0x0040_0000`.
   * For each segment, map virtual pages using `vmm.isUserPageMapped` to avoid redundant mapping.
   * Write `argv` strings into the upper user stack region and populate stack slots starting at 16-byte aligned `0x0080_3E00`.
3. **Step 3: `src/syscall/dispatch.zig` File Syscalls**
   * Implement `readUserCString(user_ptr, out_buf)` to safely extract user-space strings.
   * Implement `sysOpenat` and `sysOpen` to look up paths in VFS and allocate file descriptors.
   * Implement `sysRead` for file descriptors, copying payload slices and updating offsets.
   * Implement `sysWritev` iterating through `IoVec` arrays.
   * Implement `sysFstat` and `sysNewfstatat` filling `LinuxStat` records.
   * Implement `sysMmap` demand-mapping pages starting at `0x4000_0000`.
4. **Step 4: Clean-Room Userland & Initramfs Generation in `verify_qemu.sh`**
   * Compile the in-tree clean-room Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`) into `.cache/initramfs_root/bin/sh` using `build_user_elf`.
   * Create symbolic link or binary copy for `/bin/cat`.
   * Write `/etc/motd` with content: `Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!`.
   * Package `.cache/initramfs_root` into `.cache/initramfs.cpio` using CPIO or python script.
5. **Step 5: `src/main.zig` Updates**
   * Embed initramfs archive: `const initramfs = @import("initramfs"); const initramfs_archive = initramfs.data;`.
   * In `kmain()`, unpack archive via `cpio.unpackInitramfs`.
   * Look up `/bin/sh` or `/bin/cat`, load ELF into user address space with arguments `[_][]const u8{ "/bin/sh", "cat", "/etc/motd" }`.
   * Transfer control to user space via `syscall.enterUserMode`.
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-006 5
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-006
[TINUX_VFS] Unpacked nodes from initramfs.cpio
[TINUX_INIT] Spawning PID 1 (/bin/sh /etc/rc.sh)...
Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-006
[HARNESS] SUCCESS: TASK-006 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-006 5` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-006
## 1. Failure Summary
* **Failed Stage:** [CPIO Generation / CPIO Unpack / Userland ELF Load / Unimplemented Syscall ENOSYS / Ring 3 #PF Fault]
* **Last Syscall Number Called Before Failure:** [rax number and arguments rdi, rsi, rdx]
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
[Relevant code diff for src/fs/vfs.zig, src/fs/cpio.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
