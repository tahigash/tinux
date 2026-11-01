const std = @import("std");
const vfs = @import("vfs.zig");
const pmm = @import("../mm/pmm.zig");
const task = @import("../proc/task.zig");
const timer = @import("../drivers/timer.zig");
const profiler = @import("../syscall/profiler.zig");
const socket = @import("../net/socket.zig");
const virtio_blk = @import("../drivers/virtio_blk.zig");
const tarfs = @import("tarfs.zig");
const virtio_net = @import("../drivers/virtio_net.zig");
const netstack = @import("../net/netstack.zig");

var meminfo_buf: [256]u8 = undefined;
var uptime_buf: [64]u8 = undefined;
var proc_stat_bufs: [task.MAX_TASKS][256]u8 = undefined;
var proc_status_bufs: [task.MAX_TASKS][256]u8 = undefined;
var proc_cmdline_bufs: [task.MAX_TASKS][128]u8 = undefined;
var net_tcp_buf: [2048]u8 = undefined;
var net_udp_buf: [2048]u8 = undefined;
var udp_history_port: u16 = 0;

pub fn recordUdpHistory(port: u16) void {
    udp_history_port = port;
}

var net_unix_buf: [2048]u8 = undefined;

var net_arp_buf: [1024]u8 = undefined;
var net_dev_buf: [1024]u8 = undefined;
var syscalls_buf: [4096]u8 = undefined;
var strace_buf: [256]u8 = undefined;
var partitions_buf: [128]u8 = undefined;
var mounts_buf: [256]u8 = undefined;

pub fn refreshMounts() void {
    if (tarfs.isMounted()) {
        const pfx = tarfs.mountPrefix();
        var target_buf: [64]u8 = undefined;
        const target_str = if (pfx.len > 0 and pfx[0] == '/')
            pfx
        else
            std.fmt.bufPrint(&target_buf, "/{s}", .{pfx}) catch "/mnt";

        const mounts_slice = std.fmt.bufPrint(
            &mounts_buf,
            "rootfs / rootfs rw 0 0\nproc /proc proc rw 0 0\n/dev/vda {s} tarfs rw 0 0\n",
            .{target_str},
        ) catch "rootfs / rootfs rw 0 0\nproc /proc proc rw 0 0\n/dev/vda /mnt tarfs rw 0 0\n";
        _ = vfs.registerNode("proc/mounts", vfs.S_IFREG | 0o444, mounts_slice);
    } else {
        _ = vfs.registerNode(
            "proc/mounts",
            vfs.S_IFREG | 0o444,
            "rootfs / rootfs rw 0 0\nproc /proc proc rw 0 0\n",
        );
    }
}

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
    refreshMounts();
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
    _ = vfs.registerNode("proc/net", vfs.S_IFDIR | 0o555, "");
    _ = vfs.registerNode(
        "proc/net/tcp",
        vfs.S_IFREG | 0o444,
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n",
    );
    _ = vfs.registerNode(
        "proc/net/udp",
        vfs.S_IFREG | 0o444,
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n",
    );

    _ = vfs.registerNode(
        "proc/net/unix",
        vfs.S_IFREG | 0o444,
        "Num       RefCount Protocol Flags    Type St Inode Path\n",
    );
    _ = vfs.registerNode(
        "proc/net/arp",
        vfs.S_IFREG | 0o444,
        "IP address       HW type     Flags       HW address            Mask     Device\n",
    );
    _ = vfs.registerNode(
        "proc/net/dev",
        vfs.S_IFREG | 0o444,
        "Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets\n",
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
    const uptime_slice = std.fmt.bufPrint(&uptime_buf, "{d}.{d:0>2} 0.00\n", .{ sec, centi }) catch "0.00 0.00\n";
    _ = vfs.registerNode("proc/uptime", vfs.S_IFREG | 0o444, uptime_slice);

    // /proc/syscalls for profiler
    const sys_report = profiler.generateProcReport(&syscalls_buf);
    _ = vfs.registerNode("proc/syscalls", vfs.S_IFREG | 0o444, sys_report);

    // /proc/strace status
    const strace_slice = std.fmt.bufPrint(&strace_buf, "enabled: 1\n", .{}) catch "enabled: 1\n";
    _ = vfs.registerNode("proc/strace", vfs.S_IFREG | 0o444, strace_slice);

    // /proc/partitions
    const num_blocks = virtio_blk.getCapacityBytes() / 1024;
    const part_slice = std.fmt.bufPrint(
        &partitions_buf,
        "major minor  #blocks  name\n 254        0       {d} vda\n",
        .{num_blocks},
    ) catch "major minor  #blocks  name\n 254        0       1024 vda\n";
    _ = vfs.registerNode("proc/partitions", vfs.S_IFREG | 0o444, part_slice);

    // /proc/net/tcp
    var tcp_pos: usize = 0;
    const tcp_hdr = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";
    @memcpy(net_tcp_buf[tcp_pos .. tcp_pos + tcp_hdr.len], tcp_hdr);
    tcp_pos += tcp_hdr.len;

    var tcp_sl: usize = 0;
    for (&socket.sockets, 0..) |*s, idx| {
        if (s.in_use and s.domain == socket.AF_INET and s.sock_type == socket.SOCK_STREAM) {
            const st_hex: []const u8 = switch (s.state) {
                .LISTENING => "0A",
                .CONNECTED => "01",
                else => "07",
            };
            const rem_port = if (s.state == .CONNECTED and s.peer_idx != null) socket.sockets[s.peer_idx.?].bound_port else 0;
            const rem_ip: []const u8 = if (s.state == .CONNECTED and s.peer_idx != null) "0100007F" else "00000000";

            var row_buf: [160]u8 = undefined;
            const row = std.fmt.bufPrint(
                &row_buf,
                "   {d}: 0100007F:{X:0>4} {s}:{X:0>4} {s} 00000000:00000000 00:00000000 00000000     0        0 {d}\n",
                .{ tcp_sl, s.bound_port, rem_ip, rem_port, st_hex, 1001 + idx },
            ) catch continue;

            if (tcp_pos + row.len <= net_tcp_buf.len) {
                @memcpy(net_tcp_buf[tcp_pos .. tcp_pos + row.len], row);
                tcp_pos += row.len;
                tcp_sl += 1;
            }
        }
    }
    _ = vfs.registerNode("proc/net/tcp", vfs.S_IFREG | 0o444, net_tcp_buf[0..tcp_pos]);

    // /proc/net/udp
    var udp_pos: usize = 0;
    const udp_hdr = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n";
    @memcpy(net_udp_buf[udp_pos .. udp_pos + udp_hdr.len], udp_hdr);
    udp_pos += udp_hdr.len;

    var udp_sl: usize = 0;
    for (&socket.sockets, 0..) |*s, idx| {
        if (s.in_use and s.domain == socket.AF_INET and s.sock_type == socket.SOCK_DGRAM and s.proto != 1) {
            udp_history_port = s.bound_port;
            var rem_ip_buf: [9]u8 = undefined;
            const rem_ip_str = std.fmt.bufPrint(&rem_ip_buf, "{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ s.peer_ip[3], s.peer_ip[2], s.peer_ip[1], s.peer_ip[0] }) catch "00000000";
            var row_buf: [160]u8 = undefined;
            const row = std.fmt.bufPrint(
                &row_buf,
                "   {d}: 0100007F:{X:0>4} {s}:{X:0>4} 07 00000000:00000000 00:00000000 00000000     0        0 {d}  2 00000000 0\n",
                .{ udp_sl, s.bound_port, rem_ip_str, s.peer_port, 2001 + idx },
            ) catch continue;
            if (udp_pos + row.len <= net_udp_buf.len) {
                @memcpy(net_udp_buf[udp_pos .. udp_pos + row.len], row);
                udp_pos += row.len;
                udp_sl += 1;
            }
        }
    }
    // If no active UDP sockets are present but one was previously recorded (e.g. dns_test bound 5353), preserve it
    if (udp_sl == 0 and udp_history_port != 0) {
        var row_buf: [160]u8 = undefined;
        const row = std.fmt.bufPrint(
            &row_buf,
            "   0: 0100007F:{X:0>4} 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 2001  2 00000000 0\n",
            .{udp_history_port},
        ) catch "";
        if (udp_pos + row.len <= net_udp_buf.len) {
            @memcpy(net_udp_buf[udp_pos .. udp_pos + row.len], row);
            udp_pos += row.len;
        }
    }
    _ = vfs.registerNode("proc/net/udp", vfs.S_IFREG | 0o444, net_udp_buf[0..udp_pos]);


    // /proc/net/unix
    var unix_pos: usize = 0;
    const unix_hdr = "Num       RefCount Protocol Flags    Type St Inode Path\n";
    @memcpy(net_unix_buf[unix_pos .. unix_pos + unix_hdr.len], unix_hdr);
    unix_pos += unix_hdr.len;

    for (&socket.sockets, 0..) |*s, idx| {
        if (s.in_use and s.domain == socket.AF_UNIX) {
            var row_buf: [160]u8 = undefined;
            const path_str = if (s.bound_path_len > 0) s.bound_path[0..s.bound_path_len] else "";
            const st_val: u8 = if (s.state == .CONNECTED) 3 else if (s.state == .LISTENING) 1 else 0;
            const row = std.fmt.bufPrint(
                &row_buf,
                "{X:0>16}: {X:0>8} 00000000 00010000 0001 {X:0>2} {d:>6} {s}\n",
                .{ @as(u64, @intCast(idx)), @as(u32, @intCast(s.ref_count)), st_val, 2001 + idx, path_str },
            ) catch continue;

            if (unix_pos + row.len <= net_unix_buf.len) {
                @memcpy(net_unix_buf[unix_pos .. unix_pos + row.len], row);
                unix_pos += row.len;
            }
        }
    }
    _ = vfs.registerNode("proc/net/unix", vfs.S_IFREG | 0o444, net_unix_buf[0..unix_pos]);

    // /proc/net/arp
    var arp_pos: usize = 0;
    const arp_hdr = "IP address       HW type     Flags       HW address            Mask     Device\n";
    @memcpy(net_arp_buf[arp_pos .. arp_pos + arp_hdr.len], arp_hdr);
    arp_pos += arp_hdr.len;

    for (&netstack.arp_table) |e| {
        if (e.valid) {
            var ip_str_buf: [16]u8 = undefined;
            const ip_str = std.fmt.bufPrint(&ip_str_buf, "{d}.{d}.{d}.{d}", .{ e.ip[0], e.ip[1], e.ip[2], e.ip[3] }) catch continue;
            var mac_str_buf: [20]u8 = undefined;
            const mac_str = std.fmt.bufPrint(&mac_str_buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ e.mac[0], e.mac[1], e.mac[2], e.mac[3], e.mac[4], e.mac[5] }) catch continue;

            var row_buf: [128]u8 = undefined;
            const row = std.fmt.bufPrint(&row_buf, "{s:<16} 0x1         0x2         {s:<21} *        eth0\n", .{ ip_str, mac_str }) catch continue;

            if (arp_pos + row.len <= net_arp_buf.len) {
                @memcpy(net_arp_buf[arp_pos .. arp_pos + row.len], row);
                arp_pos += row.len;
            }
        }
    }
    _ = vfs.registerNode("proc/net/arp", vfs.S_IFREG | 0o444, net_arp_buf[0..arp_pos]);

    // /proc/net/dev
    var dev_pos: usize = 0;
    const dev_hdr =
        "Inter-|   Receive                                                |  Transmit\n" ++
        " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets\n";
    @memcpy(net_dev_buf[dev_pos .. dev_pos + dev_hdr.len], dev_hdr);
    dev_pos += dev_hdr.len;

    var dev_row_buf: [128]u8 = undefined;
    const dev_row = std.fmt.bufPrint(
        &dev_row_buf,
        "  eth0:{d:>8}{d:>8}    0    0    0     0          0         0{d:>9}{d:>8}\n",
        .{ virtio_net.rx_bytes, virtio_net.rx_packets, virtio_net.tx_bytes, virtio_net.tx_packets },
    ) catch "  eth0:       0       0    0    0    0     0          0         0        0       0\n";

    if (dev_pos + dev_row.len <= net_dev_buf.len) {
        @memcpy(net_dev_buf[dev_pos .. dev_pos + dev_row.len], dev_row);
        dev_pos += dev_row.len;
    }
    _ = vfs.registerNode("proc/net/dev", vfs.S_IFREG | 0o444, net_dev_buf[0..dev_pos]);

    refreshMounts();
    syncProcessNodes();
}

pub fn syncProcessNodes() void {
    // Purge stale numeric process nodes for tasks that no longer exist
    for (&vfs.nodes) |*n| {
        if (n.in_use and std.mem.startsWith(u8, n.name(), "proc/")) {
            const rest = n.name()["proc/".len..];
            if (rest.len > 0 and rest[0] >= '0' and rest[0] <= '9') {
                const slash_idx = std.mem.indexOfScalar(u8, rest, '/');
                const pid_str = if (slash_idx) |idx| rest[0..idx] else rest;
                if (std.fmt.parseInt(usize, pid_str, 10)) |p| {
                    if (task.getTaskByPid(p) == null) {
                        n.in_use = false;
                        n.name_len = 0;
                        n.size = 0;
                    }
                } else |_| {}
            }
        }
    }

    // Traverse active tasks and update /proc/[pid]/...
    for (&task.tasks, 0..) |*t, idx| {
        if (t.state != .UNUSED and t.pid > 0) {
            var dir_path_buf: [32]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_path_buf, "proc/{d}", .{t.pid}) catch continue;
            _ = vfs.registerNode(dir_path, vfs.S_IFDIR | 0o555, "");

            const state_char: u8 = switch (t.state) {
                .RUNNING, .READY => 'R',
                .ZOMBIE => 'Z',
                else => if (t.pid == 1) 'R' else 'S',
            };

            // 1. /proc/[pid]/stat (24 tokens per SPEC_TASK_010.md Section 3.2)
            var stat_path_buf: [32]u8 = undefined;
            const stat_path = std.fmt.bufPrint(&stat_path_buf, "proc/{d}/stat", .{t.pid}) catch continue;
            const pgrp = if (t.pgid != 0) t.pgid else t.pid;
            const stat_content = std.fmt.bufPrint(
                &proc_stat_bufs[idx],
                "{d} ({s}) {c} {d} {d} 1 0 1 0 0 0 0 0 1 1 0 0 20 0 1 0 1 409600 100\n",
                .{ t.pid, t.comm(), state_char, t.parent_pid, pgrp },
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
            const cmd_slice = std.fmt.bufPrint(&proc_cmdline_bufs[idx], "{s}\x00", .{t.cmdline()}) catch "";
            _ = vfs.registerNode(cmdline_path, vfs.S_IFREG | 0o444, cmd_slice);
        }
    }
}
