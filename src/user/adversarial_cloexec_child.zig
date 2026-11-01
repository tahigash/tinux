// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Adversarial child helper to verify O_CLOEXEC descriptor closure upon sys_execve

const std = @import("std");

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call childMain
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

fn print(msg: []const u8) void {
    _ = sys3(1, 1, @intFromPtr(msg.ptr), msg.len);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("[CLOEXEC_CHILD_FAIL] ");
    print(msg);
    print("\n");
    _ = sys1(60, code);
    unreachable;
}

fn parseUsize(s: []const u8) ?usize {
    var val: usize = 0;
    if (s.len == 0) return null;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

pub export fn childMain(initial_rsp: [*]const usize) callconv(.C) noreturn {
    print("[CLOEXEC_CHILD] Verifying descriptors across execve...\n");

    const argc = initial_rsp[0];
    if (argc < 6) {
        fail(99, "Expected 5 FD arguments: cloexec_r cloexec_w cloexec_dup nocloexec_w nocloexec_dup");
    }

    const clo_r_str = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(initial_rsp[2])), 0);
    const clo_w_str = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(initial_rsp[3])), 0);
    const clo_dup_str = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(initial_rsp[4])), 0);
    const noclo_w_str = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(initial_rsp[5])), 0);
    const noclo_dup_str = std.mem.sliceTo(@as([*:0]const u8, @ptrFromInt(initial_rsp[6])), 0);

    const clo_r = parseUsize(clo_r_str) orelse fail(10, "Invalid clo_r");
    const clo_w = parseUsize(clo_w_str) orelse fail(11, "Invalid clo_w");
    const clo_dup = parseUsize(clo_dup_str) orelse fail(12, "Invalid clo_dup");
    const noclo_w = parseUsize(noclo_w_str) orelse fail(13, "Invalid noclo_w");
    const noclo_dup = parseUsize(noclo_dup_str) orelse fail(14, "Invalid noclo_dup");

    var dbg_child: [128]u8 = undefined;
    const dbg_child_str = std.fmt.bufPrint(&dbg_child, "[CLOEXEC_CHILD] Testing clo=[{d}, {d}, {d}], noclo=[{d}, {d}]\n", .{
        clo_r, clo_w, clo_dup, noclo_w, noclo_dup,
    }) catch "";
    print(dbg_child_str);

    var buf: [32]u8 = undefined;

    // pipe read with O_CLOEXEC -> must be closed (-EBADF = -9)
    const r_clo_r = sys3(0, clo_r, @intFromPtr(&buf), buf.len);
    if (r_clo_r != -9) {
        fail(1, "cloexec pipe read remained open across execve!");
    }

    // pipe write with O_CLOEXEC -> must be closed (-EBADF = -9)
    const r_clo_w = sys3(1, clo_w, @intFromPtr("test"), 4);
    if (r_clo_w != -9) {
        fail(2, "cloexec pipe write remained open across execve!");
    }

    // dup3 with O_CLOEXEC -> must be closed (-EBADF = -9)
    const r_clo_dup = sys3(0, clo_dup, @intFromPtr(&buf), buf.len);
    if (r_clo_dup != -9) {
        fail(3, "dup3 O_CLOEXEC fd remained open across execve!");
    }

    // pipe write without O_CLOEXEC -> must remain open and writable
    const msg_noclo = "PIPE_NOCLOEXEC_OK";
    const r_noclo_w = sys3(1, noclo_w, @intFromPtr(msg_noclo.ptr), msg_noclo.len);
    if (r_noclo_w != @as(isize, @intCast(msg_noclo.len))) {
        fail(4, "non-CLOEXEC pipe write failed!");
    }

    // dup3 without O_CLOEXEC -> must remain open and writable
    const msg_noclo_dup = "DUP3_NOCLOEXEC_OK";
    const r_noclo_dup = sys3(1, noclo_dup, @intFromPtr(msg_noclo_dup.ptr), msg_noclo.len);
    if (r_noclo_dup != @as(isize, @intCast(msg_noclo_dup.len))) {
        fail(5, "non-CLOEXEC dup3 write failed!");
    }

    print("[CLOEXEC_CHILD] All descriptor assertions passed cleanly!\n");
    _ = sys1(60, 0); // Exit 0
    unreachable;
}
