# Tinux Implementation Specification: TASK-015

> **Document Status:** APPROVED FOR BUILDER EXECUTION
> * **Architect (Structure & Harness):** AI System Architect
> * **Auditor (Low-Level & ABI Contract):** AI Code Auditor
> * **Target Builder:** Autonomous AI Builder Agent
> * **Prerequisite:** `TASK-014` Passed (`./scripts/verify_qemu.sh TASK-014 10` == Exit Code 0)
---
## 0. Builder Agent Operating Rules (For Autonomous AI Builder)
You are the **Implementation Builder**. Implement the requirements adhering strictly to these rules:
1. **No Architectural Improvisation:**
   Do not alter PCI I/O port assignments, VirtIO legacy register offsets, `VirtqDesc` layout, or `VirtioBlkReqHeader` structure definitions.
2. **DMA Physical Contiguity & Memory Barrier Discipline:**
   The virtqueue ring buffer (`vring_mem`) and DMA bounce buffers must reside in physically contiguous memory within the kernel's identity-mapped space. Use memory barriers (`mfence`) when updating available and used indices.
3. **Strict Zig Version Idioms:**
   Adhere strictly to modern Zig idioms (0.13+) as defined in Section 1. Do not use deprecated functions like `@ptrToInt` or `@intToPtr`.
4. **3-Strike Escalation Protocol:**
   * If `zig build` or `./scripts/verify_qemu.sh TASK-015 10` fails 3 consecutive times, do not make a 4th speculative guess.
   * Stop immediately after the 3rd failure, generate `ESCALATION_REPORT.md` following Section 7, and halt execution.
---
## 1. Zig Idiom Cheat Sheet (Kernel Freestanding Rules)
Use modern Zig syntax (0.13 / 0.14 / 0.15+) exclusively to prevent compilation errors:
| Operation | Deprecated (Prohibited) | Required (Modern Zig) |
| :--- | :--- | :--- |
| Pointer to integer | `@ptrToInt(ptr)` | `@intFromPtr(ptr)` |
| Integer to pointer | `@intToPtr(*T, addr)` | `@as(*T, @ptrFromInt(addr))` |
| Memory fence | Compiler barrier only | `asm volatile ("mfence" ::: "memory");` |
| Volatile 16-bit access | Non-volatile dereference | `@as(*volatile u16, @ptrFromInt(addr)).*` |
| Page frame number (PFN) | `phys_addr / 4096` | `@as(u32, @intCast(phys_addr >> 12))` |
---
## 2. Task Metadata & Scope
* **Task ID:** `TASK-015`
* **Title:** `PCI Bus Enumeration, VirtIO-Block Driver (DMA Virtqueue), /dev/vda Block Device Integration, and Host Persistence Verification`
* **Target Subsystem:** `arch/x86_64`, `drivers`, `fs`, `syscall`
* **Target Files to Create / Modify:**
  * `src/arch/x86_64/io.zig` (Modify: add 16-bit `inw`/`outw` and 32-bit `inl`/`outl` port I/O helpers)
  * `src/drivers/pci.zig` (Create: PCI Configuration Mechanism #1 scanner and Bus Master enabler)
  * `src/drivers/virtio_blk.zig` (Create: VirtIO-Block PCI driver, Virtqueue setup, and synchronous sector read/write)
  * `src/fs/vfs.zig` (Modify: add `S_IFBLK = 0o060000`, `DT_BLK = 6`, `FdKind.BLKDEV = 8`, and register `/dev/vda`)
  * `src/fs/procfs.zig` (Modify: register `/proc/partitions` showing `vda` capacity)
  * `src/syscall/dispatch.zig` (Modify: support `.BLKDEV` in `sysRead`, `sysWrite`, `sysPread64`, `sysLseek`, `sysFstat`)
  * `src/main.zig` (Modify: initialize `virtio_blk.init()` and update test markers to `TASK-015`)
  * `scripts/verify_qemu.sh` (Modify: create 1 MiB raw disk image, attach via `-device virtio-blk-pci`, and verify persistence)
---
## 3. PCI & VirtIO-Block Hardware Contract (AI Audited)
### 3.1 PCI Configuration Space (Mechanism #1) Contract
On x86_64 PC hardware, I/O ports `0x0CF8` (`CONFIG_ADDRESS`) and `0x0CFC` (`CONFIG_DATA`) control PCI configuration space access:
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
   * In Command Register (Offset `0x04`), set Bit 0 (`0x01`: I/O Space Enable) and Bit 2 (`0x04`: Bus Master Enable).
   * In `BAR0` (Offset `0x10`), extract I/O port base: `io_base: u16 = @truncate(bar0 & ~@as(u32, 0x3))`.
### 3.2 VirtIO Legacy PCI Register & Virtqueue Contract
Access device registers at specified offsets from `io_base`:
| Offset | Width | Name | Initialization & Runtime Sequence |
| :--- | :--- | :--- | :--- |
| `+0x00` | `u32` (R) | `HOST_FEATURES` | Read features supported by host device. |
| `+0x04` | `u32` (W) | `GUEST_FEATURES` | Write accepted features. For basic sector I/O, write 0. |
| `+0x08` | `u32` (RW)| `QUEUE_PFN` | Write page frame number of virtqueue ring (`ring_phys >> 12`). |
| `+0x0C` | `u16` (R) | `QUEUE_NUM` | Read queue size `Q` reported by device (typically 128 or 256 in QEMU). |
| `+0x0E` | `u16` (RW)| `QUEUE_SEL` | Select queue index (write 0 for primary request queue). |
| `+0x10` | `u16` (W) | `QUEUE_NOTIFY` | Write queue index (0) to signal new available descriptors to host. |
| `+0x12` | `u8` (RW) | `DEVICE_STATUS` | State sequence: 0x00 (Reset) -> 0x01 (ACK) -> 0x03 (ACK\|DRIVER) -> 0x07 (ACK\|DRIVER\|DRIVER_OK). |
| `+0x14` | `u64` (R) | `CAPACITY` | 64-bit disk capacity in 512-byte sectors (`+0x14` low, `+0x18` high). |
#### Virtqueue Legacy Memory Layout (for Queue Size `Q`):
Allocate physically contiguous 16 KiB buffer `vring_mem` aligned to 4096 bytes:
1. **Descriptor Table (`VirtqDesc[Q]`):** Offset 0 (`16 * Q` bytes).
2. **Available Ring (`VirtqAvail`):** Offset `16 * Q` (`6 + 2 * Q` bytes).
   * `flags: u16` (offset `+0`), `idx: u16` (offset `+2`), `ring: [Q]u16` (offset `+4`).
3. **Used Ring (`VirtqUsed`):** Offset `std.mem.alignForward(usize, 16 * Q + 6 + 2 * Q, 4096)` (4096-byte aligned).
   * `flags: u16` (offset `+0`), `idx: u16` (offset `+2`), `ring: [Q]VirtqUsedElem` (offset `+4`, 8 bytes each: `id: u32, len: u32`).
---
## 4. Exact Data Structures & Signatures
### 4.1 `src/arch/x86_64/io.zig` Additions
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
    // Builder scans bus 0, slot 0..32, func 0. On match, enables Bit 0 (I/O) and Bit 2 (Bus Master)
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
1. **Step 1: Implement `src/drivers/pci.zig`:**
   * In `findDeviceAndEnableDma(target_vendor, target_device)`:
     1. Iterate slots `0..31`: read vendor and device ID from `CONFIG_DATA` at offset 0.
     2. If vendor equals `0xFFFF`, skip slot.
     3. On match (`vendor == target_vendor` and `device == target_device`):
        * Read Command register at offset `0x04` and write `cmd | 0x0000_0005` (enable I/O space and bus mastering).
        * Read `BAR0` at offset `0x10` and mask lower 2 bits to obtain `io_base`.
        * Read IRQ line from offset `0x3C`.
        * Return `PciDeviceInfo{ .bus = 0, .slot = @intCast(slot), .func = 0, .vendor_id = vendor, .device_id = device, .io_base = io_base, .irq_line = irq_line }`.
2. **Step 2: Implement `src/drivers/virtio_blk.zig`:**
   * In `init() bool`:
     1. Locate PCI block device via `pci.findDeviceAndEnableDma(VIRTIO_VENDOR_ID, VIRTIO_BLK_DEVICE_ID)`. If not found, return false.
     2. Save `io_base`.
     3. Device status sequence: write `0x00` (Reset), `0x01` (`ACKNOWLEDGE`), `0x03` (`ACKNOWLEDGE | DRIVER`).
     4. Read `HOST_FEATURES` and write 0 to `GUEST_FEATURES`.
     5. Select queue 0 (`outw(io_base + 0x0E, 0)`) and read `QUEUE_NUM` (`inw(io_base + 0x0C)`).
     6. Zero `vring_mem` buffer and calculate physical address `ring_phys = @intFromPtr(&vring_mem)`.
     7. Write page frame number to `QUEUE_PFN` (`outl(io_base + 0x08, ring_phys >> 12)`).
     8. Read disk capacity from `CAPACITY` registers at `+0x14` and `+0x18`.
     9. Set status to `0x07` (`ACKNOWLEDGE | DRIVER | DRIVER_OK`).
     10. Set `dev_ready = true` and return true.
   * In `rwSector(sector: u64, buf: *[SECTOR_SIZE]u8, is_write: bool) bool`:
     1. Verify `dev_ready` and `sector < total_sectors`.
     2. Build 3-descriptor chain:
        * Descriptor 0: `VirtioBlkReqHeader` (type `VIRTIO_BLK_T_OUT` for write, `VIRTIO_BLK_T_IN` for read, sector number), flags `VRING_DESC_F_NEXT`, next 1.
        * Descriptor 1: Sector data buffer, flags `VRING_DESC_F_NEXT` | (`VRING_DESC_F_WRITE` if read), next 2.
        * Descriptor 2: 1-byte status field, flags `VRING_DESC_F_WRITE`, next 0.
     3. Insert head index (0) into available ring, apply memory barrier, and increment available index.
     4. Notify host: `outw(io_base + 0x10, 0)`.
     5. Spin wait on used ring update: wait until `used_idx.* != last_used_idx`.
     6. Read interrupt status register to acknowledge.
     7. If reading, copy sector buffer to user buffer. Return true if status byte is 0.
3. **Step 3: Integrate `/dev/vda` and `/proc/partitions` in VFS and Syscalls:**
   * In `src/fs/vfs.zig`:
     * Define `S_IFBLK: u32 = 0o060000`, `DT_BLK: u8 = 6`, and `FdKind.BLKDEV = 8`.
     * Register node `"dev/vda"` with mode `S_IFBLK | 0o660`.
   * In `src/fs/procfs.zig`:
     * Register `"proc/partitions"` displaying major 254, minor 0, block count, and name `vda`.
   * In `src/syscall/dispatch.zig`:
     * In `sysRead` and `sysPread64`, dispatch `.BLKDEV` to `virtio_blk.readBytes()`.
     * In `sysWrite` and `sysWritev`, dispatch `.BLKDEV` to `virtio_blk.writeBytes()`.
     * In `sysLseek`, support `SEEK_SET`, `SEEK_CUR`, and `SEEK_END` bounded by device capacity.
     * In `sysFstat`, populate block device properties: `st_mode = S_IFBLK | 0o660`, `st_rdev = (254 << 8) | 0`.
     * In `sysSync`, return 0.
4. **Step 4: Update `src/main.zig` and `scripts/verify_qemu.sh`:**
   * In `src/main.zig`, initialize driver during boot: `_ = virtio_blk.init();`.
   * In `scripts/verify_qemu.sh`, provision raw disk image `/tmp/tinux_disk_${TEST_CASE}.img` with seed sector, attach via QEMU `-drive` and `-device virtio-blk-pci`, and verify guest read and write persistence.
---
## 6. Verification Harness & Pass Criteria
### 6.1 Verification Command
```bash
./scripts/verify_qemu.sh TASK-015 10
```
### 6.2 Expected Output (Pass Criteria)
Verify that all expected serial logs are emitted and `verify_qemu.sh` exits with code `0`:
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
If `zig build` or `./scripts/verify_qemu.sh TASK-015 10` fails 3 consecutive times, stop execution and generate `ESCALATION_REPORT.md`:
```markdown
# Escalation Report: TASK-015
## 1. Failure Summary
* **Failed Stage:** [zig build / PCI Device 1AF4:1001 Not Found / BAR0 Not I/O Port / Virtqueue Used Ring Spin Timeout / Persistence Mismatch]
* **PCI & VirtIO State Dump:** [io_base, queue_size, total_sectors, avail_idx, used_idx, dma_status_byte values]
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
[Relevant code diff for src/drivers/pci.zig, src/drivers/virtio_blk.zig, src/syscall/dispatch.zig]
```
## 4. Suspected Root Cause (For AI Architect / Auditor Review)
* [Hypothesis on root cause from Builder perspective (1-3 lines)]
```
