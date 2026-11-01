// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Comprehensive empirical adversarial challenge suite for TASK-016:
// sys_mount, sys_umount2, sys_sync, sys_fsync, dynamic /proc/mounts, and unmount lifecycle

const std = @import("std");

pub const SYS_READ: usize = 0;
pub const SYS_WRITE: usize = 1;
pub const SYS_OPEN: usize = 2;
pub const SYS_CLOSE: usize = 3;
pub const SYS_FSYNC: usize = 74;
pub const SYS_SYNC: usize = 162;
pub const SYS_MOUNT: usize = 165;
pub const SYS_UMOUNT2: usize = 166;
pub const SYS_EXIT_GROUP: usize = 231;

pub const O_RDONLY: usize = 0;
pub const O_WRONLY: usize = 1;
pub const O_RDWR: usize = 2;
pub const O_CREAT: usize = 64;

pub const ENOENT: isize = -2;
pub const EBADF: isize = -9;
pub const EFAULT: isize = -14;
pub const EBUSY: isize = -16;
pub const ENODEV: isize = -19;
pub const EINVAL: isize = -22;

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1) : "rcx", "r11", "memory");
}

inline fn sys2(n: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2) : "rcx", "r11", "memory");
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3) : "rcx", "r11", "memory");
}

inline fn sys5(n: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3), [d] "{r10}" (a4), [e] "{r8}" (a5) : "rcx", "r11", "memory");
}

fn puts(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn printNum(num: isize) void {
    var buf: [32]u8 = undefined;
    var idx: usize = 0;
    if (num < 0) {
        buf[0] = '-';
        idx = 1;
    }
    var u: usize = if (num < 0) @intCast(-num) else @intCast(num);
    var temp: [24]u8 = undefined;
    var t_idx: usize = 0;
    if (u == 0) {
        temp[0] = '0';
        t_idx = 1;
    } else {
        while (u > 0) {
            temp[t_idx] = @intCast('0' + (u % 10));
            t_idx += 1;
            u = u / 10;
        }
    }
    while (t_idx > 0) {
        t_idx -= 1;
        buf[idx] = temp[t_idx];
        idx += 1;
    }
    puts(buf[0..idx]);
}

export fn challengerMain() callconv(.C) noreturn {
    puts("[CHALLENGER_M16_2] Starting empirical adversarial suite for TASK-016...\n");

    // ========================================================================
    // Challenge 1: sys_fsync with invalid or closed fd (-EBADF)
    // ========================================================================
    puts("[CHALLENGE_1] Testing sys_fsync negative conditions...\n");
    {
        const r1 = sys1(SYS_FSYNC, @bitCast(@as(isize, -1)));
        puts("  fsync(-1) = ");
        printNum(r1);
        puts("\n");

        const r2 = sys1(SYS_FSYNC, 100);
        puts("  fsync(100) = ");
        printNum(r2);
        puts("\n");

        const fd = sys3(SYS_OPEN, @intFromPtr("/proc/mounts\x00"), O_RDONLY, 0);
        if (fd >= 0) {
            _ = sys1(SYS_CLOSE, @intCast(fd));
            const r3 = sys1(SYS_FSYNC, @intCast(fd));
            puts("  fsync(closed_fd) = ");
            printNum(r3);
            puts("\n");
        }
    }

    // ========================================================================
    // Challenge 2: sys_umount2 when not mounted or path mismatch (-EINVAL)
    // ========================================================================
    puts("[CHALLENGE_2] Testing sys_umount2 when not mounted...\n");
    {
        const r1 = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);
        puts("  umount2(\"/mnt\") before mount = ");
        printNum(r1);
        puts("\n");

        const r2 = sys2(SYS_UMOUNT2, 0, 0);
        puts("  umount2(null) = ");
        printNum(r2);
        puts("\n");
    }

    // ========================================================================
    // Challenge 3: sys_mount with null or invalid user pointer (-EFAULT)
    // ========================================================================
    puts("[CHALLENGE_3] Testing sys_mount with null/invalid pointers...\n");
    {
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);

        const r1 = sys5(SYS_MOUNT, @intFromPtr("/dev/vda\x00"), 0, @intFromPtr("tarfs\x00"), 0, 0);
        puts("  mount(target=NULL) = ");
        printNum(r1);
        puts(" (expected -EFAULT = -14)\n");

        const r2 = sys5(SYS_MOUNT, @intFromPtr("/dev/vda\x00"), 0x40, @intFromPtr("tarfs\x00"), 0, 0);
        puts("  mount(target=0x40) = ");
        printNum(r2);
        puts(" (expected -EFAULT = -14)\n");

        const r3 = sys5(SYS_MOUNT, 0, @intFromPtr("/mnt\x00"), @intFromPtr("tarfs\x00"), 0, 0);
        puts("  mount(source=NULL) = ");
        printNum(r3);
        puts(" (expected -EFAULT = -14)\n");
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);

        const r4 = sys5(SYS_MOUNT, @intFromPtr("/dev/vda\x00"), @intFromPtr("/mnt\x00"), 0, 0, 0);
        puts("  mount(fstype=NULL) = ");
        printNum(r4);
        puts(" (expected -EFAULT = -14)\n");
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);
    }

    // ========================================================================
    // Challenge 4: sys_mount on non-existent mount point (-ENOENT)
    // ========================================================================
    puts("[CHALLENGE_4] Testing sys_mount on non-existent mount point...\n");
    {
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/nonexistent_mount_target_dir\x00"), 0);

        const r = sys5(SYS_MOUNT, @intFromPtr("/dev/vda\x00"), @intFromPtr("/nonexistent_mount_target_dir\x00"), @intFromPtr("tarfs\x00"), 0, 0);
        puts("  mount(target=\"/nonexistent_mount_target_dir\") = ");
        printNum(r);
        puts(" (expected -ENOENT = -2)\n");
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/nonexistent_mount_target_dir\x00"), 0);
    }

    // ========================================================================
    // Challenge 5: sys_mount with invalid fstype != "tarfs" (-ENODEV)
    // ========================================================================
    puts("[CHALLENGE_5] Testing sys_mount with invalid fstype != \"tarfs\"...\n");
    {
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);

        const r1 = sys5(SYS_MOUNT, @intFromPtr("/dev/vda\x00"), @intFromPtr("/mnt\x00"), @intFromPtr("ext4\x00"), 0, 0);
        puts("  mount(fstype=\"ext4\") = ");
        printNum(r1);
        puts(" (expected -ENODEV = -19)\n");
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);

        const r2 = sys5(SYS_MOUNT, @intFromPtr("/dev/vda\x00"), @intFromPtr("/mnt\x00"), @intFromPtr("bogusfs\x00"), 0, 0);
        puts("  mount(fstype=\"bogusfs\") = ");
        printNum(r2);
        puts(" (expected -ENODEV = -19)\n");
        _ = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);
    }

    // ========================================================================
    // Challenge 6: Valid mount, double mount (-EBUSY), and unmount lifecycle
    // ========================================================================
    puts("[CHALLENGE_6] Testing valid mount, double mount (-EBUSY), path mismatch, and unmount lifecycle...\n");
    {
        // 6.1 Check /proc/mounts before mount
        var proc_buf: [256]u8 = undefined;
        const pfd1 = sys3(SYS_OPEN, @intFromPtr("/proc/mounts\x00"), O_RDONLY, 0);
        if (pfd1 >= 0) {
            const bytes_read = sys3(SYS_READ, @intCast(pfd1), @intFromPtr(&proc_buf), proc_buf.len);
            _ = sys1(SYS_CLOSE, @intCast(pfd1));
            puts("  /proc/mounts before mount:\n---BEGIN---\n");
            if (bytes_read > 0) puts(proc_buf[0..@intCast(bytes_read)]);
            puts("---END---\n");
        }

        // 6.2 Valid mount
        const r_mount = sys5(SYS_MOUNT, @intFromPtr("/dev/vda\x00"), @intFromPtr("/mnt\x00"), @intFromPtr("tarfs\x00"), 0, 0);
        puts("  mount(\"/mnt\", \"tarfs\") = ");
        printNum(r_mount);
        puts("\n");

        // 6.3 Double mount when already mounted -> should return -EBUSY (-16)
        const r_busy = sys5(SYS_MOUNT, @intFromPtr("/dev/vda\x00"), @intFromPtr("/mnt\x00"), @intFromPtr("tarfs\x00"), 0, 0);
        puts("  mount() when already mounted = ");
        printNum(r_busy);
        puts("\n");

        // 6.4 Check /proc/mounts during mount
        const pfd2 = sys3(SYS_OPEN, @intFromPtr("/proc/mounts\x00"), O_RDONLY, 0);
        if (pfd2 >= 0) {
            const bytes_read = sys3(SYS_READ, @intCast(pfd2), @intFromPtr(&proc_buf), proc_buf.len);
            _ = sys1(SYS_CLOSE, @intCast(pfd2));
            puts("  /proc/mounts while mounted:\n---BEGIN---\n");
            if (bytes_read > 0) puts(proc_buf[0..@intCast(bytes_read)]);
            puts("---END---\n");
        }

        // 6.5 Read host_seed.txt
        const seed_fd = sys3(SYS_OPEN, @intFromPtr("/mnt/host_seed.txt\x00"), O_RDONLY, 0);
        puts("  open(\"/mnt/host_seed.txt\") while mounted = ");
        printNum(seed_fd);
        puts("\n");
        if (seed_fd >= 0) {
            _ = sys1(SYS_CLOSE, @intCast(seed_fd));
        }

        // 6.6 umount with path mismatch -> should return -EINVAL (-22)
        const r_mismatch = sys2(SYS_UMOUNT2, @intFromPtr("/other_dir\x00"), 0);
        puts("  umount2(\"/other_dir\") path mismatch = ");
        printNum(r_mismatch);
        puts("\n");

        // 6.7 Valid umount
        const r_umount = sys2(SYS_UMOUNT2, @intFromPtr("/mnt\x00"), 0);
        puts("  umount2(\"/mnt\") = ");
        printNum(r_umount);
        puts("\n");

        // 6.8 Negative lookup after unmount
        const seed_after = sys3(SYS_OPEN, @intFromPtr("/mnt/host_seed.txt\x00"), O_RDONLY, 0);
        puts("  open(\"/mnt/host_seed.txt\") after unmount = ");
        printNum(seed_after);
        puts(" (expected -ENOENT = -2)\n");

        // 6.9 Check /proc/mounts after unmount
        const pfd3 = sys3(SYS_OPEN, @intFromPtr("/proc/mounts\x00"), O_RDONLY, 0);
        if (pfd3 >= 0) {
            const bytes_read = sys3(SYS_READ, @intCast(pfd3), @intFromPtr(&proc_buf), proc_buf.len);
            _ = sys1(SYS_CLOSE, @intCast(pfd3));
            puts("  /proc/mounts after unmount:\n---BEGIN---\n");
            if (bytes_read > 0) puts(proc_buf[0..@intCast(bytes_read)]);
            puts("---END---\n");
        }
    }

    puts("[CHALLENGER_M16_2] Empirical challenge execution complete.\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}
