# Tinux Implementation Specification: TASK-016
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-015` Passed (`./scripts/verify_qemu.sh TASK-015 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition POSIX USTAR （ 512 ＋）、 `sys_mount` (165) / `sys_umount2` (16
2. **Host-Compatible USTAR Checksum Discipline （strictly adhere） :**
 OS `/mnt` create‧ of `tar` with extract‧verification with 、 USTAR （
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。
4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-016 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| 8 ASCII ⽂column | 10 ⼿ | `std.fmt.parseInt(usize, oct_slice, 8)` |
| 8 ASCII | ⼿loop | `std.fmt.bufPrint(buf, "{o:0>11}\x00",.{val}) catch unreachable` |
| NUL/ empty⽩ | ⼿ | `std.mem.trimRight(u8, raw_field, &[_]u8{ 0, ' ' })` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-016`
* **Title:** `Persistent Disk Filesystem (POSIX USTAR / tarfs on /dev/vda), sys_mount / sys_umount2 / sys_sync Imple
* **Target Subsystem:** `fs`, `drivers`, `syscall`
* **Target Files to Create / Modify:**
  * `src/fs/tarfs.zig` (Create: POSIX USTAR block reader/writer backed by `virtio_blk` sectors)

  * `src/fs/vfs.zig` (Modify: notify `tarfs` on writes/unlinks under mounted prefix `"mnt"` and expose node iteratio
  * `src/fs/procfs.zig` (Modify: update `/proc/mounts` dynamically when `/dev/vda` is mounted on `/mnt`)
  * `src/syscall/dispatch.zig` (Modify: implement `sys_mount(165)`, `sys_umount2(166)`, and connect `sys_sync(162)` 
  * `src/main.zig` (Modify: register `/mnt` directory on boot and update test markers to `TASK-016`)
  * `scripts/verify_qemu.sh` (Modify: build a real USTAR disk image on host, mount `/dev/vda` onto `/mnt` inside Tin
---
## 3. Persistent Filesystem (`tarfs`) & Mount ABI Contract (Opus 5.5 Audited)
### 3.1 POSIX.1-1988 USTAR 512-Byte Sector Layout Contract
 with root permission（ `sudo mount` ） and 、 of `tar` and 100% ⽤blockfilesystem and **P
| Byte Offset | Length | Field Name | Format & Persistence Contract |
| :--- | :--- | :--- | :--- |
| `0..100` | `100 B` | `name` | mount（ NUL 、e.g.： `"host_config.txt"` or `"./host_config.txt"` ）
| `100..108` | `8 B` | `mode` | 8 ASCII ⽂column（e.g.： `"0000644\x00"` or `"0000755\x00"` ）。 |
| `108..116` | `8 B` | `uid` | `"0000000\x00"` |
| `116..124` | `8 B` | `gid` | `"0000000\x00"` |
| `124..136` | `12 B` | `size` | of 11 8 ASCII ＋ NUL （e.g.： `"00000000045\x00"` ）。 of when `"0
| `136..148` | `12 B` | `mtime` | `"00000000000\x00"` |
| `148..156` | `8 B` | `chksum` | 6 8 ASCII ＋ NUL ＋（ `"{o:0>6}\x00 "` ）。 `0x20` × 8 and 512 
| `156` | `1 B` | `typeflag` | `'0'` (`0x30`) or `0` ＝ (`S_IFREG`) 、 `'5'` (`0x35`) ＝ (`S
| `257..263` | `6 B` | `magic` | `"ustar\x00"` （ POSIX USTAR ） or `"ustar "` （ GNU tar ）。 |
| `263..265` | `2 B` | `version` | `"00"` or `" \x00"` 。 |
* **End-of-Archive Condition:**
 sectorfirst `sector_buf[0] == 0` （zerosector） and read 。write（ `syncToD
### 3.2 Linux Mount & Sync Syscall Contract (x86_64)
| Syscall Name | Num | Arguments | Exact Kernel Behavior & Return Contract |
| :--- | :--- | :--- | :--- |
| **`sys_mount`** | `165` | `source_ptr, target_ptr, fstype_ptr, flags, data_ptr` | `target` （e.g.： `"mnt"` ）。
| **`sys_umount2`** | `166` | `target_ptr, flags` | `tarfs.syncToDisk()` `"mnt/"` of VFS node `/
| **`sys_sync` / `fsync`** | `162` / `74` | `(fd)` | mount with `tarfs.syncToDisk()` execute `/dev/vda` to 
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
`tarfs.zig` `"mnt/"` of node ⾛‧persistent with 、 `src/fs/vfs.zig` of ：
```zig
pub fn getNodeSlot(idx: usize) *const VfsNode {
    return &nodes[idx];
}

```
、 `vfs.writeNode` and `vfs.unlink` of 、node of `"mnt/"` with `tarfs.isMounted()` `tr
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/fs/tarfs.zig` of `mountFromDisk` implement **
 * `!virtio_blk.isReady()` `return Errno.ENODEV;` 。
 * `target_canonical` （e.g.： `"mnt"` ） `mount_prefix_buf` 、 `_ = vfs.registerNode(target_canonical, vfs.S_IF
   * `var sector: u64 = 0;` 、 `var hdr_buf: [512]u8 = undefined;` 、 `var loaded_files: usize = 0;` 。
 * loop with `virtio_blk.rwSector(sector, &hdr_buf, false)` ：
 1. `if (hdr_buf[0] == 0) break;` （）。
 2. `hdr_buf[257..262]` `"ustar"` and ⼀verify（⼀ `break` ）。
     3. `const raw_name = std.mem.sliceTo(hdr_buf[0..100], 0);`
     4. `const rel_name = vfs.normalizePath(raw_name);`
     5. `const size_str = std.mem.trimRight(u8, hdr_buf[124..136], &[_]u8{ 0, ' ' });`
     6. `const filesize = if (size_str.len > 0) (std.fmt.parseInt(usize, size_str, 8) catch 0) else 0;`
     7. `const typeflag = hdr_buf[156];`
 8. `full_path` （ `"{s}/{s}"`, `.{ target_canonical, rel_name }` ） 。
 9. `if (typeflag == '5' or std.mem.endsWith(u8, raw_name, "/"))` （ of when）：
        * `if (!std.mem.eql(u8, rel_name, ".")) _ = vfs.registerNode(full_path, vfs.S_IFDIR | 0o755, "");`
        * `sector += 1;`
 10. （ `typeflag == '0' or typeflag == 0` ） of when：
 * empty `_ = vfs.registerNode(full_path, vfs.S_IFREG | 0o644, "");` with 、 of node 
         * `var rem = filesize; var data_sec = sector + 1; var file_off: usize = 0;`
         * `var sec_data: [512]u8 = undefined;`
 * `while (rem > 0) : (data_sec += 1)` with `virtio_blk.rwSector(data_sec, &sec_data, false)` 、 `const ch
         * `const data_sectors = (filesize + 511) / 512;`
         * `sector += 1 + data_sectors;`
         * `loaded_files += 1;`
   * `is_mounted = true; return loaded_files;`
2. **Step 2: `src/fs/tarfs.zig` of `syncToDisk` implement **
   * `if (!is_mounted or !virtio_blk.isReady()) return;`
   * `var sector: u64 = 0;` 、 `var hdr: [512]u8 = undefined;` 、 `var data_blk: [512]u8 = undefined;`
   * `const prefix = mountPrefix();`
 * `0..vfs.MAX_VFS_NODES` of node `i` ⾛：
     1. `const node = vfs.getNodeSlot(i);`
     2. `if (!node.in_use) continue;`
     3. `const name = node.name();`
     4. `if (name.len <= prefix.len + 1) continue;`
     5. `if (!std.mem.startsWith(u8, name, prefix) or name[prefix.len] != '/') continue;`
     6. `const rel_name = name[prefix.len + 1 ..];`
     7. `@memset(&hdr, 0);`
     8. `@memcpy(hdr[0..rel_name.len], rel_name);`
     9. `const is_dir = node.isDir();`
     10. `_ = std.fmt.bufPrint(hdr[100..108], "{o:0>7}\x00", .{node.mode & 0o777}) catch unreachable;`
     11. `@memcpy(hdr[108..116], "0000000\x00");` (`uid`)
     12. `@memcpy(hdr[116..124], "0000000\x00");` (`gid`)
     13. `const fsize: usize = if (is_dir) 0 else node.size;`
     14. `_ = std.fmt.bufPrint(hdr[124..136], "{o:0>11}\x00", .{fsize}) catch unreachable;`
     15. `@memcpy(hdr[136..148], "00000000000\x00");` (`mtime`)
 16. `@memset(hdr[148..156], ' ');` （⽤ of empty⽩ 8 ）
     17. `hdr[156] = if (is_dir) '5' else '0';`
     18. `@memcpy(hdr[257..263], "ustar\x00");`
     19. `@memcpy(hdr[263..265], "00");`
 20. ** :**
         `var sum: u32 = 0; for (hdr) |b| sum += b;`
         `_ = std.fmt.bufPrint(hdr[148..156], "{o:0>6}\x00 ", .{sum}) catch unreachable;`
     21. `_ = virtio_blk.rwSector(sector, &hdr, true); sector += 1;`
     22. `if (!is_dir and fsize > 0)`:
         * `const content = node.slice(); var off: usize = 0;`
         * `while (off < fsize) : (off += 512)`:
           `@memset(&data_blk, 0);`
           `const chunk = @min(fsize - off, 512);`
           `@memcpy(data_blk[0..chunk], content[off .. off + chunk]);`
           `_ = virtio_blk.rwSector(sector, &data_blk, true); sector += 1;`
 * loopexit、 `@memset(&hdr, 0);` zerosector `sector` and `sector + 1` of 2 sector。
3. **Step 3: `src/syscall/dispatch.zig` and `src/fs/procfs.zig` of update **
   * `sysMount(source_ptr: usize, target_ptr: usize, fstype_ptr: usize, flags: usize, data_ptr: usize) isize` (`165`
 target 、 `tarfs.mountFromDisk(target_canonical)` 。 `procfs.syncProcessNodes()` with 
   * `sysUmount2(target_ptr: usize, flags: usize) isize` (`166`):

 `tarfs.syncToDisk() catch |err| return errno_mod.toReturn(err);` execute `0` 。
   * `sysSync()` (`162`) / `sysFsync` (`74`):
 `if (tarfs.isMounted()) { tarfs.syncToDisk() catch {}; }` `0` 。
 * `vfs.lookup` of BusyBox `"bin/mount"`, `"mount"`, `"bin/umount"`, `"umount"`, `"bin
4. **Step 4: `scripts/verify_qemu.sh` of update（ `tar` and of ⽅persistentverification） **
 * QEMU 、 with `host_seed.txt` of USTAR disk `$DISK_IMG` （ 1 MiB ） create
     ```bash
     DISK_STAGE="/tmp/tinux_disk_stage_${TEST_CASE}"
     rm -rf "$DISK_STAGE" && mkdir -p "$DISK_STAGE"
     echo "[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!" > "$DISK_STAGE/host_seed.txt"
     tar --format=ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt
     truncate -s 1M "$DISK_IMG"
     ```
 * type（ `/bin/sh` ） to of column ⼊：
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
 * QEMU exit、 of `verify_qemu.sh` with of `tar` `$DISK_IMG` from `guest_created.txt` 
     ```bash
     if tar -xOf "$DISK_IMG" guest_created.txt 2>/dev/null | grep -q "PERSISTED_BY_TINUX_KERNEL_OVER_VIRTIO_BLK"; th
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
QEMU output of output、 of `tar -xOf` verification Exit Code `0` with ：
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
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-016 10` when、 Builder fixloop stop、 `ESCALATI
```markdown

# Escalation Report: TASK-016
## 1. Failure Summary
* **Failed Stage:** [zig build / USTAR Header Parse Error / sys_mount Failure / Writeback Checksum Error / Host tar 
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
[Relevant code diff for src/fs/tarfs.zig, src/fs/vfs.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
2. ANTIGRAVITY_MASTER_PROMPT.md（ 16 task⾃execute）
 with create SPEC_TASK_001.md 〜 SPEC_TASK_016.md of docs/specs/ placed with 、 Google Antigravity of 
（ Gemini 3.8 Flash High 、 and of Gemini 4 Argon / Claude Opus 5.5 ） of 
⽰ with 。
# Tinux Autonomous Kernel Engineering — Master Orchestrator Prompt
> **Target Environment:** Google Antigravity IDE / CLI
> * **Primary Builder Model:** Gemini 3.8 Flash High (Fast Autonomous Execution Loop)
> * **Escalation Architect / Auditor Models:** Gemini 4 Argon / Claude Opus 5.5
> * **Project Goal:** Build **Tinux**, a clean-room Linux ABI-compatible x86_64 kernel written in Zig, executing `TA
---
## 1. Directory Structure & Prerequisite Setup
executestart 、 of verify。
```text
tinux/
├── ANTIGRAVITY_MASTER_PROMPT.md # ⽰
├── PROGRESS.md # ⾃update
├── docs/
│ ├── SPEC_TEMPLATE.md # specification
│   └── specs/
│       ├── SPEC_TASK_001.md       # Boot, Serial COM1 & QEMU Harness
│       ├── SPEC_TASK_002.md       # GDT/TSS, IDT Exceptions & PMM
│       ├── SPEC_TASK_003.md       # 4-Level VMM & Kernel Heap Allocator
│       ├── SPEC_TASK_004.md       # SYSCALL/SYSRET, Ring 3 & sys_write/exit
│       ├── SPEC_TASK_005.md       # Static ELF64 Loader, Auxv, TLS & brk
│       ├── SPEC_TASK_006.md       # VFS, CPIO Initramfs & Unmodified BusyBox
│       ├── SPEC_TASK_007.md       # Multi-Process (fork/execve/wait4) & /bin/sh
│       ├── SPEC_TASK_008.md       # Pipes (pipe2), dup2 Redirection & /proc
│       ├── SPEC_TASK_009.md       # Writable tmpfs, getdents64 & ls/mkdir/rm
│       ├── SPEC_TASK_010.md       # Hardware Timer (PIT/PIC), nanosleep, ps & kill
│       ├── SPEC_TASK_011.md       # Dynamic ELF Loader (PT_INTERP / ld-musl)
│       ├── SPEC_TASK_012.md       # Interactive TTY Console (IRQ4 / termios)
│       ├── SPEC_TASK_013.md       # Linux Socket API (TCP Loopback & AF_UNIX)
│       ├── SPEC_TASK_014.md       # Multi-Threading (CLONE_VM), futex & epoll
│       ├── SPEC_TASK_015.md       # PCI Enumeration & VirtIO-Block (/dev/vda)
│       └── SPEC_TASK_016.md       # Persistent TarFS Mount (sys_mount / sync)
```
---
## 2. Prompt for Primary Builder (Gemini 3.8 Flash High)
Antigravity with **Gemini 3.8 Flash High** 、 of of ⼊⾃execute start。
```text
 Tinux of Implementation Builder with 。

`ANTIGRAVITY_MASTER_PROMPT.md` of protocol 、 `docs/specs/SPEC_TASK_001.md` from `SPEC_TASK_016.md` with 1 task
### 【protocol（ Autonomous Loop Rules ）】
1. **Pre-Flight Check （times of ） :**
 - `zig version`, `qemu-system-x86_64 --version`, `cpio --version`, `tar --version` execute verify。
 - `PROGRESS.md` existswhen、 `TASK-001` 〜 `TASK-016` of create。
 - `git status` verify、initialized `git init` execute。
2. **Sequential Task Execution （ 1 task of execute） :**
 - `PROGRESS.md` verify、 of task `TASK-0XX` 。
 - must `docs/specs/SPEC_TASK_0XX.md` ⽂ with from implement start。task and implement
3. **Verification Gate （ QEMU ⾃verification） :**
 - implement、 of 6 definitionverification `./scripts/verify_qemu.sh TASK-0XX [timeout]` execute
 - exit `0` with 、output `[TINUX_TEST] PASS: TASK-0XX` and `[HARNESS] SUCCESS: TASK-0XX verified 
4. **Checkpointing （pass of ⾃ and task to of ⾏） :**
 - verification pass、 `PROGRESS.md` of task `[x] TASK-0XX: PASSED` update、 `git add -A && git commit -m "feat(
 - 、 of task `TASK-0(XX+1)` of read、⾃loop 。
5. **3-Strike Escalation Circuit Breaker （protected of of stop） :**
 - ⼀task `./scripts/verify_qemu.sh` **3 timesconsecutive with （ Attempt 1, 2, 3 Fail ） ** when、 **4 times⽬
 - of task of 7 of `ESCALATION_REPORT.md` 、「 TASK-0XX with 3 timesconsecutive
```
---
## 3. Prompt for Escalation Architect (Gemini 4 Argon / Claude Opus 5.5)
⼀、 Gemini 3.8 Flash High of task with 3 times `ESCALATION_REPORT.md` outputstopwhen、 **Gemin
```text
Builder （ Gemini 3.8 Flash High ）implement 3 、 `ESCALATION_REPORT.md` outputstop。
1. `ESCALATION_REPORT.md` 、task of `docs/specs/SPEC_TASK_0XX.md` 、 and of verify
2. （ Root Cause ） 、 of ⾏：
 - of ⽰ of when、 `docs/specs/SPEC_TASK_0XX.md` fix、 Builder implement
 - registerpagestable of when、 of fix ⽤、 `./scripts/verify_qem
```
fix、 **Gemini 3.8 Flash High** 、「 `PROGRESS.md` of task from ⾃executeloop 」
```
