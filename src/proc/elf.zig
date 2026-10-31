const std = @import("std");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");

pub const MAIN_PIE_LOAD_BIAS: usize = 0x0040_0000;
pub const FALLBACK_PHDR_VADDR: usize = 0x003F_F000;
pub const USER_STACK_BOTTOM: usize = 0x0080_0000;
pub const USER_STACK_PAGES: usize = 8; // 32 KiB
pub const USER_STACK_TOP: usize = USER_STACK_BOTTOM + (USER_STACK_PAGES * pmm.PAGE_SIZE);
pub const INTERP_LOAD_BIAS: usize = 0x1800_0000;

pub const ET_EXEC: u16 = 2;
pub const ET_DYN: u16 = 3;
pub const EM_X86_64: u16 = 62;

pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_PHDR: u32 = 6;
pub const PT_TLS: u32 = 7;

pub const AT_NULL: u64 = 0;
pub const AT_PHDR: u64 = 3;
pub const AT_PHENT: u64 = 4;
pub const AT_PHNUM: u64 = 5;
pub const AT_PAGESZ: u64 = 6;
pub const AT_BASE: u64 = 7;
pub const AT_ENTRY: u64 = 9;
pub const AT_UID: u64 = 11;
pub const AT_EUID: u64 = 12;
pub const AT_GID: u64 = 13;
pub const AT_EGID: u64 = 14;
pub const AT_SECURE: u64 = 23;
pub const AT_RANDOM: u64 = 25;

pub const Elf64_Ehdr = extern struct {
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

    comptime {
        std.debug.assert(@sizeOf(Elf64_Ehdr) == 64);
    }
};

pub const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,

    comptime {
        std.debug.assert(@sizeOf(Elf64_Phdr) == 56);
    }
};

pub const ElfLoadResult = struct {
    entry_rip: usize,
    user_rsp: usize,
    initial_brk: usize,
    phdr_vaddr: usize,
    phent: u16,
    phnum: u16,
    interp_base: usize = 0,
};

pub const LoadError = error{
    InvalidElfMagic,
    UnsupportedArchitecture,
    OutOfMemory,
    InvalidSegment,
};

pub fn extractInterpPath(elf_bytes: []const u8) ?[]const u8 {
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

pub fn writeToUserVaddr(pml4_phys: usize, dst_vaddr: usize, src: []const u8) bool {
    var i: usize = 0;
    while (i < src.len) {
        const curr_vaddr = dst_vaddr + i;
        const page_off = curr_vaddr & 0xFFF;
        const to_copy = @min(src.len - i, 4096 - page_off);
        const phys = vmm.translate(pml4_phys, curr_vaddr) orelse return false;
        const ptr = @as([*]u8, @ptrFromInt(phys));
        @memcpy(ptr[0..to_copy], src[i .. i + to_copy]);
        i += to_copy;
    }
    return true;
}

pub fn loadElfImageSegments(
    pml4_phys: usize,
    elf_bytes: []const u8,
    forced_bias: ?usize,
) LoadError!struct {
    entry_rip: usize,
    max_vaddr: usize,
    load_bias: usize,
    phdr_vaddr: usize,
    phent: u16,
    phnum: u16,
} {
    if (elf_bytes.len < @sizeOf(Elf64_Ehdr)) return error.InvalidElfMagic;
    const ehdr = @as(*align(1) const Elf64_Ehdr, @ptrCast(elf_bytes.ptr));
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7FELF")) return error.InvalidElfMagic;
    if (ehdr.e_ident[4] != 2 or ehdr.e_ident[5] != 1 or ehdr.e_machine != EM_X86_64) return error.UnsupportedArchitecture;

    const load_bias = if (forced_bias) |b| b else (if (ehdr.e_type == ET_DYN) MAIN_PIE_LOAD_BIAS else 0);

    var max_vaddr: usize = 0;
    var phdr_vaddr: usize = 0;

    var i: usize = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        const off = @as(usize, @intCast(ehdr.e_phoff)) + i * @as(usize, ehdr.e_phentsize);
        if (off + @sizeOf(Elf64_Phdr) > elf_bytes.len) return error.InvalidSegment;
        const phdr = @as(*align(1) const Elf64_Phdr, @ptrCast(elf_bytes.ptr + off));

        if (phdr.p_type == PT_LOAD and phdr.p_memsz > 0) {
            const seg_vaddr = load_bias + @as(usize, @intCast(phdr.p_vaddr));
            const map_start = seg_vaddr & ~@as(usize, 0xFFF);
            const map_end = std.mem.alignForward(usize, seg_vaddr + @as(usize, @intCast(phdr.p_memsz)), 4096);

            var page = map_start;
            while (page < map_end) : (page += 4096) {
                if (vmm.getPteFlags(pml4_phys, page) == null) {
                    const paddr = pmm.allocZeroedPage() orelse return error.OutOfMemory;
                    _ = vmm.mapPage(pml4_phys, page, paddr, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
                }
            }

            const p_off: usize = @intCast(phdr.p_offset);
            const p_filesz: usize = @intCast(phdr.p_filesz);
            if (p_filesz > 0) {
                _ = writeToUserVaddr(pml4_phys, seg_vaddr, elf_bytes[p_off .. p_off + p_filesz]);
            }

            const seg_end = seg_vaddr + @as(usize, @intCast(phdr.p_memsz));
            if (seg_end > max_vaddr) max_vaddr = seg_end;

            if (ehdr.e_phoff >= phdr.p_offset and (ehdr.e_phoff + @as(u64, ehdr.e_phnum) * ehdr.e_phentsize) <= (phdr.p_offset + phdr.p_filesz)) {
                phdr_vaddr = seg_vaddr + @as(usize, @intCast(ehdr.e_phoff - phdr.p_offset));
            }
        }
    }

    if (phdr_vaddr == 0) {
        phdr_vaddr = FALLBACK_PHDR_VADDR;
        const page = phdr_vaddr & ~@as(usize, 0xFFF);
        if (vmm.getPteFlags(pml4_phys, page) == null) {
            const paddr = pmm.allocZeroedPage() orelse return error.OutOfMemory;
            _ = vmm.mapPage(pml4_phys, page, paddr, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
        }
        const total_ph_size = @as(usize, ehdr.e_phnum) * @as(usize, ehdr.e_phentsize);
        const p_off: usize = @intCast(ehdr.e_phoff);
        _ = writeToUserVaddr(pml4_phys, phdr_vaddr, elf_bytes[p_off .. p_off + total_ph_size]);
    }

    return .{
        .entry_rip = load_bias + @as(usize, @intCast(ehdr.e_entry)),
        .max_vaddr = max_vaddr,
        .load_bias = load_bias,
        .phdr_vaddr = phdr_vaddr,
        .phent = ehdr.e_phentsize,
        .phnum = ehdr.e_phnum,
    };
}

pub fn loadStaticElf(
    pml4_phys: usize,
    elf_bytes: []const u8,
    argv: []const []const u8,
    envp: []const []const u8,
) LoadError!ElfLoadResult {
    const main_img = try loadElfImageSegments(pml4_phys, elf_bytes, null);
    const initial_brk = std.mem.alignForward(usize, main_img.max_vaddr, 4096);

    // Map User Stack
    var stack_page = USER_STACK_BOTTOM;
    while (stack_page < USER_STACK_TOP) : (stack_page += 4096) {
        if (vmm.getPteFlags(pml4_phys, stack_page) == null) {
            const paddr = pmm.allocZeroedPage() orelse return error.OutOfMemory;
            _ = vmm.mapPage(pml4_phys, stack_page, paddr, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
        }
    }

    // Build Stack (from USER_STACK_TOP downward)
    var cur_sp = USER_STACK_TOP;

    // 1. Strings
    var argv_vaddrs: [16]usize = undefined;
    var envp_vaddrs: [16]usize = undefined;

    for (envp, 0..) |e, idx| {
        cur_sp -= (e.len + 1);
        _ = writeToUserVaddr(pml4_phys, cur_sp, e);
        _ = writeToUserVaddr(pml4_phys, cur_sp + e.len, "\x00");
        if (idx < 16) envp_vaddrs[idx] = cur_sp;
    }

    for (argv, 0..) |a, idx| {
        cur_sp -= (a.len + 1);
        _ = writeToUserVaddr(pml4_phys, cur_sp, a);
        _ = writeToUserVaddr(pml4_phys, cur_sp + a.len, "\x00");
        if (idx < 16) argv_vaddrs[idx] = cur_sp;
    }

    // 16-byte random seed for AT_RANDOM
    cur_sp -= 16;
    const at_random_vaddr = cur_sp;
    const random_seed = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    _ = writeToUserVaddr(pml4_phys, at_random_vaddr, &random_seed);

    // Padding for alignment
    cur_sp &= ~@as(usize, 0xF);

    // Construct auxv, envp, argv, argc pointers
    // Calculate total entries:
    // auxv: 11 pairs + null pair = 24 u64
    // envp: envp.len + 1
    // argv: argv.len + 1
    // argc: 1
    const auxv_entries = 12 * 2;
    const total_u64 = 1 + (argv.len + 1) + (envp.len + 1) + auxv_entries;
    if ((total_u64 % 2) != 0) {
        cur_sp -= 8; // Maintain 16-byte alignment of initial RSP
    }

    cur_sp -= auxv_entries * 8;
    const auxv_sp = cur_sp;

    const auxv_data = [_]u64{
        AT_PHDR, main_img.phdr_vaddr,
        AT_PHENT, main_img.phent,
        AT_PHNUM, main_img.phnum,
        AT_PAGESZ, 4096,
        AT_BASE, 0,
        AT_ENTRY, main_img.entry_rip,
        AT_UID, 0,
        AT_EUID, 0,
        AT_GID, 0,
        AT_EGID, 0,
        AT_SECURE, 0,
        AT_RANDOM, at_random_vaddr,
        AT_NULL, 0,
    };
    var aux_bytes: [auxv_data.len * 8]u8 = undefined;
    for (auxv_data, 0..) |v, idx| {
        std.mem.writeInt(u64, aux_bytes[idx * 8 .. (idx + 1) * 8], v, .little);
    }
    _ = writeToUserVaddr(pml4_phys, auxv_sp, &aux_bytes);

    // envp
    cur_sp -= (envp.len + 1) * 8;
    const envp_sp = cur_sp;
    for (0..envp.len) |idx| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, envp_vaddrs[idx], .little);
        _ = writeToUserVaddr(pml4_phys, envp_sp + idx * 8, &b);
    }
    var zero_b = [_]u8{0} ** 8;
    _ = writeToUserVaddr(pml4_phys, envp_sp + envp.len * 8, &zero_b);

    // argv
    cur_sp -= (argv.len + 1) * 8;
    const argv_sp = cur_sp;
    for (0..argv.len) |idx| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, argv_vaddrs[idx], .little);
        _ = writeToUserVaddr(pml4_phys, argv_sp + idx * 8, &b);
    }
    _ = writeToUserVaddr(pml4_phys, argv_sp + argv.len * 8, &zero_b);

    // argc
    cur_sp -= 8;
    var argc_b: [8]u8 = undefined;
    std.mem.writeInt(u64, &argc_b, argv.len, .little);
    _ = writeToUserVaddr(pml4_phys, cur_sp, &argc_b);

    return .{
        .entry_rip = main_img.entry_rip,
        .user_rsp = cur_sp,
        .initial_brk = initial_brk,
        .phdr_vaddr = main_img.phdr_vaddr,
        .phent = main_img.phent,
        .phnum = main_img.phnum,
    };
}
