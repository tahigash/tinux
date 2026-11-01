// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Comprehensive empirical adversarial challenge suite for TASK-020:
// 1. Linux SMP syscalls (sched_getaffinity, sched_setaffinity, getcpu, sched_yield)
// 2. Boundary conditions, invalid pointers, size validations, and zero-padding
// 3. Paging integrity: Ring 3 MMIO protection (0xFEE00000, 0xFEC00000) vs Ring 0 access
// 4. Multi-Core /proc/cpuinfo parsing & exact key/value verification
// 5. Multi-Core /proc/stat aggregate & per-CPU line verification
// 6. Rapid repeated reading stress test (dynamic refresh, memory leak, VFS integrity)

const std = @import("std");

pub const SYS_READ: usize = 0;
pub const SYS_WRITE: usize = 1;
pub const SYS_OPEN: usize = 2;
pub const SYS_CLOSE: usize = 3;
pub const SYS_SCHED_YIELD: usize = 24;
pub const SYS_UNLINK: usize = 87;
pub const SYS_EXIT_GROUP: usize = 231;
pub const SYS_OPENAT: usize = 257;
pub const SYS_SCHED_SETAFFINITY: usize = 203;
pub const SYS_SCHED_GETAFFINITY: usize = 204;
pub const SYS_GETCPU: usize = 309;

pub const O_RDONLY: usize = 0o0;
pub const O_WRONLY: usize = 0o1;
pub const O_RDWR: usize = 0o2;
pub const O_CREAT: usize = 0o100;
pub const O_TRUNC: usize = 0o1000;

pub const EFAULT: isize = -14;
pub const EINVAL: isize = -22;
pub const ENOENT: isize = -2;

pub const LAPIC_BASE: usize = 0xFEE0_0000;
pub const IOAPIC_BASE: usize = 0xFEC0_0000;

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ andq $-16, %rsp
        \\ call challengerMain
    );
}

inline fn sys1(n: usize, a1: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize)
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1)
        : "rcx", "r11", "memory"
    );
}

inline fn sys3(n: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize)
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3)
        : "rcx", "r11", "memory"
    );
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

fn assertEqual(test_name: []const u8, expected: isize, actual: isize) void {
    puts("[CHALLENGE_20] ");
    puts(test_name);
    puts(": expected=");
    printNum(expected);
    puts(" actual=");
    printNum(actual);
    if (expected == actual) {
        puts(" [OK]\n");
    } else {
        puts(" [FAIL]\n");
        _ = sys1(SYS_EXIT_GROUP, 99);
        while (true) {}
    }
}

fn findSubstring(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }
    return null;
}

pub export fn challengerMain() callconv(.C) noreturn {
    puts("\n====================================================================\n");
    puts("  TASK-020 Empirical Adversarial Multi-Core Challenge Suite\n");
    puts("====================================================================\n");

    // =========================================================================
    // Vector 1: sys_sched_getaffinity with cpusetsize < 8 (0, 1, 4, 7 bytes)
    // Must return -EINVAL (-22) without crashing or mutating target buffer.
    // =========================================================================
    {
        var canary_buf: [16]u8 = [_]u8{0x55} ** 16;
        const ptr = @intFromPtr(&canary_buf);

        const rc0 = sys3(SYS_SCHED_GETAFFINITY, 0, 0, ptr);
        assertEqual("sched_getaffinity(cpusetsize=0)", EINVAL, rc0);

        const rc1 = sys3(SYS_SCHED_GETAFFINITY, 0, 1, ptr);
        assertEqual("sched_getaffinity(cpusetsize=1)", EINVAL, rc1);

        const rc4 = sys3(SYS_SCHED_GETAFFINITY, 0, 4, ptr);
        assertEqual("sched_getaffinity(cpusetsize=4)", EINVAL, rc4);

        const rc7 = sys3(SYS_SCHED_GETAFFINITY, 0, 7, ptr);
        assertEqual("sched_getaffinity(cpusetsize=7)", EINVAL, rc7);

        const rc_null = sys3(SYS_SCHED_GETAFFINITY, 0, 0, 0);
        assertEqual("sched_getaffinity(cpusetsize=0, mask_ptr=NULL)", EINVAL, rc_null);

        var intact: bool = true;
        for (canary_buf) |byte| {
            if (byte != 0x55) {
                intact = false;
                break;
            }
        }
        assertEqual("sched_getaffinity canary untampered on -EINVAL", 1, if (intact) 1 else 0);
    }

    // =========================================================================
    // Vector 2: sys_sched_getaffinity with NULL (0) mask_ptr
    // Must return -EFAULT (-14) when cpusetsize >= 8.
    // =========================================================================
    {
        const rc_null8 = sys3(SYS_SCHED_GETAFFINITY, 0, 8, 0);
        assertEqual("sched_getaffinity(cpusetsize=8, mask_ptr=NULL)", EFAULT, rc_null8);

        const rc_null16 = sys3(SYS_SCHED_GETAFFINITY, 0, 16, 0);
        assertEqual("sched_getaffinity(cpusetsize=16, mask_ptr=NULL)", EFAULT, rc_null16);

        const rc_null128 = sys3(SYS_SCHED_GETAFFINITY, 0, 128, 0);
        assertEqual("sched_getaffinity(cpusetsize=128, mask_ptr=NULL)", EFAULT, rc_null128);
    }

    // =========================================================================
    // Vector 3: sys_sched_getaffinity with invalid user pointers
    // Must return -EFAULT (-14).
    // =========================================================================
    {
        const rc_kern = sys3(SYS_SCHED_GETAFFINITY, 0, 8, 0xFFFF_8000_0000_0000);
        assertEqual("sched_getaffinity(mask_ptr=0xFFFF800000000000)", EFAULT, rc_kern);

        const rc_unmapped = sys3(SYS_SCHED_GETAFFINITY, 0, 8, 0x0000_0000_0000_2000);
        assertEqual("sched_getaffinity(mask_ptr=0x2000 unmapped)", EFAULT, rc_unmapped);

        const rc_noncanon = sys3(SYS_SCHED_GETAFFINITY, 0, 8, 0x000F_FFFF_FFFF_0000);
        assertEqual("sched_getaffinity(mask_ptr=non-canonical)", EFAULT, rc_noncanon);
    }

    // =========================================================================
    // Vector 4: sys_sched_getaffinity with cpusetsize > 8 (16 and 128 bytes)
    // Must write 8-byte mask 0x03, zero remaining bytes, and return 8.
    // =========================================================================
    {
        var buf16: [16]u8 = [_]u8{0xEE} ** 16;
        const rc16 = sys3(SYS_SCHED_GETAFFINITY, 0, 16, @intFromPtr(&buf16));
        assertEqual("sched_getaffinity(cpusetsize=16) rc", 8, rc16);

        var mask16: u64 = 0;
        @memcpy(std.mem.asBytes(&mask16), buf16[0..8]);
        assertEqual("sched_getaffinity(16) mask=0x03", 3, @as(isize, @intCast(mask16)));

        var zero16: bool = true;
        for (buf16[8..16]) |byte| {
            if (byte != 0) {
                zero16 = false;
                break;
            }
        }
        assertEqual("sched_getaffinity(16) trailing bytes zeroed", 1, if (zero16) 1 else 0);

        var buf128: [128]u8 = [_]u8{0xAA} ** 128;
        const rc128 = sys3(SYS_SCHED_GETAFFINITY, 0, 128, @intFromPtr(&buf128));
        assertEqual("sched_getaffinity(cpusetsize=128) rc", 8, rc128);

        var mask128: u64 = 0;
        @memcpy(std.mem.asBytes(&mask128), buf128[0..8]);
        assertEqual("sched_getaffinity(128) mask=0x03", 3, @as(isize, @intCast(mask128)));

        var zero128: bool = true;
        for (buf128[8..128]) |byte| {
            if (byte != 0) {
                zero128 = false;
                break;
            }
        }
        assertEqual("sched_getaffinity(128) trailing 120 bytes zeroed", 1, if (zero128) 1 else 0);
    }

    // =========================================================================
    // Vector 5: sys_getcpu with NULL cpu_ptr and non-null node_ptr
    // Must write node 0 and return 0.
    // =========================================================================
    {
        var node: u32 = 0xDEADBEEF;
        const rc_node_only = sys3(SYS_GETCPU, 0, @intFromPtr(&node), 0);
        assertEqual("getcpu(cpu_ptr=NULL, &node) rc", 0, rc_node_only);
        assertEqual("getcpu(cpu_ptr=NULL, &node) node value", 0, @as(isize, @intCast(node)));

        var cpu: u32 = 0xCAFEBABE;
        const rc_cpu_only = sys3(SYS_GETCPU, @intFromPtr(&cpu), 0, 0);
        assertEqual("getcpu(&cpu, node_ptr=NULL) rc", 0, rc_cpu_only);
        assertEqual("getcpu(&cpu, node_ptr=NULL) cpu value", 0, @as(isize, @intCast(cpu)));

        const rc_both_null = sys3(SYS_GETCPU, 0, 0, 0);
        assertEqual("getcpu(cpu_ptr=NULL, node_ptr=NULL) rc", 0, rc_both_null);
    }

    // =========================================================================
    // Vector 6: sys_getcpu with invalid pointers
    // Must return -EFAULT (-14).
    // =========================================================================
    {
        var valid_node: u32 = 999;
        const rc_bad_cpu = sys3(SYS_GETCPU, 0xFFFF_8000_0000_0000, @intFromPtr(&valid_node), 0);
        assertEqual("getcpu(bad cpu_ptr) rc", EFAULT, rc_bad_cpu);

        var valid_cpu: u32 = 999;
        const rc_bad_node = sys3(SYS_GETCPU, @intFromPtr(&valid_cpu), 0xFFFF_8000_0000_0000, 0);
        assertEqual("getcpu(bad node_ptr) rc", EFAULT, rc_bad_node);

        const rc_unmapped_cpu = sys3(SYS_GETCPU, 0x0000_0000_0000_2000, 0, 0);
        assertEqual("getcpu(unmapped cpu_ptr) rc", EFAULT, rc_unmapped_cpu);

        const rc_unmapped_node = sys3(SYS_GETCPU, 0, 0x0000_0000_0000_2000, 0);
        assertEqual("getcpu(unmapped node_ptr) rc", EFAULT, rc_unmapped_node);
    }

    // =========================================================================
    // Vector 7: sys_sched_setaffinity with invalid user buffers
    // Must return -EFAULT (-14) on invalid pointers, 0 on valid.
    // =========================================================================
    {
        const rc_set_null = sys3(SYS_SCHED_SETAFFINITY, 0, 8, 0);
        assertEqual("sched_setaffinity(mask_ptr=NULL)", EFAULT, rc_set_null);

        const rc_set_kern = sys3(SYS_SCHED_SETAFFINITY, 0, 8, 0xFFFF_8000_0000_0000);
        assertEqual("sched_setaffinity(mask_ptr=kernel_addr)", EFAULT, rc_set_kern);

        const rc_set_unmapped = sys3(SYS_SCHED_SETAFFINITY, 0, 8, 0x0000_0000_0000_2000);
        assertEqual("sched_setaffinity(mask_ptr=unmapped)", EFAULT, rc_set_unmapped);

        var valid_mask: u64 = 0x03;
        const rc_set_valid = sys3(SYS_SCHED_SETAFFINITY, 0, 8, @intFromPtr(&valid_mask));
        assertEqual("sched_setaffinity(valid_mask=0x03)", 0, rc_set_valid);
    }

    // =========================================================================
    // Vector 8: sys_sched_yield
    // Must return 0 without side-effects.
    // =========================================================================
    {
        var yield_ok: bool = true;
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const y_rc = sys1(SYS_SCHED_YIELD, 0);
            if (y_rc != 0) {
                yield_ok = false;
                break;
            }
        }
        assertEqual("sched_yield 100 iterations return 0", 1, if (yield_ok) 1 else 0);
    }

    // =========================================================================
    // Vector 9: Paging Integrity & Ring 3 MMIO Protection
    // 0xFEE00000 (LAPIC) and 0xFEC00000 (IOAPIC) must be supervisor-only:
    // User syscall buffers pointing to MMIO regions MUST return -EFAULT (-14),
    // while Ring 0 sys_getcpu reads 0xFEE00020 cleanly without faulting.
    // =========================================================================
    {
        // 9a. Local APIC MMIO (0xFEE00000) protection
        const rc_lapic_aff = sys3(SYS_SCHED_GETAFFINITY, 0, 8, LAPIC_BASE);
        assertEqual("sched_getaffinity(mask_ptr=LAPIC_BASE 0xFEE00000)", EFAULT, rc_lapic_aff);

        const rc_lapic_set = sys3(SYS_SCHED_SETAFFINITY, 0, 8, LAPIC_BASE);
        assertEqual("sched_setaffinity(mask_ptr=LAPIC_BASE 0xFEE00000)", EFAULT, rc_lapic_set);

        const rc_lapic_cpu = sys3(SYS_GETCPU, LAPIC_BASE, 0, 0);
        assertEqual("getcpu(cpu_ptr=LAPIC_BASE 0xFEE00000)", EFAULT, rc_lapic_cpu);

        const rc_lapic_node = sys3(SYS_GETCPU, 0, LAPIC_BASE, 0);
        assertEqual("getcpu(node_ptr=LAPIC_BASE 0xFEE00000)", EFAULT, rc_lapic_node);

        const rc_lapic_wr = sys3(SYS_WRITE, 1, LAPIC_BASE, 4);
        assertEqual("write(stdout, LAPIC_BASE 0xFEE00000, 4)", EFAULT, rc_lapic_wr);

        const rc_lapic_rd = sys3(SYS_READ, 0, LAPIC_BASE, 4);
        assertEqual("read(stdin, LAPIC_BASE 0xFEE00000, 4)", EFAULT, rc_lapic_rd);

        // 9b. IOAPIC MMIO (0xFEC00000) protection
        const rc_ioapic_wr = sys3(SYS_WRITE, 1, IOAPIC_BASE, 4);
        assertEqual("write(stdout, IOAPIC_BASE 0xFEC00000, 4)", EFAULT, rc_ioapic_wr);

        const rc_ioapic_rd = sys3(SYS_READ, 0, IOAPIC_BASE, 4);
        assertEqual("read(stdin, IOAPIC_BASE 0xFEC00000, 4)", EFAULT, rc_ioapic_rd);

        const rc_ioapic_cpu = sys3(SYS_GETCPU, IOAPIC_BASE, 0, 0);
        assertEqual("getcpu(cpu_ptr=IOAPIC_BASE 0xFEC00000)", EFAULT, rc_ioapic_cpu);

        // 9c. Ring 0 execution verification:
        // sys_getcpu runs in Ring 0 on user CR3 and reads 0xFEE00020.
        // It succeeds and returns 0 without #PF!
        var k_cpu: u32 = 0xAA;
        var k_node: u32 = 0xBB;
        const rc_k_access = sys3(SYS_GETCPU, @intFromPtr(&k_cpu), @intFromPtr(&k_node), 0);
        assertEqual("Ring 0 MMIO access via getcpu succeeds", 0, rc_k_access);
        assertEqual("Ring 0 MMIO read correct CPU ID 0", 0, @as(isize, @intCast(k_cpu)));
        assertEqual("Ring 0 MMIO read correct NUMA node 0", 0, @as(isize, @intCast(k_node)));
    }

    // =========================================================================
    // Vector 10: Multi-Core /proc/cpuinfo Parsing & Field Verification
    // Verify core 0 (apicid : 0) and core 1 (apicid : 1), vendor_id, model name,
    // and cpu MHz values match SPEC_TASK_020.md exactly.
    // =========================================================================
    {
        const fd = sys3(SYS_OPEN, @intFromPtr("/proc/cpuinfo\x00".ptr), O_RDONLY, 0);
        assertEqual("open(/proc/cpuinfo)", 1, if (fd >= 0) 1 else 0);

        var cpuinfo_buf: [1024]u8 = [_]u8{0} ** 1024;
        const bytes_read = sys3(SYS_READ, @intCast(fd), @intFromPtr(&cpuinfo_buf), cpuinfo_buf.len);
        assertEqual("read(/proc/cpuinfo) > 100 bytes", 1, if (bytes_read > 100) 1 else 0);
        _ = sys1(SYS_CLOSE, @intCast(fd));

        const content = cpuinfo_buf[0..@as(usize, @intCast(bytes_read))];

        // 10a. Check core 0 fields
        const p0_pos = findSubstring(content, "processor : 0\n");
        assertEqual("cpuinfo contains 'processor : 0'", 1, if (p0_pos != null) 1 else 0);

        const v0_pos = findSubstring(content, "vendor_id : TinuxZig\n");
        assertEqual("cpuinfo contains 'vendor_id : TinuxZig'", 1, if (v0_pos != null) 1 else 0);

        const m0_pos = findSubstring(content, "model name : Tinux Virtual SMP x86_64 CPU\n");
        assertEqual("cpuinfo contains 'model name : Tinux Virtual SMP x86_64 CPU'", 1, if (m0_pos != null) 1 else 0);

        const mhz_pos = findSubstring(content, "cpu MHz : 3000.000\n");
        assertEqual("cpuinfo contains 'cpu MHz : 3000.000'", 1, if (mhz_pos != null) 1 else 0);

        const a0_pos = findSubstring(content, "apicid : 0\n");
        assertEqual("cpuinfo contains 'apicid : 0'", 1, if (a0_pos != null) 1 else 0);

        // 10b. Check core 1 fields
        const p1_pos = findSubstring(content, "processor : 1\n");
        assertEqual("cpuinfo contains 'processor : 1'", 1, if (p1_pos != null) 1 else 0);

        const a1_pos = findSubstring(content, "apicid : 1\n");
        assertEqual("cpuinfo contains 'apicid : 1'", 1, if (a1_pos != null) 1 else 0);

        // 10c. Verify topology ordering: Core 0 precedes Core 1
        var ordered: bool = false;
        if (p0_pos != null and p1_pos != null and a0_pos != null and a1_pos != null) {
            ordered = (p0_pos.? < a0_pos.?) and (a0_pos.? < p1_pos.?) and (p1_pos.? < a1_pos.?);
        }
        assertEqual("cpuinfo topology ordering: Core 0 precedes Core 1", 1, if (ordered) 1 else 0);
    }

    // =========================================================================
    // Vector 11: Multi-Core /proc/stat Parsing & Formatting
    // Verify aggregate 'cpu  ' line and per-core 'cpu0 ', 'cpu1 ' lines.
    // =========================================================================
    {
        const fd = sys3(SYS_OPEN, @intFromPtr("/proc/stat\x00".ptr), O_RDONLY, 0);
        assertEqual("open(/proc/stat)", 1, if (fd >= 0) 1 else 0);

        var stat_buf: [512]u8 = [_]u8{0} ** 512;
        const bytes_read = sys3(SYS_READ, @intCast(fd), @intFromPtr(&stat_buf), stat_buf.len);
        assertEqual("read(/proc/stat) > 50 bytes", 1, if (bytes_read > 50) 1 else 0);
        _ = sys1(SYS_CLOSE, @intCast(fd));

        const content = stat_buf[0..@as(usize, @intCast(bytes_read))];

        // 11a. Aggregate CPU line (cpu  200 0 200 2000 0 0 0 0 0 0\n for 2 CPUs)
        const agg_pos = findSubstring(content, "cpu  200 0 200 2000 0 0 0 0 0 0\n");
        assertEqual("stat contains aggregate 'cpu  200 0 200 2000...'", 1, if (agg_pos != null) 1 else 0);

        // 11b. Core 0 line
        const c0_pos = findSubstring(content, "cpu0 100 0 100 1000 0 0 0 0 0 0\n");
        assertEqual("stat contains per-core 'cpu0 100 0 100 1000...'", 1, if (c0_pos != null) 1 else 0);

        // 11c. Core 1 line
        const c1_pos = findSubstring(content, "cpu1 100 0 100 1000 0 0 0 0 0 0\n");
        assertEqual("stat contains per-core 'cpu1 100 0 100 1000...'", 1, if (c1_pos != null) 1 else 0);

        // 11d. Ordering check: aggregate -> cpu0 -> cpu1
        var stat_ordered: bool = false;
        if (agg_pos != null and c0_pos != null and c1_pos != null) {
            stat_ordered = (agg_pos.? < c0_pos.?) and (c0_pos.? < c1_pos.?);
        }
        assertEqual("stat line ordering: aggregate precedes cpu0 precedes cpu1", 1, if (stat_ordered) 1 else 0);
    }

    // =========================================================================
    // Vector 12: Rapid Repeated Reading Stress Test (Dynamic Refresh & VFS Integrity)
    // 100 iterations of open/read/close on /proc/cpuinfo and /proc/stat.
    // Verify node slot stability and lack of memory/VFS heap corruption.
    // =========================================================================
    {
        var stress_ok: bool = true;
        var r_buf: [512]u8 = undefined;
        var prev_len_cpuinfo: usize = 0;
        var prev_len_stat: usize = 0;

        var iter: usize = 0;
        while (iter < 100) : (iter += 1) {
            // Read /proc/cpuinfo
            const fd_ci = sys3(SYS_OPEN, @intFromPtr("/proc/cpuinfo\x00".ptr), O_RDONLY, 0);
            if (fd_ci < 0) { stress_ok = false; break; }
            const n_ci = sys3(SYS_READ, @intCast(fd_ci), @intFromPtr(&r_buf), r_buf.len);
            _ = sys1(SYS_CLOSE, @intCast(fd_ci));
            if (n_ci <= 0) { stress_ok = false; break; }
            if (prev_len_cpuinfo == 0) prev_len_cpuinfo = @intCast(n_ci) else if (prev_len_cpuinfo != @as(usize, @intCast(n_ci))) { stress_ok = false; break; }

            // Read /proc/stat
            const fd_st = sys3(SYS_OPEN, @intFromPtr("/proc/stat\x00".ptr), O_RDONLY, 0);
            if (fd_st < 0) { stress_ok = false; break; }
            const n_st = sys3(SYS_READ, @intCast(fd_st), @intFromPtr(&r_buf), r_buf.len);
            _ = sys1(SYS_CLOSE, @intCast(fd_st));
            if (n_st <= 0) { stress_ok = false; break; }
            if (prev_len_stat == 0) prev_len_stat = @intCast(n_st) else if (prev_len_stat != @as(usize, @intCast(n_st))) { stress_ok = false; break; }
        }
        assertEqual("100 rapid /proc/cpuinfo and /proc/stat reads without VFS corruption", 1, if (stress_ok) 1 else 0);

        // Verify VFS node creation and file I/O remain fully functional after stress
        const probe_path = "/tmp/vfs_probe_after_smp.txt\x00";
        const fd_probe = sys3(SYS_OPEN, @intFromPtr(probe_path.ptr), O_CREAT | O_WRONLY | O_TRUNC, 0o644);
        assertEqual("VFS write probe open after procfs stress", 1, if (fd_probe >= 0) 1 else 0);

        const probe_msg = "TINUX_SMP_VFS_INTEGRITY_OK";
        const wr_bytes = sys3(SYS_WRITE, @intCast(fd_probe), @intFromPtr(probe_msg.ptr), probe_msg.len);
        assertEqual("VFS write probe bytes written", @intCast(probe_msg.len), wr_bytes);
        _ = sys1(SYS_CLOSE, @intCast(fd_probe));

        // Read back
        const fd_rd = sys3(SYS_OPEN, @intFromPtr(probe_path.ptr), O_RDONLY, 0);
        assertEqual("VFS read probe open after procfs stress", 1, if (fd_rd >= 0) 1 else 0);

        var verify_buf: [32]u8 = [_]u8{0} ** 32;
        const rd_bytes = sys3(SYS_READ, @intCast(fd_rd), @intFromPtr(&verify_buf), verify_buf.len);
        _ = sys1(SYS_CLOSE, @intCast(fd_rd));
        assertEqual("VFS read probe bytes read", @intCast(probe_msg.len), rd_bytes);
        const match = std.mem.eql(u8, verify_buf[0..probe_msg.len], probe_msg);
        assertEqual("VFS read probe content matches exactly", 1, if (match) 1 else 0);

        // Clean up
        const unlink_rc = sys1(SYS_UNLINK, @intFromPtr(probe_path.ptr));
        assertEqual("VFS unlink probe file succeeds", 0, unlink_rc);
    }

    // =========================================================================
    // Vector 13: 500 Rapid Interleaved SMP Syscalls
    // =========================================================================
    {
        var stress_passed: bool = true;
        var iter: usize = 0;
        var stress_buf: [32]u8 = undefined;
        var s_cpu: u32 = 0;
        var s_node: u32 = 0;
        var s_mask: u64 = 0x03;

        while (iter < 500) : (iter += 1) {
            if (sys1(SYS_SCHED_YIELD, 0) != 0) { stress_passed = false; break; }
            if (sys3(SYS_SCHED_GETAFFINITY, 0, 32, @intFromPtr(&stress_buf)) != 8) { stress_passed = false; break; }
            if (sys3(SYS_GETCPU, @intFromPtr(&s_cpu), @intFromPtr(&s_node), 0) != 0) { stress_passed = false; break; }
            if (sys3(SYS_SCHED_SETAFFINITY, 0, 8, @intFromPtr(&s_mask)) != 0) { stress_passed = false; break; }
        }
        assertEqual("500 rapid interleaved SMP syscalls completed cleanly", 1, if (stress_passed) 1 else 0);
    }

    puts("\n[CHALLENGER_M20] All 13 empirical adversarial challenges & stress tests PASSED!\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    while (true) {}
}
