# Tinux Implementation Specification: TASK-009
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-008` Passed (`./scripts/verify_qemu.sh TASK-008 5` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition `linux_dirent64` of ⼿、 `VfsNode` of buffer、、
2. **Strict `getdents64` 8-Byte Alignment （ of strictly adhere） :**
 `sys_getdents64` user spacebuffer of `d_reclen` 、must `std.mem.alignForward(usize, 19 + na
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-009 5` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.

---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| ⾮write | `@ptrCast(*u64, buf).*= val` (`#GP`/Panic) | `std.mem.writeInt(u64, buf[0..8], val,.little
| ⽂columnfirst⼀ | loop⼿ | `std.mem.startsWith(u8, haystack, prefix)` |
| ⽂column⽂ | loop⼿ | `std.mem.indexOfScalar(u8, slice, '/')` |
| memoryfreed | ⼀ of `free` | `heap.allocator().free(node.rw_buf.?[0..node.rw_cap])` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-009`
* **Title:** `Writable In-Memory Filesystem (tmpfs: create/write/truncate/unlink/mkdir), Directory Listing (sys_getd
* **Target Subsystem:** `fs`, `proc`, `syscall`
* **Target Files to Create / Modify:**
  * `src/fs/vfs.zig` (Modify: upgrade `VfsNode` with mutable `rw_buf`, parent directory auto-creation, `writeNode`, 
  * `src/proc/task.zig` (Modify: add per-task `cwd_buf` / `cwd_len` initialized to `"."` and copy across `fork`)
  * `src/syscall/dispatch.zig` (Modify: implement `sys_getdents64`, `sys_mkdir`/`sys_mkdirat`, `sys_unlink`/`sys_rmd
  * `src/main.zig` (Modify: create `/tmp` directory on boot and update test markers to `TASK-009`)
  * `scripts/verify_qemu.sh` (Modify: update `/etc/rc.sh` to test `mkdir`, `>`, `touch`, `ls`, `cat`, and `rm`)
---
## 3. Writable VFS (tmpfs) & `getdents64` ABI Contract (Opus 5.5 Audited)
### 3.1 `sys_getdents64` (Syscall 217) Binary Layout Contract
Linux of `sys_getdents64(unsigned int fd, struct linux_dirent64 *dirp, unsigned int count)` 、 of ⻑
```text
Offset  Size      Field       Description
------  --------  ----------  --------------------------------------------------------
0       8 bytes   d_ino       u64 (little-endian): Inode number (non-zero, e.g. idx + 1)
8       8 bytes   d_off       i64 (little-endian): Next offset cookie (cursor + 1)
16      2 bytes   d_reclen    u16 (little-endian): Total record size (multiple of 8!)
18      1 byte    d_type      u8: File type (DT_CHR=2, DT_DIR=4, DT_REG=8)
19      N+1 bytes d_name      NUL-terminated filename (basename only, no '/')
20+N    0..7 B    padding     Zero-filled padding up to d_reclen
```
* **`d_type` rules :**
  * `(mode & S_IFMT) == S_IFDIR (0o040000)` → `DT_DIR = 4`
  * `(mode & S_IFMT) == S_IFCHR (0o020000)` → `DT_CHR = 2`
 * （ `S_IFREG` ） → `DT_REG = 8`
* ** parent⼦evaluation (`isDirectChild(dir_path, node_path)`):**
 * `dir_path` `"."` （） of when：
 `node_path` `"."` with 、 `std.mem.indexOfScalar(u8, node_path, '/') == null` with of ⼦ with 、 `chi
 * `dir_path` `"."` （e.g.： `"tmp/work"` ） of when：
 `node_path.len > dir_path.len + 1` with 、 `std.mem.startsWith(u8, node_path, dir_path)` `node_path[dir_path
### 3.2 Writable File Operations & Open Flags Contract
| Flag / Syscall | Value (Octal / Hex) | Exact Kernel Behavior |
| :--- | :--- | :--- |
| **`O_CREAT`** | `0o100` (`0x40`) | existswhen、 `S_IFREG \| (mode & 0o777)` with `VfsNode` create。
| **`O_EXCL`** | `0o200` (`0x80`) | `O_CREAT` and 、 existswhen `-EEXIST (-17)` 。 |
| **`O_TRUNC`** | `0o1000` (`0x200`) | of 、（ `size` ） `0` 。 |
| **`O_APPEND`** | `0o2000` (`0x400`) | write（ `sys_write` / `sys_writev` ） of 、must `fd_entry.offset = node.si
| **`O_DIRECTORY`** | `0o200000` (`0x10000`) | of node（ `S_IFDIR` ） with when、 `-ENOTDIR (-20)
### 3.3 Directory, Deletion & Timestamp Syscalls Contract
| Syscall Name | Number (`rax`) | Arguments | Exact Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_getcwd`** | `79` | `buf_ptr, size` | of task of `cwd` `"."` `"/"\x00` 、 `"/" ++ cwd ++ 
| **`sys_chdir`** | `80` | `path_ptr` | `vfs.lookup` with exists `S_IFDIR` verify（ `-ENOEN
| **`sys_mkdir` / `mkdirat`** | `83` / `258` | `(dirfd,) path_ptr, mode` | 、 exists `-EEXIST (-17)`
| **`sys_rmdir`** | `84` | `path_ptr` | `sysUnlinkat(AT_FDCWD, path_ptr, AT_REMOVEDIR)` 。 |
| **`sys_creat`** | `85` | `path_ptr, mode` | `sysOpenat(AT_FDCWD, path_ptr, O_CREAT \| O_WRONLY \| O_TRUNC, mode)` 

| **`sys_unlink` / `unlinkat`** | `87` / `263` | `(dirfd,) path_ptr (, flags)` | node （ `-ENOENT` ）。
| **`sys_getdents64`** | `217` | `fd, dirp, count` | 3.1 of 、
| **`sys_utimensat`** | `280` | `dirfd, path_ptr, times, flags` | ** 【 `touch` mandatory】 ** `path_ptr == 0` of when
| **`sys_statx`** | `332` | `dirfd, path, flags, mask, buf` | `-ENOSYS (-38)` （ `musl` / `glibc` ⾃
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
pub const MAX_FILE_SIZE: usize = 65536; // 64 KiB max per dynamic tmpfs file
pub const S_IFMT: u32 = 0o170000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFCHR: u32 = 0o020000;
pub const S_IFREG: u32 = 0o100000;
pub const DT_CHR: u8 = 2;
pub const DT_DIR: u8 = 4;
pub const DT_REG: u8 = 8;
pub const O_RDONLY: u32 = 0o0;
pub const O_WRONLY: u32 = 0o1;
pub const O_RDWR: u32 = 0o2;
pub const O_CREAT: u32 = 0o100;
pub const O_EXCL: u32 = 0o200;
pub const O_TRUNC: u32 = 0o1000;
pub const O_APPEND: u32 = 0o2000;
pub const O_DIRECTORY: u32 = 0o200000;
pub const O_CLOEXEC: u32 = 0o2000000;
pub const AT_FDCWD: isize = -100;
pub const AT_REMOVEDIR: usize = 0x200;
pub const VfsNode = struct {
    in_use: bool = false,
    name_buf: [MAX_PATH_LEN]u8 = [_]u8{0} ** MAX_PATH_LEN,
    name_len: usize = 0,
    mode: u32 = 0,
    ro_data: []const u8 = &[_]u8{},
    rw_buf: ?[*]u8 = null,
    rw_cap: usize = 0,
    size: usize = 0,
    inode_no: u64 = 0,
    pub fn name(self: *const VfsNode) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn slice(self: *const VfsNode) []const u8 {
        if (self.rw_buf) |ptr| {
            return ptr[0..self.size];
        }
        return self.ro_data[0..self.size];
    }
    pub fn isDir(self: *const VfsNode) bool {
        return (self.mode & S_IFMT) == S_IFDIR;
    }
};
```
### 4.2 Path Resolution & Directory Functions in `src/fs/vfs.zig`
Builder of function `src/fs/vfs.zig` implement：
```zig
/// Resolves raw_path relative to base_cwd (or "/" if raw_path starts with '/'),
/// collapsing ".", "..", and multiple slashes into a canonical VFS path (e.g. "." or "tmp/work/file").
pub fn resolvePath(base_cwd: []const u8, raw_path: []const u8, out_buf: *[MAX_PATH_LEN]u8) []const u8 {
    // Builder implements canonical path resolution according to Section 5

}
/// Truncates a node's content to 0 bytes.
pub fn truncateNode(node_idx: usize) void {
    var n = &nodes[node_idx];
    n.size = 0;
}
/// Writes `src` bytes into `nodes[node_idx]` at `offset`, allocating or growing `rw_buf` via `heap.allocator()`.
pub fn writeNode(node_idx: usize, offset: usize, src: []const u8) Errno!usize {
    // Builder implements copy-on-write / dynamic buffer growth via heap.allocator()
}
/// Creates a directory node (`S_IFDIR`). Returns Errno.EEXIST if already exists.
pub fn mkdir(canonical_path: []const u8, mode: u32) Errno!void {
    // Builder implements directory creation
}
/// Removes a file or directory node. Checks AT_REMOVEDIR, EISDIR, ENOTDIR, and ENOTEMPTY.
pub fn unlink(canonical_path: []const u8, remove_dir: bool) Errno!void {
    // Builder implements file/directory removal and frees rw_buf if allocated
}
/// Packs linux_dirent64 records into `user_buf` starting from `file.offset` cursor.
pub fn getdents64(file: *FdEntry, user_buf: []u8) Errno!usize {
    // Builder implements directory iteration according to Section 3.1 and Section 5
}
```
### 4.3 `src/uapi/errno.zig` Addition
`Errno` enum `ENOTEMPTY = 39` definition of whenadd。
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/vfs.zig` of and parent⾃ **
   * `resolvePath(base_cwd: []const u8, raw_path: []const u8, out_buf: *[MAX_PATH_LEN]u8) []const u8`:
 1. ⼤ 16 of preservestack `var parts: [16][]const u8 = undefined; var depth: usize = 0;`
 2. `raw_path` `'/'` with when、 `base_cwd` （ `"."` of when） `'/'` with `parts` 
 3. `raw_path` `'/'` with （ `std.mem.tokenizeScalar(u8, raw_path, '/')` ）⾛：
 * `part` `""` or `"."` 。
 * `part` `".."` `if (depth > 0) depth -= 1;` 。
 * `parts[depth] = part; depth += 1;` 。
 4. `depth == 0` `"."` 。
 5. `depth > 0` `parts[0..depth]` `'/'` with `out_buf` write、 of 。
 * ** parent of ⾃ (`ensureParentDirs`):**
 `registerNode(raw_path, mode, data)` 、 `'/'` when（e.g.： `"etc/motd"` `"tmp/wo
 * `vfs.init()` with `"."`, `"dev"`, `"dev/null"`, `"tmp"`, `"bin"`, `"etc"` of 。
 * BusyBox of ：
 `lookup` （ or `open` ） 、 `"bin/"` of （ `"bin/ls"`, `"bin/mkdir"`, `"bin/touc
2. **Step 2: `writeNode`, `mkdir`, `unlink`, `getdents64` Implementation **
   * `writeNode(node_idx: usize, offset: usize, src: []const u8) Errno!usize`:
     1. `var n = &nodes[node_idx];`
 2. `if ((n.mode & S_IFMT) == S_IFCHR) return src.len;` （ `/dev/null` to of write of ）。
     3. `if (n.isDir()) return Errno.EISDIR;`
     4. `if (src.len == 0) return 0;`
     5. `const end_pos = offset + src.len;`
     6. `if (end_pos > MAX_FILE_SIZE) return Errno.ENOSPC;`
     7. `if (n.rw_buf == null or end_pos > n.rw_cap)`:
 * `new_cap = @max(std.mem.alignForward(usize, end_pos, 4096), 4096);` 、 `const new_slice = 
 * of `n.slice()` `@memcpy(new_slice[0..n.size], n.slice())` with 、 `n.rw_buf` `h
 * `n.rw_buf = new_slice.ptr; n.rw_cap = new_cap;` update。
     8. `@memcpy(n.rw_buf.?[offset..end_pos], src);`
     9. `if (end_pos > n.size) n.size = end_pos;`
     10. `return src.len;`
   * `getdents64(file: *FdEntry, user_buf: []u8) Errno!usize`:
     1. `const dir_node = &nodes[file.node_idx];`
     2. `if (!dir_node.isDir()) return Errno.ENOTDIR;`
     3. `const dir_path = dir_node.name();`
     4. `var written: usize = 0;`
     5. `var cursor = file.offset;` （ `0` = `"."`, `1` = `".."`, `2 .. 2 + MAX_VFS_NODES` = `nodes[cursor - 2]` ）。

 6. loop with `cursor < 2 + MAX_VFS_NODES` ⾛：
        * `var entry_name: []const u8 = ""; var d_ino: u64 = 1; var d_type: u8 = DT_DIR; var matched = false;`
        * `if (cursor == 0) { entry_name = "."; d_ino = dir_node.inode_no; d_type = DT_DIR; matched = true; }`
        * `else if (cursor == 1) { entry_name = ".."; d_ino = 1; d_type = DT_DIR; matched = true; }`
 * `else`: `const cand = &nodes[cursor - 2];` `cand.in_use` with 、 3.1 of `isDirectChild(dir_path, 
        * `if (matched)`:
          * `const reclen = std.mem.alignForward(usize, 19 + entry_name.len + 1, 8);`
          * `if (written + reclen > user_buf.len)`:
 `if (written == 0) return Errno.EINVAL;` （buffer 1 when）
 `break;` （times `cursor` ）。
          * `var rec = user_buf[written .. written + reclen];`
          * `@memset(rec, 0);`
          * `std.mem.writeInt(u64, rec[0..8], d_ino, .little);`
          * `std.mem.writeInt(i64, rec[8..16], @intCast(cursor + 1), .little);`
          * `std.mem.writeInt(u16, rec[16..18], @intCast(reclen), .little);`
          * `rec[18] = d_type;`
          * `@memcpy(rec[19 .. 19 + entry_name.len], entry_name);`
          * `written += reclen;`
        * `cursor += 1;`
     7. `file.offset = cursor;`
     8. `return written;`
3. **Step 3: `src/proc/task.zig` and `src/syscall/dispatch.zig` Implementation **
 * `Task` struct `cwd_buf: [vfs.MAX_PATH_LEN]u8 = [_]u8{'.'} ++ [_]u8{0} ** (vfs.MAX_PATH_LEN - 1)` and `cwd_len: 
 * `dispatch.zig` `resolveUserPath(dirfd: isize, user_path_ptr: usize, out_canonical: *[vfs.MAX_P
 * user space⽂column 、 `dirfd == vfs.AT_FDCWD` （ or value） `cur.cwd()` 、 `dirfd >= 0` of 
 * `sysOpenat` (257) with `O_CREAT`, `O_EXCL`, `O_TRUNC`, `O_APPEND`, `O_DIRECTORY` 。
 * `sysWrite` (1) & `sysWritev` (20) with `.VFS_FILE` write：
 * `(entry.flags & vfs.O_APPEND) != 0` `entry.offset = vfs.getNodeByIndex(entry.node_idx).size;` 。
     * `const n = vfs.writeNode(entry.node_idx, entry.offset, slice) catch |err| return errno_mod.toReturn(err);`
     * `entry.offset += n; return @intCast(n);`
   * `sysGetdents64` (217), `sysMkdir` (83), `sysMkdirat` (258), `sysUnlink` (87), `sysRmdir` (84), `sysUnlinkat` (2
4. **Step 4: `scripts/verify_qemu.sh` and `src/main.zig` of update **
 * `scripts/verify_qemu.sh` of `.cache/initramfs_root/etc/rc.sh` of update：
     ```sh
     #!/bin/sh
     echo "[TINUX_SH] Testing writable tmpfs & directory operations..."
     /bin/mkdir /tmp/work
     echo "Tinux tmpfs write and redirection OK!" > /tmp/work/hello.txt
     /bin/touch /tmp/work/stamp.tmp
     echo "[TINUX_LS] Listing /tmp/work before rm:"
     /bin/ls /tmp/work
     /bin/cat /tmp/work/hello.txt
     /bin/rm /tmp/work/stamp.tmp
     echo "[TINUX_LS] Listing /tmp/work after rm:"
     /bin/ls /tmp/work
     echo "[TINUX_TMPFS] All file creation, listing, and deletion tests passed!"
     exit 0
     ```
 * `.cache/initramfs_root/bin/` `mkdir`, `touch`, `ls`, `rm` of （ or ） add（
 * `src/main.zig` of start `[TINUX_TEST] START: TASK-009\n` 、 PID 1 exit of PASS `[TINUX_TEST] PASS
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
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-009 5` when、 Builder fixloop stop、 `ESCALATIO
```markdown
# Escalation Report: TASK-009
## 1. Failure Summary
* **Failed Stage:** [zig build / mkdir ENOENT / Shell Redirection > Failure / getdents64 Alignment Crash / touch uti
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
[Relevant code diff for src/fs/vfs.zig or src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
