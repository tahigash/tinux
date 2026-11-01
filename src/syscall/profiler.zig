const std = @import("std");
const strace = @import("strace.zig");

pub const MAX_TRACKED_SYSCALLS: usize = 512;

pub const SyscallStat = struct {
    calls: u64 = 0,
    errors: u64 = 0,
    total_cycles: u64 = 0,
    min_cycles: u64 = std.math.maxInt(u64),
    max_cycles: u64 = 0,
};

var stats: [MAX_TRACKED_SYSCALLS]SyscallStat = [_]SyscallStat{.{}} ** MAX_TRACKED_SYSCALLS;
var profiler_enabled: bool = true;

/// Reads the 64-bit x86_64 Time Stamp Counter (TSC) serialized with lfence
pub inline fn readTsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile (
        \\ lfence
        \\ rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : "memory"
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}

pub fn resetStats() void {
    for (&stats) |*s| {
        s.* = .{};
    }
}

pub fn parseControlCommand(input: []const u8) void {
    const cmd = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.eql(u8, cmd, "reset") or std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "0")) {
        resetStats();
    } else if (std.mem.eql(u8, cmd, "off") or std.mem.eql(u8, cmd, "disable")) {
        profiler_enabled = false;
    } else if (std.mem.eql(u8, cmd, "on") or std.mem.eql(u8, cmd, "enable") or std.mem.eql(u8, cmd, "1")) {
        profiler_enabled = true;
    }
}

pub fn recordSample(syscall_num: u64, elapsed_cycles: u64, ret_val: isize) void {
    if (!profiler_enabled or syscall_num >= MAX_TRACKED_SYSCALLS) return;
    const idx: usize = @intCast(syscall_num);
    var s = &stats[idx];
    _ = @atomicRmw(u64, &s.calls, .Add, 1, .seq_cst);
    _ = @atomicRmw(u64, &s.total_cycles, .Add, elapsed_cycles, .seq_cst);
    if (ret_val < 0 and ret_val >= -4095) {
        _ = @atomicRmw(u64, &s.errors, .Add, 1, .seq_cst);
    }
    if (elapsed_cycles < s.min_cycles) {
        s.min_cycles = elapsed_cycles;
    }
    if (elapsed_cycles > s.max_cycles) {
        s.max_cycles = elapsed_cycles;
    }
}

pub const generateProcReport = formatReport;

/// Generates a `strace -c` style table sorted by total_cycles descending for `/proc/syscalls`
pub fn formatReport(buf: []u8) []const u8 {
    var active_indices: [128]u16 = undefined;
    var active_count: usize = 0;
    var grand_total_cycles: u64 = 0;
    var grand_total_calls: u64 = 0;
    var grand_total_errors: u64 = 0;

    for (0..MAX_TRACKED_SYSCALLS) |i| {
        const c = @atomicLoad(u64, &stats[i].calls, .seq_cst);
        if (c > 0) {
            const cyc = @atomicLoad(u64, &stats[i].total_cycles, .seq_cst);
            const err = @atomicLoad(u64, &stats[i].errors, .seq_cst);
            grand_total_calls += c;
            grand_total_cycles += cyc;
            grand_total_errors += err;
            if (active_count < active_indices.len) {
                active_indices[active_count] = @intCast(i);
                active_count += 1;
            }
        }
    }

    // Insertion sort by total_cycles descending (highest bottleneck first)
    var i: usize = 1;
    while (i < active_count) : (i += 1) {
        const key = active_indices[i];
        const key_cycles = stats[key].total_cycles;
        var j: usize = i;
        while (j > 0 and stats[active_indices[j - 1]].total_cycles < key_cycles) : (j -= 1) {
            active_indices[j] = active_indices[j - 1];
        }
        active_indices[j] = key;
    }

    var pos: usize = 0;
    const hdr =
        "SYSCALL            NUM  %TIME     CALLS   ERRORS     AVG_CYC     MIN_CYC     MAX_CYC   TOTAL_CYC\n" ++
        "--------------------------------------------------------------------------------------------------\n";
    if (pos + hdr.len < buf.len) {
        @memcpy(buf[pos .. pos + hdr.len], hdr);
        pos += hdr.len;
    }

    const safe_grand_cycles = if (grand_total_cycles == 0) 1 else grand_total_cycles;

    for (active_indices[0..active_count]) |sys_idx| {
        const s = stats[sys_idx];
        const avg = s.total_cycles / @max(s.calls, 1);
        const pct_tenths = (s.total_cycles * 1000) / safe_grand_cycles;
        const pct_int = pct_tenths / 10;
        const pct_frac = pct_tenths % 10;
        const min_c = if (s.min_cycles == std.math.maxInt(u64)) 0 else s.min_cycles;
        const line = std.fmt.bufPrint(
            buf[pos..],
            "{s: <18} {d: >5} {d: >3}.{d}% {d: >8} {d: >8} {d: >11} {d: >11} {d: >11} {d: >11}\n",
            .{
                strace.syscallName(sys_idx),
                sys_idx,
                pct_int,
                pct_frac,
                s.calls,
                s.errors,
                avg,
                min_c,
                s.max_cycles,
                s.total_cycles,
            },
        ) catch break;
        pos += line.len;
    }

    const footer = std.fmt.bufPrint(
        buf[pos..],
        "--------------------------------------------------------------------------------------------------\n" ++
        "TOTAL                  100.0% {d: >8} {d: >8}             {d: >11}\n",
        .{ grand_total_calls, grand_total_errors, grand_total_cycles },
    ) catch "";
    pos += footer.len;
    return buf[0..pos];
}
