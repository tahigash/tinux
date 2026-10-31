# Tinux Implementation Specification: TASK-006
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-005` Passed (`./scripts/verify_qemu.sh TASK-005 5` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition CPIO 、 VFS node、 FD table、 `LinuxStat` （ 144 bytes ） of memory、
2. **Strict Zig Version Idioms:**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
3. **User Page Remapping Safety （ Identity Map and of ⽌） :**
 kernel space of Identity Map （ `PTE_USER` ） and user spacepages（ `0x0040_0000` 、 `PTE_USER` ） 
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-006 5` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| 16 ASCII ⽂column of | ⼿ | `std.fmt.parseInt(u32, hex_slice, 16)` |
| ⽂column⼀evaluation | `a == b` (⽐) | `std.mem.eql(u8, a, b)` |
| 4 | `(x + 3) & ~3` (typeerror) | `std.mem.alignForward(usize, x, 4)` |
| C column to of ⽂column | loop⼿ | `@memcpy(dst[0..src.len], src)` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-006`
* **Title:** `In-Memory VFS, Initramfs (newc CPIO) Unpacker, File I/O Syscalls (openat/read/writev/close/fstat/ioctl
* **Target Subsystem:** `fs`, `proc`, `mm`, `syscall`
* **Target Files to Create / Modify:**
  * `src/mm/pmm.zig` (Modify: reserve first 16 MiB so kernel + embedded initramfs never collide with user virtual ad
  * `src/mm/vmm.zig` (Modify: add `isUserPageMapped` helper checking `PTE_PRESENT | PTE_USER`)
  * `src/fs/vfs.zig` (Create: in-memory VFS node table and File Descriptor table)
  * `src/fs/cpio.zig` (Create: SVR4 `newc` `070701` CPIO archive parser)
  * `src/proc/elf.zig` (Modify: support `ET_EXEC` & `ET_DYN` Static-PIE + dynamic `argv` slices)
  * `src/syscall/dispatch.zig` (Modify: add VFS I/O, `writev`, `fstat`/`newfstatat`, `ioctl`, `uname`, `mmap`, ID sy
  * `src/main.zig` (Modify: mount `initramfs.cpio` and boot `/bin/busybox cat /etc/motd`)

  * `scripts/verify_qemu.sh` (Modify: build `initramfs.cpio` containing `/bin/busybox` and `/etc/motd`)
---
## 3. VFS, CPIO & Linux ABI Contract (Opus 5.5 Audited)
### 3.1 SVR4 `newc` CPIO Format Contract (`070701` / `070702`)
Linux of initramfs `newc` CPIO of ：
1. **Header (110 bytes fixed ASCII):**
 * `c_magic` (`[6]u8`): `"070701"` or `"070702"` 。
 * 13 of 8 ⽂ of 16 ASCII ⽂column（ `[8]u8` ）。 important of `c_mode` (offset `14..22`) 、 `c_filesiz
2. **Filename & 4-Byte Alignment:**
 * of `offset + 110` from `namesize` NUL of （ and `namesize - 1` ⽂column⻑
 * `"TRAILER!!!"` of when and 。
 * of start： `data_offset = std.mem.alignForward(usize, header_offset + 110 + namesize, 4)` 。
 * of of ： `next_offset = std.mem.alignForward(usize, data_offset + filesize, 4)` 。
3. **Path Normalization Rule:**
 * CPIO of （ `"./etc/motd"`, `"/etc/motd"`, `"etc/motd"` ） and `sys_openat` ⼀、
### 3.2 Linux x86_64 File & Runtime Syscalls Contract
 of BusyBox （ `musl` or `glibc` ） from `cat /etc/motd` with ：
| Syscall | Num | Arguments | Exact Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_read`** | `0` | `fd, buf, count` | `fd == 0` `0` (EOF) 。 `fd >= 3` `VfsFile` of from ⼤ 
| **`sys_open`** | `2` | `path_ptr, flags, mode` | `sysOpenat(AT_FDCWD, path_ptr, flags, mode)` 。 |
| **`sys_close`** | `3` | `fd` | `fd >= 3` of FD freed `0` 。 `-EBADF (-9)` 。 |
| **`sys_stat` / `sys_lstat`** | `4` / `6` | `path_ptr, statbuf` | `sysNewfstatat(AT_FDCWD, path_ptr, statbuf, 0)` 
| **`sys_fstat`** | `5` | `fd, statbuf` | `fd == 0, 1, 2` Device (`st_mode = 0o020666`) 、 `fd >= 3` 
| **`sys_lseek`** | `8` | `fd, offset, whence` | `SEEK_SET(0)`, `SEEK_CUR(1)`, `SEEK_END(2)` 
| **`sys_mmap`** | `9` | `addr, len, prot, flags, fd, off` | `mmap_next_vaddr` (`0x4000_0000` start) or `MAP_FIXED
| **`sys_mprotect` / `munmap`** | `10` / `11` | `addr, len,...` | `0` (Success) 。 |
| **`sys_ioctl`** | `16` | `fd, req, argp` | `fd <= 2` `req == 0x5413` (`TIOCGWINSZ`) of when、 `argp` `ws_row=2
| **`sys_writev`** | `20` | `fd, iov_ptr, iovcnt` | ** 【mandatory】 ** `musl` of `stdout` output with use。 `iovcnt` of `Io
| **`sys_uname`** | `63` | `buf_ptr` | `LinuxUtsname` (390 bytes: `sysname="Linux"`, `nodename="tinux"`, `release="6
| **`sys_openat`** | `257` | `dirfd, path_ptr, flags, mode` | ⽂column 、 VFS from empty FD (`3..63`
| **`sys_newfstatat`** | `262` | `dirfd, path_ptr, statbuf, flag` | `AT_EMPTY_PATH (0x1000)` of when `sysFstat(dirfd
| **ID / Stub Syscalls** | Misc | `39, 102, 104, 107, 108, 110, 273, 302` | `getpid(39)=1`, `getppid(110)=0`, `getui
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/mm/pmm.zig` & `src/mm/vmm.zig` Updates
1. **`src/mm/pmm.zig`:**
 Initramfs and user space（ `0x0040_0000.. 0x00FF_FFFF` ） and of ‧
   ```zig
   const kernel_end_phys = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), PAGE_SIZE);
   const safe_start_phys = @max(kernel_end_phys, 0x0100_0000); // Start dynamic allocations at >= 16 MiB
   const start_page = safe_start_phys / PAGE_SIZE;
   ```
2. **`src/mm/vmm.zig`:**
 virtual address **`PTE_USER` ** of pages evaluationfunction add：
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
    data: []const u8 = &[_]u8{},
    inode_no: u64 = 0,
    pub fn name(self: *const VfsNode) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};
pub const OpenFile = struct {
    in_use: bool = false,
    node_idx: usize = 0,
    offset: usize = 0,
    flags: u32 = 0,
};
pub const LinuxStat = extern struct {
    st_dev: u64 = 1,
    st_ino: u64 = 1,
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
    __unused: [3]i64 = .{ 0, 0, 0 },
    comptime {
        std.debug.assert(@sizeOf(LinuxStat) == 144);
        std.debug.assert(@offsetOf(LinuxStat, "st_mode") == 24);
        std.debug.assert(@offsetOf(LinuxStat, "st_size") == 48);
    }
};
var nodes: [MAX_VFS_NODES]VfsNode = [_]VfsNode{.{}} ** MAX_VFS_NODES;
var fd_table: [MAX_OPEN_FILES]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN_FILES;
pub fn init() void {
    // Builder clears nodes/fd_table and registers "/dev/null" and root "."
}
pub fn normalizePath(raw_path: []const u8) []const u8 {
    var p = raw_path;
    while (p.len > 0) {
        if (std.mem.startsWith(u8, p, "./")) {
            p = p[2..];
        } else if (p[0] == '/') {
            p = p[1..];
        } else {
            break;
        }
    }

    if (p.len == 0) return ".";
    return p;
}
pub fn registerNode(raw_path: []const u8, mode: u32, data: []const u8) bool {
    // Builder adds or updates node in `nodes` array
}
pub fn lookup(raw_path: []const u8) ?*const VfsNode {
    // Builder normalizes path and returns matching *const VfsNode
}
pub fn open(raw_path: []const u8, flags: u32) Errno!usize {
    // Builder looks up node, allocates fd in range 3..MAX_OPEN_FILES, returns fd
}
pub fn getFile(fd: usize) ?*OpenFile {
    if (fd < 3 or fd >= MAX_OPEN_FILES) return null;
    if (!fd_table[fd].in_use) return null;
    return &fd_table[fd];
}
pub fn getNodeByIndex(idx: usize) *const VfsNode {
    return &nodes[idx];
}
pub fn close(fd: usize) Errno!void {
    if (fd < 3 or fd >= MAX_OPEN_FILES or !fd_table[fd].in_use) return Errno.EBADF;
    fd_table[fd].in_use = false;
}
```
### 4.3 `src/fs/cpio.zig`
```zig
const std = @import("std");
const vfs = @import("vfs.zig");
const serial = @import("../drivers/serial.zig");
pub fn mountInitramfs(archive: []const u8) usize {
    // Builder parses SVR4 newc ("070701" / "070702") entries and registers each in vfs
}
```
### 4.4 `src/proc/elf.zig` Signature Update
`loadStaticElf` `argv: []const []const u8` 、 `ET_EXEC (2)` and `ET_DYN (3)` of ⽅ update
```zig
pub fn loadStaticElf(
    pml4_phys: usize,
    elf_bytes: []const u8,
    argv: []const []const u8,
) !LoadedImage
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/vfs.zig` and `src/fs/cpio.zig` Implementation **
 * `vfs.init()` with initialized、 `registerNode(".", S_IFDIR | 0o755, "")` and `registerNode("dev/null", S_IFCHR
   * `cpio.mountInitramfs(archive: []const u8) usize`:
     1. `var offset: usize = 0;` 、 `var count: usize = 0;` 。
 2. `while (offset + 110 <= archive.len)` with loop。
 3. `const magic = archive[offset.. offset + 6];` `"070701"` with `"070702"` with `break` 。
     4. `const mode = std.fmt.parseInt(u32, archive[offset + 14 .. offset + 22], 16) catch break;`
     5. `const filesize = std.fmt.parseInt(usize, archive[offset + 54 .. offset + 62], 16) catch break;`
     6. `const namesize = std.fmt.parseInt(usize, archive[offset + 94 .. offset + 102], 16) catch break;`
     7. `const name_start = offset + 110;`
 8. `const name_slice = archive[name_start.. name_start + namesize - 1];` (of NUL) 。
     9. `if (std.mem.eql(u8, name_slice, "TRAILER!!!")) break;`
     10. `const data_start = std.mem.alignForward(usize, name_start + namesize, 4);`
     11. `const data_slice = archive[data_start .. data_start + filesize];`
     12. `if (vfs.registerNode(name_slice, mode, data_slice)) count += 1;`
     13. `offset = std.mem.alignForward(usize, data_start + filesize, 4);`
 14. loopexit、 `count` 。
2. **Step 2: `src/proc/elf.zig` of （ Static-PIE & `argv` ） **
 * `ehdr.e_type != 2 and ehdr.e_type != 3` of when of error and 。

 * `const load_bias: usize = if (ehdr.e_type == 3) 0x0040_0000 else 0;` definition、 `PT_LOAD` of `seg_start = load_
 * pagesevaluation must `!vmm.isUserPageMapped(pml4_phys, page_addr)` use（ 、 of Ident
 * stackpages（ `0x0080_3000` ） of ⽂columnregion（ `0xF00` ） `argv[0..argv.len]` of ⽂column 
 * `0x0080_3E00` （ 16 boundary） from `slot: [*]u64` ：
     * `slot[0] = argv.len` (`argc`)
 * `slot[1.. 1 + argv.len]` = `argv_ptrs[i]`
 * `slot[1 + argv.len] = 0` (`argv` NULL)
 * `envp[0] = env_str_vaddr`, `envp[1] = 0` 、 and `TASK-005` and `auxv` placed。
3. **Step 3: `src/syscall/dispatch.zig` of implement **
 * user space of NUL ⽂column `readUserCString(user_ptr: usize, out_buf: []u8) Errno![]const
   * **`sysWritev` (20):**
 `pub const IoVec = extern struct { base: usize, len: usize };` definition、 `0..iovcnt` loop `iov.len > 0` of 
   * **`sysOpenat` (257) & `sysOpen` (2):**
 ⽂column 、 `vfs.open(path, @truncate(flags))` with FD 。
   * **`sysRead` (0):**
 `fd == 0` `0` 。 `vfs.getFile(fd)` 、 `node = vfs.getNodeByIndex(file.node_idx)` of `node.data` 
   * **`sysFstat` (5) & `sysNewfstatat` (262):**
 `LinuxStat` struct 、 `@as(*align(1) LinuxStat, @ptrFromInt(statbuf_ptr)).* = st;` with 。
   * **`sysMmap` (9):**
 `var mmap_next_vaddr: usize = 0x4000_0000;` ⽤。 `len == 0` `-EINVAL` 。 `aligned_len = s
4. **Step 4: `scripts/verify_qemu.sh` with of BusyBox and Initramfs ⽣ **
 * `verify_qemu.sh` with 、 `zig build` of of ⼿ with `src/fs/initramfs.cpio` ⾃⽣：
 1. `.cache/initramfs_root/bin` and `.cache/initramfs_root/etc` create。
 2. `.cache/initramfs_root/etc/motd` of ⽂column ：
        `[TINUX_VFS] Welcome to Tinux! Unmodified Linux BusyBox is alive via CPIO Initramfs!`
 3. `/bin/busybox` of ：
 * of `/bin/busybox` （ `file /bin/busybox | grep -q "statically linked"` ） with `.cach
 * with `.cache/busybox-static` cacheverify、 `curl -fsSL --connect-timeout 5 htt
 * ⼀ with above ⼊⼿ with when of and 、 `zig build-exe -target x86_64-linux-musl -O
     4. `(cd .cache/initramfs_root && find . -print0 | cpio --null -o -H newc > ../../src/fs/initramfs.cpio 2>/dev/n
5. **Step 5: `src/main.zig` of update **
 * `const initramfs_bytes = @embedFile("fs/initramfs.cpio");` with 。
 * `kmain()` with execute：
     1. `serial.writeString("[TINUX_TEST] START: TASK-006\n");`
     2. `vfs.init();`
     3. `const mounted_count = cpio.mountInitramfs(initramfs_bytes);`
     4. `std.debug.assert(mounted_count >= 2);`
     5. `serial.writeString("[TINUX_VFS] Initramfs mounted cleanly\n");`
     6. `const bb_node = vfs.lookup("/bin/busybox") orelse @panic(" /bin/busybox not found in VFS");`
     7. `const argv = [_][]const u8{ "/bin/busybox", "cat", "/etc/motd" };`
     8. `const image = elf.loadStaticElf(vmm.getKernelPml4Phys(), bb_node.data, &argv) catch @panic("BusyBox ELF loa
     9. `dispatch.initBrk(image.initial_brk);`
     10. `serial.writeString("[TINUX_EXEC] Launching /bin/busybox cat /etc/motd...\n");`
     11. `syscall.enterUserMode(image.entry_rip, image.user_rsp);`
 * `dispatch.zig` of `sysExit(0)` of PASS `[TINUX_TEST] PASS: TASK-006\n` update。
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
[TINUX_VFS] Initramfs mounted cleanly
[TINUX_EXEC] Launching /bin/busybox cat /etc/motd...
[TINUX_VFS] Welcome to Tinux! Unmodified Linux BusyBox is alive via CPIO Initramfs!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-006
[HARNESS] SUCCESS: TASK-006 verified cleanly!
```
---

## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-006 5` when、 Builder fixloop stop、 `ESCALATIO
```markdown
# Escalation Report: TASK-006
## 1. Failure Summary
* **Failed Stage:** [CPIO Generation / CPIO Parse / BusyBox ELF Load / Unimplemented Syscall ENOSYS / Ring 3 #PF Fau
* **Last Syscall Number Called Before Failure:** [rax number and rdi, rsi, rdx of value ]
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
[Relevant code diff for src/fs/vfs.zig, src/fs/cpio.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
