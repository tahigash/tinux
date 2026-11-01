const std = @import("std");
const pmm = @import("../mm/pmm.zig");
const vmm = @import("../mm/vmm.zig");

// ELF Segment Types
pub const PT_NULL: u32 = 0;
pub const PT_LOAD: u32 = 1;
pub const PT_DYNAMIC: u32 = 2;
pub const PT_INTERP: u32 = 3;
pub const PT_PHDR: u32 = 6;
pub const PT_TLS: u32 = 7;

// ELF File Types & Architecture
pub const ET_EXEC: u16 = 2;
pub const ET_DYN: u16 = 3;
pub const EM_X86_64: u16 = 62;

// System V AMD64 Auxiliary Vector Tags
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

// Memory Layout Constants & User Space Boundaries (TASK-011: 32 KiB Stack)
pub const MAIN_PIE_LOAD_BIAS: usize = 0x0040_0000;
pub const INTERP_LOAD_BIAS: usize = 0x1800_0000;
pub const FALLBACK_PHDR_VADDR: usize = 0x003F_F000;

pub const USER_ADDR_MAX: usize = 0x0000_8000_0000_0000;
pub const USER_STACK_BOTTOM: usize = 0x0080_0000;
pub const USER_STACK_PAGES: usize = 8; // 32 KiB
pub const USER_STACK_TOP: usize = USER_STACK_BOTTOM + (USER_STACK_PAGES * vmm.PAGE_SIZE); // 0x0080_8000

// ELF64 Header (64 bytes)
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
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_ident") == 0);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_type") == 16);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_machine") == 18);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_version") == 20);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_entry") == 24);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_phoff") == 32);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_shoff") == 40);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_flags") == 48);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_ehsize") == 52);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_phentsize") == 54);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_phnum") == 56);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_shentsize") == 58);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_shnum") == 60);
        std.debug.assert(@offsetOf(Elf64_Ehdr, "e_shstrndx") == 62);
    }
};

// ELF64 Program Header (56 bytes)
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
        std.debug.assert(@offsetOf(Elf64_Phdr, "p_type") == 0);
        std.debug.assert(@offsetOf(Elf64_Phdr, "p_flags") == 4);
        std.debug.assert(@offsetOf(Elf64_Phdr, "p_offset") == 8);
        std.debug.assert(@offsetOf(Elf64_Phdr, "p_vaddr") == 16);
        std.debug.assert(@offsetOf(Elf64_Phdr, "p_paddr") == 24);
        std.debug.assert(@offsetOf(Elf64_Phdr, "p_filesz") == 32);
        std.debug.assert(@offsetOf(Elf64_Phdr, "p_memsz") == 40);
        std.debug.assert(@offsetOf(Elf64_Phdr, "p_align") == 48);
    }
};

// ELF64 Auxiliary Vector Entry (16 bytes)
pub const Elf64_Auxv = extern struct {
    a_type: u64,
    a_val: u64,

    comptime {
        std.debug.assert(@sizeOf(Elf64_Auxv) == 16);
        std.debug.assert(@offsetOf(Elf64_Auxv, "a_type") == 0);
        std.debug.assert(@offsetOf(Elf64_Auxv, "a_val") == 8);
    }
};

// Loaded Image Result matching SPEC_TASK_005 Section 4.1
pub const LoadedImage = struct {
    entry_rip: usize,
    user_rsp: usize,
    initial_brk: usize,
};

pub const SegmentMapResult = struct {
    max_vaddr: usize,
    phdr_vaddr: usize,
    entry_rip: usize,
};

pub const LoadError = error{
    InvalidElfMagic,
    UnsupportedArchitecture,
    OutOfMemory,
    InvalidSegment,
    InterpreterNotFound,
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

/// Copy data to user virtual address space in pml4_phys across page boundaries
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

fn isUserMapped(pml4_phys: usize, vaddr: usize) bool {
    const flags = vmm.getPteFlags(pml4_phys, vaddr) orelse return false;
    return (flags & vmm.PTE_USER) != 0;
}

/// Primary static ELF64 loader conforming strictly to SPEC_TASK_005 Section 4.1
pub fn loadStaticElf(
    pml4_phys: usize,
    elf_bytes: []const u8,
) LoadError!LoadedImage {
    return loadStaticElfInternal(pml4_phys, elf_bytes, null, null);
}

/// Extended loader for multi-argument invocations (forward compatible with dispatch.zig SYS_EXECVE and main.zig)
pub fn loadStaticElfWithArgs(
    pml4_phys: usize,
    elf_bytes: []const u8,
    argv: []const []const u8,
    envp: []const []const u8,
) LoadError!LoadedImage {
    return loadStaticElfInternal(pml4_phys, elf_bytes, argv, envp);
}

pub fn mapElfSegments(
    pml4_phys: usize,
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
            const seg_page_end = std.mem.alignForward(usize, seg_end, 4096);
            if (seg_page_end > USER_ADDR_MAX) return error.InvalidSegment;

            var page_vaddr = seg_page_start;
            while (page_vaddr < seg_page_end) : (page_vaddr += 4096) {
                if (!isUserMapped(pml4_phys, page_vaddr)) {
                    const paddr = pmm.allocZeroedPage() orelse return error.OutOfMemory;
                    _ = vmm.mapPage(pml4_phys, page_vaddr, paddr, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
                }
            }

            if (seg_filesz > 0) {
                const p_off = @as(usize, @intCast(phdr.p_offset));
                if (p_off > elf_bytes.len or seg_filesz > elf_bytes.len - p_off) return error.InvalidSegment;
                if (!writeToUserVaddr(pml4_phys, seg_start, elf_bytes[p_off .. p_off + seg_filesz])) {
                    return error.OutOfMemory;
                }
            }

            if (seg_memsz > seg_filesz) {
                const bss_start = seg_start + seg_filesz;
                const partial_len = @min(seg_end - bss_start, 4096 - (bss_start & 0xFFF));
                if (partial_len > 0) {
                    const zeros = [_]u8{0} ** 512;
                    var off_z: usize = 0;
                    while (off_z < partial_len) {
                        const chunk = @min(partial_len - off_z, zeros.len);
                        _ = writeToUserVaddr(pml4_phys, bss_start + off_z, zeros[0..chunk]);
                        off_z += chunk;
                    }
                }
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

fn loadStaticElfInternal(
    pml4_phys: usize,
    elf_bytes: []const u8,
    custom_argv: ?[]const []const u8,
    custom_envp: ?[]const []const u8,
) LoadError!LoadedImage {
    var main_res = try mapElfSegments(pml4_phys, elf_bytes, MAIN_PIE_LOAD_BIAS);
    const ehdr = @as(*align(1) const Elf64_Ehdr, @ptrCast(elf_bytes.ptr));

    // Fallback if program headers were not mapped in any PT_LOAD segment
    if (main_res.phdr_vaddr == 0) {
        main_res.phdr_vaddr = FALLBACK_PHDR_VADDR;
        const page = main_res.phdr_vaddr & ~@as(usize, 0xFFF);
        if (!isUserMapped(pml4_phys, page)) {
            const paddr = pmm.allocZeroedPage() orelse return error.OutOfMemory;
            _ = vmm.mapPage(pml4_phys, page, paddr, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
        }
        const total_ph_size = @as(usize, ehdr.e_phnum) * @as(usize, ehdr.e_phentsize);
        const p_off = @as(usize, @intCast(ehdr.e_phoff));
        if (p_off + total_ph_size <= elf_bytes.len) {
            _ = writeToUserVaddr(pml4_phys, main_res.phdr_vaddr, elf_bytes[p_off .. p_off + total_ph_size]);
        }
    }

    var at_base: usize = 0;
    var start_rip: usize = main_res.entry_rip;

    // Check for PT_INTERP
    if (extractInterpPath(elf_bytes)) |interp_path| {
        const vfs = @import("../fs/vfs.zig");
        const interp_idx = vfs.lookup(interp_path) orelse return error.InterpreterNotFound;
        const interp_node = vfs.getNode(interp_idx);
        const interp_slice = interp_node.slice();
        const interp_res = try mapElfSegments(pml4_phys, interp_slice, INTERP_LOAD_BIAS);
        at_base = INTERP_LOAD_BIAS;
        start_rip = interp_res.entry_rip;
    }

    // Map 32 KiB User Stack (0x0080_0000 .. 0x0080_8000)
    var stack_page = USER_STACK_BOTTOM;
    while (stack_page < USER_STACK_TOP) : (stack_page += 4096) {
        if (!isUserMapped(pml4_phys, stack_page)) {
            const paddr = pmm.allocZeroedPage() orelse return error.OutOfMemory;
            _ = vmm.mapPage(pml4_phys, stack_page, paddr, vmm.PTE_PRESENT | vmm.PTE_WRITABLE | vmm.PTE_USER);
        }
    }

    // Construct System V AMD64 Initial Stack
    const user_rsp: usize = if (custom_argv == null and custom_envp == null) blk: {
        const argv0_str = "/sbin/init\x00";
        const envp0_str = "PATH=/bin:/usr/bin\x00";
        const random_seed = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };

        const argv0_vaddr: usize = 0x0080_7F00;
        const envp0_vaddr: usize = 0x0080_7F20;
        const at_random_vaddr: usize = 0x0080_7F40;

        _ = writeToUserVaddr(pml4_phys, argv0_vaddr, argv0_str);
        _ = writeToUserVaddr(pml4_phys, envp0_vaddr, envp0_str);
        _ = writeToUserVaddr(pml4_phys, at_random_vaddr, &random_seed);

        const rsp_start: usize = 0x0080_7E00;
        const stack_slots = [_]u64{
            // argc
            1,
            // argv
            argv0_vaddr,
            0, // argv[1] = NULL
            // envp
            envp0_vaddr,
            0, // envp[1] = NULL
            // auxv pairs
            AT_PAGESZ, 4096,
            AT_PHDR, main_res.phdr_vaddr,
            AT_PHENT, @as(u64, ehdr.e_phentsize),
            AT_PHNUM, @as(u64, ehdr.e_phnum),
            AT_BASE, at_base,
            AT_ENTRY, main_res.entry_rip,
            AT_RANDOM, at_random_vaddr,
            AT_SECURE, 0,
            AT_UID, 0,
            AT_EUID, 0,
            AT_GID, 0,
            AT_EGID, 0,
            AT_NULL, 0,
        };

        var slot_bytes: [stack_slots.len * 8]u8 = undefined;
        for (stack_slots, 0..) |val, idx| {
            std.mem.writeInt(u64, slot_bytes[idx * 8 ..][0..8], val, .little);
        }
        _ = writeToUserVaddr(pml4_phys, rsp_start, &slot_bytes);
        break :blk rsp_start;
    } else blk: {
        const argv = custom_argv.?;
        const envp = custom_envp.?;
        var cur_sp = USER_STACK_TOP;

        // Pass 1: Write envp strings downwards from USER_STACK_TOP
        for (envp) |e| {
            if (cur_sp < USER_STACK_BOTTOM + e.len + 1) return error.OutOfMemory;
            cur_sp -= (e.len + 1);
            _ = writeToUserVaddr(pml4_phys, cur_sp, e);
            _ = writeToUserVaddr(pml4_phys, cur_sp + e.len, "\x00");
        }

        // Pass 1 (cont): Write argv strings downwards
        for (argv) |a| {
            if (cur_sp < USER_STACK_BOTTOM + a.len + 1) return error.OutOfMemory;
            cur_sp -= (a.len + 1);
            _ = writeToUserVaddr(pml4_phys, cur_sp, a);
            _ = writeToUserVaddr(pml4_phys, cur_sp + a.len, "\x00");
        }

        // Write 16-byte random seed for AT_RANDOM
        if (cur_sp < USER_STACK_BOTTOM + 16) return error.OutOfMemory;
        cur_sp -= 16;
        const at_random_vaddr = cur_sp;
        const random_seed = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
        _ = writeToUserVaddr(pml4_phys, at_random_vaddr, &random_seed);

        // Align string & data area to 16-byte boundary
        cur_sp &= ~@as(usize, 0xF);

        // Auxiliary vector definition (13 pairs = 26 u64 words)
        const auxv_data = [_]u64{
            AT_PHDR, main_res.phdr_vaddr,
            AT_PHENT, @as(u64, ehdr.e_phentsize),
            AT_PHNUM, @as(u64, ehdr.e_phnum),
            AT_PAGESZ, 4096,
            AT_BASE, at_base,
            AT_ENTRY, main_res.entry_rip,
            AT_UID, 0,
            AT_EUID, 0,
            AT_GID, 0,
            AT_EGID, 0,
            AT_SECURE, 0,
            AT_RANDOM, at_random_vaddr,
            AT_NULL, 0,
        };
        const auxv_entries: usize = auxv_data.len;

        // Calculate total words below string area to maintain 16-byte RSP alignment
        const total_u64 = 1 + (argv.len + 1) + (envp.len + 1) + auxv_entries;
        if ((total_u64 % 2) != 0) {
            if (cur_sp < USER_STACK_BOTTOM + 8) return error.OutOfMemory;
            cur_sp -= 8;
        }

        // Auxiliary vector table placement
        const auxv_bytes_len = auxv_entries * 8;
        if (cur_sp < USER_STACK_BOTTOM + auxv_bytes_len) return error.OutOfMemory;
        cur_sp -= auxv_bytes_len;
        const auxv_sp = cur_sp;

        var aux_bytes: [auxv_data.len * 8]u8 = undefined;
        for (auxv_data, 0..) |v, idx| {
            std.mem.writeInt(u64, aux_bytes[idx * 8 ..][0..8], v, .little);
        }
        _ = writeToUserVaddr(pml4_phys, auxv_sp, &aux_bytes);

        // envp pointer table placement
        const envp_table_bytes = (envp.len + 1) * 8;
        if (cur_sp < USER_STACK_BOTTOM + envp_table_bytes) return error.OutOfMemory;
        cur_sp -= envp_table_bytes;
        const envp_sp = cur_sp;

        // Pass 2: Stream envp pointer addresses derived directly from USER_STACK_TOP
        var str_vaddr: usize = USER_STACK_TOP;
        for (envp, 0..) |e, idx| {
            str_vaddr -= (e.len + 1);
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, str_vaddr, .little);
            _ = writeToUserVaddr(pml4_phys, envp_sp + idx * 8, &b);
        }
        var zero_b = [_]u8{0} ** 8;
        _ = writeToUserVaddr(pml4_phys, envp_sp + envp.len * 8, &zero_b);

        // argv pointer table placement
        const argv_table_bytes = (argv.len + 1) * 8;
        if (cur_sp < USER_STACK_BOTTOM + argv_table_bytes) return error.OutOfMemory;
        cur_sp -= argv_table_bytes;
        const argv_sp = cur_sp;

        // Pass 2 (cont): Stream argv pointer addresses derived directly from string stream
        for (argv, 0..) |a, idx| {
            str_vaddr -= (a.len + 1);
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, str_vaddr, .little);
            _ = writeToUserVaddr(pml4_phys, argv_sp + idx * 8, &b);
        }
        _ = writeToUserVaddr(pml4_phys, argv_sp + argv.len * 8, &zero_b);

        // argc word placement
        if (cur_sp < USER_STACK_BOTTOM + 8) return error.OutOfMemory;
        cur_sp -= 8;
        var argc_b: [8]u8 = undefined;
        std.mem.writeInt(u64, &argc_b, argv.len, .little);
        _ = writeToUserVaddr(pml4_phys, cur_sp, &argc_b);

        break :blk cur_sp;
    };

    // 5. Initial Program Break
    const initial_brk = std.mem.alignForward(usize, main_res.max_vaddr, vmm.PAGE_SIZE);

    return LoadedImage{
        .entry_rip = start_rip,
        .user_rsp = user_rsp,
        .initial_brk = initial_brk,
    };
}
