// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Adversarial test suite for TASK-008: IPC pipes, dup3 edge cases, O_CLOEXEC propagation, and /proc reads

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
const SYS_LSEEK: usize = 8;
const SYS_PREAD64: usize = 17;
const SYS_PIPE: usize = 22;
const SYS_DUP2: usize = 33;
const SYS_FORK: usize = 57;
const SYS_EXECVE: usize = 59;
const SYS_EXIT: usize = 60;
const SYS_WAIT4: usize = 61;
const SYS_PIPE2: usize = 293;
const SYS_DUP3: usize = 292;

const O_CLOEXEC: usize = 0x80000;
const SEEK_SET: usize = 0;
const SEEK_CUR: usize = 1;
const SEEK_END: usize = 2;

fn print(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("[ADVERSARIAL_FAIL] ");
    print(msg);
    print("\n");
    _ = sys1(SYS_EXIT, code);
    unreachable;
}

pub export fn testMain() callconv(.C) noreturn {
    print("\n[ADVERSARIAL_TEST] START: TASK-008 IPC, dup3, O_CLOEXEC & /proc Suite\n");

    // =========================================================================
    // Challenge 1: sys_dup3 Edge Cases
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 1: sys_dup3 edge cases (oldfd == newfd, bad flags)...\n");

    // 1.1 oldfd == newfd with flags = 0 -> -EINVAL (-22)
    const d1 = sys3(SYS_DUP3, 1, 1, 0);
    if (d1 != -22) fail(101, "dup3(1, 1, 0) did not return -EINVAL (-22)");

    // 1.2 oldfd == newfd with flags = O_CLOEXEC -> -EINVAL (-22)
    const d2 = sys3(SYS_DUP3, 1, 1, O_CLOEXEC);
    if (d2 != -22) fail(102, "dup3(1, 1, O_CLOEXEC) did not return -EINVAL (-22)");

    // 1.3 oldfd == newfd with invalid fd (100) -> -EINVAL (-22)
    const d3 = sys3(SYS_DUP3, 100, 100, 0);
    if (d3 != -22) fail(103, "dup3(100, 100, 0) did not return -EINVAL (-22)");

    // 1.4 invalid flags (1) -> -EINVAL (-22)
    const d4 = sys3(SYS_DUP3, 1, 20, 1);
    if (d4 != -22) fail(104, "dup3(1, 20, 1) did not return -EINVAL (-22)");

    // 1.5 invalid flags (O_CLOEXEC | 1) -> -EINVAL (-22)
    const d5 = sys3(SYS_DUP3, 1, 20, O_CLOEXEC | 1);
    if (d5 != -22) fail(105, "dup3(1, 20, O_CLOEXEC | 1) did not return -EINVAL (-22)");

    // 1.6 invalid flags (~0) -> -EINVAL (-22)
    const d6 = sys3(SYS_DUP3, 1, 20, 0xFFFFFFFF);
    if (d6 != -22) fail(106, "dup3(1, 20, 0xFFFFFFFF) did not return -EINVAL (-22)");

    // 1.7 oldfd out of range (100) -> -EBADF (-9)
    const d7 = sys3(SYS_DUP3, 100, 20, 0);
    if (d7 != -9) fail(107, "dup3(100, 20, 0) did not return -EBADF (-9)");

    // 1.8 newfd out of range (100) -> -EBADF (-9)
    const d8 = sys3(SYS_DUP3, 1, 100, 0);
    if (d8 != -9) fail(108, "dup3(1, 100, 0) did not return -EBADF (-9)");

    // 1.9 valid dup3
    const d9 = sys3(SYS_DUP3, 1, 25, 0);
    if (d9 != 25) fail(109, "dup3(1, 25, 0) failed to return 25");
    const test_write = "dup3_ok\n";
    const w9 = sys3(SYS_WRITE, 25, @intFromPtr(test_write.ptr), test_write.len);
    if (w9 != @as(isize, @intCast(test_write.len))) fail(110, "write to dup3 fd 25 failed");
    _ = sys1(SYS_CLOSE, 25);

    print("[ADVERSARIAL_TEST] PASS: sys_dup3 edge cases verified cleanly.\n");

    // =========================================================================
    // Challenge 2: sys_pipe2 Edge Cases
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 2: sys_pipe2 edge cases (flags validation)...\n");

    var pfd_temp: [2]i32 = .{ -1, -1 };
    // 2.1 invalid flag 1 -> -EINVAL (-22)
    const p1 = sys2(SYS_PIPE2, @intFromPtr(&pfd_temp), 1);
    if (p1 != -22) fail(201, "pipe2(pfd, 1) did not return -EINVAL (-22)");

    // 2.2 invalid flag 0x1000 -> -EINVAL (-22)
    const p2 = sys2(SYS_PIPE2, @intFromPtr(&pfd_temp), 0x1000);
    if (p2 != -22) fail(202, "pipe2(pfd, 0x1000) did not return -EINVAL (-22)");

    // 2.3 invalid buffer pointer (0) -> -EFAULT (-14)
    const p3 = sys2(SYS_PIPE2, 0, 0);
    if (p3 != -14) fail(203, "pipe2(0, 0) did not return -EFAULT (-14)");

    print("[ADVERSARIAL_TEST] PASS: sys_pipe2 edge cases verified cleanly.\n");

    // =========================================================================
    // Challenge 3: Multi-Stage IPC Pipeline (3 processes connected via 2 pipes)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 3: Multi-stage pipeline (Proc1 | Proc2 | Proc3)...\n");

    var pipe1: [2]i32 = .{ -1, -1 };
    var pipe2: [2]i32 = .{ -1, -1 };
    if (sys2(SYS_PIPE2, @intFromPtr(&pipe1), 0) != 0) fail(301, "pipe2 for pipe1 failed");
    if (sys2(SYS_PIPE2, @intFromPtr(&pipe2), 0) != 0) fail(302, "pipe2 for pipe2 failed");

    // Fork Producer (Proc1)
    const pid1 = sys0(SYS_FORK);
    if (pid1 < 0) fail(303, "fork proc1 failed");
    if (pid1 == 0) {
        _ = sys1(SYS_CLOSE, @intCast(pipe1[0]));
        _ = sys1(SYS_CLOSE, @intCast(pipe2[0]));
        _ = sys1(SYS_CLOSE, @intCast(pipe2[1]));
        const payload = "STAGE1_PAYLOAD_DATA\n";
        _ = sys3(SYS_WRITE, @intCast(pipe1[1]), @intFromPtr(payload.ptr), payload.len);
        _ = sys1(SYS_CLOSE, @intCast(pipe1[1]));
        _ = sys1(SYS_EXIT, 0);
        unreachable;
    }

    // Fork Filter (Proc2)
    const pid2 = sys0(SYS_FORK);
    if (pid2 < 0) fail(304, "fork proc2 failed");
    if (pid2 == 0) {
        _ = sys1(SYS_CLOSE, @intCast(pipe1[1]));
        _ = sys1(SYS_CLOSE, @intCast(pipe2[0]));
        var in_buf: [64]u8 = undefined;
        const n = sys3(SYS_READ, @intCast(pipe1[0]), @intFromPtr(&in_buf), in_buf.len);
        _ = sys1(SYS_CLOSE, @intCast(pipe1[0]));
        if (n <= 0) {
            _ = sys1(SYS_EXIT, 1);
            unreachable;
        }
        // Write transformed data to pipe2
        _ = sys3(SYS_WRITE, @intCast(pipe2[1]), @intFromPtr(&in_buf), @intCast(n));
        const extra = "+STAGE2_APPENDED\n";
        _ = sys3(SYS_WRITE, @intCast(pipe2[1]), @intFromPtr(extra.ptr), extra.len);
        _ = sys1(SYS_CLOSE, @intCast(pipe2[1]));
        _ = sys1(SYS_EXIT, 0);
        unreachable;
    }

    // Fork Consumer (Proc3)
    const pid3 = sys0(SYS_FORK);
    if (pid3 < 0) fail(305, "fork proc3 failed");
    if (pid3 == 0) {
        _ = sys1(SYS_CLOSE, @intCast(pipe1[0]));
        _ = sys1(SYS_CLOSE, @intCast(pipe1[1]));
        _ = sys1(SYS_CLOSE, @intCast(pipe2[1]));
        var final_buf: [128]u8 = undefined;
        var total: usize = 0;
        while (total < final_buf.len) {
            const rd = sys3(SYS_READ, @intCast(pipe2[0]), @intFromPtr(&final_buf[total]), final_buf.len - total);
            if (rd <= 0) break; // EOF
            total += @intCast(rd);
        }
        _ = sys1(SYS_CLOSE, @intCast(pipe2[0]));
        const expected = "STAGE1_PAYLOAD_DATA\n+STAGE2_APPENDED\n";
        if (total != expected.len or !std.mem.eql(u8, final_buf[0..total], expected)) {
            _ = sys1(SYS_EXIT, 2);
            unreachable;
        }
        _ = sys1(SYS_EXIT, 0);
        unreachable;
    }

    // Parent closes all its copies of pipe ends
    _ = sys1(SYS_CLOSE, @intCast(pipe1[0]));
    _ = sys1(SYS_CLOSE, @intCast(pipe1[1]));
    _ = sys1(SYS_CLOSE, @intCast(pipe2[0]));
    _ = sys1(SYS_CLOSE, @intCast(pipe2[1]));

    // Wait for all 3 children
    var st1: i32 = -1;
    var st2: i32 = -1;
    var st3: i32 = -1;
    _ = sys4(SYS_WAIT4, @intCast(pid1), @intFromPtr(&st1), 0, 0);
    _ = sys4(SYS_WAIT4, @intCast(pid2), @intFromPtr(&st2), 0, 0);
    _ = sys4(SYS_WAIT4, @intCast(pid3), @intFromPtr(&st3), 0, 0);

    if (st1 != 0 or st2 != 0 or st3 != 0) {
        fail(306, "Multi-stage pipeline child process failed exit code verification");
    }

    print("[ADVERSARIAL_TEST] PASS: Multi-stage 3-process IPC pipeline verified cleanly.\n");

    // =========================================================================
    // Challenge 4: O_CLOEXEC Propagation Across sys_execve
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 4: O_CLOEXEC propagation across sys_execve...\n");

    var pfd_cloexec: [2]i32 = .{ -1, -1 };
    var pfd_nocloexec: [2]i32 = .{ -1, -1 };

    // Allocate pipe2 with O_CLOEXEC -> fds 3 and 4
    if (sys2(SYS_PIPE2, @intFromPtr(&pfd_cloexec), O_CLOEXEC) != 0) fail(401, "pipe2 cloexec failed");
    // Allocate pipe2 without O_CLOEXEC -> fds 5 and 6
    if (sys2(SYS_PIPE2, @intFromPtr(&pfd_nocloexec), 0) != 0) fail(402, "pipe2 non-cloexec failed");

    var dbg_buf: [128]u8 = undefined;
    const dbg_str = std.fmt.bufPrint(&dbg_buf, "[PARENT_ALLOC] pfd_cloexec=[{d}, {d}], pfd_nocloexec=[{d}, {d}]\n", .{
        pfd_cloexec[0], pfd_cloexec[1], pfd_nocloexec[0], pfd_nocloexec[1],
    }) catch "";
    print(dbg_str);

    // Duplicate fd 5 to fd 10 with O_CLOEXEC
    if (sys3(SYS_DUP3, @intCast(pfd_nocloexec[0]), 10, O_CLOEXEC) != 10) fail(403, "dup3 to 10 cloexec failed");
    // Duplicate fd 6 to fd 11 without O_CLOEXEC
    if (sys3(SYS_DUP3, @intCast(pfd_nocloexec[1]), 11, 0) != 11) fail(404, "dup3 to 11 non-cloexec failed");

    var arg_clo_r: [16]u8 = undefined;
    var arg_clo_w: [16]u8 = undefined;
    var arg_clo_dup: [16]u8 = undefined;
    var arg_noclo_w: [16]u8 = undefined;
    var arg_noclo_dup: [16]u8 = undefined;

    const s_clo_r = std.fmt.bufPrintZ(&arg_clo_r, "{d}", .{pfd_cloexec[0]}) catch "";
    const s_clo_w = std.fmt.bufPrintZ(&arg_clo_w, "{d}", .{pfd_cloexec[1]}) catch "";
    const s_clo_dup = std.fmt.bufPrintZ(&arg_clo_dup, "{d}", .{10}) catch "";
    const s_noclo_w = std.fmt.bufPrintZ(&arg_noclo_w, "{d}", .{pfd_nocloexec[1]}) catch "";
    const s_noclo_dup = std.fmt.bufPrintZ(&arg_noclo_dup, "{d}", .{11}) catch "";

    const exec_pid = sys0(SYS_FORK);
    if (exec_pid < 0) fail(405, "fork for execve failed");
    if (exec_pid == 0) {
        // In child: execute helper with FD arguments
        const prog: [*:0]const u8 = "/bin/adversarial_cloexec_child";
        var argv = [7]usize{
            @intFromPtr(prog),
            @intFromPtr(s_clo_r.ptr),
            @intFromPtr(s_clo_w.ptr),
            @intFromPtr(s_clo_dup.ptr),
            @intFromPtr(s_noclo_w.ptr),
            @intFromPtr(s_noclo_dup.ptr),
            0,
        };
        var envp = [1]usize{0};
        _ = sys3(SYS_EXECVE, @intFromPtr(prog), @intFromPtr(&argv), @intFromPtr(&envp));
        _ = sys1(SYS_EXIT, 127);
        unreachable;
    }

    // In parent: read from non-cloexec read end (fd 5) to receive child messages
    var exec_recv_buf: [64]u8 = undefined;
    var exec_recv_len: usize = 0;
    while (exec_recv_len < 34) {
        const nr = sys3(SYS_READ, @intCast(pfd_nocloexec[0]), @intFromPtr(&exec_recv_buf[exec_recv_len]), exec_recv_buf.len - exec_recv_len);
        if (nr <= 0) break;
        exec_recv_len += @intCast(nr);
    }

    var exec_st: i32 = -1;
    _ = sys4(SYS_WAIT4, @intCast(exec_pid), @intFromPtr(&exec_st), 0, 0);

    // Close remaining pipe ends in parent
    _ = sys1(SYS_CLOSE, @intCast(pfd_cloexec[0]));
    _ = sys1(SYS_CLOSE, @intCast(pfd_cloexec[1]));
    _ = sys1(SYS_CLOSE, @intCast(pfd_nocloexec[0]));
    _ = sys1(SYS_CLOSE, @intCast(pfd_nocloexec[1]));
    _ = sys1(SYS_CLOSE, 10);
    _ = sys1(SYS_CLOSE, 11);

    if (exec_st != 0) {
        fail(406, "adversarial_cloexec_child exited with non-zero status");
    }
    const expected_exec_recv = "PIPE_NOCLOEXEC_OKDUP3_NOCLOEXEC_OK";
    if (exec_recv_len != expected_exec_recv.len or !std.mem.eql(u8, exec_recv_buf[0..exec_recv_len], expected_exec_recv)) {
        fail(407, "Unexpected content received from non-CLOEXEC descriptors");
    }

    print("[ADVERSARIAL_TEST] PASS: O_CLOEXEC closure and non-CLOEXEC persistence verified cleanly.\n");

    // =========================================================================
    // Challenge 5: /proc Virtual Files (Multiple Reads, Offset Reads, pread64)
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 5: /proc/version and /proc/meminfo reads...\n");

    // 5.1 Multiple chunked reads on /proc/version
    const vfd = sys3(SYS_OPEN, @intFromPtr("/proc/version"), 0, 0);
    if (vfd < 0) fail(501, "open /proc/version failed");

    var ver_full_buf: [128]u8 = undefined;
    var ver_pos: usize = 0;
    var chunk_reads: usize = 0;
    while (true) {
        const nr = sys3(SYS_READ, @intCast(vfd), @intFromPtr(&ver_full_buf[ver_pos]), 7);
        if (nr < 0) fail(502, "read /proc/version failed");
        if (nr == 0) break; // EOF
        ver_pos += @intCast(nr);
        chunk_reads += 1;
    }
    if (chunk_reads < 2) fail(503, "Expected multiple chunked reads for /proc/version");
    const exp_ver = "Linux version 6.6.0-tinux (zig@tinux) #1 SMP PREEMPT Tinux 2026\n";
    if (ver_pos != exp_ver.len or !std.mem.eql(u8, ver_full_buf[0..ver_pos], exp_ver)) {
        fail(504, "/proc/version content mismatch");
    }

    // 5.2 lseek offset read on /proc/version
    // Seek to offset 6 ("version...")
    const sk1 = sys3(SYS_LSEEK, @intCast(vfd), 6, SEEK_SET);
    if (sk1 != 6) fail(505, "lseek SEEK_SET 6 failed");
    var piece_buf: [16]u8 = undefined;
    const np1 = sys3(SYS_READ, @intCast(vfd), @intFromPtr(&piece_buf), 7);
    if (np1 != 7 or !std.mem.eql(u8, piece_buf[0..7], "version")) {
        fail(506, "lseek offset read mismatch");
    }

    // Seek from end: last 8 bytes (" 2026\n")
    const sk2 = sys3(SYS_LSEEK, @intCast(vfd), @as(usize, @bitCast(@as(isize, -7))), SEEK_END);
    if (sk2 != @as(isize, @intCast(exp_ver.len - 7))) fail(507, "lseek SEEK_END -7 failed");
    const np2 = sys3(SYS_READ, @intCast(vfd), @intFromPtr(&piece_buf), 7);
    if (np2 != 7 or !std.mem.eql(u8, piece_buf[0..7], "x 2026\n")) {
        fail(508, "lseek SEEK_END read mismatch");
    }

    // 5.3 pread64 on /proc/version (does not mutate offset)
    const cur_pos_before = sys3(SYS_LSEEK, @intCast(vfd), 0, SEEK_CUR);
    var pread_buf: [16]u8 = undefined;
    const pr_cnt = sys4(SYS_PREAD64, @intCast(vfd), @intFromPtr(&pread_buf), 7, 6);
    if (pr_cnt != 7 or !std.mem.eql(u8, pread_buf[0..7], "version")) {
        fail(509, "pread64 on /proc/version failed");
    }
    const cur_pos_after = sys3(SYS_LSEEK, @intCast(vfd), 0, SEEK_CUR);
    if (cur_pos_before != cur_pos_after) {
        fail(510, "pread64 mutated file offset");
    }
    _ = sys1(SYS_CLOSE, @intCast(vfd));

    // 5.4 Multiple reads and rewind on /proc/meminfo
    const mfd = sys3(SYS_OPEN, @intFromPtr("/proc/meminfo"), 0, 0);
    if (mfd < 0) fail(511, "open /proc/meminfo failed");
    var mem_buf: [256]u8 = undefined;
    var mem_pos: usize = 0;
    while (true) {
        const mr = sys3(SYS_READ, @intCast(mfd), @intFromPtr(&mem_buf[mem_pos]), 16);
        if (mr <= 0) break;
        mem_pos += @intCast(mr);
    }
    if (mem_pos == 0) fail(512, "Empty read from /proc/meminfo");
    const mem_str = mem_buf[0..mem_pos];
    if (std.mem.indexOf(u8, mem_str, "MemTotal:") == null or std.mem.indexOf(u8, mem_str, "kB\n") == null) {
        fail(513, "/proc/meminfo content missing MemTotal / kB");
    }

    // Rewind with lseek(0, SEEK_SET) and read again
    const msk = sys3(SYS_LSEEK, @intCast(mfd), 0, SEEK_SET);
    if (msk != 0) fail(514, "lseek rewind on /proc/meminfo failed");
    var mem_rewind: [9]u8 = undefined;
    const mr2 = sys3(SYS_READ, @intCast(mfd), @intFromPtr(&mem_rewind), 9);
    if (mr2 != 9 or !std.mem.eql(u8, mem_rewind[0..9], "MemTotal:")) {
        fail(515, "rewind read on /proc/meminfo mismatch");
    }
    _ = sys1(SYS_CLOSE, @intCast(mfd));

    // 5.5 Independent file descriptors on /proc/version
    const fd_a = sys3(SYS_OPEN, @intFromPtr("/proc/version"), 0, 0);
    const fd_b = sys3(SYS_OPEN, @intFromPtr("/proc/version"), 0, 0);
    if (fd_a < 0 or fd_b < 0) fail(516, "dual open /proc/version failed");

    var piece_a: [5]u8 = undefined;
    var piece_b: [5]u8 = undefined;
    _ = sys3(SYS_READ, @intCast(fd_a), @intFromPtr(&piece_a), 5);
    _ = sys3(SYS_READ, @intCast(fd_b), @intFromPtr(&piece_b), 5);
    if (!std.mem.eql(u8, piece_a[0..5], "Linux") or !std.mem.eql(u8, piece_b[0..5], "Linux")) {
        fail(517, "independent descriptors did not both read from offset 0");
    }

    _ = sys3(SYS_READ, @intCast(fd_a), @intFromPtr(&piece_a), 5);
    if (!std.mem.eql(u8, piece_a[0..5], " vers")) {
        fail(518, "fd_a did not advance independently");
    }
    // fd_b should still be at offset 5
    _ = sys3(SYS_READ, @intCast(fd_b), @intFromPtr(&piece_b), 5);
    if (!std.mem.eql(u8, piece_b[0..5], " vers")) {
        fail(519, "fd_b offset was affected by fd_a");
    }

    _ = sys1(SYS_CLOSE, @intCast(fd_a));
    _ = sys1(SYS_CLOSE, @intCast(fd_b));

    print("[ADVERSARIAL_TEST] PASS: /proc multiple reads, offsets, pread64, & independence verified.\n");

    print("\n[ADVERSARIAL_TEST] ALL CHALLENGES PASSED EMPIRICALLY!\n");
    _ = sys1(SYS_EXIT, 0);
    unreachable;
}
