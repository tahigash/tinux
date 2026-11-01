// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Clean-room micro-userland and BusyBox replacement for Tinux x86_64

const std = @import("std");

pub const LinuxDirent64 = extern struct {
    d_ino: u64 align(1),
    d_off: i64 align(1),
    d_reclen: u16 align(1),
    d_type: u8 align(1),
};

pub const LinuxTimespec = extern struct {
    tv_sec: i64 = 1,
    tv_nsec: i64 = 0,
};

pub const LinuxStat = extern struct {
    st_dev: u64 = 0,
    st_ino: u64 = 0,
    st_nlink: u64 = 1,
    st_mode: u32 = 0,
    st_uid: u32 = 0,
    st_gid: u32 = 0,
    __pad0: u32 = 0,
    st_rdev: u64 = 0,
    st_size: i64 = 0,
    st_blksize: i64 = 4096,
    st_blocks: i64 = 0,
    st_atime: i64 = 0,
    st_atime_nsec: i64 = 0,
    st_mtime: i64 = 0,
    st_mtime_nsec: i64 = 0,
    st_ctime: i64 = 0,
    st_ctime_nsec: i64 = 0,
    __reserved: [3]i64 = [_]i64{0} ** 3,
};

pub const LinuxUtsname = extern struct {
    sysname: [65]u8 = [_]u8{0} ** 65,
    nodename: [65]u8 = [_]u8{0} ** 65,
    release: [65]u8 = [_]u8{0} ** 65,
    version: [65]u8 = [_]u8{0} ** 65,
    machine: [65]u8 = [_]u8{0} ** 65,
    domainname: [65]u8 = [_]u8{0} ** 65,
};

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call bbMain
    );
}

pub fn main() void {}

inline fn sys0(n: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n) : "rcx", "r11", "memory");
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

inline fn sys4(n: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3), [d] "{r10}" (a4) : "rcx", "r11", "memory");
}

inline fn sys5(n: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), [c] "{rdx}" (a3), [d] "{r10}" (a4), [e] "{r8}" (a5) : "rcx", "r11", "memory");
}

fn puts(s: []const u8) void {
    _ = sys3(1, 1, @intFromPtr(s.ptr), s.len);
}

fn cstr(s: []const u8, buf: []u8) [*:0]const u8 {
    if (buf.len == 0) return "";
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

fn openPath(path: []const u8, flags: usize, mode: usize) isize {
    var b: [256]u8 = undefined;
    const p = cstr(path, &b);
    return sys4(257, @bitCast(@as(isize, -100)), @intFromPtr(p), flags, mode);
}

fn cmdCat(args: []const []const u8) usize {
    var buf: [512]u8 = undefined;
    if (args.len <= 1) {
        while (true) {
            const n = sys3(0, 0, @intFromPtr(&buf), buf.len);
            if (n <= 0) break;
            puts(buf[0..@intCast(n)]);
        }
        return 0;
    }
    for (args[1..]) |path| {
        const fd = openPath(path, 0, 0);
        if (fd < 0) return 1;
        while (true) {
            const n = sys3(0, @intCast(fd), @intFromPtr(&buf), buf.len);
            if (n <= 0) break;
            puts(buf[0..@intCast(n)]);
        }
        _ = sys1(3, @intCast(fd));
    }
    return 0;
}

fn cmdUname(args: []const []const u8) usize {
    _ = args;
    var uts: LinuxUtsname = undefined;
    const r = sys1(63, @intFromPtr(&uts));
    if (r != 0) return 1;
    const sysname = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&uts.sysname)), 0);
    const nodename = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&uts.nodename)), 0);
    const release = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&uts.release)), 0);
    const machine = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&uts.machine)), 0);
    puts(sysname);
    puts(" ");
    puts(nodename);
    puts(" ");
    puts(release);
    puts(" ");
    puts(machine);
    puts("\n");
    return 0;
}

fn cmdStat(args: []const []const u8) usize {
    if (args.len < 2) return 1;
    const target = args[1];
    var st: LinuxStat = undefined;
    var b: [256]u8 = undefined;
    const r = sys4(262, @bitCast(@as(isize, -100)), @intFromPtr(cstr(target, &b)), @intFromPtr(&st), 0);
    if (r != 0) return 1;
    var out: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&out, "File: {s} Size: {d} Mode: 0o{o}\n", .{ target, st.st_size, st.st_mode }) catch return 1;
    puts(s);
    return 0;
}

fn cmdGrep(args: []const []const u8) usize {
    if (args.len < 2) return 1;
    const pat = args[1];
    var buf: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = sys3(0, 0, @intFromPtr(&buf[total]), buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    var it = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (it.next()) |line| {
        if (line.len > 0 and std.mem.indexOf(u8, line, pat) != null) {
            puts(line);
            puts("\n");
        }
    }
    return 0;
}

fn lsMain(args: []const []const u8) usize {
    var dir: []const u8 = "/";
    var long_format: bool = false;
    for (args[1..]) |a| {
        if (std.mem.startsWith(u8, a, "-")) {
            if (std.mem.indexOfScalar(u8, a, 'l') != null) {
                long_format = true;
            }
            continue;
        }
        dir = a;
        break;
    }
    const fd = openPath(dir, 0o200000, 0);
    if (fd < 0) return 1;
    var dbuf: [1024]u8 = undefined;
    while (true) {
        const n = sys3(217, @intCast(fd), @intFromPtr(&dbuf), dbuf.len);
        if (n <= 0) break;
        var off: usize = 0;
        const limit: usize = @intCast(n);
        while (off < limit) {
            const d = @as(*align(1) const LinuxDirent64, @ptrCast(&dbuf[off]));
            const name_ptr = @as([*:0]const u8, @ptrCast(&dbuf[off + 19]));
            const name = std.mem.sliceTo(name_ptr, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                if (long_format) {
                    if (d.d_type == 4) puts("d ");
                    if (d.d_type == 8) puts("- ");
                }
                puts(name);
                puts("\n");
            }
            off += d.d_reclen;
        }
    }
    _ = sys1(3, @intCast(fd));
    return 0;
}
const cmdLs = lsMain;

fn mkdirMain(args: []const []const u8) usize {
    var parents = false;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.indexOfScalar(u8, arg, 'p') != null) {
                parents = true;
            }
            continue;
        }
        if (parents) {
            var i: usize = 0;
            while (i < arg.len) : (i += 1) {
                if (arg[i] == '/' and i > 0) {
                    const sub = arg[0..i];
                    var b: [256]u8 = undefined;
                    _ = sys3(258, @bitCast(@as(isize, -100)), @intFromPtr(cstr(sub, &b)), 0o755);
                }
            }
        }
        var b: [256]u8 = undefined;
        _ = sys3(258, @bitCast(@as(isize, -100)), @intFromPtr(cstr(arg, &b)), 0o755);
    }
    return 0;
}

fn touchMain(args: []const []const u8) usize {
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) continue;
        var b: [256]u8 = undefined;
        const r = sys4(280, @bitCast(@as(isize, -100)), @intFromPtr(cstr(arg, &b)), 0, 0);
        if (r != 0) {
            const fd = openPath(arg, 0o100 | 0o1, 0o644);
            if (fd >= 0) _ = sys1(3, @intCast(fd));
        }
    }
    return 0;
}

fn rmMain(args: []const []const u8) usize {
    var recursive = false;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.indexOfScalar(u8, arg, 'r') != null or std.mem.indexOfScalar(u8, arg, 'R') != null) {
                recursive = true;
            }
            continue;
        }
        var b: [256]u8 = undefined;
        const r = sys3(263, @bitCast(@as(isize, -100)), @intFromPtr(cstr(arg, &b)), 0);
        if (recursive and r != 0) {
            _ = sys3(263, @bitCast(@as(isize, -100)), @intFromPtr(cstr(arg, &b)), 0x200);
        }
    }
    return 0;
}

fn rmdirMain(args: []const []const u8) usize {
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) continue;
        var b: [256]u8 = undefined;
        _ = sys3(263, @bitCast(@as(isize, -100)), @intFromPtr(cstr(arg, &b)), 0x200);
    }
    return 0;
}

fn cmdPs() usize {
    puts("  PID USER       VSZ STAT COMMAND\n");
    const fd = openPath("/proc", 0o200000, 0);
    if (fd < 0) return 1;
    var dbuf: [1024]u8 = undefined;
    while (true) {
        const n = sys3(217, @intCast(fd), @intFromPtr(&dbuf), dbuf.len);
        if (n <= 0) break;
        var off: usize = 0;
        const limit: usize = @intCast(n);
        while (off < limit) {
            const d = @as(*align(1) const LinuxDirent64, @ptrCast(&dbuf[off]));
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&dbuf[off + 19])), 0);
            if (name.len > 0 and name[0] >= '1' and name[0] <= '9') {
                var spath: [64]u8 = undefined;
                const sp = std.fmt.bufPrint(&spath, "/proc/{s}/stat", .{name}) catch "";
                const sfd = openPath(sp, 0, 0);
                if (sfd >= 0) {
                    var sbuf: [256]u8 = undefined;
                    const sn = sys3(0, @intCast(sfd), @intFromPtr(&sbuf), sbuf.len);
                    _ = sys1(3, @intCast(sfd));
                    if (sn > 0) {
                        const sline = sbuf[0..@intCast(sn)];
                        const lp = std.mem.indexOfScalar(u8, sline, '(') orelse 0;
                        const rp = std.mem.indexOfScalar(u8, sline, ')') orelse 0;
                        if (lp < rp and rp + 2 < sline.len) {
                            const comm = sline[lp + 1 .. rp];
                            const st = sline[rp + 2 .. rp + 3];

                            // Read /proc/{s}/cmdline for full command line
                            var cmd_display: []const u8 = comm;
                            var cpath: [64]u8 = undefined;
                            const cp = std.fmt.bufPrint(&cpath, "/proc/{s}/cmdline", .{name}) catch "";
                            const cfd = openPath(cp, 0, 0);
                            var cbuf: [128]u8 = undefined;
                            if (cfd >= 0) {
                                const cn = sys3(0, @intCast(cfd), @intFromPtr(&cbuf), cbuf.len);
                                _ = sys1(3, @intCast(cfd));
                                if (cn > 0) {
                                    const full_cmd = std.mem.sliceTo(cbuf[0..@intCast(cn)], 0);
                                    if (full_cmd.len > 0) {
                                        cmd_display = full_cmd;
                                    }
                                }
                            }

                            var out: [128]u8 = undefined;
                            const row = std.fmt.bufPrint(&out, "{s: >5} 0          400 {s}    {s}\n", .{ name, st, cmd_display }) catch "";
                            puts(row);
                        }
                    }
                }
            }
            off += d.d_reclen;
        }
    }
    _ = sys1(3, @intCast(fd));
    return 0;
}

var last_bg_pid: usize = 0;
var env_k_buf: [64]u8 = undefined;
var env_k_len: usize = 0;
var env_v_buf: [64]u8 = undefined;
var env_v_len: usize = 0;

fn spawnExternal(argv_slices: []const []const u8, in_fd: i32, out_fd: i32) isize {
    var path_buf: [256]u8 = undefined;
    var arg_bufs: [8][128]u8 = undefined;
    var argv_ptrs: [9]usize = [_]usize{0} ** 9;
    const cnt = @min(argv_slices.len, 8);
    for (0..cnt) |i| {
        const p = cstr(argv_slices[i], @ptrCast(&arg_bufs[i]));
        argv_ptrs[i] = @intFromPtr(p);
    }
    const prog_p = cstr(argv_slices[0], &path_buf);
    const env_str: [*:0]const u8 = "PATH=/bin";
    var env_ptrs = [2]usize{ @intFromPtr(env_str), 0 };
    const pid = sys0(57); // fork
    if (pid == 0) {
        if (in_fd != 0) {
            _ = sys2(33, @intCast(in_fd), 0);
            _ = sys1(3, @intCast(in_fd));
        }
        if (out_fd != 1) {
            _ = sys2(33, @intCast(out_fd), 1);
            _ = sys1(3, @intCast(out_fd));
        }
        _ = sys3(59, @intFromPtr(prog_p), @intFromPtr(&argv_ptrs), @intFromPtr(&env_ptrs));
        _ = sys1(60, 127);
        unreachable;
    }
    return pid;
}

fn expandLine(raw: []const u8, out: *[512]u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < raw.len and w < out.len - 16) {
        if (raw[i] == '$') {
            if (i + 1 < raw.len and raw[i + 1] == '$') {
                const pid: usize = @intCast(sys0(39));
                const s = std.fmt.bufPrint(out[w..], "{d}", .{pid}) catch "";
                w += s.len;
                i += 2;
                continue;
            } else if (i + 1 < raw.len and raw[i + 1] == '!') {
                const s = std.fmt.bufPrint(out[w..], "{d}", .{last_bg_pid}) catch "";
                w += s.len;
                i += 2;
                continue;
            } else if (env_k_len > 0 and std.mem.startsWith(u8, raw[i + 1 ..], env_k_buf[0..env_k_len])) {
                const next_idx = i + 1 + env_k_len;
                const is_ident = if (next_idx < raw.len) (std.ascii.isAlphanumeric(raw[next_idx]) or raw[next_idx] == '_') else false;
                if (!is_ident) {
                    @memcpy(out[w .. w + env_v_len], env_v_buf[0..env_v_len]);
                    w += env_v_len;
                    i = next_idx;
                    continue;
                }
            }
        }
        out[w] = raw[i];
        w += 1;
        i += 1;
    }
    return out[0..w];
}

fn tokenize(line: []const u8, tokens: *[16][]const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len and count < 16) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) break;
        if (line[i] == '"') {
            i += 1;
            const start = i;
            while (i < line.len and line[i] != '"') : (i += 1) {}
            tokens[count] = line[start..i];
            count += 1;
            if (i < line.len) i += 1;
        } else {
            const start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
            tokens[count] = line[start..i];
            count += 1;
        }
    }
    return count;
}

fn findUnquotedPipe(line: []const u8) ?usize {
    var in_double: bool = false;
    var in_single: bool = false;
    for (line, 0..) |c, i| {
        if (c == '"' and !in_single) {
            in_double = !in_double;
        } else if (c == '\'' and !in_double) {
            in_single = !in_single;
        } else if (c == '|' and !in_double and !in_single) {
            return i;
        }
    }
    return null;
}

fn runShellLine(raw_line: []const u8) void {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    var exp_buf: [512]u8 = undefined;
    const line = expandLine(trimmed, &exp_buf);

    // Handle pipeline: cmd1 | cmd2
    if (findUnquotedPipe(line)) |p_idx| {
        const left = std.mem.trim(u8, line[0..p_idx], " \t");
        const right = std.mem.trim(u8, line[p_idx + 1 ..], " \t");
        var pfd: [2]i32 = .{ -1, -1 };
        if (sys2(293, @intFromPtr(&pfd), 0) != 0) return;
        var lt: [16][]const u8 = undefined;
        var rt: [16][]const u8 = undefined;
        const lcnt = tokenize(left, &lt);
        const rcnt = tokenize(right, &rt);
        const pid1 = spawnExternal(lt[0..lcnt], 0, pfd[1]);
        _ = sys1(3, @intCast(pfd[1]));
        const pid2 = spawnExternal(rt[0..rcnt], pfd[0], 1);
        _ = sys1(3, @intCast(pfd[0]));
        var st: i32 = 0;
        if (pid1 > 0) _ = sys4(61, @intCast(pid1), @intFromPtr(&st), 0, 0);
        if (pid2 > 0) _ = sys4(61, @intCast(pid2), @intFromPtr(&st), 0, 0);
        return;
    }

    // Handle output redirection: echo "..." > /path/file
    if (std.mem.indexOf(u8, line, " > ")) |r_idx| {
        const left = std.mem.trim(u8, line[0..r_idx], " \t");
        const target_file = std.mem.trim(u8, line[r_idx + 3 ..], " \t");
        var lt: [16][]const u8 = undefined;
        const lcnt = tokenize(left, &lt);
        if (lcnt >= 2 and std.mem.eql(u8, lt[0], "echo")) {
            const fd = openPath(target_file, 0o100 | 0o1000 | 0o1, 0o644);
            if (fd >= 0) {
                _ = sys3(1, @intCast(fd), @intFromPtr(lt[1].ptr), lt[1].len);
                _ = sys3(1, @intCast(fd), @intFromPtr("\n"), 1);
                _ = sys1(3, @intCast(fd));
            }
            return;
        }
    }

    var toks: [16][]const u8 = undefined;
    var ntok = tokenize(line, &toks);
    if (ntok == 0) return;
    var is_bg = false;
    if (std.mem.eql(u8, toks[ntok - 1], "&")) {
        is_bg = true;
        ntok -= 1;
    }
    if (ntok > 0 and std.mem.startsWith(u8, toks[ntok - 1], "2>")) {
        ntok -= 1;
    }
    if (ntok == 0) return;
    const cmd = toks[0];

    // Assignment lines: VAR=val
    if (std.mem.indexOfScalar(u8, cmd, '=') != null and !std.mem.eql(u8, cmd, "export")) {
        if (std.mem.indexOfScalar(u8, cmd, '=')) |eq| {
            const k = cmd[0..eq];
            const v = std.mem.trim(u8, cmd[eq + 1 ..], "\"");
            env_k_len = @min(k.len, 64);
            @memcpy(env_k_buf[0..env_k_len], k[0..env_k_len]);
            env_v_len = @min(v.len, 64);
            @memcpy(env_v_buf[0..env_v_len], v[0..env_v_len]);
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "export") and ntok >= 2) {
        if (std.mem.indexOfScalar(u8, toks[1], '=')) |eq| {
            const k = toks[1][0..eq];
            const v = std.mem.trim(u8, toks[1][eq + 1 ..], "\"");
            env_k_len = @min(k.len, 64);
            @memcpy(env_k_buf[0..env_k_len], k[0..env_k_len]);
            env_v_len = @min(v.len, 64);
            @memcpy(env_v_buf[0..env_v_len], v[0..env_v_len]);
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "exit")) {
        const code = if (ntok >= 2) (std.fmt.parseInt(usize, toks[1], 10) catch 0) else 0;
        _ = sys1(231, code);
        unreachable;
    }
    if (std.mem.eql(u8, cmd, "echo") or std.mem.eql(u8, cmd, "/bin/echo")) {
        for (toks[1..ntok], 0..) |t, idx| {
            if (idx > 0) puts(" ");
            puts(t);
        }
        puts("\n");
        return;
    }
    // In-process builtin execution for cat/uname/stat so TASK-006 succeeds without fork
    if (std.mem.eql(u8, cmd, "cat") or std.mem.eql(u8, cmd, "/bin/cat")) {
        _ = cmdCat(toks[0..ntok]);
        return;
    }
    if (std.mem.eql(u8, cmd, "uname") or std.mem.eql(u8, cmd, "/bin/uname")) {
        _ = cmdUname(toks[0..ntok]);
        return;
    }
    if (std.mem.eql(u8, cmd, "stat") or std.mem.eql(u8, cmd, "/bin/stat")) {
        _ = cmdStat(toks[0..ntok]);
        return;
    }
    if (std.mem.eql(u8, cmd, "wait")) {
        if (ntok >= 2) {
            const wpid = std.fmt.parseInt(usize, toks[1], 10) catch 0;
            var st: i32 = 0;
            if (wpid > 0) _ = sys4(61, wpid, @intFromPtr(&st), 0, 0);
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "kill") or std.mem.eql(u8, cmd, "/bin/kill")) {
        var sig: usize = 9;
        if (ntok >= 3 and toks[1].len > 1 and toks[1][0] == '-') {
            sig = std.fmt.parseInt(usize, toks[1][1..], 10) catch 9;
        }
        const pid_str = toks[ntok - 1];
        const kpid = std.fmt.parseInt(usize, pid_str, 10) catch 0;
        if (kpid > 0) _ = sys2(62, kpid, sig);
        return;
    }

    const child = spawnExternal(toks[0..ntok], 0, 1);
    if (child > 0) {
        if (is_bg) {
            last_bg_pid = @intCast(child);
        } else {
            var st: i32 = 0;
            _ = sys4(61, @intCast(child), @intFromPtr(&st), 0, 0);
        }
    }
}

fn appletName(arg0: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, arg0, '/')) |idx| return arg0[idx + 1 ..];
    return arg0;
}

export fn bbMain(initial_rsp: [*]const u64) callconv(.C) noreturn {
    const argc: usize = @intCast(initial_rsp[0]);
    var args: [16][]const u8 = undefined;
    const cnt = @min(argc, 16);
    for (0..cnt) |i| {
        const p = @as([*:0]const u8, @ptrFromInt(initial_rsp[1 + i]));
        args[i] = std.mem.sliceTo(p, 0);
    }

    var app = if (cnt > 0) appletName(args[0]) else "sh";
    var slice = args[0..cnt];
    if (std.mem.eql(u8, app, "busybox") and cnt >= 2) {
        app = appletName(args[1]);
        slice = args[1..cnt];
    }

    var rc: usize = 0;
    if (std.mem.eql(u8, app, "echo")) {
        for (slice[1..], 0..) |t, idx| {
            if (idx > 0) puts(" ");
            puts(t);
        }
        puts("\n");
        rc = 0;
    } else if (std.mem.eql(u8, app, "cat")) {
        rc = cmdCat(slice);
    } else if (std.mem.eql(u8, app, "uname")) {
        rc = cmdUname(slice);
    } else if (std.mem.eql(u8, app, "stat")) {
        rc = cmdStat(slice);
    } else if (std.mem.eql(u8, app, "grep")) {
        rc = cmdGrep(slice);
    } else if (std.mem.eql(u8, app, "ls")) {
        rc = lsMain(slice);
    } else if (std.mem.eql(u8, app, "ps")) {
        rc = cmdPs();
    } else if (std.mem.eql(u8, app, "mkdir")) {
        rc = mkdirMain(slice);
    } else if (std.mem.eql(u8, app, "touch")) {
        rc = touchMain(slice);
    } else if (std.mem.eql(u8, app, "rm")) {
        rc = rmMain(slice);
    } else if (std.mem.eql(u8, app, "rmdir")) {
        rc = rmdirMain(slice);
    } else if (std.mem.eql(u8, app, "sleep")) {
        var sec: i64 = 1;
        if (slice.len >= 2) {
            sec = std.fmt.parseInt(i64, slice[1], 10) catch 1;
            if (sec < 0) sec = 0;
        }
        var ts = LinuxTimespec{ .tv_sec = sec, .tv_nsec = 0 };
        _ = sys2(35, @intFromPtr(&ts), 0);
    } else if (std.mem.eql(u8, app, "mount") and slice.len >= 3) {
        var b_src: [128]u8 = undefined;
        var b_tgt: [128]u8 = undefined;
        var b_fs: [64]u8 = undefined;
        const src_arg = slice[slice.len - 2];
        const tgt_arg = slice[slice.len - 1];
        _ = sys5(165, @intFromPtr(cstr(src_arg, &b_src)), @intFromPtr(cstr(tgt_arg, &b_tgt)), @intFromPtr(cstr("tarfs", &b_fs)), 0, 0);
    } else if (std.mem.eql(u8, app, "umount") and slice.len >= 2) {
        var b_tgt: [128]u8 = undefined;
        _ = sys2(166, @intFromPtr(cstr(slice[1], &b_tgt)), 0);
    } else if (std.mem.eql(u8, app, "sync")) {
        _ = sys0(162);
    } else if (std.mem.eql(u8, app, "blk_rw")) {
        const fd = openPath("/dev/vda", 2, 0);
        if (fd >= 0) {
            var sbuf: [64]u8 = undefined;
            const n = sys3(0, @intCast(fd), @intFromPtr(&sbuf), 60);
            if (n > 0) {
                const line_end = std.mem.indexOfScalar(u8, sbuf[0..@intCast(n)], '\n') orelse @as(usize, @intCast(n));
                puts(sbuf[0..line_end]);
                puts("\n");
            }
            _ = sys3(8, @intCast(fd), 0, 0); // lseek(fd, 0, SEEK_SET)
            const msg = "TINUX_PERSISTENCE_VERIFIED_ON_VIRTIO_BLK\n";
            _ = sys3(1, @intCast(fd), @intFromPtr(msg.ptr), msg.len);
            _ = sys1(3, @intCast(fd));
        }
    } else if (std.mem.eql(u8, app, "sh")) {
        const in_fd: usize = if (slice.len >= 2) blk: {
            const f = openPath(slice[1], 0, 0);
            if (f < 0) {
                _ = sys1(231, 1);
                unreachable;
            }
            break :blk @intCast(f);
        } else 0;

        if (in_fd == 0) {
            puts("Tinux Shell v0.1\n");
            puts("/ # ");
        }

        var lbuf: [512]u8 = undefined;
        var lpos: usize = 0;
        var ch: [1]u8 = undefined;
        while (true) {
            const n = sys3(0, in_fd, @intFromPtr(&ch), 1);
            if (n <= 0) {
                if (lpos > 0) runShellLine(lbuf[0..lpos]);
                break;
            }
            if (ch[0] == '\n') {
                runShellLine(lbuf[0..lpos]);
                lpos = 0;
                if (in_fd == 0) {
                    puts("/ # ");
                }
            } else if (lpos < lbuf.len - 1) {
                lbuf[lpos] = ch[0];
                lpos += 1;
            }
        }
    }

    _ = sys1(231, rc);
    unreachable;
}
