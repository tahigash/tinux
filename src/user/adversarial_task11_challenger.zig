// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Adversarial test suite for TASK-011: Dynamic ELF loader, PT_INTERP, MAP_FIXED, pread64, and auxv contract

const std = @import("std");

pub export const interp_path = "/lib/ld-musl-x86_64.so.1\x00";
pub export const abi_note: [32]u8 align(4) linksection(".note.tinux") = [_]u8{0} ** 32;

pub export fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ movq %rsp, %rdi
        \\ andq $-16, %rsp
        \\ call testMain
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

inline fn sys6(n: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) isize {
    return asm volatile ("syscall"
        : [r] "={rax}" (-> isize),
        : [n] "{rax}" (n),
          [a] "{rdi}" (a1),
          [b] "{rsi}" (a2),
          [c] "{rdx}" (a3),
          [d] "{r10}" (a4),
          [e] "{r8}"  (a5),
          [f] "{r9}"  (a6),
        : "rcx", "r11", "memory"
    );
}

const SYS_READ: usize = 0;
const SYS_WRITE: usize = 1;
const SYS_OPEN: usize = 2;
const SYS_CLOSE: usize = 3;
const SYS_LSEEK: usize = 8;
const SYS_MMAP: usize = 9;
const SYS_PREAD64: usize = 17;
const SYS_EXIT: usize = 60;
const SYS_READLINK: usize = 89;
const SYS_UNLINK: usize = 87;
const SYS_EXIT_GROUP: usize = 231;
const SYS_OPENAT: usize = 257;
const SYS_READLINKAT: usize = 267;

const O_RDONLY: usize = 0;
const O_WRONLY: usize = 1;
const O_RDWR: usize = 2;
const O_CREAT: usize = 0o100;
const O_TRUNC: usize = 0o1000;

const PROT_READ: usize = 0x1;
const PROT_WRITE: usize = 0x2;
const MAP_PRIVATE: usize = 0x02;
const MAP_FIXED: usize = 0x10;
const MAP_ANONYMOUS: usize = 0x20;

const SEEK_SET: usize = 0;
const SEEK_CUR: usize = 1;
const SEEK_END: usize = 2;

const EPERM: isize = -1;
const ENOENT: isize = -2;
const ENOEXEC: isize = -8;
const EBADF: isize = -9;
const EFAULT: isize = -14;
const EINVAL: isize = -22;

const AT_NULL: u64 = 0;
const AT_PHDR: u64 = 3;
const AT_PHENT: u64 = 4;
const AT_PHNUM: u64 = 5;
const AT_PAGESZ: u64 = 6;
const AT_BASE: u64 = 7;
const AT_ENTRY: u64 = 9;
const AT_RANDOM: u64 = 25;

fn print(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("\n[CHALLENGER11_FAIL] Code ");
    var num_buf: [16]u8 = undefined;
    var val = code;
    var idx: usize = num_buf.len;
    if (val == 0) {
        idx -= 1;
        num_buf[idx] = '0';
    } else {
        while (val > 0) {
            idx -= 1;
            num_buf[idx] = '0' + @as(u8, @intCast(val % 10));
            val /= 10;
        }
    }
    print(num_buf[idx..]);
    print(": ");
    print(msg);
    print("\n");
    _ = sys1(SYS_EXIT_GROUP, code);
    unreachable;
}

pub export fn testMain(initial_rsp: [*]const u64) callconv(.C) noreturn {
    asm volatile ("" : : [p1] "r" (&interp_path), [p2] "r" (&abi_note) : "memory");

    print("\n[CHALLENGER11] START: TASK-011 Dynamic ELF Loader & Auxv Empirical Challenge Suite\n");

    // =========================================================================
    // Challenge 1: Stack Pointer Alignment & Auxiliary Vector Verification
    // =========================================================================
    print("[CHALLENGER11] Challenge 1: Stack pointer 16-byte alignment & Auxv contract...\n");

    const raw_rsp = @intFromPtr(initial_rsp);
    if ((raw_rsp % 16) != 0) fail(101, "initial_rsp is not 16-byte aligned");

    const argc = initial_rsp[0];
    if (argc < 1) fail(102, "argc is less than 1");

    var idx: usize = 1 + @as(usize, @intCast(argc)) + 1;
    while (initial_rsp[idx] != 0) : (idx += 1) {}
    idx += 1; // Skip terminating NULL of envp

    var found_base: u64 = 0;
    var found_entry: u64 = 0;
    var found_phdr: u64 = 0;
    var found_phent: u64 = 0;
    var found_phnum: u64 = 0;
    var found_pagesz: u64 = 0;
    var found_random: u64 = 0;
    var found_null = false;

    while (idx < 500) {
        const key = initial_rsp[idx];
        const val = initial_rsp[idx + 1];
        if (key == AT_NULL) {
            found_null = true;
            break;
        }
        if (key == AT_BASE) found_base = val;
        if (key == AT_ENTRY) found_entry = val;
        if (key == AT_PHDR) found_phdr = val;
        if (key == AT_PHENT) found_phent = val;
        if (key == AT_PHNUM) found_phnum = val;
        if (key == AT_PAGESZ) found_pagesz = val;
        if (key == AT_RANDOM) found_random = val;
        idx += 2;
    }

    if (!found_null) fail(103, "AT_NULL pair not found in auxv");
    if (found_base != 0x1800_0000) fail(104, "AT_BASE is not 0x18000000");
    if (found_entry == 0) fail(105, "AT_ENTRY is zero");
    if (found_phdr == 0) fail(106, "AT_PHDR is zero");
    if (found_phent != 56) fail(107, "AT_PHENT is not 56 bytes");
    if (found_phnum == 0) fail(108, "AT_PHNUM is zero");
    if (found_pagesz != 4096) fail(109, "AT_PAGESZ is not 4096 bytes");
    if (found_random == 0) fail(110, "AT_RANDOM pointer is null");

    print("[CHALLENGER11] PASS: RSP alignment (16-byte) and Auxv contract confirmed.\n");

    // =========================================================================
    // Challenge 2: sys_pread64 Semantics & Seek Offset Invariance
    // =========================================================================
    print("[CHALLENGER11] Challenge 2: sys_pread64 offset isolation, EOF, and error handling...\n");

    const so_path = "/lib/libtinux.so\x00";
    const fd_so = sys3(SYS_OPEN, @intFromPtr(so_path.ptr), O_RDONLY, 0);
    if (fd_so < 0) fail(201, "Failed to open /lib/libtinux.so");
    const ufd_so: usize = @intCast(fd_so);

    // Initial seek position should be 0
    const initial_off = sys3(SYS_LSEEK, ufd_so, 0, SEEK_CUR);
    if (initial_off != 0) fail(202, "Initial file offset is not 0");

    // Advance file offset to 5 using lseek
    const moved_off = sys3(SYS_LSEEK, ufd_so, 5, SEEK_SET);
    if (moved_off != 5) fail(203, "lseek SEEK_SET 5 failed");

    // Issue pread64 at offset 0 for 8 bytes ("TINUX_SO")
    var buf_pread: [32]u8 = undefined;
    const n1 = sys4(SYS_PREAD64, ufd_so, @intFromPtr(&buf_pread), 8, 0);
    if (n1 != 8) fail(204, "pread64 at offset 0 failed to read 8 bytes");
    if (!std.mem.eql(u8, buf_pread[0..8], "TINUX_SO")) fail(205, "pread64 content mismatch at offset 0");

    // Crucial check: verify file offset in fd_table has NOT changed from 5!
    const cur_off_after_pread = sys3(SYS_LSEEK, ufd_so, 0, SEEK_CUR);
    if (cur_off_after_pread != 5) fail(206, "pread64 modified file descriptor offset (POSIX violation)");

    // Issue pread64 with count == 0: must return 0
    const n_zero = sys4(SYS_PREAD64, ufd_so, @intFromPtr(&buf_pread), 0, 0);
    if (n_zero != 0) fail(207, "pread64 with count 0 did not return 0");

    // Issue pread64 past EOF: offset 1000 on small file: must return 0
    const n_past_eof = sys4(SYS_PREAD64, ufd_so, @intFromPtr(&buf_pread), 16, 1000);
    if (n_past_eof != 0) fail(208, "pread64 past EOF did not return 0");

    // Issue pread64 with bad fd: must return -EBADF (-9)
    const n_bad_fd = sys4(SYS_PREAD64, 999, @intFromPtr(&buf_pread), 8, 0);
    if (n_bad_fd != EBADF) fail(209, "pread64 with invalid fd did not return -EBADF");

    // Issue pread64 with invalid buffer pointer: must return -EFAULT (-14)
    const n_bad_buf = sys4(SYS_PREAD64, ufd_so, 0xFFFF_FFFF_8000_0000, 8, 0);
    if (n_bad_buf != EFAULT) fail(210, "pread64 with invalid buffer did not return -EFAULT");

    _ = sys1(SYS_CLOSE, ufd_so);

    print("[CHALLENGER11] PASS: sys_pread64 semantics and offset invariance confirmed.\n");

    // =========================================================================
    // Challenge 3: sys_readlink and sys_readlinkat (/proc/self/exe & symlinks)
    // =========================================================================
    print("[CHALLENGER11] Challenge 3: sys_readlink & sys_readlinkat /proc/self/exe resolution...\n");

    var exe_buf: [128]u8 = undefined;
    const exe_path_req = "/proc/self/exe\x00";

    // 3.1 Test sys_readlink
    const n_rl = sys3(SYS_READLINK, @intFromPtr(exe_path_req.ptr), @intFromPtr(&exe_buf), exe_buf.len);
    if (n_rl <= 0) fail(301, "readlink /proc/self/exe returned <= 0");
    const u_rl: usize = @intCast(n_rl);
    print("  /proc/self/exe resolved via readlink: ");
    print(exe_buf[0..u_rl]);
    print("\n");

    // 3.2 Test sys_readlinkat with AT_FDCWD (-100)
    const AT_FDCWD: usize = @bitCast(@as(isize, -100));
    var exe_buf2: [128]u8 = undefined;
    const n_rlat = sys4(SYS_READLINKAT, AT_FDCWD, @intFromPtr(exe_path_req.ptr), @intFromPtr(&exe_buf2), exe_buf2.len);
    if (n_rlat != n_rl) fail(302, "readlinkat length differs from readlink");
    if (!std.mem.eql(u8, exe_buf[0..u_rl], exe_buf2[0..u_rl])) fail(303, "readlinkat target string mismatch");

    // 3.3 Test readlink on non-existent path: must return -ENOENT (-2)
    const non_exist = "/nonexistent/symlink\x00";
    const n_noent = sys3(SYS_READLINK, @intFromPtr(non_exist.ptr), @intFromPtr(&exe_buf), exe_buf.len);
    if (n_noent != ENOENT) fail(304, "readlink on non-existent path did not return -ENOENT");

    // 3.4 Test readlink with invalid user buffer: must return -EFAULT (-14)
    const n_fault = sys3(SYS_READLINK, @intFromPtr(exe_path_req.ptr), 0xFFFF_FFFF_8000_0000, 32);
    if (n_fault != EFAULT) fail(305, "readlink with invalid user buffer did not return -EFAULT");

    print("[CHALLENGER11] PASS: sys_readlink and sys_readlinkat contracts confirmed.\n");

    // =========================================================================
    // Challenge 4: sys_mmap MAP_FIXED & File Remapping
    // =========================================================================
    print("[CHALLENGER11] Challenge 4: sys_mmap MAP_FIXED anonymous & file-backed remapping...\n");

    const fix_addr1: usize = 0x2800_0000;
    // 4.1 Anonymous MAP_FIXED at 0x2800_0000
    const map1 = sys6(SYS_MMAP, fix_addr1, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, 0, 0);
    if (map1 != @as(isize, @intCast(fix_addr1))) fail(401, "mmap MAP_FIXED at 0x2800_0000 failed");

    // Write a test pattern to mapped address
    const p_test = @as([*]u8, @ptrFromInt(fix_addr1));
    @memcpy(p_test[0..16], "OriginalPattern!");
    if (!std.mem.eql(u8, p_test[0..16], "OriginalPattern!")) fail(402, "Failed to read back pattern from mapped memory");

    // 4.2 Overwrite remapping at exact same address 0x2800_0000 with MAP_FIXED
    // According to POSIX, MAP_FIXED replaces the previous mapping with fresh zeroed pages
    const map1_overwrite = sys6(SYS_MMAP, fix_addr1, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, 0, 0);
    if (map1_overwrite != @as(isize, @intCast(fix_addr1))) fail(403, "mmap MAP_FIXED overwrite failed");

    // Verify that the memory has been zeroed and old pattern is gone
    var is_zeroed = true;
    for (p_test[0..16]) |b| {
        if (b != 0) {
            is_zeroed = false;
            break;
        }
    }
    if (!is_zeroed) fail(404, "MAP_FIXED remapping did not zero-initialize newly mapped page");

    // 4.3 File-backed MAP_FIXED at 0x2900_0000 from /lib/libtinux.so
    const fix_addr2: usize = 0x2900_0000;
    const fd_so2 = sys3(SYS_OPEN, @intFromPtr(so_path.ptr), O_RDONLY, 0);
    if (fd_so2 < 0) fail(405, "Failed to reopen /lib/libtinux.so for mmap");
    const ufd_so2: usize = @intCast(fd_so2);

    const map_file = sys6(SYS_MMAP, fix_addr2, 4096, PROT_READ, MAP_PRIVATE | MAP_FIXED, ufd_so2, 0);
    _ = sys1(SYS_CLOSE, ufd_so2);
    if (map_file != @as(isize, @intCast(fix_addr2))) fail(406, "File-backed mmap MAP_FIXED failed");

    const p_file = @as([*]const u8, @ptrFromInt(fix_addr2));
    if (!std.mem.eql(u8, p_file[0..8], "TINUX_SO")) fail(407, "File-backed mmap content mismatch at 0x2900_0000");

    // 4.4 mmap with length == 0 must fail with -EINVAL (-22)
    const map_zero_len = sys6(SYS_MMAP, 0, 0, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);
    if (map_zero_len != EINVAL) fail(408, "mmap with len 0 did not return -EINVAL");

    print("[CHALLENGER11] PASS: sys_mmap MAP_FIXED anonymous & file remapping confirmed.\n");

    // =========================================================================
    // Challenge 5: Dynamic Linker Co-Loading & Shared Memory Verification
    // =========================================================================
    print("[CHALLENGER11] Challenge 5: ld-musl co-loading & 0x25000000 shared object access...\n");

    // In TASK-011, ld-musl loaded at AT_BASE=0x1800_0000 maps /lib/libtinux.so at 0x2500_0000
    // Verify that our process space has access to this mapping
    const shared_slice = @as([*]const u8, @ptrFromInt(0x2500_0000))[0..24];
    if (!std.mem.eql(u8, shared_slice[0..8], "TINUX_SO")) {
        fail(501, "Shared library memory at 0x2500_0000 is invalid or unmapped");
    }

    print("[CHALLENGER11] PASS: ld-musl co-loading and shared library mapping confirmed.\n");

    print("\n[CHALLENGER11] ALL 5 ADVERSARIAL CHALLENGES EMPIRICALLY CONFIRMED!\n");
    _ = sys1(SYS_EXIT_GROUP, 0);
    unreachable;
}

pub fn main() void {}
