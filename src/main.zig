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
pub const CURRENT_TASK: TaskId = .TASK_001;

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
        inline else => |t| runFullKernel(t),
    }
}
