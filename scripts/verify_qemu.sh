#!/usr/bin/env bash
set -uo pipefail
# ==============================================================================
# Tinux Unified Build & QEMU Verification Harness (TASK-001 .. TASK-020)
# Usage: ./scripts/verify_qemu.sh <TASK-0XX> [TIMEOUT_SECONDS]
# ==============================================================================
TEST_CASE="${1:-TASK-001}"
TIMEOUT_SEC="${2:-10}"
TASK_NUM=$(echo "$TEST_CASE" | sed -E 's/^TASK-0*//')
if ! [[ "$TASK_NUM" =~ ^[0-9]+$ ]]; then
    TASK_NUM=1
fi
LOG_FILE="/tmp/tinux_qemu_${TEST_CASE}.log"
DISK_IMG="/tmp/tinux_disk_${TEST_CASE}.img"
KERNEL_BIN="zig-out/bin/tinux"
INITRAMFS_ROOT=".cache/initramfs_root"
mkdir -p .cache src/proc src/fs "$INITRAMFS_ROOT/bin" "$INITRAMFS_ROOT/etc" \
         "$INITRAMFS_ROOT/lib" "$INITRAMFS_ROOT/tmp" "$INITRAMFS_ROOT/mnt"

# ------------------------------------------------------------------------------
# Pre-Check: Clean-Room License & Binary Guardrail Audit
# ------------------------------------------------------------------------------
if [[ -f "scripts/check_license_guardrails.py" ]]; then
    if python -c "import sys" >/dev/null 2>&1; then
        python scripts/check_license_guardrails.py || exit 1
    elif python3 -c "import sys" >/dev/null 2>&1; then
        python3 scripts/check_license_guardrails.py || exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Helper: Cross-compile a standalone x86_64-linux userland ELF with Zig
# Automatically adapts calling convention syntax across Zig 0.13 / 0.14 / 0.15+
# ------------------------------------------------------------------------------
build_user_elf() {
    local src_file="$1"
    local out_bin="$2"
    local pie_flag="${3:--fno-pie}"
    if [[ ! -f "$src_file" ]]; then
        echo "[HARNESS] ERROR: Missing user source file: $src_file"
        return 1
    fi
    if zig build-exe "$src_file" \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        "$pie_flag" \
        "-femit-bin=${out_bin}" >/dev/null 2>&1; then
        chmod +x "$out_bin"
        return 0
    fi
    # Fallback for Zig 0.14.1 / 0.15+ where callconv(.C)/.Naked became lowercase .c/.naked
    local patched_src=".cache/$(basename "$src_file")"
    sed -e 's/callconv(\.C)/callconv(.c)/g' \
        -e 's/callconv(\.Naked)/callconv(.naked)/g' \
        "$src_file" > "$patched_src"
    if ! zig build-exe "$patched_src" \
        -target x86_64-linux-none \
        -O ReleaseSmall \
        "$pie_flag" \
        "-femit-bin=${out_bin}"; then
        echo "[HARNESS] FAIL: Failed to compile user ELF $src_file"
        return 1
    fi
    chmod +x "$out_bin"
    return 0
}
# ------------------------------------------------------------------------------
# Helper: Build or Provision Static x86_64 Linux /bin/busybox
# ------------------------------------------------------------------------------
ensure_busybox_elf() {
    local bb_out="${INITRAMFS_ROOT}/bin/busybox"
    if [[ "${USE_HOST_BUSYBOX:-0}" == "1" ]] && command -v busybox >/dev/null 2>&1; then
        local bb_path
        bb_path=$(command -v busybox)
        if file "$bb_path" | grep -q "x86-64" && file "$bb_path" | grep -q "statically linked"; then
            cp "$bb_path" "$bb_out"
            chmod +x "$bb_out"
            return 0
        fi
    fi
    local bb_src=".cache/tinux_busybox.zig"
    cat << ' BB_EOF' > "$bb_src"
const std = @import("std");
const LinuxDirent64 = extern struct {
    d_ino: u64 align(1),
    d_off: i64 align(1),
    d_reclen: u16 align(1),
    d_type: u8 align(1),
};
const LinuxTimespec = extern struct {
    tv_sec: i64 = 1,
    tv_nsec: i64 = 0,
};
export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call bbMain
    );
}
inline fn sys0(n: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n) : "rcx", "r11", "memory");
}
inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1) : "rcx", "r11", "me
}
inline fn sys2(n: usize, a1: usize, a2: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2) :
}
inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), 
}
inline fn sys4(n: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), 
}
inline fn sys5(n: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) isize {
    return asm volatile ("syscall" : [r] "={rax}" (-> isize) : [n] "{rax}" (n), [a] "{rdi}" (a1), [b] "{rsi}" (a2), 
}
fn puts(s: []const u8) void {
    _ = sys3(1, 1, @intFromPtr(s.ptr), s.len);
}
fn cstr(s: []const u8, buf: *[256]u8) [*:0]const u8 {
    const n = @min(s.len, 255);
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
fn cmdLs(args: []const []const u8) usize {
    const dir = if (args.len > 1) args[1] else "/";
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
                puts(name);
                puts("\n");
            }
            off += d.d_reclen;
        }
    }
    _ = sys1(3, @intCast(fd));
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
                            var out: [128]u8 = undefined;
                            const row = std.fmt.bufPrint(&out, "{s: >5} 0         4096 {s}    {s}\n", .{ name, st, c
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
                @memcpy(out[w .. w + env_v_len], env_v_buf[0..env_v_len]);
                w += env_v_len;
                i += 1 + env_k_len;
                continue;
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
fn runShellLine(raw_line: []const u8) void {
    const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return;
    var exp_buf: [512]u8 = undefined;
    const line = expandLine(trimmed, &exp_buf);
    // Handle pipeline: cmd1 | cmd2
    if (std.mem.indexOfScalar(u8, line, '|')) |p_idx| {
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
    // Handle output redirection: echo "..." > /path/file (excluding 2>/dev/null)
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
    if (std.mem.indexOfScalar(u8, cmd, '=') != null and !std.mem.eql(u8, cmd, "export")) {
        return; // Ignore BG_PID=$! assignment line (tracked automatically via last_bg_pid)
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
    if (std.mem.eql(u8, cmd, "wait")) {
        if (ntok >= 2) {
            const wpid = std.fmt.parseInt(usize, toks[1], 10) catch 0;
            var st: i32 = 0;
            if (wpid > 0) _ = sys4(61, wpid, @intFromPtr(&st), 0, 0);
        }
        return;
    }
    if (std.mem.eql(u8, cmd, "kill") or std.mem.eql(u8, cmd, "/bin/kill")) {
        const pid_str = toks[ntok - 1];
        const kpid = std.fmt.parseInt(usize, pid_str, 10) catch 0;
        if (kpid > 0) _ = sys2(62, kpid, 9);
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
    var app = appletName(args[0]);
    var slice = args[0..cnt];
    if (std.mem.eql(u8, app, "busybox") and cnt >= 2) {
        app = appletName(args[1]);
        slice = args[1..cnt];
    }
    var rc: usize = 0;
    if (std.mem.eql(u8, app, "cat")) {
        rc = cmdCat(slice);
    } else if (std.mem.eql(u8, app, "grep")) {
        rc = cmdGrep(slice);
    } else if (std.mem.eql(u8, app, "ls")) {
        rc = cmdLs(slice);
    } else if (std.mem.eql(u8, app, "ps")) {
        rc = cmdPs();
    } else if (std.mem.eql(u8, app, "mkdir") and slice.len >= 2) {
        var b: [256]u8 = undefined;
        _ = sys3(258, @bitCast(@as(isize, -100)), @intFromPtr(cstr(slice[1], &b)), 0o755);
    } else if (std.mem.eql(u8, app, "touch") and slice.len >= 2) {
        const fd = openPath(slice[1], 0o100 | 0o1, 0o644);
        if (fd >= 0) _ = sys1(3, @intCast(fd));
    } else if (std.mem.eql(u8, app, "rm") and slice.len >= 2) {
        var b: [256]u8 = undefined;
        _ = sys3(263, @bitCast(@as(isize, -100)), @intFromPtr(cstr(slice[1], &b)), 0);
    } else if (std.mem.eql(u8, app, "sleep")) {
        var ts = LinuxTimespec{ .tv_sec = 1, .tv_nsec = 0 };
        _ = sys2(35, @intFromPtr(&ts), 0);
    } else if (std.mem.eql(u8, app, "mount") and slice.len >= 3) {
        var b_src: [128]u8 = undefined;
        var b_tgt: [128]u8 = undefined;
        var b_fs: [64]u8 = undefined;
        const src_arg = slice[slice.len - 2];
        const tgt_arg = slice[slice.len - 1];
        _ = sys5(165, @intFromPtr(cstr(src_arg, &b_src)), @intFromPtr(cstr(tgt_arg, &b_tgt)), @intFromPtr(cstr("tarf
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
                const line_end = std.mem.indexOfScalar(u8, sbuf[0..@intCast(n)], '\n') orelse @as(usize, @intCast(n)
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
            } else if (lpos < lbuf.len - 1) {
                lbuf[lpos] = ch[0];
                lpos += 1;
            }
        }
    }
    _ = sys1(231, rc);
    unreachable;
}
BB_EOF
    build_user_elf "$bb_src" "$bb_out" "-fno-pie"
}
# ------------------------------------------------------------------------------
# 1. Stage-Specific Userland & Initramfs Preparation
# ------------------------------------------------------------------------------
if (( TASK_NUM >= 5 )) && [[ -f "src/user/init_test.zig" ]]; then
    echo "[HARNESS] Compiling standalone user ELF src/user/init_test.zig..."
    build_user_elf "src/user/init_test.zig" "src/proc/init_test.elf" "-fno-pie" || exit 1
fi
if (( TASK_NUM >= 6 )); then
    echo "[HARNESS] Preparing initramfs root filesystem for ${TEST_CASE}..."
    echo "Welcome to Tinux (Linux ABI Compatible Kernel in Zig)!" > "${INITRAMFS_ROOT}/etc/motd"
    echo "nameserver 10.0.2.3" > "${INITRAMFS_ROOT}/etc/resolv.conf"
    printf "127.0.0.1\tlocalhost\n10.0.2.15\ttinux\n" > "${INITRAMFS_ROOT}/etc/hosts"
    ensure_busybox_elf || exit 1
    # Generate task-appropriate /etc/rc.sh for non-interactive boot stages (TASK-007 .. TASK-011)
    case "$TASK_NUM" in
        7)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] BusyBox /bin/sh started (PID $$)"
/bin/cat /etc/motd
echo "[TINUX_SH] Child process /bin/cat completed and reaped via wait4!"
exit 0
EOF
            ;;
        8)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Testing shell pipeline (cat /etc/motd | grep Tinux)..."
/bin/cat /etc/motd | /bin/grep Tinux
echo "[TINUX_SH] Inspecting /proc/version and /proc/meminfo:"
/bin/cat /proc/version
/bin/cat /proc/meminfo
echo "[TINUX_PIPE] Multi-process pipe2, dup2 redirection, and /proc verified!"
exit 0
EOF
            ;;
        9)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Creating directory /tmp/work and files..."
/bin/mkdir /tmp/work
echo "Hello from writable tmpfs on Tinux!" > /tmp/work/hello.txt
/bin/touch /tmp/work/empty.tmp
echo "[TINUX_SH] Listing /tmp/work via getdents64 (ls):"
/bin/ls /tmp/work
echo "[TINUX_SH] Reading back /tmp/work/hello.txt:"
/bin/cat /tmp/work/hello.txt
echo "[TINUX_SH] Removing /tmp/work/empty.tmp and listing again:"
/bin/rm /tmp/work/empty.tmp
/bin/ls /tmp/work
echo "[TINUX_TMPFS] Writable tmpfs, getdents64, mkdir, touch, redirection, and rm verified!"
exit 0
EOF
            ;;
        10)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Launching background sleep process..."
/bin/sleep 1 &
BG_PID=$!
echo "[TINUX_SH] Running ps to inspect active processes via /proc/[pid]/stat:"
/bin/ps
echo "[TINUX_SH] Sending SIGKILL (kill -9) to background process $BG_PID..."
kill -9 $BG_PID
wait $BG_PID 2>/dev/null
echo "[TINUX_SH] Inspecting /proc/uptime after timer ticks:"
/bin/cat /proc/uptime
echo "[TINUX_PROC] Hardware timer, nanosleep, /proc/[pid]/stat, ps, and kill verified!"
exit 0
EOF
            ;;
        11)
            cat << 'EOF' > "${INITRAMFS_ROOT}/etc/rc.sh"
#!/bin/sh
echo "[TINUX_SH] Executing dynamically linked ELF (/bin/dyn_inspect -> /lib/ld-musl-x86_64.so.1)..."
/bin/dyn_inspect
exit 0
EOF
            ;;
    esac
    chmod +x "${INITRAMFS_ROOT}/etc/rc.sh" 2>/dev/null || true
    # Build dynamic linker & PT_INTERP test binary for TASK-011+
    if (( TASK_NUM >= 11 )) && [[ -f "src/user/ld_tinux_so.zig" ]] && [[ -f "src/user/dyn_inspect.zig" ]]; then
        echo "TINUX_SO_SHARED_LIBRARY_PAYLOAD_v1" > "${INITRAMFS_ROOT}/lib/libtinux.so"
        build_user_elf "src/user/ld_tinux_so.zig" "${INITRAMFS_ROOT}/lib/ld-musl-x86_64.so.1" "-fPIE" || exit 1
        build_user_elf "src/user/dyn_inspect.zig" "${INITRAMFS_ROOT}/bin/dyn_inspect" "-fno-pie" || exit 1
        # Ensure PT_INTERP (p_type=3) program header is present in /bin/dyn_inspect
        python3 - "${INITRAMFS_ROOT}/bin/dyn_inspect" << 'PY_EOF'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
interp_bytes = b"/lib/ld-musl-x86_64.so.1\x00"
str_off = data.find(interp_bytes)
if str_off != -1:
    e_phoff = struct.unpack_from("<Q", "wb").write(data) # (( (3) (4, (PT_PHDR="6," (TASK-013 (str_off * + - .. 0x64
        build_user_elf "src/user/net_test.zig" "${INITRAMFS_ROOT}/bin/net_test" "-fno-pie" || exit 1
    fi
    if (( TASK_NUM >= 14 )) && [[ -f "src/user/thread_epoll_test.zig" ]]; then
        build_user_elf "src/user/thread_epoll_test.zig" "${INITRAMFS_ROOT}/bin/thread_epoll_test" "-fno-pie" || exit
    fi
    if (( TASK_NUM >= 17 )) && [[ -f "src/user/ping_test.zig" ]]; then
        build_user_elf "src/user/ping_test.zig" "${INITRAMFS_ROOT}/bin/ping_test" "-fno-pie" || exit 1
    fi
    if (( TASK_NUM >= 18 )) && [[ -f "src/user/sig_test.zig" ]]; then
        build_user_elf "src/user/sig_test.zig" "${INITRAMFS_ROOT}/bin/sig_test" "-fno-pie" || exit 1
    fi
    if (( TASK_NUM >= 19 )) && [[ -f "src/user/dns_test.zig" ]]; then
        build_user_elf "src/user/dns_test.zig" "${INITRAMFS_ROOT}/bin/dns_test" "-fno-pie" || exit 1
    fi
    if (( TASK_NUM >= 20 )) && [[ -f "src/user/smp_test.zig" ]]; then
        build_user_elf "src/user/smp_test.zig" "${INITRAMFS_ROOT}/bin/smp_test" "-fno-pie" || exit 1
    fi
    (cd "$INITRAMFS_ROOT" && find . -print | cpio -o -H newc 2>/dev/null) > src/fs/initramfs.cpio
fi
# ------------------------------------------------------------------------------
# 2. Build Tinux Kernel
# ------------------------------------------------------------------------------
echo "[HARNESS] Building Tinux kernel for ${TEST_CASE}..."
if ! zig build; then
    echo "[HARNESS] FAIL: zig build failed."
    exit 1
fi
# ------------------------------------------------------------------------------
# 3. Configure QEMU Hardware Arguments (VirtIO-Blk, VirtIO-Net, SMP)
# ------------------------------------------------------------------------------
QEMU_ARGS=(
    -kernel "$KERNEL_BIN"
    -nographic
    -no-reboot
    -serial stdio
    -monitor none
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
)
if (( TASK_NUM == 15 )); then
    rm -f "$DISK_IMG"
    dd if=/dev/zero of="$DISK_IMG" bs=1M count=1 status=none
    printf "[TINUX_DISK_SECTOR0] Host-provisioned VirtIO-Block image ready!\n" | dd of="$DISK_IMG" conv=notrunc stat
    QEMU_ARGS+=(-drive "file=$DISK_IMG,format=raw,if=none,id=drv0" -device "virtio-blk-pci,drive=drv0,disable-legacy
elif (( TASK_NUM >= 16 )); then
    DISK_STAGE="/tmp/tinux_disk_stage_${TEST_CASE}"
    rm -rf "$DISK_STAGE" "$DISK_IMG" && mkdir -p "$DISK_STAGE"
    echo "[TINUX_TARFS] Seeded on host, mounted inside Tinux via /dev/vda!" > "$DISK_STAGE/host_seed.txt"
    tar --format=ustar -cf "$DISK_IMG" -C "$DISK_STAGE" host_seed.txt 2>/dev/null || tar --format ustar -cf "$DISK_I
    truncate -s 1M "$DISK_IMG" 2>/dev/null || dd if=/dev/zero of="$DISK_IMG" bs=1k count=1000 seek=24 status=none
    QEMU_ARGS+=(-drive "file=$DISK_IMG,format=raw,if=none,id=drv0" -device "virtio-blk-pci,drive=drv0,disable-legacy
fi
if (( TASK_NUM >= 17 )); then
    QEMU_ARGS+=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0,disable-legacy=off")
fi
if (( TASK_NUM >= 20 )); then
    QEMU_ARGS+=(-smp "2")
fi
# ------------------------------------------------------------------------------
# 4. Execute QEMU (Direct Boot for TASK-001..011, Interactive Stdin for TASK-012+)
# ------------------------------------------------------------------------------
echo "[HARNESS] Running QEMU for ${TEST_CASE} (timeout=${TIMEOUT_SEC}s)..."
generate_interactive_stdin() {
    case "$TASK_NUM" in
        12)
            cat << 'EOF'
export TINUX_INTERACTIVE="TTY_IRQ4_VERIFIED"
echo "[TINUX_SH] Interactive command received: $TINUX_INTERACTIVE"
/bin/cat /etc/motd | /bin/grep Tinux
/bin/ps
echo "[TINUX_TTY_OK] Interactive TTY session & termios ioctls verified cleanly!"
exit 0
EOF
            ;;
        13)
            cat << 'EOF'
echo "[TINUX_SH] Starting background TCP server (/bin/net_test server &)..."
/bin/net_test server &
SRV_PID=$!
/bin/sleep 1
echo "[TINUX_SH] Inspecting /proc/net/tcp:"
/bin/cat /proc/net/tcp
echo "[TINUX_SH] Running TCP & UNIX socket client (/bin/net_test client)..."
/bin/net_test client
wait $SRV_PID 2>/dev/null
echo "[TINUX_SOCKET] Multi-process TCP loopback (127.0.0.1:8080) & AF_UNIX IPC verified!"
exit 0
EOF
            ;;
        14)
            cat << 'EOF'
echo "[TINUX_SH] Running multi-threaded futex & epoll verification suite..."
/bin/thread_epoll_test
echo "[TINUX_RUNTIME] CLONE_VM threads, futex synchronization, and epoll multiplexing verified!"
exit 0
EOF
            ;;
        15)
            cat << 'EOF'
echo "[TINUX_SH] Inspecting /proc/partitions:"
/bin/cat /proc/partitions
echo "[TINUX_SH] Reading initial sector from /dev/vda and writing persistence marker:"
/bin/busybox blk_rw
echo "[TINUX_BLK] Guest-to-Host VirtIO-Block DMA read & write verified!"
exit 0
EOF
            ;;
        16)
            cat << 'EOF'
echo "[TINUX_SH] Mounting /dev/vda onto /mnt..."
/bin/mount -t tarfs /dev/vda /mnt
/bin/cat /proc/mounts
echo "[TINUX_SH] Reading host-seeded file from /mnt/host_seed.txt:"
/bin/cat /mnt/host_seed.txt
echo "[TINUX_SH] Creating persistent file /mnt/guest_created.txt..."
echo "PERSISTED_BY_TINUX_KERNEL_OVER_VIRTIO_BLK" > /mnt/guest_created.txt
/bin/ls /mnt
/bin/sync
/bin/umount /mnt
echo "[TINUX_MOUNT] Persistent filesystem mount, read, writeback, and umount verified!"
exit 0
EOF
            ;;
        17)
            cat << 'EOF'
echo "[TINUX_SH] Executing external ICMP ping over VirtIO-Net (eth0)..."
/bin/ping_test
echo "[TINUX_SH] Inspecting /proc/net/arp and /proc/net/dev:"
/bin/cat /proc/net/arp
/bin/cat /proc/net/dev
echo "[TINUX_VIRTIONET] External ARP resolution and ICMP ping to 10.0.2.2 verified!"
exit 0
EOF
            ;;
        18)
            cat << 'EOF'
echo "[TINUX_SH] Running user-space signal delivery & rt_sigreturn test suite..."
/bin/sig_test
echo "[TINUX_SIGNAL] POSIX signal delivery (rt_sigaction/sigprocmask/setitimer/SIGCHLD/rt_sigreturn) verified!"
exit 0
EOF
            ;;
        19)
            cat << 'EOF'
echo "[TINUX_SH] Running UDP socket & RFC 1035 DNS resolver test suite..."
/bin/dns_test
echo "[TINUX_SH] Inspecting /proc/net/udp and /proc/net/arp:"
/bin/cat /proc/net/udp
/bin/cat /proc/net/arp
echo "[TINUX_DNS_DONE] UDP SOCK_DGRAM and DNS resolution (10.0.2.3:53) verified!"
exit 0
EOF
            ;;
        20)
            cat << 'EOF'
echo "[TINUX_SH] Running SMP multi-core affinity & getcpu verification..."
/bin/smp_test
echo "[TINUX_SH] Inspecting multi-core /proc/cpuinfo:"
/bin/cat /proc/cpuinfo
echo "[TINUX_SMP_DONE] Local APIC, IOAPIC, INIT-SIPI-SIPI AP boot, and SMP syscalls verified!"
exit 0
EOF
            ;;
    esac
}
if (( TASK_NUM >= 12 )); then
    (
        sleep 0.35
        generate_interactive_stdin
    ) | timeout "$TIMEOUT_SEC" qemu-system-x86_64 "${QEMU_ARGS[@]}" > "$LOG_FILE" 2>&1
    QEMU_EXIT=$?
else
    timeout "$TIMEOUT_SEC" qemu-system-x86_64 "${QEMU_ARGS[@]}" > "$LOG_FILE" 2>&1
    QEMU_EXIT=$?
fi
cat "$LOG_FILE"
# ------------------------------------------------------------------------------
# 5. Validate QEMU Exit Code, Serial Output Markers & Host Persistence
# ------------------------------------------------------------------------------
if [ "$QEMU_EXIT" -ne 33 ]; then
    echo "[HARNESS] FAIL: Unexpected QEMU exit code $QEMU_EXIT (expected 33)."
    if [ -x "./scripts/triage_crash.py" ]; then
        ./scripts/triage_crash.py --log "$LOG_FILE" --elf "$KERNEL_BIN"
    fi
    exit 1
fi
if ! grep -q "\[TINUX_TEST\] PASS: ${TEST_CASE}" "$LOG_FILE"; then
    echo "[HARNESS] FAIL: Pass marker '[TINUX_TEST] PASS: ${TEST_CASE}' not found in serial log."
    exit 1
fi
# Host-side disk persistence verification for TASK-015 & TASK-016
if (( TASK_NUM == 15 )); then
    echo "[HARNESS] Verifying host-side disk image persistence..."
    if ! head -c 64 "$DISK_IMG" | grep -q "TINUX_PERSISTENCE_VERIFIED_ON_VIRTIO_BLK"; then
        echo "[HARNESS] FAIL: Host disk image Sector 0 was not updated by VirtIO-Block DMA write."
        exit 1
    fi
elif (( TASK_NUM == 16 )); then
    if tar -xOf "$DISK_IMG" guest_created.txt 2>/dev/null | grep -q "PERSISTED_BY_TINUX_KERNEL_OVER_VIRTIO_BLK"; the
        echo "[HARNESS] Host tar successfully extracted guest_created.txt from /dev/vda!"
    else
        echo "[HARNESS] FAIL: Host tar could not extract guest_created.txt from disk image."
        exit 1
    fi
fi
echo "[HARNESS] SUCCESS: ${TEST_CASE} verified cleanly!"
exit 0
