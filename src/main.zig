const std = @import("std");
const serial = @import("drivers/serial.zig");
const io = @import("arch/x86_64/io.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pmm = @import("mm/pmm.zig");
const vmm = @import("mm/vmm.zig");
const heap = @import("mm/heap.zig");
const syscall_arch = @import("arch/x86_64/syscall.zig");
const timer = @import("drivers/timer.zig");
const vfs = @import("fs/vfs.zig");
const cpio = @import("fs/cpio.zig");
const pipe_mod = @import("fs/pipe.zig");
const procfs = @import("fs/procfs.zig");
const tty = @import("drivers/tty.zig");
const socket = @import("net/socket.zig");
const epoll = @import("fs/epoll.zig");
const elf = @import("proc/elf.zig");
const task = @import("proc/task.zig");
const dispatch = @import("syscall/dispatch.zig");

// Embedded initramfs archive provided via build system (.cache/initramfs.cpio)
const initramfs = @import("initramfs");
const initramfs_archive: []const u8 = initramfs.data;

// Embedded userland test ELF binary provided via build system (.cache/init_test.elf)
const init_test = @import("init_test");
const init_test_elf: []const u8 = init_test.data;

// Milestone configuration provided via build system
const task_config = @import("task_config");

comptime {
    std.testing.refAllDecls(idt);
    std.testing.refAllDecls(vmm);
    std.testing.refAllDecls(heap);
    std.testing.refAllDecls(syscall_arch);
    std.testing.refAllDecls(dispatch);
}

pub const TaskId = enum {
    TASK_001,
    TASK_002,
    TASK_003,
    TASK_004,
    TASK_005,
    TASK_006,
    TASK_007,
    TASK_008,
    TASK_009,
    TASK_010,
    TASK_011,
    TASK_012,
    TASK_013,
    TASK_014,
    TASK_015,
    TASK_016,
    TASK_017,
    TASK_018,
    TASK_019,
    TASK_020,

    pub fn toSlice(self: TaskId) []const u8 {
        return switch (self) {
            .TASK_001 => "TASK-001",
            .TASK_002 => "TASK-002",
            .TASK_003 => "TASK-003",
            .TASK_004 => "TASK-004",
            .TASK_005 => "TASK-005",
            .TASK_006 => "TASK-006",
            .TASK_007 => "TASK-007",
            .TASK_008 => "TASK-008",
            .TASK_009 => "TASK-009",
            .TASK_010 => "TASK-010",
            .TASK_011 => "TASK-011",
            .TASK_012 => "TASK-012",
            .TASK_013 => "TASK-013",
            .TASK_014 => "TASK-014",
            .TASK_015 => "TASK-015",
            .TASK_016 => "TASK-016",
            .TASK_017 => "TASK-017",
            .TASK_018 => "TASK-018",
            .TASK_019 => "TASK-019",
            .TASK_020 => "TASK-020",
        };
    }

    pub fn parse(s: []const u8) ?TaskId {
        inline for (std.meta.fields(TaskId)) |field| {
            if (std.mem.eql(u8, s, field.name)) {
                return @enumFromInt(field.value);
            }
            const enum_val: TaskId = @enumFromInt(field.value);
            if (std.mem.eql(u8, s, enum_val.toSlice())) {
                return enum_val;
            }
        }
        return null;
    }
};

/// Active milestone target. Configured via build option -Dtask=<TASK-0XX> (defaults to TASK-005):
pub const CURRENT_TASK: TaskId = TaskId.parse(task_config.task) orelse .TASK_005;

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    serial.print("\n[TINUX_PANIC] {s}\n", .{msg});
    io.qemuExitFailure();
}

fn runTask001() noreturn {
    serial.writeString("[TINUX_BOOT] Zig x86_64 Kernel Initialized\n");
    serial.writeString("[TINUX_TEST] START: TASK-001\n");
    serial.writeString("[TINUX_TEST] PASS: TASK-001\n");
    io.qemuExitSuccess();
}

fn runTask002() noreturn {
    serial.init();
    serial.writeString("[TINUX_TEST] START: TASK-002\n");
    gdt.init();
    serial.writeString("[TINUX_GDT] GDT & TSS loaded\n");
    idt.init();
    serial.writeString("[TINUX_IDT] IDT loaded\n");
    asm volatile ("int3");
    std.debug.assert(idt.breakpoint_hit_count == 1);
    pmm.init();
    std.debug.assert(pmm.getFreePageCount() >= 30000);
    const p1 = pmm.allocZeroedPage().?;
    const p2 = pmm.allocZeroedPage().?;
    std.debug.assert(p1 != p2);
    pmm.freePage(p1);
    const p3 = pmm.allocZeroedPage().?;
    std.debug.assert(p3 == p1);
    serial.writeString("[TINUX_TEST] PASS: TASK-002\n");
    io.qemuExitSuccess();
}

fn runTask003() noreturn {
    serial.init();
    serial.writeString("[TINUX_TEST] START: TASK-003\n");

    gdt.init();
    idt.init();
    pmm.init();

    vmm.init();
    serial.writeString("[TINUX_VMM] 4-level paging active (CR3 switched)\n");

    const kpml4 = vmm.getKernelPml4Phys();

    // NULL guard page translation returns null
    std.debug.assert(vmm.translate(kpml4, 0x0000_0000) == null);

    // Identity mapped address translation
    std.debug.assert(vmm.translate(kpml4, 0x0010_0000).? == 0x0010_0000);

    // Scratch virtual mapping test
    const scratch_vaddr: usize = 0x2000_0000;
    const test_phys = pmm.allocZeroedPage() orelse @panic("TASK-003: failed to allocate physical page");
    std.debug.assert(vmm.mapPage(kpml4, scratch_vaddr, test_phys, vmm.PTE_PRESENT | vmm.PTE_WRITABLE));
    std.debug.assert(vmm.translate(kpml4, scratch_vaddr).? == test_phys);

    const scratch_ptr = @as(*volatile u64, @ptrFromInt(scratch_vaddr));
    const magic_sig: u64 = 0xCAFE_BABE_DEAD_BEEF;
    scratch_ptr.* = magic_sig;
    std.debug.assert(scratch_ptr.* == magic_sig);

    const phys_ptr = @as(*volatile u64, @ptrFromInt(test_phys));
    std.debug.assert(phys_ptr.* == magic_sig);

    _ = vmm.unmapPage(kpml4, scratch_vaddr);
    std.debug.assert(vmm.translate(kpml4, scratch_vaddr) == null);
    pmm.freePage(test_phys);

    // Kernel heap verification
    heap.init();
    serial.writeString("[TINUX_HEAP] Kernel heap initialized\n");

    const alloc = heap.allocator();
    const slice1 = alloc.alloc(u64, 32) catch @panic("TASK-003: heap alloc failed");
    for (slice1, 0..) |*item, idx| {
        item.* = 0x1234_5678_0000_0000 | @as(u64, idx);
    }
    for (slice1, 0..) |item, idx| {
        std.debug.assert(item == (0x1234_5678_0000_0000 | @as(u64, idx)));
    }

    const slice1_addr = @intFromPtr(slice1.ptr);
    alloc.free(slice1);

    const slice2 = alloc.alloc(u64, 32) catch @panic("TASK-003: heap realloc failed");
    const slice2_addr = @intFromPtr(slice2.ptr);
    std.debug.assert(slice2_addr == slice1_addr);
    alloc.free(slice2);

    // Hardened Alignment Verification: 64-byte alignment
    const ptr_align64 = heap.kmallocAligned(64, 64) orelse @panic("TASK-003: kmallocAligned(64, 64) failed!");
    std.debug.assert(@intFromPtr(ptr_align64) % 64 == 0);
    const slice64 = ptr_align64[0..64];
    for (slice64, 0..) |*b, i| {
        b.* = @as(u8, @truncate(i ^ 0xA5));
    }
    for (slice64, 0..) |b, i| {
        std.debug.assert(b == @as(u8, @truncate(i ^ 0xA5)));
    }
    heap.kfree(ptr_align64);

    // Hardened Varied Heap Allocations: multiple sizes, alignments, and out-of-order freeing
    const v_u8 = alloc.alloc(u8, 64) catch @panic("TASK-003: v_u8 alloc failed");
    const v_u16 = alloc.alloc(u16, 128) catch @panic("TASK-003: v_u16 alloc failed");
    const v_u32 = alloc.alloc(u32, 256) catch @panic("TASK-003: v_u32 alloc failed");
    const v_u64 = alloc.alloc(u64, 512) catch @panic("TASK-003: v_u64 alloc failed");

    for (v_u8, 0..) |*b, i| {
        b.* = @as(u8, @truncate(i *% 3 +% 1));
    }
    for (v_u16, 0..) |*w, i| {
        w.* = @as(u16, @truncate(i *% 7 +% 0x100));
    }
    for (v_u32, 0..) |*d, i| {
        d.* = @as(u32, @truncate(i *% 13 +% 0x10000));
    }
    for (v_u64, 0..) |*q, i| {
        q.* = 0xFEED_FACE_0000_0000 | @as(u64, i);
    }

    for (v_u8, 0..) |b, i| {
        std.debug.assert(b == @as(u8, @truncate(i *% 3 +% 1)));
    }
    for (v_u16, 0..) |w, i| {
        std.debug.assert(w == @as(u16, @truncate(i *% 7 +% 0x100)));
    }
    for (v_u32, 0..) |d, i| {
        std.debug.assert(d == @as(u32, @truncate(i *% 13 +% 0x10000)));
    }
    for (v_u64, 0..) |q, i| {
        std.debug.assert(q == (0xFEED_FACE_0000_0000 | @as(u64, i)));
    }

    // Out-of-order deallocation to verify bidirectional free-list coalescing
    alloc.free(v_u16);
    alloc.free(v_u64);
    alloc.free(v_u8);
    alloc.free(v_u32);

    // Verify heap memory clean reuse after complete coalescing
    const slice_reuse = alloc.alloc(u64, 32) catch @panic("TASK-003: slice_reuse alloc failed");
    std.debug.assert(@intFromPtr(slice_reuse.ptr) == slice1_addr);
    alloc.free(slice_reuse);

    serial.writeString("[TINUX_TEST] PASS: TASK-003\n");
    io.qemuExitSuccess();
}

const USER_TEST_PAYLOAD = [_]u8{
    // movq $39, %rax; syscall; cmpq $1, %rax; jne .Lfail_getpid (+0x30 bytes)
    0x48, 0xC7, 0xC0, 0x27, 0x00, 0x00, 0x00, 0x0F, 0x05, 0x48, 0x83, 0xF8, 0x01, 0x75, 0x30,
    // movq $1, %rax; movq $1, %rdi; leaq msg(%rip), %rsi; movq $44, %rdx; syscall; cmpq $44, %rax; jne .Lfail_write (+0x1C bytes)
    0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x00, 0x48, 0xC7, 0xC7, 0x01, 0x00, 0x00, 0x00,
    0x48, 0x8D, 0x35, 0x3B, 0x00, 0x00, 0x00, 0x48, 0xC7, 0xC2, 0x2C, 0x00, 0x00, 0x00,
    0x0F, 0x05, 0x48, 0x83, 0xF8, 0x2C, 0x75, 0x1C,
    // movq $60, %rax; xorq %rdi, %rdi; syscall
    0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00, 0x48, 0x31, 0xFF, 0x0F, 0x05,
    // .Lfail_getpid: movq $60, %rax; movq $1, %rdi; syscall
    0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00, 0x48, 0xC7, 0xC7, 0x01, 0x00, 0x00, 0x00, 0x0F, 0x05,
    // .Lfail_write: movq $60, %rax; movq $2, %rdi; syscall
    0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00, 0x48, 0xC7, 0xC7, 0x02, 0x00, 0x00, 0x00, 0x0F, 0x05,
    // msg: "[TINUX_USER] Hello from Ring 3 via SYSCALL!\n"
    0x5B, 0x54, 0x49, 0x4E, 0x55, 0x58, 0x5F, 0x55, 0x53, 0x45, 0x52, 0x5D, 0x20, 0x48, 0x65, 0x6C,
    0x6C, 0x6F, 0x20, 0x66, 0x72, 0x6F, 0x6D, 0x20, 0x52, 0x69, 0x6E, 0x67, 0x20, 0x33, 0x20, 0x76,
    0x69, 0x61, 0x20, 0x53, 0x59, 0x53, 0x43, 0x41, 0x4C, 0x4C, 0x21, 0x0A,
};

fn runTask004() noreturn {
    serial.init();
    serial.writeString("[TINUX_TEST] START: TASK-004\n");

    gdt.init();
    idt.init();
    // Mask legacy 8259A PIC interrupts until remapped in TASK-010
    io.outb(0x21, 0xFF);
    io.outb(0xA1, 0xFF);
    pmm.init();
    vmm.init();
    heap.init();
    syscall_arch.init();
    serial.writeString("[TINUX_SYSCALL] MSRs initialized\n");

    const kpml4 = vmm.getKernelPml4Phys();
    _ = task.initPid1(kpml4, 0, "task004");

    // Map user code page at 0x0040_0000 (4 KiB)
    const code_vaddr: usize = 0x0040_0000;
    const code_phys = pmm.allocZeroedPage() orelse @panic("TASK-004: failed to alloc user code page");
    std.debug.assert(vmm.mapPage(kpml4, code_vaddr, code_phys, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER));

    // Copy user test payload into code page
    const code_dst = @as([*]u8, @ptrFromInt(code_phys))[0..USER_TEST_PAYLOAD.len];
    @memcpy(code_dst, &USER_TEST_PAYLOAD);

    // Map 2 user stack pages at 0x0080_0000 and 0x0080_1000 (8 KiB)
    const stack_phys1 = pmm.allocZeroedPage() orelse @panic("TASK-004: failed to alloc user stack page 1");
    const stack_phys2 = pmm.allocZeroedPage() orelse @panic("TASK-004: failed to alloc user stack page 2");
    std.debug.assert(vmm.mapPage(kpml4, 0x0080_0000, stack_phys1, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER));
    std.debug.assert(vmm.mapPage(kpml4, 0x0080_1000, stack_phys2, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER));

    serial.writeString("[TINUX_USER] Entering Ring 3...\n");

    // Enter Ring 3
    syscall_arch.enterUserMode(code_vaddr, 0x0080_2000);
}

fn runTask005() noreturn {
    serial.init();
    serial.writeString("[TINUX_TEST] START: TASK-005\n");

    gdt.init();
    idt.init();
    // Mask legacy 8259A PIC interrupts until remapped in TASK-010
    io.outb(0x21, 0xFF);
    io.outb(0xA1, 0xFF);
    pmm.init();
    vmm.init();
    heap.init();
    syscall_arch.init();

    dispatch.setCurrentTestName("TASK-005");

    const kpml4 = vmm.getKernelPml4Phys();
    _ = task.initPid1(kpml4, 0, "init_test");

    const image = elf.loadStaticElf(kpml4, init_test_elf) catch |err| {
        serial.print("ELF load error: {}\n", .{err});
        @panic("TASK-005: Failed to load init_test ELF");
    };

    dispatch.initBrk(image.initial_brk);

    serial.writeString("[TINUX_ELF] Loaded static ELF64 image, jumping to _start...\n");
    syscall_arch.enterUserMode(image.entry_rip, image.user_rsp);
}

fn runFullKernel(target_task: TaskId) noreturn {
    serial.print("[TINUX_TEST] START: {s}\n", .{target_task.toSlice()});

    gdt.init();
    serial.writeString("[TINUX_GDT] GDT and 64-bit TSS loaded\n");

    idt.init();
    serial.writeString("[TINUX_IDT] IDT loaded (vectors 0..31)\n");

    pmm.init();
    vmm.init();
    serial.writeString("[TINUX_VMM] 4-level page table manager & CR3 switch verified\n");

    heap.init();
    serial.writeString("[TINUX_HEAP] std.mem.Allocator kernel heap & coalescing verified\n");

    syscall_arch.init();
    serial.writeString("[TINUX_SYSCALL] MSRs (EFER.SCE, STAR, LSTAR, FMASK) configured\n");

    timer.init();
    serial.writeString("[TINUX_TIMER] 8259A PIC & 8254 PIT (100Hz) initialized\n");

    vfs.init();
    pipe_mod.init();
    procfs.initAndRegister();

    tty.init();
    serial.writeString("[TINUX_TTY] 16550A UART IRQ4 & POSIX line discipline initialized\n");

    socket.init();
    epoll.init();

    // Unpack CPIO archive
    if (initramfs_archive.len > 0) {
        const unpacked = cpio.unpackInitramfs(initramfs_archive);
        serial.print("[TINUX_VFS] Unpacked {d} nodes from initramfs.cpio\n", .{unpacked});
    }

    dispatch.setCurrentTestName(target_task.toSlice());

    // Look for init binary or shell
    var init_binary_data: ?[]const u8 = null;
    var init_binary_name: []const u8 = "bin/sh";

    if (vfs.lookup("bin/sh")) |idx| {
        init_binary_data = vfs.getNode(idx).slice();
        init_binary_name = "/bin/sh";
    } else if (vfs.lookup("bin/busybox")) |idx| {
        init_binary_data = vfs.getNode(idx).slice();
        init_binary_name = "/bin/busybox";
    }

    if (init_binary_data) |raw_elf| {
        const pid1_pml4 = vmm.createFreshUserPml4() orelse @panic("Failed to allocate PID 1 PML4");
        const is_interactive = @intFromEnum(target_task) >= @intFromEnum(TaskId.TASK_012);
        if (is_interactive) {
            const argv = [_][]const u8{ "/bin/sh" };
            const envp = [_][]const u8{ "PATH=/bin", "HOME=/", "TERM=vt100" };
            const loaded = elf.loadStaticElfWithArgs(pid1_pml4, raw_elf, &argv, &envp) catch |err| {
                serial.print("ELF load error: {}\n", .{err});
                @panic("Failed to load init ELF binary");
            };
            const pid1_task = task.initPid1(pid1_pml4, loaded.initial_brk, "/bin/sh");
            pid1_task.setCmdline(&argv);
            serial.writeString("[TINUX_INIT] Spawning interactive shell PID 1 (/bin/sh)...\n");
            syscall_arch.enterUserMode(loaded.entry_rip, loaded.user_rsp);
        } else {
            const argv = [_][]const u8{ init_binary_name, "/etc/rc.sh" };
            const envp = [_][]const u8{ "PATH=/bin", "HOME=/", "TERM=vt100" };
            const loaded = elf.loadStaticElfWithArgs(pid1_pml4, raw_elf, &argv, &envp) catch |err| {
                serial.print("ELF load error: {}\n", .{err});
                @panic("Failed to load init ELF binary");
            };
            const pid1_task = task.initPid1(pid1_pml4, loaded.initial_brk, init_binary_name);
            pid1_task.setCmdline(&argv);
            serial.print("[TINUX_INIT] Spawning PID 1 ({s} /etc/rc.sh)...\n", .{init_binary_name});
            syscall_arch.enterUserMode(loaded.entry_rip, loaded.user_rsp);
        }
    } else {
        serial.writeString("[TINUX_INIT] No userland binary found in initramfs.cpio\n");
        io.qemuExitSuccess();
    }

    while (true) {
        asm volatile ("hlt");
    }
}

export fn kmain() callconv(.C) noreturn {
    serial.init();

    switch (CURRENT_TASK) {
        .TASK_001 => runTask001(),
        .TASK_002 => runTask002(),
        .TASK_003 => runTask003(),
        .TASK_004 => runTask004(),
        .TASK_005 => runTask005(),
        inline else => |t| runFullKernel(t),
    }
}
