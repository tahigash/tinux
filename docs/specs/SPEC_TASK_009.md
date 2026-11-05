# Tinux Implementation Specification: TASK-009
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** AI System Architect
> * **Auditor (Low-Level & ABI Contract):** AI Code Auditor
> * **Target Builder:** Autonomous AI Builder Agent
---
## 0. Builder Agent Operating Rules
You are the Implementation Builder. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter `linux_dirent64` byte layouts, VFS writable buffer resizing policies, open flag bit values, or errno codes.
2. **Strict `getdents64` 8-Byte Alignment:**
   In `sys_getdents64`, record lengths (`d_reclen`) must be aligned to 8-byte boundaries using `std.mem.alignForward(usize, 19 + name.len + 1, 8)`.
3. **Strict Zig Version Idioms:**
   Do not output deprecated Zig idioms (0.10/0.11 era). Adhere strictly to Section 1 "Zig Idiom Cheat Sheet".
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-009 5` fails three consecutive times, do not make a fourth speculative guess.
   * Stop immediately after the third failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Unaligned memory write | `@ptrCast(*u64, buf).* = val` | `std.mem.writeInt(u64, buf[0..8], val, .little)` |
| String prefix check | Manual character loop | `std.mem.startsWith(u8, haystack, prefix)` |
| String search scalar | Manual loop | `std.mem.indexOfScalar(u8, slice, '/')` |
| Free heap memory | Implicit slice free | `heap.allocator().free(node.rw_buf.?[0..node.rw_cap])` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-009`
* **Title:** `Writable In-Memory Filesystem (tmpfs), Directory Listing (sys_getdents64), File Manipulation (sys_mkdir / sys_unlink / sys_lseek), and Shell Utilities (touch / ls / rm)`
* **Target Subsystem:** `fs`, `proc`, `syscall`
* **Target Files to Create / Modify:**
  * `src/fs/vfs.zig` (Modify: add dynamic writable buffers to `VfsNode`, implement path normalization, child filtering, and directory traversal)
  * `src/proc/task.zig` (Modify: add `cwd` tracking per task)
  * `src/syscall/dispatch.zig` (Modify: implement `getdents64`, `mkdir`/`mkdirat`, `unlink`/`unlinkat`, `rmdir`, `lseek`, `utimensat`, `statx`)
  * `src/main.zig` (Modify: initialize VFS and run TASK-009 test)
  * `scripts/verify_qemu.sh` (Modify: provide the in-tree Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`))
---
## 3. Directory & File Manipulation Contract (AI Audited)
### 3.1 `sys_getdents64` Record Format Contract
The Linux x86_64 `sys_getdents64` system call fills the user buffer with variable-length `linux_dirent64` records:
```text
Offset  Length    Field       Type / Purpose
0       8 bytes   d_ino       u64: Inode number (non-zero)
8       8 bytes   d_off       i64: Offset to next record in directory stream
16      2 bytes   d_reclen    u16 (little-endian): Total record size (must be multiple of 8)
18      1 byte    d_type      u8: File type (DT_CHR=2, DT_DIR=4, DT_REG=8)
19      N+1 bytes d_name      NUL-terminated filename (basename only, no slashes)
20+N    0..7 B    padding     Zero-filled padding up to d_reclen boundary
```
* **`d_type` mappings:**
  * `(mode & S_IFMT) == S_IFDIR (0o040000)` -> `DT_DIR = 4`
  * `(mode & S_IFMT) == S_IFCHR (0o020000)` -> `DT_CHR = 2`
  * Regular files (`S_IFREG`) -> `DT_REG = 8`
* **Direct child filtering (`isDirectChild(dir_path, node_path)`):**
  * When `dir_path` is `"."` (root): match if `node_path != "."` and `std.mem.indexOfScalar(u8, node_path, '/') == null`.
  * When `dir_path` is a subdirectory (e.g. `"tmp/work"`): match if `node_path.len > dir_path.len + 1`, starts with `dir_path` followed by `'/'`, and contains no further slashes.
### 3.2 Writable File Operations & Open Flags Contract
| Flag / Syscall | Value (Octal / Hex) | Exact Kernel Behavior |
| :--- | :--- | :--- |
| **`O_CREAT`** | `0o100` (`0x40`) | If file does not exist, creates a new `VfsNode` with mode `S_IFREG | (mode & 0o777)`. |
| **`O_EXCL`** | `0o200` (`0x80`) | Used with `O_CREAT`. If file already exists, returns `-EEXIST (-17)`. |
| **`O_TRUNC`** | `0o1000` (`0x200`) | If file exists and is opened for writing, truncates file size to 0. |
| **`O_APPEND`** | `0o2000` (`0x400`) | Before each write, resets file offset to current node size. |
| **`O_DIRECTORY`** | `0o200000` (`0x10000`) | If target node is not a directory (`S_IFDIR`), returns `-ENOTDIR (-20)`. |
### 3.3 Directory, Deletion & Timestamp Syscalls Contract
| Syscall Name | Number (`rax`) | Arguments | Exact Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_getcwd`** | `79` | `buf_ptr, size` | Writes current working directory (e.g. `"/\0"`) into user buffer and returns length. |
| **`sys_chdir`** | `80` | `path_ptr` | Resolves path in VFS, verifies `S_IFDIR`, updates task `cwd`, and returns 0 or `-ENOENT`/`-ENOTDIR`. |
| **`sys_mkdir` / `mkdirat`** | `83` / `258` | `(dirfd,) path_ptr, mode` | Creates a new directory node. Returns `-EEXIST` if path exists, or 0 on success. |
| **`sys_rmdir`** | `84` | `path_ptr` | Delegates to `sysUnlinkat(AT_FDCWD, path_ptr, AT_REMOVEDIR)`. Returns `-ENOTEMPTY` if directory contains children. |
| **`sys_creat`** | `85` | `path_ptr, mode` | Delegates to `sysOpenat(AT_FDCWD, path_ptr, O_CREAT | O_WRONLY | O_TRUNC, mode)`. |
| **`sys_unlink` / `unlinkat`** | `87` / `263` | `(dirfd,) path_ptr (, flags)` | Removes matching VFS node, freeing allocated buffers. Returns 0 or `-ENOENT`. |
| **`sys_getdents64`** | `217` | `fd, dirp, count` | Fills user buffer with `linux_dirent64` records for direct children of directory. |
| **`sys_utimensat`** | `280` | `dirfd, path_ptr, times, flags` | Updates timestamps or returns 0 for `touch` support. |
| **`sys_statx`** | `332` | `dirfd, path, flags, mask, buf` | Returns `-ENOSYS (-38)` allowing libc fallbacks to `newfstatat`. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/fs/vfs.zig` Upgraded Data Structures
```zig
const std = @import("std");
const heap = @import("../mm/heap.zig");
const pipe = @import("pipe.zig");
const Errno = @import("../uapi/errno.zig").Errno;

pub const MAX_VFS_NODES: usize = 128;
pub const MAX_OPEN_FILES: usize = 64;
pub const MAX_PATH_LEN: usize = 128;
pub const MAX_FILE_SIZE: usize = 65536;

pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFREG: u32 = 0o100000;

pub const O_RDONLY: u32 = 0;
pub const O_WRONLY: u32 = 1;
pub const O_RDWR: u32 = 2;
pub const O_CREAT: u32 = 0o100;
pub const O_EXCL: u32 = 0o200;
pub const O_TRUNC: u32 = 0o1000;
pub const O_APPEND: u32 = 0o2000;
pub const O_DIRECTORY: u32 = 0o200000;

pub const DT_UNKNOWN: u8 = 0;
pub const DT_FIFO: u8 = 1;
pub const DT_CHR: u8 = 2;
pub const DT_DIR: u8 = 4;
pub const DT_BLK: u8 = 6;
pub const DT_REG: u8 = 8;
pub const DT_LNK: u8 = 10;
pub const DT_SOCK: u8 = 12;

pub const VfsNode = struct {
    in_use: bool = false,
    name_buf: [MAX_PATH_LEN]u8 = [_]u8{0} ** MAX_PATH_LEN,
    name_len: usize = 0,
    mode: u32 = 0,
    static_data: []const u8 = "",
    rw_buf: ?[*]u8 = null,
    rw_cap: usize = 0,
    size: usize = 0,

    pub fn slice(self: *const VfsNode) []const u8 {
        if (self.rw_buf) |ptr| {
            return ptr[0..self.size];
        }
        return self.static_data[0..self.size];
    }
};
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Path Resolution and Parent Hierarchy in `vfs.zig`**
   * Implement `resolveTaskPath(cwd, raw_path, out_buf)`:
     * Break input into path components, resolving `.` and `..` segments safely.
     * Return clean, canonical normalized path string.
   * In `registerNode(path, mode, data)`:
     * Ensure all parent directory components exist in the node table before registering leaf node.
2. **Step 2: Writable Node Dynamic Resizing**
   * In `writeNode(node_idx, offset, src)`:
     * If `node.rw_buf == null`, allocate initial buffer via `heap.allocator().alloc(u8, new_cap)`.
     * Copy existing static data into dynamic buffer.
     * If write offset exceeds capacity, reallocate buffer with aligned size up to `MAX_FILE_SIZE`.
     * Copy `src` bytes into buffer and update `node.size`.
3. **Step 3: `sysGetdents64` Directory Traversal**
   * Read entries starting from current file descriptor offset.
   * Yield virtual entries `.` and `..` for cursor positions 0 and 1.
   * For subsequent cursor positions, iterate over VFS nodes:
     * Check `isDirectChild(dir_path, cand.name())`.
     * Construct 8-byte aligned `linux_dirent64` record in user buffer.
     * Advance offset and return total bytes written.
4. **Step 4: Harness and Verification in `verify_qemu.sh`**
   * Ensure userland utilities `mkdir`, `touch`, `ls`, `rm`, `cat` are provisioned from the in-tree Zig userland (`/bin/sh` synthesized from `tinux_busybox.zig`).
   * Execute `/etc/rc.sh` test sequence creating `/tmp/work`, writing files, listing directory contents, and deleting temporary files.
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-009 5
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-009
[TINUX_INIT] Spawning PID 1 (/bin/sh /etc/rc.sh)...
[TINUX_SH] Testing writable tmpfs & directory operations...
[TINUX_LS] Listing /tmp/work before rm:
hello.txt
stamp.tmp
Tinux tmpfs write and redirection OK!
[TINUX_LS] Listing /tmp/work after rm:
hello.txt
[TINUX_TMPFS] All file creation, listing, and deletion tests passed!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-009
[HARNESS] SUCCESS: TASK-009 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-009 5` fails three consecutive times, stop the modification loop and record an escalation report in `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-009
## 1. Failure Summary
* **Failed Stage:** [zig build / mkdir ENOENT / Shell Redirection Failure / getdents64 Alignment Crash / touch utimensat / rm unlink Error]
* **Last Syscall & Path Before Failure:** [Syscall Num, Path String, Return Errno]
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
[Relevant code diff for src/fs/vfs.zig or src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For AI Architect / Auditor Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
