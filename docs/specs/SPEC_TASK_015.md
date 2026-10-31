# Tinux Implementation Specification: TASK-015
> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** Gemini 4 Argon
> * **Auditor (Low-Level & ABI Contract):** Claude Opus 5.5
> * **Target Builder:** Gemini 3.8 Flash High (via Google Antigravity)
> * **Prerequisite:** `TASK-014` Passed (`./scripts/verify_qemu.sh TASK-014 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Gemini 3.8 Flash High)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
 specification with definition PCI I/O portnumber、 VirtIO Legacy Register Offset、 `VirtqDesc` / `VirtioBlkReqHeader` of struct
2. **DMA Physical Contiguity & Memory Barrier Discipline （ DMA consecutive and memory of strictly adhere） :**
 Virtqueue of ringregion（ `vring_mem` ） and DMA buffer、pages Physical address 100% consecutive
3. **Strict Zig Version Idioms （ Zig ⽂ of strictly adhere） :**
 must 1 of 「 Zig Idiom Cheat Sheet 」 、function ⼀use。

4. **3-Strike Escalation Protocol:**
 * or `./scripts/verify_qemu.sh TASK-015 10` **3 timesconsecutive with ** when、 **4 times⽬ of speculativefix ⾏
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (KernelFreestanding Rules)
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| memory | with of Ring update | `asm volatile ("mfence" ::: "memory");` |
| 16bit | of structreferenced（ with ） | `@as(*volatile u16, @ptrFromInt(addr)).*` |
| pagesframenumber (PFN) | `phys_addr / 4096` (type⼀) | `@as(u32, @intCast(phys_addr >> 12))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-015`
* **Title:** `PCI Bus Enumeration, VirtIO-Block Driver (DMA Virtqueue), /dev/vda Block Device Integration, and Host 
* **Target Subsystem:** `arch/x86_64`, `drivers`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/arch/x86_64/io.zig` (Modify: add 16-bit `inw`/`outw` and 32-bit `inl`/`outl` port I/O helpers)
  * `src/drivers/pci.zig` (Create: PCI Configuration Mechanism #1 scanner and Bus Master enabler)
  * `src/drivers/virtio_blk.zig` (Create: VirtIO-Block PCI driver, Virtqueue setup, and synchronous sector read/writ
  * `src/fs/vfs.zig` (Modify: add `S_IFBLK = 0o060000`, `DT_BLK = 6`, `FdKind.BLKDEV = 8`, and register `/dev/vda`)
  * `src/fs/procfs.zig` (Modify: register `/proc/partitions` showing `vda` capacity)
  * `src/syscall/dispatch.zig` (Modify: support `.BLKDEV` in `sysRead`, `sysWrite`, `sysPread64`, `sysLseek`, `sysFs
  * `src/main.zig` (Modify: initialize `virtio_blk.init()` and update test markers to `TASK-015`)
  * `scripts/verify_qemu.sh` (Modify: create 1 MiB raw disk image, attach via `-device virtio-blk-pci`, and verify b
---
## 3. PCI & VirtIO-Block Hardware Contract (Opus 5.5 Audited)
### 3.1 PCI Configuration Space (Mechanism #1) Contract
x86_64 PC with 、 I/O port `0x0CF8` (`CONFIG_ADDRESS`) and `0x0CFC` (`CONFIG_DATA`) ⽤ PCI Device of 
1. **Address Format (`u32` written to `0x0CF8`):**
   ```text
   Bit 31       : Enable Bit (Must be 1 -> 0x8000_0000)
   Bits 23..16  : Bus Number (0..255)
   Bits 15..11  : Slot / Device Number (0..31)
   Bits 10..8   : Function Number (0..7)
   Bits 7..2    : Register Offset (offset & 0xFC, 4-byte aligned)
   ```
2. **Target Device Identification (VirtIO-Block Transitional PCI):**
   * `Vendor ID` (Offset `0x00` lower 16 bits) == **`0x1AF4`** (Red Hat / Qumranet VirtIO)
   * `Device ID` (Offset `0x00` upper 16 bits) == **`0x1001`** (VirtIO Block Device)
3. **PCI Command Register & BAR0 Extraction:**
 * Offset `0x04` (Command Register, lower 16 bits) 、 **Bit 0 (`0x01`: I/O Space Enable)** and **Bit 2 (`0x0
 * Offset `0x10` (`BAR0`) 、 2 mask `io_base: u16 = @truncate(bar0 & ~@as(u32, 0x3))` Vir
### 3.2 VirtIO Legacy PCI Register & Virtqueue Contract
`io_base` from of port and initialized of strictly adhere：
| Offset | Width | Name | Initialization & Runtime Sequence |
| :--- | :--- | :--- | :--- |
| `+0x00` | `u32` (R) | `HOST_FEATURES` | Device 。 |
| `+0x04` | `u32` (W) | `GUEST_FEATURES` | sector of `0` 。 |
| `+0x08` | `u32` (RW)| `QUEUE_PFN` | Virtqueue Physical address `4096` with pagesframenumber（ `ring_phys >> 12` ） 
| `+0x0C` | `u16` (R) | `QUEUE_NUM` | Devicerequestqueue `Q` （ QEMU `128` or `256` ） 
| `+0x0E` | `u16` (RW)| `QUEUE_SEL` | queue `0` `0` 。 |
| `+0x10` | `u16` (W) | `QUEUE_NOTIFY` | Available Ring update、 `0` with QEMU DMA start notified。 |
| `+0x12` | `u8` (RW) | `DEVICE_STATUS` | 1. `0x00` (Reset) → 2. `0x01` (`ACKNOWLEDGE`) → 3. `0x03` (`ACKNOWLEDGE \|
| `+0x14` | `u64` (R) | `CAPACITY` | 512 sector of disk（ `+0x14` 32bit 、 `+0x18` 32bit ）。 |
#### Virtqueue Legacy Memory Layout (for Queue Size `Q`):
4096 boundary consecutivememory `vring_mem` of ：
1. **Descriptor Table (`VirtqDesc[Q]`):** `0` （ `16 * Q` bytes ）。
2. **Available Ring (`VirtqAvail`):** `16 * Q` （ `6 + 2 * Q` bytes ）。

   * `flags: u16` (offset `+0`), `idx: u16` (offset `+2`), `ring: [Q]u16` (offset `+4`).
3. **Used Ring (`VirtqUsed`):** **`std.mem.alignForward(usize, 16 * Q + 6 + 2 * Q, 4096)`** （ 4096 boundary
 * `flags: u16` (offset `+0`), `idx: u16` (offset `+2`), `ring: [Q]VirtqUsedElem` (offset `+4`, 8 bytes: `id: u32
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/arch/x86_64/io.zig` Additions
 of `outb` / `inb` 、 of 16-bit / 32-bit port I/O function add：
```zig
pub inline fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "N{dx}" (port),
        : "memory"
    );
}
pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
        : "memory"
    );
}
pub inline fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "N{dx}" (port),
        : "memory"
    );
}
pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
        : "memory"
    );
}
```
### 4.2 `src/drivers/pci.zig`
```zig
const io = @import("../arch/x86_64/io.zig");
pub const CONFIG_ADDRESS: u16 = 0x0CF8;
pub const CONFIG_DATA: u16 = 0x0CFC;
pub const PciDeviceInfo = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    io_base: u16,
    irq_line: u8,
};
pub fn readConfig32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const addr: u32 = 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
    io.outl(CONFIG_ADDRESS, addr);
    return io.inl(CONFIG_DATA);
}
pub fn writeConfig32(bus: u8, slot: u8, func: u8, offset: u8, val: u32) void {
    const addr: u32 = 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |

        (@as(u32, offset) & 0xFC);
    io.outl(CONFIG_ADDRESS, addr);
    io.outl(CONFIG_DATA, val);
}
pub fn findDeviceAndEnableDma(target_vendor: u16, target_device: u16) ?PciDeviceInfo {
    // Builder scans bus 0, slot 0..32, func 0. On match, enables Bit 0 (I/O) & Bit 2 (Bus Master)
    // in Command register (offset 0x04), reads BAR0 (offset 0x10), and returns PciDeviceInfo.
}
```
### 4.3 `src/drivers/virtio_blk.zig`
```zig
const std = @import("std");
const io = @import("../arch/x86_64/io.zig");
const pci = @import("pci.zig");
const serial = @import("serial.zig");
pub const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
pub const VIRTIO_BLK_DEVICE_ID: u16 = 0x1001;
pub const SECTOR_SIZE: usize = 512;
pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;
pub const VIRTIO_BLK_T_IN: u32 = 0;  // Read from disk
pub const VIRTIO_BLK_T_OUT: u32 = 1; // Write to disk
pub const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
    comptime {
        std.debug.assert(@sizeOf(VirtqDesc) == 16);
    }
};
pub const VirtioBlkReqHeader = extern struct {
    req_type: u32,
    reserved: u32 = 0,
    sector: u64,
    comptime {
        std.debug.assert(@sizeOf(VirtioBlkReqHeader) == 16);
    }
};
// Physically contiguous 16 KiB buffer in identity-mapped kernel .bss (supports Queue Size up to 256)
var vring_mem: [16384]u8 align(4096) = [_]u8{0} ** 16384;
var dma_req_hdr: VirtioBlkReqHeader align(64) = .{ .req_type = 0, .sector = 0 };
var dma_sector_buf: [SECTOR_SIZE]u8 align(64) = [_]u8{0} ** SECTOR_SIZE;
var dma_status_byte: u8 align(16) = 0xFF;
var dev_ready: bool = false;
var io_base: u16 = 0;
var queue_size: u16 = 0;
var last_used_idx: u16 = 0;
var total_sectors: u64 = 0;
pub fn init() bool {
    // Builder initializes PCI device, resets VirtIO status, sets QUEUE_PFN, reads capacity, sets DRIVER_OK
}
pub fn isReady() bool {
    return dev_ready;
}
pub fn getCapacityBytes() usize {
    return @as(usize, @intCast(total_sectors)) * SECTOR_SIZE;
}
pub fn rwSector(sector: u64, buf: *[SECTOR_SIZE]u8, is_write: bool) bool {
    // Builder executes 3-descriptor chain (Header -> Data -> Status) synchronous DMA request
}
pub fn readBytes(offset: usize, dst: []u8) usize {
    // Builder reads arbitrary byte range across 512-byte sectors via rwSector(..., false)

}
pub fn writeBytes(offset: usize, src: []const u8) usize {
    // Builder performs read-modify-write or full-sector write across 512-byte sectors via rwSector(..., true)
}
```
---
## 5. Step-by-Step Implementation Logic & State Transitions
1. **Step 1: `src/drivers/pci.zig` Implementation **
   * `findDeviceAndEnableDma(target_vendor, target_device)`:
 1. `0..32` of `slot` ⾛、 `const id_reg = readConfig32(0, @intCast(slot), 0, 0x00);` 。
 2. `const vendor: u16 = @truncate(id_reg);` `0xFFFF` `continue` 。
     3. `const device: u16 = @truncate(id_reg >> 16);`
 4. `vendor == target_vendor and device == target_device` ：
        * `const cmd_stat = readConfig32(0, @intCast(slot), 0, 0x04);`
 * `writeConfig32(0, @intCast(slot), 0, 0x04, cmd_stat | 0x0000_0005);` （ I/O Space + Bus Master enabled）。
        * `const bar0 = readConfig32(0, @intCast(slot), 0, 0x10);`
        * `const irq_reg = readConfig32(0, @intCast(slot), 0, 0x3C);`
        * `return .{ .bus = 0, .slot = @intCast(slot), .func = 0, .vendor_id = vendor, .device_id = device, .io_base
2. **Step 2: `src/drivers/virtio_blk.zig` Implementation **
   * `init() bool`:
     1. `const pci_dev = pci.findDeviceAndEnableDma(VIRTIO_VENDOR_ID, VIRTIO_BLK_DEVICE_ID) orelse return false;`
     2. `io_base = pci_dev.io_base;`
     3. `io.outb(io_base + 0x12, 0x00);` (Reset)
     4. `io.outb(io_base + 0x12, 0x01);` (`ACKNOWLEDGE`)
     5. `io.outb(io_base + 0x12, 0x03);` (`ACKNOWLEDGE | DRIVER`)
 6. `_ = io.inl(io_base + 0x00);` (`HOST_FEATURES`)
     7. `io.outl(io_base + 0x04, 0);` (`GUEST_FEATURES = 0`)
     8. `io.outw(io_base + 0x0E, 0);` (`QUEUE_SEL = 0`)
 9. `queue_size = io.inw(io_base + 0x0C);` (`QUEUE_NUM` 、 `0` `return false`)
     10. `@memset(&vring_mem, 0);`
     11. `const ring_phys = @intFromPtr(&vring_mem);`
 12. `io.outl(io_base + 0x08, @as(u32, @intCast(ring_phys >> 12)));` (`QUEUE_PFN` write)
     13. `const cap_low = io.inl(io_base + 0x14); const cap_high = io.inl(io_base + 0x18);`
     14. `total_sectors = (@as(u64, cap_high) << 32) | @as(u64, cap_low);`
     15. `io.outb(io_base + 0x12, 0x07);` (`ACKNOWLEDGE | DRIVER | DRIVER_OK`)
     16. `dev_ready = true; return true;`
   * `rwSector(sector: u64, buf: *[SECTOR_SIZE]u8, is_write: bool) bool`:
     1. `if (!dev_ready or sector >= total_sectors) return false;`
     2. `const ring_base = @intFromPtr(&vring_mem);`
     3. `const descs = @as([*]volatile VirtqDesc, @ptrFromInt(ring_base));`
     4. `const avail_base = ring_base + (@as(usize, queue_size) * 16);`
     5. `const used_base = std.mem.alignForward(usize, avail_base + 6 + (@as(usize, queue_size) * 2), 4096);`
     6. `dma_req_hdr = .{ .req_type = if (is_write) VIRTIO_BLK_T_OUT else VIRTIO_BLK_T_IN, .reserved = 0, .sector = 
     7. `if (is_write) @memcpy(&dma_sector_buf, buf);`
     8. `dma_status_byte = 0xFF;`
     9. **Descriptor 0 (Header):**
        `descs[0] = .{ .addr = @intFromPtr(&dma_req_hdr), .len = @sizeOf(VirtioBlkReqHeader), .flags = VRING_DESC_F_
     10. **Descriptor 1 (Data):**
         `descs[1] = .{ .addr = @intFromPtr(&dma_sector_buf), .len = SECTOR_SIZE, .flags = VRING_DESC_F_NEXT | (if (
     11. **Descriptor 2 (Status):**
         `descs[2] = .{ .addr = @intFromPtr(&dma_status_byte), .len = 1, .flags = VRING_DESC_F_WRITE, .next = 0 };`
 12. **Available Ring update :**
         * `const avail_idx_ptr = @as(*volatile u16, @ptrFromInt(avail_base + 2));`
         * `const avail_ring = @as([*]volatile u16, @ptrFromInt(avail_base + 4));`
         * `const cur_avail = avail_idx_ptr.*;`
 * `avail_ring[cur_avail % queue_size] = 0;` （firstdisknumber `0` ）
         * `asm volatile ("mfence" ::: "memory");`
         * `avail_idx_ptr.* = cur_avail +% 1;`
         * `asm volatile ("mfence" ::: "memory");`
 13. **QEMU to of notified and ring :**
         * `io.outw(io_base + 0x10, 0);` (`QUEUE_NOTIFY = 0`)
         * `const used_idx_ptr = @as(*volatile u16, @ptrFromInt(used_base + 2));`
         * `while (used_idx_ptr.* == last_used_idx) { asm volatile ("pause"); }`
         * `last_used_idx = used_idx_ptr.*;`
         * `_ = io.inb(io_base + 0x13);` (Clear ISR status)
     14. `if (!is_write) @memcpy(buf, &dma_sector_buf);`
     15. `return (@as(*volatile u8, @ptrFromPtr(&dma_status_byte)).* == 0);`
3. **Step 3: `/dev/vda` and `/proc/partitions` of VFS / Syscall **
   * `src/fs/vfs.zig`:
 * `pub const S_IFBLK: u32 = 0o060000;` 、 `pub const DT_BLK: u8 = 6;` 、 `FdKind.BLKDEV = 8` add。

 * `vfs.init()` with `registerNode("dev/vda", S_IFBLK | 0o660, "")` 、 `vfs.open` with `"dev/vda"`
   * `src/fs/procfs.zig`:
 * `initAndRegister()` （ or `syncProcessNodes()` ） with `"proc/partitions"` `"major minor #blocks name\n 254 
   * `src/syscall/dispatch.zig`:
 * `sysRead` (0) / `sysPread64` (17): `entry.kind ==.BLKDEV` of when、 `virtio_blk.readBytes(offset, slice)` 
 * `sysWrite` (1) / `sysWritev` (20): `entry.kind ==.BLKDEV` of when、 `virtio_blk.writeBytes(entry.offset, slice)
 * `sysLseek` (8): `entry.kind ==.BLKDEV` of when、 `virtio_blk.getCapacityBytes()` and `SEEK_SET
 * `sysFstat` (5): `entry.kind ==.BLKDEV` of when、 `st_mode = vfs.S_IFBLK | 0o660`, `st_rdev = (254 << 8) | 0`, `
 * `sysSync` (162) / `sysFsync` (74) / `sysFdatasync` (75): `0` (Success) 。
4. **Step 4: `scripts/verify_qemu.sh` and `src/main.zig` of update **
 * `src/main.zig` of `kmain()` with `pci` & `virtio_blk.init()` 、 `serial.writeString("[TINUX_BLK]
 * `scripts/verify_qemu.sh` with ：
 1. test⽤ of 1 MiB ⽣disk `/tmp/tinux_disk_${TEST_CASE}.img` create、first（ Sector 0 ） with 
        ```bash
        DISK_IMG="/tmp/tinux_disk_${TEST_CASE}.img"
        dd if=/dev/zero of="$DISK_IMG" bs=1M count=1 status=none
        printf "[TINUX_DISK_SECTOR0] Host-provisioned VirtIO-Block image ready!\n" | dd of="$DISK_IMG" conv=notrunc 
        ```
 2. QEMU add：
        ```bash
        -drive file="$DISK_IMG",format=raw,if=none,id=drv0 \
        -device virtio-blk-pci,drive=drv0,disable-legacy=off
        ```
 3. type（ `/bin/sh` ） to of column （ or `/bin/blk_test` with `/dev/vda` of first⾏ and Sect
 * `/proc/partitions` `cat` with displayed。
 * `/dev/vda` from signature output to displayed、 `"TINUX_PERSISTENCE_VERIFIED_ON_VIRTIO_BLK\n"
 4. QEMU Exit Code `33` with normalexit、 ** of `verify_qemu.sh` with `head -c 64 "$DISK_IMG" | grep -q "
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-015 10
```
### 6.2 Expected Output (Pass Criteria)
QEMU output of output、disk writepersistent `verify_qemu.sh` Exit Co
```text
[TINUX_TEST] START: TASK-015
[TINUX_BLK] VirtIO-Block PCI device (/dev/vda) initialized
[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...
[TINUX_SH] Inspecting /proc/partitions:
major minor  #blocks  name
 254        0       1024 vda
[TINUX_SH] Reading initial sector from /dev/vda:
[TINUX_DISK_SECTOR0] Host-provisioned VirtIO-Block image ready!
[TINUX_SH] Writing persistence marker to /dev/vda...
[TINUX_BLK] Guest-to-Host VirtIO-Block DMA read & write verified!
[TINUX_SYSCALL] sys_exit(0) received from Ring 3
[TINUX_TEST] PASS: TASK-015
[HARNESS] Verifying host-side disk image persistence...
[HARNESS] SUCCESS: TASK-015 verified cleanly!
```
---
## 7. Escalation Report Template (On 3rd Consecutive Failure)
3 timesconsecutive with or `./scripts/verify_qemu.sh TASK-015 10` when、 Builder fixloop stop、 `ESCALATI
```markdown
# Escalation Report: TASK-015
## 1. Failure Summary
* **Failed Stage:** [zig build / PCI Device 1AF4:1001 Not Found / BAR0 Not I/O Port / Virtqueue Used Ring Spin Timeo
* **PCI & VirtIO State Dump:** [io_base, queue_size, total_sectors, avail_idx, used_idx, dma_status_byte of value ]
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
[Relevant code diff for src/drivers/pci.zig, src/drivers/virtio_blk.zig, src/syscall/dispatch.zig ]
```
## 4. Suspected Root Cause (For Argon / Opus 5.5 Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
