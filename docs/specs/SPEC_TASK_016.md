# Tinux Implementation Specification: TASK-016

> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** AI System Architect
> * **Auditor (Low-Level & ABI Contract):** AI Code Auditor
> * **Target Builder:** Autonomous AI Builder Agent
> * **Prerequisite:** `TASK-015` Passed (`./scripts/verify_qemu.sh TASK-015 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Autonomous AI Builder)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter POSIX USTAR 512-byte header parsing offsets, `sys_mount` (165) / `sys_umount2` (166) argument handling, or `/dev/vda` sector writeback algorithms specified here.
2. **Host-Compatible USTAR Checksum Discipline:**
   Disk archives generated or updated inside Tinux must be 100% extractable by host tools (GNU tar / BSD tar). Checksum calculation must strictly sum all 512 header bytes treating the 8 checksum bytes as ASCII spaces (`0x20`).
3. **Strict Zig Version Idioms:**
   Adhere strictly to modern Zig idioms (0.13+) as defined in Section 1. Do not use deprecated functions like `@ptrToInt` or `@intToPtr`.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-016 10` fails 3 consecutive times, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Parse octal ASCII string | Manual byte math | `std.fmt.parseInt(usize, oct_slice, 8)` |
| Format octal ASCII string | Manual loop | `std.fmt.bufPrint(buf, "{o:0>11}\x00", .{val}) catch unreachable` |
| Trim NUL or whitespace | Manual scanning | `std.mem.trimRight(u8, raw_field, &[_]u8{ 0, ' ' })` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-016`
* **Title:** `sys_mount / sys_umount2 / sys_sync Implementation and USTAR tarfs Mount`
* **Target Subsystem:** `fs`, `drivers`, `syscall`
* **Target Files to Create / Modify:**
  * `src/fs/tarfs.zig` (Create: POSIX USTAR block reader/writer backed by `virtio_blk` sectors)
  * `src/fs/vfs.zig` (Modify: notify `tarfs` on writes/unlinks under mounted prefix `"mnt"` and expose node iteration)
  * `src/fs/procfs.zig` (Modify: update `/proc/mounts` dynamically when `/dev/vda` is mounted on `/mnt`)
  * `src/syscall/dispatch.zig` (Modify: implement `sys_mount(165)`, `sys_umount2(166)`, and connect `sys_sync(162)`)
  * `src/main.zig` (Modify: register `/mnt` directory on boot and update test markers to `TASK-016`)
  * `scripts/verify_qemu.sh` (Modify: build real USTAR disk image on host, mount `/dev/vda` onto `/mnt`, verify persistence)
---
## 3. Persistent Filesystem (`tarfs`) & Mount ABI Contract (AI Audited)
### 3.1 POSIX.1-1988 USTAR 512-Byte Sector Layout Contract
To allow host inspection and modification without loopback root permissions, disk contents are formatted as standard POSIX USTAR archives:
| Byte Offset | Length | Field Name | Format & Persistence Contract |
| :--- | :--- | :--- | :--- |
| `0..100` | `100 B` | `name` | File path relative to mount root (NUL-terminated ASCII, e.g. `"host_seed.txt"`). |
| `100..108` | `8 B` | `mode` | Octal permissions string (e.g. `"0000644\x00"` or `"0000755\x00"`). |
| `108..116` | `8 B` | `uid` | Owner user ID in octal ASCII (default `"0000000\x00"`). |
| `116..124` | `8 B` | `gid` | Owner group ID in octal ASCII (default `"0000000\x00"`). |
| `124..136` | `12 B` | `size` | File size in octal ASCII (11 digits plus NUL, e.g. `"00000000045\x00"`). 0 for directories. |
| `136..148` | `12 B` | `mtime` | Modification timestamp in octal ASCII (default `"00000000000\x00"`). |
| `148..156` | `8 B` | `chksum` | Header checksum (6 octal digits + NUL + space: `"{o:0>6}\x00 "`). Computed with checksum field set to 8 spaces. |
| `156` | `1 B` | `typeflag` | `'0'` (`0x30`) or `\0` for regular file (`S_IFREG`), `'5'` (`0x35`) for directory (`S_IFDIR`). |
| `157..257` | `100 B` | `linkname` | Target name for symbolic or hard link. |
| `257..263` | `6 B` | `magic` | POSIX magic string: `"ustar\x00"` (POSIX USTAR) or `"ustar "` (GNU tar). |
| `263..265` | `2 B` | `version` | POSIX version string: `"00"` or `" \x00"`. |
| `265..297` | `32 B` | `uname` | Owner user name in ASCII (default empty or `"root\x00"`). |
| `297..329` | `32 B` | `gname` | Owner group name in ASCII (default empty or `"root\x00"`). |
| `329..337` | `8 B` | `devmajor` | Device major number for character or block special files. |
| `337..345` | `8 B` | `devminor` | Device minor number for character or block special files. |
| `345..500` | `155 B` | `prefix` | Prefix path for filenames exceeding 100 characters. |
* **End-of-Archive Condition:**
  Two consecutive 512-byte blocks filled completely with zeros (`0x00`) indicate the end of the archive.
### 3.2 Linux Mount & Sync Syscall Contract (x86_64)
| Syscall Name | Num | Arguments | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_mount`** | `165` | `source_ptr, target_ptr, fstype_ptr, flags, data_ptr` | Mount block device `source` on directory `target` (e.g. `"/mnt"`). Calls `tarfs.mountFromDisk`. Returns 0. |
| **`sys_umount2`** | `166` | `target_ptr, flags` | Flushes filesystem changes to disk via `tarfs.syncToDisk()`, unlinks mounted VFS nodes, unmounts target. Returns 0. |
| **`sys_sync` / `fsync`** | `162` / `74` | `(fd)` | If filesystem is mounted, flush in-memory VFS nodes under mount point to disk via `tarfs.syncToDisk()`. Returns 0. |
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/fs/tarfs.zig`
```zig
const std = @import("std");
const vfs = @import("vfs.zig");
const virtio_blk = @import("../drivers/virtio_blk.zig");
const Errno = @import("../uapi/errno.zig").Errno;
var is_mounted: bool = false;
var mount_prefix_buf: [64]u8 = [_]u8{ 'm', 'n', 't' } ++ [_]u8{0} ** 61;
var mount_prefix_len: usize = 3;
pub fn isMounted() bool {
    return is_mounted;
}
pub fn mountPrefix() []const u8 {
    return mount_prefix_buf[0..mount_prefix_len];
}
pub fn mountFromDisk(target_canonical: []const u8) Errno!usize {
    // Builder reads 512-byte sectors from virtio_blk, parses USTAR headers,
    // and registers each entry into VFS under "<target_canonical>/<rel_name>"
}
pub fn syncToDisk() Errno!void {
    // Builder iterates all active VFS nodes under "<mount_prefix>/", formats 512-byte USTAR headers
    // with valid octal checksums + padded data sectors, writes them to virtio_blk, and writes 2 zero sectors
}
```
### 4.2 `src/fs/vfs.zig` Additions
Expose node access in `src/fs/vfs.zig` for `tarfs` serialization:
```zig
pub fn getNodeSlot(idx: usize) *const VfsNode {
    return &nodes[idx];
}
```
In `vfs.writeNode` and `vfs.unlink`, track modification under `"mnt/"` so `tarfs.syncToDisk()` can persist changes.
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: Implement `mountFromDisk` in `src/fs/tarfs.zig`:**
   * Verify disk availability: `if (!virtio_blk.isReady()) return Errno.ENODEV;`.
   * Store mount prefix (e.g. `"mnt"`) and ensure VFS mount point exists: `_ = vfs.registerNode(target_canonical, vfs.S_IFDIR | 0o755, "");`.
   * Sector iteration loop:
     1. Read sector: `_ = virtio_blk.rwSector(sector, &hdr_buf, false);`.
     2. If `hdr_buf[0] == 0`, check for end-of-archive and terminate scan.
     3. Verify magic bytes: `hdr_buf[257..262]` must start with `"ustar"`. If invalid, break.
     4. Parse filename: extract `raw_name = std.mem.sliceTo(hdr_buf[0..100], 0);` and normalize relative path.
     5. Parse file size: parse octal string from `hdr_buf[124..136]`.
     6. Extract `typeflag = hdr_buf[156];`.
     7. Form full path: `full_path = "{s}/{s}"` with target prefix and relative path.
     8. If directory (`typeflag == '5'` or trailing slash):
        * Register directory node: `_ = vfs.registerNode(full_path, vfs.S_IFDIR | 0o755, "");`.
        * Increment `sector += 1;`.
     9. If regular file (`typeflag == '0'` or `0`):
        * Register file node: `_ = vfs.registerNode(full_path, vfs.S_IFREG | 0o644, "");`.
        * Read data sectors sequentially into file node data buffer.
        * Calculate required data sectors: `data_sectors = (filesize + 511) / 512;`.
        * Advance sector pointer: `sector += 1 + data_sectors;`.
        * Increment loaded file count.
   * Set `is_mounted = true; return loaded_files;`.
2. **Step 2: Implement `syncToDisk` in `src/fs/tarfs.zig`:**
   * If not mounted or block device not ready, return immediately.
   * Initialize sector cursor to 0: `var sector: u64 = 0;`.
   * Iterate all active VFS nodes:
     1. Retrieve node: `const node = vfs.getNodeSlot(i);`.
     2. Skip unused nodes or nodes not located under mount prefix.
     3. Extract relative path: `const rel_name = name[prefix.len + 1 ..];`.
     4. Format 512-byte USTAR header buffer:
        * Copy relative path into `hdr[0..100]`.
        * Format octal mode: `_ = std.fmt.bufPrint(hdr[100..108], "{o:0>7}\x00", .{node.mode & 0o777}) catch unreachable;`.
        * Set `uid` and `gid` to `"0000000\x00"`.
        * Set file size in octal ASCII: 0 for directories, `node.size` for regular files.
        * Set `mtime` to `"00000000000\x00"`.
        * Set `typeflag` to `'5'` for directories, `'0'` for files.
        * Write magic `"ustar\x00"` and version `"00"`.
        * Populate checksum field with 8 spaces (`0x20`), compute sum of all 512 bytes, and format checksum as `"{o:0>6}\x00 "`.
     5. Write header sector to disk: `_ = virtio_blk.rwSector(sector, &hdr, true); sector += 1;`.
     6. If regular file with data:
        * Write file payload in 512-byte chunks (zero-padding the final sector).
        * Advance sector cursor for each data sector written.
   * Write two consecutive 512-byte zero sectors to mark end of archive.
3. **Step 3: Update `src/syscall/dispatch.zig` and `src/fs/procfs.zig`:**
   * In `sysMount(source_ptr, target_ptr, fstype_ptr, flags, data_ptr)`:
     * Read target path from user space (e.g. `"/mnt"`).
     * Call `tarfs.mountFromDisk(target_canonical)`.
     * Update `/proc/mounts` in `procfs.syncProcessNodes()` to list `/dev/vda /mnt tarfs rw 0 0`.
     * Return 0 on success.
   * In `sysUmount2(target_ptr, flags)`:
     * Flush changes: `tarfs.syncToDisk() catch |err| return errno_mod.toReturn(err);`.
     * Unlink child nodes under mount point, set `is_mounted = false`, and return 0.
   * In `sysSync()` and `sysFsync(fd)`:
     * If `tarfs.isMounted()`, call `tarfs.syncToDisk() catch {};`.
     * Return 0.
4. **Step 4: Update test harness in `scripts/verify_qemu.sh`:**
   * Provision raw disk image with a seeded USTAR archive using host `tar`:
     ```bash
     DISK_STAGE="/tmp/tinux_disk_stage_${TEST_CASE}"
     rm -rf "$DISK_STAGE" && mkdir -p "$DISK_STAGE"
     echo "[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!" > "$DISK_STAGE/host_seed.txt"
     tar --format=ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt
     truncate -s 1M "$DISK_IMG"
     ```
   * Execute shell operations inside the VM:
     ```sh
     echo "[TINUX_SH] Mounting /dev/vda onto /mnt..."
     /bin/mount -t tarfs /dev/vda /mnt
     /bin/cat /proc/mounts
     echo "[TINUX_SH] Reading host-seeded file from /mnt/host_seed.txt:"
     /bin/cat /mnt/host_seed.txt
     echo "[TINUX_SH] Creating persistent file /mnt/guest_created.txt..."
     echo "PERSISTED_BY_TINUX_KERNEL_OVER_VIRTIO_BLK" > /mnt/guest_created.txt
     /bin/ls /mnt
     /bin/sync
     /bin/umount /mnt
     echo "[TINUX_MOUNT] Persistent filesystem mount, read, writeback, and umount verified!"
     exit 0
     ```
   * After VM exit, verify guest data persistence from host using `tar -xOf`:
     ```bash
     if tar -xOf "$DISK_IMG" guest_created.txt 2>/dev/null | grep -q "PERSISTED_BY_TINUX_KERNEL_OVER_VIRTIO_BLK"; then
         echo "[HARNESS] Host tar successfully extracted guest_created.txt from /dev/vda!"
     else
         echo "[HARNESS] FAIL: Host tar could not extract guest_created.txt from disk image."
         exit 1
     fi
     ```
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-016 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
```text
[TINUX_TEST] START: TASK-016
[TINUX_BLK] VirtIO-Block PCI device (/dev/vda) initialized
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Mounting /dev/vda onto /mnt...
rootfs / rootfs rw 0 0
proc /proc proc rw 0 0
/dev/vda /mnt tarfs rw 0 0
[TINUX_SH] Reading host-seeded file from /mnt/host_seed.txt:
[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!
[TINUX_SH] Creating persistent file /mnt/guest_created.txt...
host_seed.txt
guest_created.txt
[TINUX_MOUNT] Persistent filesystem mount, read, writeback, and umount verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-016
[HARNESS] Host tar successfully extracted guest_created.txt from /dev/vda!
[HARNESS] SUCCESS: TASK-016 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
If `zig build` or `./scripts/verify_qemu.sh TASK-016 10` fails 3 consecutive times, stop execution and generate `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-016
## 1. Failure Summary
* **Failed Stage:** [zig build / USTAR Header Parse Error / sys_mount Failure / Writeback Checksum Error / Host tar Extraction Failed]
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
[Relevant code diff for src/fs/tarfs.zig, src/fs/vfs.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For AI Architect / Auditor Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
