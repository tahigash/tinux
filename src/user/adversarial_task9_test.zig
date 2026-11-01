// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Adversarial test suite for TASK-009: Writable tmpfs, dynamic reallocation, MAX_FILE_SIZE limit, directory protection, and rmdir semantics

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
const SYS_EXIT: usize = 60;
const SYS_MKDIR: usize = 83;
const SYS_RMDIR: usize = 84;
const SYS_CREAT: usize = 85;
const SYS_UNLINK: usize = 87;
const SYS_GETDENTS64: usize = 217;
const SYS_OPENAT: usize = 257;
const SYS_MKDIRAT: usize = 258;
const SYS_UNLINKAT: usize = 263;

const O_RDONLY: usize = 0;
const O_WRONLY: usize = 1;
const O_RDWR: usize = 2;
const O_CREAT: usize = 0o100;
const O_EXCL: usize = 0o200;
const O_TRUNC: usize = 0o1000;
const O_APPEND: usize = 0o2000;
const O_DIRECTORY: usize = 0o200000;

const AT_FDCWD: usize = @bitCast(@as(isize, -100));
const AT_REMOVEDIR: usize = 0x200;

const SEEK_SET: usize = 0;
const SEEK_CUR: usize = 1;
const SEEK_END: usize = 2;

const EPERM: isize = -1;
const ENOENT: isize = -2;
const EBADF: isize = -9;
const EEXIST: isize = -17;
const ENOTDIR: isize = -20;
const EISDIR: isize = -21;
const EINVAL: isize = -22;
const ENOSPC: isize = -28;
const ENOTEMPTY: isize = -39;

fn print(msg: []const u8) void {
    _ = sys3(SYS_WRITE, 1, @intFromPtr(msg.ptr), msg.len);
}

fn fail(code: usize, msg: []const u8) noreturn {
    print("\n[ADVERSARIAL_FAIL] Error code ");
    // Convert code to decimal
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
    _ = sys1(SYS_EXIT, code);
    unreachable;
}

pub export fn testMain() callconv(.C) noreturn {
    print("\n[ADVERSARIAL_TEST] START: TASK-009 Writable Tmpfs & VFS Semantics Suite\n");

    // =========================================================================
    // Challenge 1: Dynamic Heap Allocation, Truncation, Append, and File Growth
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 1: Dynamic reallocation, O_TRUNC, O_APPEND, and growth...\n");

    const file_path = "/tmp/test_alloc_stress.txt\x00";

    // 1.1 Create new file via O_CREAT | O_RDWR
    const fd1 = sys3(SYS_OPEN, @intFromPtr(file_path.ptr), O_CREAT | O_RDWR | O_TRUNC, 0o644);
    if (fd1 < 0) fail(101, "Failed to open /tmp/test_alloc_stress.txt with O_CREAT | O_RDWR | O_TRUNC");
    const ufd1: usize = @intCast(fd1);

    // Initial small write: 16 bytes
    const chunk1 = "InitialBlock1234";
    const w1 = sys3(SYS_WRITE, ufd1, @intFromPtr(chunk1.ptr), chunk1.len);
    if (w1 != @as(isize, @intCast(chunk1.len))) fail(102, "Initial 16-byte write failed");

    // Sequential write: 16 bytes
    const chunk2 = "SecondBlock_5678";
    const w2 = sys3(SYS_WRITE, ufd1, @intFromPtr(chunk2.ptr), chunk2.len);
    if (w2 != @as(isize, @intCast(chunk2.len))) fail(103, "Second 16-byte write failed");

    // Lseek back to 0 and verify 32 bytes read back
    const seek_res = sys3(SYS_LSEEK, ufd1, 0, SEEK_SET);
    if (seek_res != 0) fail(104, "lseek SEEK_SET 0 failed");

    var read_buf: [64]u8 = undefined;
    const r1 = sys3(SYS_READ, ufd1, @intFromPtr(&read_buf), 32);
    if (r1 != 32) fail(105, "Read back of 32 bytes failed");
    if (!std.mem.eql(u8, read_buf[0..16], chunk1)) fail(106, "chunk1 mismatch");
    if (!std.mem.eql(u8, read_buf[16..32], chunk2)) fail(107, "chunk2 mismatch");

    _ = sys1(SYS_CLOSE, ufd1);

    // 1.2 Test O_TRUNC
    const fd_trunc = sys3(SYS_OPEN, @intFromPtr(file_path.ptr), O_RDWR | O_TRUNC, 0);
    if (fd_trunc < 0) fail(108, "Failed to open with O_TRUNC");
    const ufd_trunc: usize = @intCast(fd_trunc);

    // Read immediately: should return 0 (EOF, file size truncated to 0)
    const r_trunc = sys3(SYS_READ, ufd_trunc, @intFromPtr(&read_buf), 32);
    if (r_trunc != 0) fail(109, "O_TRUNC file did not read back 0 bytes (not empty)");

    // Write new content into truncated file: 10 bytes
    const trunc_content = "Truncated!";
    const w_trunc = sys3(SYS_WRITE, ufd_trunc, @intFromPtr(trunc_content.ptr), trunc_content.len);
    if (w_trunc != @as(isize, @intCast(trunc_content.len))) fail(110, "Write into truncated file failed");
    _ = sys1(SYS_CLOSE, ufd_trunc);

    // 1.3 Test O_APPEND
    const fd_app = sys3(SYS_OPEN, @intFromPtr(file_path.ptr), O_RDWR | O_APPEND, 0);
    if (fd_app < 0) fail(111, "Failed to open with O_APPEND");
    const ufd_app: usize = @intCast(fd_app);

    // Deliberately lseek to offset 0: O_APPEND write MUST still write at EOF (offset 10)
    _ = sys3(SYS_LSEEK, ufd_app, 0, SEEK_SET);
    const app_content = "_AppendedExtra";
    const w_app = sys3(SYS_WRITE, ufd_app, @intFromPtr(app_content.ptr), app_content.len);
    if (w_app != @as(isize, @intCast(app_content.len))) fail(112, "O_APPEND write failed");
    _ = sys1(SYS_CLOSE, ufd_app);

    // Verify concatenated content: "Truncated!_AppendedExtra" (24 bytes)
    const fd_verify = sys3(SYS_OPEN, @intFromPtr(file_path.ptr), O_RDONLY, 0);
    if (fd_verify < 0) fail(113, "Failed to reopen file for append verification");
    const r_app = sys3(SYS_READ, @intCast(fd_verify), @intFromPtr(&read_buf), 64);
    if (r_app != 24) fail(114, "O_APPEND verify expected 24 bytes");
    const expected_app = "Truncated!_AppendedExtra";
    if (!std.mem.eql(u8, read_buf[0..24], expected_app)) fail(115, "O_APPEND content mismatch");
    _ = sys1(SYS_CLOSE, @intCast(fd_verify));

    // 1.4 Test dynamic heap buffer growth across 256B, 1KB, 4KB, 16KB, 32KB boundaries
    const fd_grow = sys3(SYS_OPEN, @intFromPtr(file_path.ptr), O_RDWR | O_TRUNC, 0);
    if (fd_grow < 0) fail(116, "Failed to reopen for growth test");
    const ufd_grow: usize = @intCast(fd_grow);

    var pattern_block: [512]u8 = undefined;
    for (&pattern_block, 0..) |*b, i| {
        b.* = @as(u8, @truncate(i ^ 0x5C));
    }

    // Grow in 512-byte blocks up to 32768 bytes (64 blocks)
    var blk_idx: usize = 0;
    while (blk_idx < 64) : (blk_idx += 1) {
        const wr = sys3(SYS_WRITE, ufd_grow, @intFromPtr(&pattern_block), 512);
        if (wr != 512) fail(117, "Growth block write failed");
    }

    // Verify total size is 32768
    const cur_pos = sys3(SYS_LSEEK, ufd_grow, 0, SEEK_CUR);
    if (cur_pos != 32768) fail(118, "File size after 64 blocks is not 32768");

    // Seek back to start and verify integrity of written data
    _ = sys3(SYS_LSEEK, ufd_grow, 0, SEEK_SET);
    var check_block: [512]u8 = undefined;
    blk_idx = 0;
    while (blk_idx < 64) : (blk_idx += 1) {
        const rd = sys3(SYS_READ, ufd_grow, @intFromPtr(&check_block), 512);
        if (rd != 512) fail(119, "Growth block read back failed");
        if (!std.mem.eql(u8, &check_block, &pattern_block)) fail(120, "Growth block data corrupted during reallocation");
    }
    _ = sys1(SYS_CLOSE, ufd_grow);
    _ = sys1(SYS_UNLINK, @intFromPtr(file_path.ptr));

    print("[ADVERSARIAL_TEST] PASS: Dynamic allocation, O_TRUNC, O_APPEND, and growth verified.\n");

    // =========================================================================
    // Challenge 2: Boundary Condition: MAX_FILE_SIZE = 65536 and ENOSPC
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 2: MAX_FILE_SIZE = 65536 boundary and ENOSPC...\n");

    const max_file = "/tmp/max_file_stress.bin\x00";
    const fd_max = sys3(SYS_OPEN, @intFromPtr(max_file.ptr), O_CREAT | O_RDWR | O_TRUNC, 0o644);
    if (fd_max < 0) fail(201, "Failed to open max_file_stress.bin");
    const ufd_max: usize = @intCast(fd_max);

    // Fill exactly up to 65536 bytes (128 blocks of 512 bytes)
    blk_idx = 0;
    while (blk_idx < 128) : (blk_idx += 1) {
        const wr = sys3(SYS_WRITE, ufd_max, @intFromPtr(&pattern_block), 512);
        if (wr != 512) fail(202, "Fill to 65536 failed");
    }

    const end_pos = sys3(SYS_LSEEK, ufd_max, 0, SEEK_CUR);
    if (end_pos != 65536) fail(203, "File offset not at 65536");

    // 2.1 Writing 1 byte past 65536 MUST fail with -ENOSPC (-28)
    const overflow_byte: [1]u8 = .{0xFF};
    const wr_overflow = sys3(SYS_WRITE, ufd_max, @intFromPtr(&overflow_byte), 1);
    if (wr_overflow != ENOSPC) fail(204, "Write past 65536 did not return -ENOSPC (-28)");

    // 2.2 Writing 512 bytes past 65536 MUST fail with -ENOSPC (-28)
    const wr_overflow_large = sys3(SYS_WRITE, ufd_max, @intFromPtr(&pattern_block), 512);
    if (wr_overflow_large != ENOSPC) fail(205, "Large write past 65536 did not return -ENOSPC (-28)");

    // 2.3 Partial overflow check: seek to 65530 (6 bytes remaining) and attempt writing 10 bytes
    // Kernel contract: if offset + count > MAX_FILE_SIZE, returns -ENOSPC without partial write corruption
    _ = sys3(SYS_LSEEK, ufd_max, 65530, SEEK_SET);
    const ten_bytes: [10]u8 = [_]u8{0xAA} ** 10;
    const wr_partial = sys3(SYS_WRITE, ufd_max, @intFromPtr(&ten_bytes), 10);
    if (wr_partial != ENOSPC) fail(206, "Writing 10 bytes at offset 65530 did not return -ENOSPC (-28)");

    // 2.4 Verify valid write within limit still works: seek to 65530 and write exactly 6 bytes (reaches 65536)
    const six_bytes: [6]u8 = [_]u8{0x77} ** 6;
    const wr_valid_boundary = sys3(SYS_WRITE, ufd_max, @intFromPtr(&six_bytes), 6);
    if (wr_valid_boundary != 6) fail(207, "Writing exactly up to boundary 65536 failed");

    _ = sys1(SYS_CLOSE, ufd_max);
    _ = sys1(SYS_UNLINK, @intFromPtr(max_file.ptr));

    print("[ADVERSARIAL_TEST] PASS: MAX_FILE_SIZE = 65536 boundary and ENOSPC verified.\n");

    // =========================================================================
    // Challenge 3: Directory Protection: Writes to Directory Fail with EISDIR
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 3: Directory write protection (EISDIR)...\n");

    const dir_path = "/tmp/test_dir_prot\x00";
    const mk_res = sys2(SYS_MKDIR, @intFromPtr(dir_path.ptr), 0o755);
    if (mk_res != 0) fail(301, "mkdir /tmp/test_dir_prot failed");

    // 3.1 Opening directory with O_WRONLY must fail with -EISDIR (-21)
    const fd_dir_wronly = sys3(SYS_OPEN, @intFromPtr(dir_path.ptr), O_WRONLY, 0);
    if (fd_dir_wronly != EISDIR) fail(302, "open(dir, O_WRONLY) did not return -EISDIR (-21)");

    // 3.2 Opening directory with O_RDWR must fail with -EISDIR (-21)
    const fd_dir_rdwr = sys3(SYS_OPEN, @intFromPtr(dir_path.ptr), O_RDWR, 0);
    if (fd_dir_rdwr != EISDIR) fail(303, "open(dir, O_RDWR) did not return -EISDIR (-21)");

    // 3.3 Opening directory with O_RDONLY succeeds, but write() on that fd must fail with -EISDIR (-21)
    const fd_dir_rd = sys3(SYS_OPEN, @intFromPtr(dir_path.ptr), O_RDONLY, 0);
    if (fd_dir_rd < 0) fail(304, "open(dir, O_RDONLY) failed");
    const ufd_dir_rd: usize = @intCast(fd_dir_rd);

    const dummy_write = "DirectoryCorruptAttempt";
    const wr_dir_res = sys3(SYS_WRITE, ufd_dir_rd, @intFromPtr(dummy_write.ptr), dummy_write.len);
    if (wr_dir_res != EISDIR) fail(305, "write() on directory fd did not return -EISDIR (-21)");

    _ = sys1(SYS_CLOSE, ufd_dir_rd);

    print("[ADVERSARIAL_TEST] PASS: Directory write protection (EISDIR) verified.\n");

    // =========================================================================
    // Challenge 4: Non-Empty Directory Removal (ENOTEMPTY) and Directory Ops
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 4: Non-empty directory removal and rmdir semantics...\n");

    const child_file = "/tmp/test_dir_prot/child.txt\x00";
    const fd_child = sys3(SYS_OPEN, @intFromPtr(child_file.ptr), O_CREAT | O_WRONLY, 0o644);
    if (fd_child < 0) fail(401, "Failed to create child file in test_dir_prot");
    const child_payload = "ChildData";
    _ = sys3(SYS_WRITE, @intCast(fd_child), @intFromPtr(child_payload.ptr), child_payload.len);
    _ = sys1(SYS_CLOSE, @intCast(fd_child));

    // 4.1 sys_rmdir on non-empty directory must fail with -ENOTEMPTY (-39)
    const rmdir_res1 = sys1(SYS_RMDIR, @intFromPtr(dir_path.ptr));
    if (rmdir_res1 != ENOTEMPTY) fail(402, "rmdir on non-empty directory did not return -ENOTEMPTY (-39)");

    // 4.2 sys_unlinkat(AT_FDCWD, dir_path, AT_REMOVEDIR) must also fail with -ENOTEMPTY (-39)
    const unlinkat_res = sys3(SYS_UNLINKAT, AT_FDCWD, @intFromPtr(dir_path.ptr), AT_REMOVEDIR);
    if (unlinkat_res != ENOTEMPTY) fail(403, "unlinkat(AT_REMOVEDIR) on non-empty dir did not return -ENOTEMPTY (-39)");

    // 4.3 unlink on a directory WITHOUT AT_REMOVEDIR must fail with -EISDIR (-21)
    const unlink_dir_res = sys1(SYS_UNLINK, @intFromPtr(dir_path.ptr));
    if (unlink_dir_res != EISDIR) fail(404, "unlink on directory without AT_REMOVEDIR did not return -EISDIR (-21)");

    // 4.4 rmdir on a regular file must fail with -ENOTDIR (-20)
    const rmdir_file_res = sys1(SYS_RMDIR, @intFromPtr(child_file.ptr));
    if (rmdir_file_res != ENOTDIR) fail(405, "rmdir on regular file did not return -ENOTDIR (-20)");

    // 4.5 Remove the child file
    const unlink_child_res = sys1(SYS_UNLINK, @intFromPtr(child_file.ptr));
    if (unlink_child_res != 0) fail(406, "unlink child file failed");

    // 4.6 Now rmdir on empty directory must succeed (returns 0)
    const rmdir_empty_res = sys1(SYS_RMDIR, @intFromPtr(dir_path.ptr));
    if (rmdir_empty_res != 0) fail(407, "rmdir on empty directory failed");

    // 4.7 rmdir on non-existent directory must return -ENOENT (-2)
    const rmdir_noent_res = sys1(SYS_RMDIR, @intFromPtr(dir_path.ptr));
    if (rmdir_noent_res != ENOENT) fail(408, "rmdir on non-existent dir did not return -ENOENT (-2)");

    print("[ADVERSARIAL_TEST] PASS: Non-empty directory removal and rmdir semantics verified.\n");

    // =========================================================================
    // Challenge 5: sys_getdents64 8-Byte Alignment & Dirent Record Integrity
    // =========================================================================
    print("[ADVERSARIAL_TEST] Challenge 5: sys_getdents64 record layout & 8-byte alignment...\n");

    const getdents_dir = "/tmp/dents_test\x00";
    if (sys2(SYS_MKDIR, @intFromPtr(getdents_dir.ptr), 0o755) != 0) fail(501, "mkdir dents_test failed");

    // Create 3 files with varying name lengths: 1 char ("a"), 7 chars ("1234567"), 12 chars ("abcdefghijkl")
    const f1 = "/tmp/dents_test/a\x00";
    const f2 = "/tmp/dents_test/1234567\x00";
    const f3 = "/tmp/dents_test/abcdefghijkl\x00";

    const fd_f1 = sys3(SYS_OPEN, @intFromPtr(f1.ptr), O_CREAT | O_WRONLY, 0o644);
    if (fd_f1 < 0) fail(502, "Failed to create f1");
    _ = sys1(SYS_CLOSE, @intCast(fd_f1));

    const fd_f2 = sys3(SYS_OPEN, @intFromPtr(f2.ptr), O_CREAT | O_WRONLY, 0o644);
    if (fd_f2 < 0) fail(503, "Failed to create f2");
    _ = sys1(SYS_CLOSE, @intCast(fd_f2));

    const fd_f3 = sys3(SYS_OPEN, @intFromPtr(f3.ptr), O_CREAT | O_WRONLY, 0o644);
    if (fd_f3 < 0) fail(504, "Failed to create f3");
    _ = sys1(SYS_CLOSE, @intCast(fd_f3));

    const fd_dents = sys3(SYS_OPEN, @intFromPtr(getdents_dir.ptr), O_RDONLY, 0);
    if (fd_dents < 0) fail(505, "Failed to open dents_test dir");
    const ufd_dents: usize = @intCast(fd_dents);

    var dents_buf: [1024]u8 = [_]u8{0} ** 1024;
    const nread = sys3(SYS_GETDENTS64, ufd_dents, @intFromPtr(&dents_buf), dents_buf.len);
    if (nread <= 0) fail(506, "getdents64 returned <= 0");

    // Parse linux_dirent64 records:
    // Offset 0: d_ino (u64)
    // Offset 8: d_off (i64)
    // Offset 16: d_reclen (u16)
    // Offset 18: d_type (u8)
    // Offset 19: d_name
    var b_off: usize = 0;
    var entry_count: usize = 0;
    var found_dot = false;
    var found_dotdot = false;
    var found_f1 = false;
    var found_f2 = false;
    var found_f3 = false;

    while (b_off < @as(usize, @intCast(nread))) {
        const reclen = std.mem.readInt(u16, dents_buf[b_off + 16 ..][0..2], .little);
        // Verify reclen is positive and 8-byte aligned!
        if (reclen == 0 or (reclen % 8) != 0) fail(507, "d_reclen is not 8-byte aligned");
        if (b_off + reclen > @as(usize, @intCast(nread))) fail(508, "reclen exceeds total bytes read");

        const d_ino = std.mem.readInt(u64, dents_buf[b_off..][0..8], .little);
        if (d_ino == 0) fail(509, "d_ino must be non-zero");

        const d_type = dents_buf[b_off + 18];
        const name_start = b_off + 19;
        var name_len: usize = 0;
        while (name_start + name_len < b_off + reclen and dents_buf[name_start + name_len] != 0) : (name_len += 1) {}
        const name_slice = dents_buf[name_start .. name_start + name_len];

        if (std.mem.eql(u8, name_slice, ".")) {
            found_dot = true;
            if (d_type != 4) fail(510, ". must have DT_DIR (4)");
        } else if (std.mem.eql(u8, name_slice, "..")) {
            found_dotdot = true;
            if (d_type != 4) fail(511, ".. must have DT_DIR (4)");
        } else if (std.mem.eql(u8, name_slice, "a")) {
            found_f1 = true;
            if (d_type != 8) fail(512, "a must have DT_REG (8)");
        } else if (std.mem.eql(u8, name_slice, "1234567")) {
            found_f2 = true;
            if (d_type != 8) fail(513, "1234567 must have DT_REG (8)");
        } else if (std.mem.eql(u8, name_slice, "abcdefghijkl")) {
            found_f3 = true;
            if (d_type != 8) fail(514, "abcdefghijkl must have DT_REG (8)");
        }

        entry_count += 1;
        b_off += reclen;
    }

    if (!found_dot or !found_dotdot or !found_f1 or !found_f2 or !found_f3) {
        fail(515, "Missing expected dirent entries in dents_test");
    }

    _ = sys1(SYS_CLOSE, ufd_dents);

    // Cleanup dents_test
    _ = sys1(SYS_UNLINK, @intFromPtr(f1.ptr));
    _ = sys1(SYS_UNLINK, @intFromPtr(f2.ptr));
    _ = sys1(SYS_UNLINK, @intFromPtr(f3.ptr));
    _ = sys1(SYS_RMDIR, @intFromPtr(getdents_dir.ptr));

    print("[ADVERSARIAL_TEST] PASS: sys_getdents64 layout & 8-byte alignment verified.\n");

    print("\n[ADVERSARIAL_TEST] ALL ADVERSARIAL STRESS CHALLENGES PASSED SUCCESSFULLY!\n");
    _ = sys1(SYS_EXIT, 0);
    unreachable;
}
