// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Adversarial test suite for TASK-009: sys_getdents64 validation, record alignment, virtual entries, and directory operations

const std = @import("std");

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call testMain
    );
}

inline fn sys0(n: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
        : "rcx", "r11", "memory"
    );
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
        : "rcx", "r11", "memory"
    );
}

inline fn sys2(n: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
        : "rcx", "r11", "memory"
    );
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
        : "rcx", "r11", "memory"
    );
}

inline fn sys4(n: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
          [d] "{r10}" (a4),
        : "rcx", "r11", "memory"
    );
}

const SYS_READ: usize = 0;
const SYS_WRITE: usize = 1;
const SYS_OPEN: usize = 2;
const SYS_CLOSE: usize = 3;
const SYS_EXIT: usize = 60;
const SYS_MKDIR: usize = 83;
const SYS_RMDIR: usize = 84;
const SYS_UNLINK: usize = 87;
const SYS_GETDENTS64: usize = 217;
const SYS_OPENAT: usize = 257;
const SYS_MKDIRAT: usize = 258;
const SYS_UNLINKAT: usize = 263;

const AT_FDCWD: isize = -100;
const AT_REMOVEDIR: usize = 0x200;

const O_RDONLY: usize = 0;
const O_WRONLY: usize = 1;
const O_RDWR: usize = 2;
const O_CREAT: usize = 0o100;
const O_EXCL: usize = 0o200;
const O_TRUNC: usize = 0o1000;
const O_DIRECTORY: usize = 0o200000;

const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;

fn print(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn printInt(val: isize) void {
    var buf: [32]u8 = undefined;
    var v = val;
    var negative = false;
    if (v < 0) {
        negative = true;
        v = -v;
    }
    var idx: usize = buf.len;
    if (v == 0) {
        idx -= 1;
        buf[idx] = '0';
    } else {
        while (v > 0) {
            idx -= 1;
            buf[idx] = @as(u8, @intCast(@rem(v, 10))) + '0';
            v = @divTrunc(v, 10);
        }
    }
    if (negative) {
        idx -= 1;
        buf[idx] = '-';
    }
    print(buf[idx..]);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("[CHALLENGER2_FAIL] ");
    print(msg);
    print("\n");
    _ = sys1(SYS_EXIT, code);
    unreachable;
}

fn openPath(path: []const u8, flags: usize, mode: usize) isize {
    var c_path: [256]u8 = undefined;
    if (path.len >= c_path.len) return -1;
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;
    return sys4(SYS_OPENAT, @bitCast(AT_FDCWD), @intFromPtr(&c_path), flags, mode);
}

fn mkdirPath(path: []const u8, mode: usize) isize {
    var c_path: [256]u8 = undefined;
    if (path.len >= c_path.len) return -1;
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;
    return sys3(SYS_MKDIRAT, @bitCast(AT_FDCWD), @intFromPtr(&c_path), mode);
}

fn unlinkPath(path: []const u8) isize {
    var c_path: [256]u8 = undefined;
    if (path.len >= c_path.len) return -1;
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;
    return sys3(SYS_UNLINKAT, @bitCast(AT_FDCWD), @intFromPtr(&c_path), 0);
}

fn rmdirPath(path: []const u8) isize {
    var c_path: [256]u8 = undefined;
    if (path.len >= c_path.len) return -1;
    @memcpy(c_path[0..path.len], path);
    c_path[path.len] = 0;
    return sys3(SYS_UNLINKAT, @bitCast(AT_FDCWD), @intFromPtr(&c_path), AT_REMOVEDIR);
}

pub export fn testMain() callconv(.C) noreturn {
    print("\n=======================================================\n");
    print("[CHALLENGER2_TEST] START: TASK-009 Empirical Challenge Suite\n");
    print("=======================================================\n\n");

    // =========================================================================
    // Objective 1: sys_getdents64 on a non-directory FD fails with -ENOTDIR (-20)
    // =========================================================================
    print("[TEST 1] Verifying sys_getdents64 on non-directory FD returns -ENOTDIR (-20)...\n");
    {
        // 1a: Existing static file /etc/motd
        const fd_motd = openPath("/etc/motd", O_RDONLY, 0);
        if (fd_motd < 0) fail(101, "Failed to open /etc/motd");
        var buf: [512]u8 = undefined;
        const res_motd = sys3(SYS_GETDENTS64, @intCast(fd_motd), @intFromPtr(&buf), buf.len);
        _ = sys1(SYS_CLOSE, @intCast(fd_motd));

        print("  -> sys_getdents64 on static file /etc/motd: returned ");
        printInt(res_motd);
        print(" (expected -20)\n");
        if (res_motd != -20) fail(102, "sys_getdents64 on /etc/motd did not return -ENOTDIR (-20)");

        // 1b: Writable tmpfs file /tmp/ch2_file.txt
        const fd_tmp = openPath("/tmp/ch2_file.txt", O_CREAT | O_WRONLY | O_TRUNC, 0o644);
        print("  -> created /tmp/ch2_file.txt: fd=");
        printInt(fd_tmp);
        print("\n");
        if (fd_tmp < 0) fail(103, "Failed to create /tmp/ch2_file.txt");
        _ = sys3(SYS_WRITE, @intCast(fd_tmp), @intFromPtr("challenge2 payload".ptr), 18);
        _ = sys1(SYS_CLOSE, @intCast(fd_tmp));

        const fd_tmp_ro = openPath("/tmp/ch2_file.txt", O_RDONLY, 0);
        print("  -> re-opened /tmp/ch2_file.txt: fd=");
        printInt(fd_tmp_ro);
        print("\n");
        if (fd_tmp_ro < 0) fail(104, "Failed to open /tmp/ch2_file.txt for reading");
        const res_tmp = sys3(SYS_GETDENTS64, @intCast(fd_tmp_ro), @intFromPtr(&buf), buf.len);
        _ = sys1(SYS_CLOSE, @intCast(fd_tmp_ro));

        print("  -> sys_getdents64 on writable regular file: returned ");
        printInt(res_tmp);
        print(" (expected -20)\n");
        if (res_tmp != -20) fail(105, "sys_getdents64 on regular tmpfs file did not return -ENOTDIR (-20)");

        // 1c: Invalid descriptor (e.g. 42) -> expected -EBADF (-9)
        const res_bad = sys3(SYS_GETDENTS64, 42, @intFromPtr(&buf), buf.len);
        print("  -> sys_getdents64 on invalid fd 42: returned ");
        printInt(res_bad);
        print(" (expected -9)\n");
        if (res_bad != -9) fail(106, "sys_getdents64 on invalid fd did not return -EBADF (-9)");

        print("[TEST 1] RESULT: PASS (-ENOTDIR -20 verified on non-directory FDs)\n\n");
    }

    // =========================================================================
    // Objective 2: sys_getdents64 with buffer smaller than single record fails with -EINVAL (-22)
    // =========================================================================
    print("[TEST 2] Verifying buffer smaller than single record fails with -EINVAL (-22)...\n");
    {
        const fd_dir = openPath("/tmp", O_RDONLY | O_DIRECTORY, 0);
        if (fd_dir < 0) fail(201, "Failed to open /tmp directory");

        var test_buf: [64]u8 = undefined;

        // In /tmp, first record is "." with min size 19 + 1 + 1 = 21 -> 8-byte aligned to 24 bytes.
        // Buffer sizes 0, 1, 10, 16, 23 must all return -EINVAL (-22).
        const small_sizes = [_]usize{ 0, 1, 10, 16, 20, 23 };
        for (small_sizes) |sz| {
            const ret = sys3(SYS_GETDENTS64, @intCast(fd_dir), @intFromPtr(&test_buf), sz);
            print("  -> sys_getdents64 with buffer size ");
            printInt(@intCast(sz));
            print(": returned ");
            printInt(ret);
            print(" (expected -22)\n");
            if (ret != -22) fail(202, "sys_getdents64 with undersized buffer did not return -EINVAL (-22)");
        }

        // Buffer size 24: exactly fits the single "." record!
        const ret_exact = sys3(SYS_GETDENTS64, @intCast(fd_dir), @intFromPtr(&test_buf), 24);
        print("  -> sys_getdents64 with buffer size 24 (exact size): returned ");
        printInt(ret_exact);
        print(" (expected 24)\n");
        if (ret_exact != 24) fail(203, "sys_getdents64 with exact buffer size 24 did not return 24");

        _ = sys1(SYS_CLOSE, @intCast(fd_dir));
        print("[TEST 2] RESULT: PASS (-EINVAL -22 verified on buffers smaller than record)\n\n");
    }

    // =========================================================================
    // Objective 3: Virtual directory entries . and .. (cursor 0 and 1, d_type == DT_DIR)
    // =========================================================================
    print("[TEST 3] Verifying virtual directory entries '.' and '..' (cursor 0 and 1, d_type == DT_DIR)...\n");
    {
        const mk_res = mkdirPath("/tmp/ch2_virt_dir", 0o755);
        print("  -> mkdir /tmp/ch2_virt_dir: returned ");
        printInt(mk_res);
        print("\n");
        const fd_vdir = openPath("/tmp/ch2_virt_dir", O_RDONLY | O_DIRECTORY, 0);
        print("  -> open /tmp/ch2_virt_dir: returned ");
        printInt(fd_vdir);
        print("\n");
        if (fd_vdir < 0) fail(301, "Failed to open /tmp/ch2_virt_dir");

        var vbuf: [512]u8 = undefined;
        const vread = sys3(SYS_GETDENTS64, @intCast(fd_vdir), @intFromPtr(&vbuf), vbuf.len);
        print("  -> bytes read from /tmp/ch2_virt_dir: ");
        printInt(vread);
        print(" (expected >= 48 for . and ..)\n");
        if (vread < 48) fail(302, "Expected at least 48 bytes for '.' and '..'");

        // Entry 0: "."
        const d0_reclen = std.mem.readInt(u16, vbuf[16..][0..2], .little);
        const d0_off = std.mem.readInt(i64, vbuf[8..][0..8], .little);
        const d0_type = vbuf[18];
        const d0_name_ptr = @as([*:0]const u8, @ptrCast(&vbuf[19]));
        const d0_name = std.mem.sliceTo(d0_name_ptr, 0);

        print("  -> Entry 0: name='");
        print(d0_name);
        print("', d_type=");
        printInt(@intCast(d0_type));
        print(", d_off=");
        printInt(d0_off);
        print(", d_reclen=");
        printInt(@intCast(d0_reclen));
        print("\n");

        if (!std.mem.eql(u8, d0_name, ".")) fail(303, "Entry 0 name is not '.'");
        if (d0_type != DT_DIR) fail(304, "Entry 0 d_type is not DT_DIR (4)");
        if (d0_off != 1) fail(305, "Entry 0 d_off is not 1");
        if (d0_reclen != 24) fail(306, "Entry 0 d_reclen is not 24");

        // Entry 1: ".."
        const off1: usize = d0_reclen;
        const d1_reclen = std.mem.readInt(u16, vbuf[off1 + 16 ..][0..2], .little);
        const d1_off = std.mem.readInt(i64, vbuf[off1 + 8 ..][0..8], .little);
        const d1_type = vbuf[off1 + 18];
        const d1_name_ptr = @as([*:0]const u8, @ptrCast(&vbuf[off1 + 19]));
        const d1_name = std.mem.sliceTo(d1_name_ptr, 0);

        print("  -> Entry 1: name='");
        print(d1_name);
        print("', d_type=");
        printInt(@intCast(d1_type));
        print(", d_off=");
        printInt(d1_off);
        print(", d_reclen=");
        printInt(@intCast(d1_reclen));
        print("\n");

        if (!std.mem.eql(u8, d1_name, "..")) fail(307, "Entry 1 name is not '..'");
        if (d1_type != DT_DIR) fail(308, "Entry 1 d_type is not DT_DIR (4)");
        if (d1_off != 2) fail(309, "Entry 1 d_off is not 2");
        if (d1_reclen != 24) fail(310, "Entry 1 d_reclen is not 24");

        _ = sys1(SYS_CLOSE, @intCast(fd_vdir));
        print("[TEST 3] RESULT: PASS (virtual entries '.' and '..' verified at cursor 0 and 1 with DT_DIR)\n\n");
    }

    // =========================================================================
    // Objective 4: 8-byte alignment of each record's d_reclen across varying lengths
    // =========================================================================
    print("[TEST 4] Verifying 8-byte alignment of each record's d_reclen...\n");
    {
        _ = mkdirPath("/tmp/ch2_align_test", 0o755);

        // Create 12 files with varying name lengths from 1 char to 14 chars
        const file_names = [_][]const u8{
            "x",
            "xy",
            "xyz",
            "xyzw",
            "xyzw1",
            "xyzw12",
            "xyzw123",
            "xyzw1234",
            "xyzw12345",
            "xyzw123456",
            "xyzw1234567",
            "xyzw12345678",
            "xyzw123456789",
            "xyzw1234567890",
        };

        for (file_names) |fn_str| {
            var path_buf: [64]u8 = undefined;
            const full_p = std.fmt.bufPrint(&path_buf, "/tmp/ch2_align_test/{s}", .{fn_str}) catch unreachable;
            const f = openPath(full_p, O_CREAT | O_WRONLY | O_TRUNC, 0o644);
            if (f < 0) fail(401, "Failed to create file for alignment test");
            _ = sys1(SYS_CLOSE, @intCast(f));
        }

        const fd_align = openPath("/tmp/ch2_align_test", O_RDONLY | O_DIRECTORY, 0);
        if (fd_align < 0) fail(402, "Failed to open /tmp/ch2_align_test");

        var abuf: [2048]u8 = undefined;
        const total_bytes = sys3(SYS_GETDENTS64, @intCast(fd_align), @intFromPtr(&abuf), abuf.len);
        if (total_bytes <= 0) fail(403, "sys_getdents64 returned <= 0 on /tmp/ch2_align_test");

        var cur_off: usize = 0;
        const limit_bytes: usize = @intCast(total_bytes);
        var entry_count: usize = 0;

        while (cur_off < limit_bytes) {
            const reclen = std.mem.readInt(u16, abuf[cur_off + 16 ..][0..2], .little);
            const d_ino = std.mem.readInt(u64, abuf[cur_off..][0..8], .little);
            const d_off = std.mem.readInt(i64, abuf[cur_off + 8 ..][0..8], .little);
            const d_type = abuf[cur_off + 18];
            const name_ptr = @as([*:0]const u8, @ptrCast(&abuf[cur_off + 19]));
            const entry_name = std.mem.sliceTo(name_ptr, 0);

            print("  [#");
            printInt(@intCast(entry_count));
            print("] off=");
            printInt(@intCast(cur_off));
            print(", reclen=");
            printInt(@intCast(reclen));
            print(", name='");
            print(entry_name);
            print("', len=");
            printInt(@intCast(entry_name.len));
            print(", ino=");
            printInt(@intCast(d_ino));
            print(", d_off=");
            printInt(d_off);
            print(", d_type=");
            printInt(@intCast(d_type));
            print("\n");

            // 1. Must be strictly 8-byte aligned
            if ((reclen % 8) != 0) fail(404, "d_reclen is not a multiple of 8");

            // 2. Buffer offset must be strictly 8-byte aligned
            if ((cur_off % 8) != 0) fail(405, "Current record start offset is not 8-byte aligned");

            // 3. reclen must be at least min required size
            const min_rec = 19 + entry_name.len + 1;
            const expected_aligned = std.mem.alignForward(usize, min_rec, 8);
            if (reclen != expected_aligned) fail(406, "reclen does not match alignForward(19+len+1, 8)");

            // 4. d_ino must be positive
            if (d_ino == 0) fail(407, "d_ino is 0");

            cur_off += reclen;
            entry_count += 1;
        }

        print("  -> Inspected ");
        printInt(@intCast(entry_count));
        print(" records. All d_reclen and record offsets are 100% 8-byte aligned.\n");

        if (entry_count != 2 + file_names.len) {
            fail(408, "Record count does not match expected total (. + .. + 14 files)");
        }

        _ = sys1(SYS_CLOSE, @intCast(fd_align));
        print("[TEST 4] RESULT: PASS (All records strictly verified 8-byte aligned)\n\n");
    }

    print("=======================================================\n");
    print("[CHALLENGER2_TEST] ALL EMPIRICAL CHALLENGES VERIFIED CLEANLY!\n");
    print("=======================================================\n");
    _ = sys1(SYS_EXIT, 0);
    unreachable;
}
