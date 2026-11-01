const std = @import("std");
const vfs = @import("vfs.zig");
const pmm = @import("../mm/pmm.zig");
const task = @import("../proc/task.zig");
const timer = @import("../drivers/timer.zig");
const profiler = @import("../syscall/profiler.zig");

var meminfo_buf: [256]u8 = undefined;
var uptime_buf: [64]u8 = undefined;
var proc_stat_bufs: [task.MAX_TASKS][256]u8 = undefined;
var proc_status_bufs: [task.MAX_TASKS][256]u8 = undefined;
var proc_cmdline_bufs: [task.MAX_TASKS][64]u8 = undefined;
var net_tcp_buf: [1024]u8 = undefined;
var syscalls_buf: [4096]u8 = undefined;
var strace_buf: [256]u8 = undefined;

pub fn initAndRegister() void {
    _ = vfs.registerNode("proc", vfs.S_IFDIR | 0o555, "");
    _ = vfs.registerNode(
        "proc/version",
        vfs.S_IFREG | 0o444,
        "Linux version 6.6.0-tinux (zig@tinux) #1 SMP PREEMPT Tinux 2026\n",
    );
    _ = vfs.registerNode(
        "proc/cpuinfo",
        vfs.S_IFREG | 0o444,
        "processor\t: 0\nvendor_id\t: TinuxZig\nmodel name\t: Tinux x86_64 Virtual CPU\ncpu MHz\t\t: 3000.000\n",
    );
    _ = vfs.registerNode(
        "proc/uptime",
        vfs.S_IFREG | 0o444,
        "12.34 12.00\n",
    );
    _ = vfs.registerNode(
        "proc/mounts",
        vfs.S_IFREG | 0o444,
        "rootfs / rootfs rw 0 0\nproc /proc proc rw 0 0\n",
    );
    _ = vfs.registerNode(
        "proc/cmdline",
        vfs.S_IFREG | 0o444,
        "console=ttyS0 root=/dev/ram0 rw\n",
    );
    _ = vfs.registerNode(
        "proc/stat",
        vfs.S_IFREG | 0o444,
        "cpu  100 0 100 1000 0 0 0 0 0 0\ncpu0 100 0 100 1000 0 0 0 0 0 0\n",
    );

    refreshDynamicNodes();
}

pub fn refreshDynamicNodes() void {
    const total_kb = pmm.TOTAL_RAM_BYTES / 1024;
    const free_kb = pmm.getFreePageCount() * 4;
    const meminfo_slice = std.fmt.bufPrint(
        &meminfo_buf,
        "MemTotal:         {d} kB\nMemFree:          {d} kB\nMemAvailable:     {d} kB\n",
        .{ total_kb, free_kb, free_kb },
    ) catch "MemTotal: 131072 kB\n";
    _ = vfs.registerNode("proc/meminfo", vfs.S_IFREG | 0o444, meminfo_slice);

    const current_ticks = timer.getTicks();
    const sec = current_ticks / timer.HZ;
    const centi = (current_ticks % timer.HZ);
    const uptime_slice = std.fmt.bufPrint(&uptime_buf, "{d}.{d:0>2} {d}.{d:0>2}\n", .{ sec, centi, sec, centi }) catch "0.00 0.00\n";
    _ = vfs.registerNode("proc/uptime", vfs.S_IFREG | 0o444, uptime_slice);

    // /proc/syscalls for profiler
    const sys_report = profiler.generateProcReport(&syscalls_buf);
    _ = vfs.registerNode("proc/syscalls", vfs.S_IFREG | 0o444, sys_report);

    // /proc/strace status
    const strace_slice = std.fmt.bufPrint(&strace_buf, "enabled: 1\n", .{}) catch "enabled: 1\n";
    _ = vfs.registerNode("proc/strace", vfs.S_IFREG | 0o444, strace_slice);

    syncProcessNodes();
}

pub fn syncProcessNodes() void {
    // Traverse active tasks and update /proc/[pid]/...
    for (&task.tasks, 0..) |*t, idx| {
        if (t.state != .UNUSED and t.pid > 0) {
            var dir_path_buf: [32]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_path_buf, "proc/{d}", .{t.pid}) catch continue;
            _ = vfs.registerNode(dir_path, vfs.S_IFDIR | 0o555, "");

            const state_char: u8 = switch (t.state) {
                .RUNNING, .READY => 'R',
                .ZOMBIE => 'Z',
                else => 'S',
            };

            // 1. /proc/[pid]/stat
            var stat_path_buf: [32]u8 = undefined;
            const stat_path = std.fmt.bufPrint(&stat_path_buf, "proc/{d}/stat", .{t.pid}) catch continue;
            const stat_content = std.fmt.bufPrint(
                &proc_stat_bufs[idx],
                "{d} ({s}) {c} {d} {d} 1 0 -1 4194304 0 0 0 0 1 1 0 0 20 0 1 0 1 4194304 128 18446744073709551615 4194304 4200000 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n",
                .{ t.pid, t.comm(), state_char, t.parent_pid, t.pgid },
            ) catch "";
            _ = vfs.registerNode(stat_path, vfs.S_IFREG | 0o444, stat_content);

            // 2. /proc/[pid]/status
            var status_path_buf: [32]u8 = undefined;
            const status_path = std.fmt.bufPrint(&status_path_buf, "proc/{d}/status", .{t.pid}) catch continue;
            const status_content = std.fmt.bufPrint(
                &proc_status_bufs[idx],
                "Name:\t{s}\nState:\t{c}\nPid:\t{d}\nPPid:\t{d}\n",
                .{ t.comm(), state_char, t.pid, t.parent_pid },
            ) catch "";
            _ = vfs.registerNode(status_path, vfs.S_IFREG | 0o444, status_content);

            // 3. /proc/[pid]/cmdline
            var cmdline_path_buf: [32]u8 = undefined;
            const cmdline_path = std.fmt.bufPrint(&cmdline_path_buf, "proc/{d}/cmdline", .{t.pid}) catch continue;
            const cmd_slice = std.fmt.bufPrint(&proc_cmdline_bufs[idx], "{s}\x00", .{t.comm()}) catch "";
            _ = vfs.registerNode(cmdline_path, vfs.S_IFREG | 0o444, cmd_slice);
        }
    }
}
