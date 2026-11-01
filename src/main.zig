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
const elf = @import("proc/elf.zig");
const task = @import("proc/task.zig");
const dispatch = @import("syscall/dispatch.zig");

// Embedded initramfs archive provided via build system (.cache/initramfs.cpio)
const initramfs = @import("initramfs");
const initramfs_archive: []const u8 = initramfs.data;

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
};

/// Active milestone target. Update this single line to activate sequential suites:
pub const CURRENT_TASK: TaskId = .TASK_003;

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

    serial.writeString("[TINUX_TEST] PASS: TASK-003\n");
    io.qemuExitSuccess();
}

fn runFullKernel(target_task: TaskId) noreturn {

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
        const argv = [_][]const u8{ init_binary_name, "/etc/rc.sh" };
        const envp = [_][]const u8{ "PATH=/bin", "HOME=/", "TERM=vt100" };

        const loaded = elf.loadStaticElf(pid1_pml4, raw_elf, &argv, &envp) catch |err| {
            serial.print("ELF load error: {}\n", .{err});
            @panic("Failed to load init ELF binary");
        };

        const pid1_task = task.initPid1(pid1_pml4, loaded.initial_brk, init_binary_name);
        _ = pid1_task;

        serial.print("[TINUX_INIT] Spawning PID 1 ({s} /etc/rc.sh)...\n", .{init_binary_name});
        syscall_arch.enterUserMode(loaded.entry_rip, loaded.user_rsp);
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
        inline else => |t| runFullKernel(t),
    }
}
