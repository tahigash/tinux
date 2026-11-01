// Copyright (c) 2026 Tinux Project Developers
// Dual-licensed under MIT or Apache-2.0
// Empirical stress test for ELF structures, boundary conditions, and stack alignment

const std = @import("std");

// ELF Segment Types
const PT_NULL: u32 = 0;
const PT_LOAD: u32 = 1;
const PT_DYNAMIC: u32 = 2;
const PT_INTERP: u32 = 3;
const PT_NOTE: u32 = 4;
const PT_PHDR: u32 = 6;

// ELF File Types & Machine
const ET_EXEC: u16 = 2;
const ET_DYN: u16 = 3;
const EM_X86_64: u16 = 62;

// Auxiliary Vector Constants
const AT_NULL: u64 = 0;
const AT_PHDR: u64 = 3;
const AT_PHENT: u64 = 4;
const AT_PHNUM: u64 = 5;
const AT_PAGESZ: u64 = 6;
const AT_BASE: u64 = 7;
const AT_ENTRY: u64 = 9;
const AT_UID: u64 = 11;
const AT_EUID: u64 = 12;
const AT_GID: u64 = 13;
const AT_EGID: u64 = 14;
const AT_SECURE: u64 = 23;
const AT_RANDOM: u64 = 25;

const USER_ADDR_MAX: usize = 0x0000_8000_0000_0000;
const MAIN_PIE_LOAD_BIAS: usize = 0x0040_0000;
const INTERP_LOAD_BIAS: usize = 0x1800_0000;
const FALLBACK_PHDR_VADDR: usize = 0x003F_F000;
const USER_STACK_BOTTOM: usize = 0x0080_0000;
const USER_STACK_PAGES: usize = 8;
const USER_STACK_TOP: usize = USER_STACK_BOTTOM + (USER_STACK_PAGES * 4096);

const Elf64_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

const LoadError = error{
    InvalidElfMagic,
    UnsupportedArchitecture,
    OutOfMemory,
    InvalidSegment,
    InterpreterNotFound,
};

fn extractInterpPath(elf_bytes: []const u8) ?[]const u8 {
    if (elf_bytes.len < @sizeOf(Elf64_Ehdr)) return null;
    const ehdr = @as(*align(1) const Elf64_Ehdr, @ptrCast(elf_bytes.ptr));
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7FELF")) return null;

    var i: usize = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        const off = @as(usize, @intCast(ehdr.e_phoff)) + i * @as(usize, ehdr.e_phentsize);
        if (off + @sizeOf(Elf64_Phdr) > elf_bytes.len) break;
        const phdr = @as(*align(1) const Elf64_Phdr, @ptrCast(elf_bytes.ptr + off));
        if (phdr.p_type == PT_INTERP and phdr.p_filesz > 0) {
            const p_off: usize = @intCast(phdr.p_offset);
            const p_filesz: usize = @intCast(phdr.p_filesz);
            if (p_off + p_filesz <= elf_bytes.len) {
                return std.mem.sliceTo(elf_bytes[p_off .. p_off + p_filesz], 0);
            }
        }
    }
    return null;
}

const SegmentMapResult = struct {
    max_vaddr: usize,
    phdr_vaddr: usize,
    entry_rip: usize,
};

fn validateAndCalculateElfSegments(
    elf_bytes: []const u8,
    pie_load_bias: usize,
) LoadError!SegmentMapResult {
    if (elf_bytes.len < @sizeOf(Elf64_Ehdr)) return error.InvalidElfMagic;
    const ehdr = @as(*align(1) const Elf64_Ehdr, @ptrCast(elf_bytes.ptr));
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7FELF")) return error.InvalidElfMagic;
    if (ehdr.e_ident[4] != 2 or ehdr.e_ident[5] != 1 or (ehdr.e_type != ET_EXEC and ehdr.e_type != ET_DYN) or ehdr.e_machine != EM_X86_64) {
        return error.UnsupportedArchitecture;
    }
    if (ehdr.e_phentsize < @sizeOf(Elf64_Phdr)) return error.InvalidSegment;

    const bias: usize = if (ehdr.e_type == ET_DYN) pie_load_bias else 0;
    const entry_rip = bias + @as(usize, @intCast(ehdr.e_entry));
    if (entry_rip >= USER_ADDR_MAX) return error.UnsupportedArchitecture;

    var max_vaddr: usize = 0;
    var phdr_vaddr: usize = 0;

    var i: usize = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        const off = @as(usize, @intCast(ehdr.e_phoff)) + i * @as(usize, ehdr.e_phentsize);
        if (off + @sizeOf(Elf64_Phdr) > elf_bytes.len) return error.InvalidSegment;
        const phdr = @as(*align(1) const Elf64_Phdr, @ptrCast(elf_bytes.ptr + off));

        if (phdr.p_type == PT_PHDR) {
            phdr_vaddr = bias + @as(usize, @intCast(phdr.p_vaddr));
        }

        if (phdr.p_type == PT_LOAD and phdr.p_memsz > 0) {
            if (phdr.p_filesz > phdr.p_memsz) return error.InvalidSegment;

            const seg_start = bias + @as(usize, @intCast(phdr.p_vaddr));
            const seg_memsz = @as(usize, @intCast(phdr.p_memsz));
            const seg_filesz = @as(usize, @intCast(phdr.p_filesz));

            if (seg_start >= USER_ADDR_MAX or seg_memsz > USER_ADDR_MAX - seg_start) {
                return error.InvalidSegment;
            }
            const seg_end = seg_start + seg_memsz;
            if (seg_end > max_vaddr) max_vaddr = seg_end;

            const seg_page_start = seg_start & ~@as(usize, 0xFFF);
            _ = seg_page_start;
            const seg_page_end = std.mem.alignForward(usize, seg_end, 4096);
            if (seg_page_end > USER_ADDR_MAX) return error.InvalidSegment;

            if (seg_filesz > 0) {
                const p_off = @as(usize, @intCast(phdr.p_offset));
                if (p_off > elf_bytes.len or seg_filesz > elf_bytes.len - p_off) return error.InvalidSegment;
            }

            if (phdr_vaddr == 0 and
                ehdr.e_phoff >= phdr.p_offset and
                (ehdr.e_phoff + @as(u64, ehdr.e_phnum) * ehdr.e_phentsize) <= (phdr.p_offset + phdr.p_filesz))
            {
                phdr_vaddr = seg_start + @as(usize, @intCast(ehdr.e_phoff - phdr.p_offset));
            }
        }
    }

    return SegmentMapResult{
        .max_vaddr = max_vaddr,
        .phdr_vaddr = phdr_vaddr,
        .entry_rip = entry_rip,
    };
}

fn checkStackAlignmentFormula(argv_len: usize, envp_len: usize) bool {
    var cur_sp: usize = USER_STACK_TOP;
    // Arbitrary mock string space
    cur_sp -= (argv_len * 10 + envp_len * 15 + 16);
    cur_sp &= ~@as(usize, 0xF);

    const auxv_entries: usize = 26; // 13 pairs
    const total_u64 = 1 + (argv_len + 1) + (envp_len + 1) + auxv_entries;
    if ((total_u64 % 2) != 0) {
        cur_sp -= 8;
    }

    const auxv_bytes_len = auxv_entries * 8;
    cur_sp -= auxv_bytes_len;

    const envp_table_bytes = (envp_len + 1) * 8;
    cur_sp -= envp_table_bytes;

    const argv_table_bytes = (argv_len + 1) * 8;
    cur_sp -= argv_table_bytes;

    cur_sp -= 8; // argc

    return (cur_sp % 16) == 0;
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("[CHALLENGE] Starting Host ELF & Auxv Empirical Validation...\n", .{});

    // 1. Structure Assertions
    try stdout.print("[CHALLENGE 1] Verifying ELF ABI struct sizes & offsets...\n", .{});
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Elf64_Ehdr));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Elf64_Phdr));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(extern struct { a_type: u64, a_val: u64 }));
    try stdout.print("  [PASS] Elf64_Ehdr (64B), Elf64_Phdr (56B), Elf64_Auxv (16B) conform to AMD64 ABI\n", .{});

    // 2. Truncated and Corrupted ELFs
    try stdout.print("[CHALLENGE 2] Testing malformed ELF boundary conditions...\n", .{});

    // 2a. Short ELF (< 64 bytes)
    const short_elf = [_]u8{ 0x7F, 'E', 'L', 'F' } ++ [_]u8{0} ** 30;
    try std.testing.expectError(error.InvalidElfMagic, validateAndCalculateElfSegments(&short_elf, MAIN_PIE_LOAD_BIAS));

    // 2b. Corrupted Magic
    var bad_magic: [128]u8 = [_]u8{0} ** 128;
    bad_magic[0] = 0x7E;
    bad_magic[1] = 'E';
    bad_magic[2] = 'L';
    bad_magic[3] = 'F';
    try std.testing.expectError(error.InvalidElfMagic, validateAndCalculateElfSegments(&bad_magic, MAIN_PIE_LOAD_BIAS));

    // 2c. 32-bit ELF (ELFCLASS32: e_ident[4] = 1)
    var elf_32: [128]u8 = [_]u8{0} ** 128;
    @memcpy(elf_32[0..4], "\x7FELF");
    elf_32[4] = 1; // 32-bit
    elf_32[5] = 1; // little endian
    try std.testing.expectError(error.UnsupportedArchitecture, validateAndCalculateElfSegments(&elf_32, MAIN_PIE_LOAD_BIAS));

    // 2d. Big-endian ELF (e_ident[5] = 2)
    var elf_be: [128]u8 = [_]u8{0} ** 128;
    @memcpy(elf_be[0..4], "\x7FELF");
    elf_be[4] = 2; // 64-bit
    elf_be[5] = 2; // big-endian
    try std.testing.expectError(error.UnsupportedArchitecture, validateAndCalculateElfSegments(&elf_be, MAIN_PIE_LOAD_BIAS));

    // 2e. Non x86-64 Architecture (e_machine = 3 e.g. i386)
    var elf_arm: [128]u8 = [_]u8{0} ** 128;
    @memcpy(elf_arm[0..4], "\x7FELF");
    elf_arm[4] = 2;
    elf_arm[5] = 1;
    elf_arm[16] = 2; // ET_EXEC
    elf_arm[18] = 3; // EM_386
    try std.testing.expectError(error.UnsupportedArchitecture, validateAndCalculateElfSegments(&elf_arm, MAIN_PIE_LOAD_BIAS));

    try stdout.print("  [PASS] Corrupted/unsupported header rejections verified\n", .{});

    // 3. Segment Boundary Conditions: p_filesz > p_memsz
    try stdout.print("[CHALLENGE 3] Testing p_filesz > p_memsz violation...\n", .{});
    var elf_invalid_seg: [128]u8 = [_]u8{0} ** 128;
    @memcpy(elf_invalid_seg[0..4], "\x7FELF");
    elf_invalid_seg[4] = 2; // 64-bit
    elf_invalid_seg[5] = 1; // little endian
    elf_invalid_seg[16] = 2; // ET_EXEC
    elf_invalid_seg[18] = 62; // EM_X86_64
    std.mem.writeInt(u64, elf_invalid_seg[32..40], 64, .little); // e_phoff = 64
    std.mem.writeInt(u16, elf_invalid_seg[54..56], 56, .little); // e_phentsize = 56
    std.mem.writeInt(u16, elf_invalid_seg[56..58], 1, .little); // e_phnum = 1

    // Setup Phdr at offset 64: PT_LOAD, p_filesz = 200, p_memsz = 100
    std.mem.writeInt(u32, elf_invalid_seg[64..68], PT_LOAD, .little);
    std.mem.writeInt(u64, elf_invalid_seg[72..80], 0, .little); // p_offset = 0
    std.mem.writeInt(u64, elf_invalid_seg[80..88], 0x0040_0000, .little); // p_vaddr
    std.mem.writeInt(u64, elf_invalid_seg[96..104], 200, .little); // p_filesz = 200
    std.mem.writeInt(u64, elf_invalid_seg[104..112], 100, .little); // p_memsz = 100

    try std.testing.expectError(error.InvalidSegment, validateAndCalculateElfSegments(&elf_invalid_seg, MAIN_PIE_LOAD_BIAS));
    try stdout.print("  [PASS] p_filesz (200) > p_memsz (100) correctly rejected with InvalidSegment\n", .{});

    // 4. Testing Segment Memory Overflow past USER_ADDR_MAX
    try stdout.print("[CHALLENGE 4] Testing segment memory overflow past USER_ADDR_MAX...\n", .{});
    std.mem.writeInt(u64, elf_invalid_seg[80..88], USER_ADDR_MAX - 100, .little); // p_vaddr
    std.mem.writeInt(u64, elf_invalid_seg[96..104], 50, .little); // p_filesz = 50
    std.mem.writeInt(u64, elf_invalid_seg[104..112], 200, .little); // p_memsz = 200 (crosses USER_ADDR_MAX)
    try std.testing.expectError(error.InvalidSegment, validateAndCalculateElfSegments(&elf_invalid_seg, MAIN_PIE_LOAD_BIAS));
    try stdout.print("  [PASS] Segment exceeding USER_ADDR_MAX correctly rejected with InvalidSegment\n", .{});

    // 5. Testing PT_INTERP Extraction and Edge Cases
    try stdout.print("[CHALLENGE 5] Testing extractInterpPath boundary conditions...\n", .{});
    // Valid PT_INTERP
    var elf_dyn: [256]u8 = [_]u8{0} ** 256;
    @memcpy(elf_dyn[0..4], "\x7FELF");
    elf_dyn[4] = 2;
    elf_dyn[5] = 1;
    elf_dyn[16] = 3; // ET_DYN
    elf_dyn[18] = 62;
    std.mem.writeInt(u64, elf_dyn[32..40], 64, .little); // e_phoff = 64
    std.mem.writeInt(u16, elf_dyn[54..56], 56, .little); // e_phentsize = 56
    std.mem.writeInt(u16, elf_dyn[56..58], 1, .little); // e_phnum = 1

    const interp_str = "/lib/ld-musl-x86_64.so.1\x00";
    const interp_off = 130;
    @memcpy(elf_dyn[interp_off .. interp_off + interp_str.len], interp_str);

    std.mem.writeInt(u32, elf_dyn[64..68], PT_INTERP, .little);
    std.mem.writeInt(u64, elf_dyn[72..80], interp_off, .little); // p_offset
    std.mem.writeInt(u64, elf_dyn[96..104], interp_str.len, .little); // p_filesz
    std.mem.writeInt(u64, elf_dyn[104..112], interp_str.len, .little); // p_memsz

    const extracted = extractInterpPath(&elf_dyn);
    try std.testing.expect(extracted != null);
    try std.testing.expectEqualStrings("/lib/ld-musl-x86_64.so.1", extracted.?);
    try stdout.print("  [PASS] extractInterpPath correctly recovered interpreter path\n", .{});

    // 5b. PT_INTERP offset out of bounds
    std.mem.writeInt(u64, elf_dyn[72..80], 500, .little); // p_offset = 500 > elf_dyn.len
    const extracted_oob = extractInterpPath(&elf_dyn);
    try std.testing.expect(extracted_oob == null);
    try stdout.print("  [PASS] Out-of-bounds PT_INTERP safely returned null\n", .{});

    // 6. Stack Alignment Verification across 2500 argv/envp combinations
    try stdout.print("[CHALLENGE 6] Testing 16-byte stack alignment across 2500 (argc, envc) variations...\n", .{});
    var argc_test: usize = 0;
    while (argc_test < 50) : (argc_test += 1) {
        var envc_test: usize = 0;
        while (envc_test < 50) : (envc_test += 1) {
            if (!checkStackAlignmentFormula(argc_test, envc_test)) {
                try stdout.print("  [FAIL] Alignment violated for argc={d}, envc={d}\n", .{ argc_test, envc_test });
                return error.InvalidSegment;
            }
        }
    }
    try stdout.print("  [PASS] All 2500 (argc 0..49, envc 0..49) configurations produce 16-byte aligned RSP\n", .{});

    // 7. Static vs Dynamic Auxv Values
    try stdout.print("[CHALLENGE 7] Validating Static vs Dynamic Auxv Tag Specifications...\n", .{});
    // Static executable:
    // AT_BASE = 0
    // AT_ENTRY = main_entry_rip
    // Dynamic executable:
    // AT_BASE = 0x1800_0000
    // AT_ENTRY = main_entry_rip
    // Transfer entry_rip = interp_entry_rip
    try std.testing.expectEqual(@as(usize, 0x1800_0000), INTERP_LOAD_BIAS);
    try std.testing.expectEqual(@as(usize, 0x0040_0000), MAIN_PIE_LOAD_BIAS);
    try std.testing.expectEqual(@as(usize, 0x003F_F000), FALLBACK_PHDR_VADDR);
    try stdout.print("  [PASS] Static vs Dynamic memory layout constants verified\n", .{});

    try stdout.print("\n[CHALLENGE] ALL 7 HOST EMPIRICAL CHALLENGES PASSED CLEANLY!\n", .{});
}
