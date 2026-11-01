const std = @import("std");
const pmm = @import("pmm.zig");

pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;

pub const PTE_PRESENT: u64 = 1 << 0;
pub const PTE_WRITABLE: u64 = 1 << 1;
pub const PTE_USER: u64 = 1 << 2;
pub const PTE_WRITE_THROUGH: u64 = 1 << 3;
pub const PTE_CACHE_DISABLE: u64 = 1 << 4;
pub const PTE_ACCESSED: u64 = 1 << 5;
pub const PTE_DIRTY: u64 = 1 << 6;
pub const PTE_HUGE: u64 = 1 << 7;
pub const PTE_GLOBAL: u64 = 1 << 8;
pub const PTE_NO_EXECUTE: u64 = 1 << 63;
pub const PTE_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

pub const PageTable = extern struct {
    entries: [512]u64 align(4096) = [_]u64{0} ** 512,

    comptime {
        std.debug.assert(@sizeOf(PageTable) == 4096);
    }
};

var kernel_pml4_phys: usize = 0;

pub inline fn pml4Index(vaddr: usize) usize {
    return (vaddr >> 39) & 0x1FF;
}

pub inline fn pdptIndex(vaddr: usize) usize {
    return (vaddr >> 30) & 0x1FF;
}

pub inline fn pdIndex(vaddr: usize) usize {
    return (vaddr >> 21) & 0x1FF;
}

pub inline fn ptIndex(vaddr: usize) usize {
    return (vaddr >> 12) & 0x1FF;
}

pub inline fn invlpg(vaddr: usize) void {
    asm volatile ("invlpg (%[vaddr])"
        :
        : [vaddr] "r" (vaddr),
        : "memory"
    );
}

pub inline fn loadCr3(pml4_phys: usize) void {
    asm volatile ("mov %[phys], %%cr3"
        :
        : [phys] "r" (pml4_phys),
        : "memory"
    );
}

pub inline fn readCr3() usize {
    return asm volatile ("mov %%cr3, %[ret]"
        : [ret] "=r" (-> usize),
    );
}

pub fn getKernelPml4Phys() usize {
    return kernel_pml4_phys;
}

fn getOrCreateNextTable(table: *PageTable, idx: usize, is_user: bool) ?*PageTable {
    var entry = table.entries[idx];
    if ((entry & PTE_PRESENT) == 0) {
        const new_page_phys = pmm.allocZeroedPage() orelse return null;
        var dir_flags: u64 = PTE_PRESENT | PTE_WRITABLE;
        if (is_user) dir_flags |= PTE_USER;
        entry = @as(u64, new_page_phys) | dir_flags;
        table.entries[idx] = entry;
    } else if (is_user and (entry & PTE_USER) == 0) {
        // Directory entry was shared from kernel. Allocate a private table copy
        // to prevent mutating shared kernel page tables.
        const old_phys: usize = @intCast(entry & PTE_ADDR_MASK);
        const old_table = @as(*PageTable, @ptrFromInt(old_phys));
        const new_page_phys = pmm.allocZeroedPage() orelse return null;
        const new_table = @as(*PageTable, @ptrFromInt(new_page_phys));
        new_table.* = old_table.*;
        entry = @as(u64, new_page_phys) | (entry & 0xFFF) | PTE_USER | PTE_WRITABLE;
        table.entries[idx] = entry;
    }
    const next_phys: usize = @intCast(entry & PTE_ADDR_MASK);
    return @as(*PageTable, @ptrFromInt(next_phys));
}

pub fn mapPage(pml4_phys: usize, vaddr: usize, paddr: usize, flags: u64) bool {
    std.debug.assert(vaddr % PAGE_SIZE == 0);
    std.debug.assert(paddr % PAGE_SIZE == 0);
    const is_user = (flags & PTE_USER) != 0;
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const pdpt = getOrCreateNextTable(pml4, pml4Index(vaddr), is_user) orelse return false;
    const pd = getOrCreateNextTable(pdpt, pdptIndex(vaddr), is_user) orelse return false;
    const pt = getOrCreateNextTable(pd, pdIndex(vaddr), is_user) orelse return false;

    pt.entries[ptIndex(vaddr)] = (@as(u64, paddr) & PTE_ADDR_MASK) | flags | PTE_PRESENT;
    invlpg(vaddr);
    return true;
}

pub fn unmapPage(pml4_phys: usize, vaddr: usize) ?usize {
    std.debug.assert(vaddr % PAGE_SIZE == 0);
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const pml4e = pml4.entries[pml4Index(vaddr)];
    if ((pml4e & PTE_PRESENT) == 0) return null;
    const pdpt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pml4e & PTE_ADDR_MASK))));
    const pdpte = pdpt.entries[pdptIndex(vaddr)];
    if ((pdpte & PTE_PRESENT) == 0) return null;
    const pd = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pdpte & PTE_ADDR_MASK))));
    const pde = pd.entries[pdIndex(vaddr)];
    if ((pde & PTE_PRESENT) == 0) return null;
    const pt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pde & PTE_ADDR_MASK))));
    const pt_entry = &pt.entries[ptIndex(vaddr)];
    if ((pt_entry.* & PTE_PRESENT) == 0) return null;
    const old_phys: usize = @intCast(pt_entry.* & PTE_ADDR_MASK);
    pt_entry.* = 0;
    invlpg(vaddr);
    return old_phys;
}

pub fn translate(pml4_phys: usize, vaddr: usize) ?usize {
    const pml4 = @as([*]const u64, @ptrFromInt(pml4_phys));
    const pml4e = pml4[pml4Index(vaddr)];
    if ((pml4e & PTE_PRESENT) == 0) return null;
    const pdpt = @as([*]const u64, @ptrFromInt(@as(usize, @intCast(pml4e & PTE_ADDR_MASK))));
    const pdpte = pdpt[pdptIndex(vaddr)];
    if ((pdpte & PTE_PRESENT) == 0) return null;
    const pd = @as([*]const u64, @ptrFromInt(@as(usize, @intCast(pdpte & PTE_ADDR_MASK))));
    const pde = pd[pdIndex(vaddr)];
    if ((pde & PTE_PRESENT) == 0) return null;
    const pt = @as([*]const u64, @ptrFromInt(@as(usize, @intCast(pde & PTE_ADDR_MASK))));
    const pte = pt[ptIndex(vaddr)];
    if ((pte & PTE_PRESENT) == 0) return null;
    const page_base: usize = @intCast(pte & PTE_ADDR_MASK);
    return page_base + (vaddr & 0xFFF);
}

pub fn getPteFlags(pml4_phys: usize, vaddr: usize) ?u64 {
    const pml4 = @as([*]const u64, @ptrFromInt(pml4_phys));
    const pml4e = pml4[pml4Index(vaddr)];
    if ((pml4e & PTE_PRESENT) == 0) return null;
    const pdpt = @as([*]const u64, @ptrFromInt(@as(usize, @intCast(pml4e & PTE_ADDR_MASK))));
    const pdpte = pdpt[pdptIndex(vaddr)];
    if ((pdpte & PTE_PRESENT) == 0) return null;
    const pd = @as([*]const u64, @ptrFromInt(@as(usize, @intCast(pdpte & PTE_ADDR_MASK))));
    const pde = pd[pdIndex(vaddr)];
    if ((pde & PTE_PRESENT) == 0) return null;
    const pt = @as([*]const u64, @ptrFromInt(@as(usize, @intCast(pde & PTE_ADDR_MASK))));
    const pte = pt[ptIndex(vaddr)];
    if ((pte & PTE_PRESENT) == 0) return null;
    return pte & 0xFFF;
}

pub fn init() void {
    kernel_pml4_phys = pmm.allocZeroedPage() orelse @panic("VMM: failed to alloc kernel PML4");

    // Identity-map 0x0000_1000 .. 0x0800_0000 (leave Page 0 unmapped as NULL guard!)
    var addr: usize = PAGE_SIZE;
    while (addr < pmm.TOTAL_RAM_BYTES) : (addr += PAGE_SIZE) {
        if (!mapPage(kernel_pml4_phys, addr, addr, PTE_PRESENT | PTE_WRITABLE)) {
            @panic("VMM: failed to identity map kernel RAM");
        }
    }

    // Map Local APIC & IOAPIC MMIO with PTE_CACHE_DISABLE
    _ = mapPage(kernel_pml4_phys, 0xFEC0_0000, 0xFEC0_0000, PTE_PRESENT | PTE_WRITABLE | PTE_CACHE_DISABLE);
    _ = mapPage(kernel_pml4_phys, 0xFEE0_0000, 0xFEE0_0000, PTE_PRESENT | PTE_WRITABLE | PTE_CACHE_DISABLE);

    loadCr3(kernel_pml4_phys);
}

pub const cloneKernelPml4 = createFreshUserPml4;

pub fn createFreshUserPml4() ?usize {
    const src_pml4 = @as(*PageTable, @ptrFromInt(kernel_pml4_phys));
    const src_pdpt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(src_pml4.entries[0] & PTE_ADDR_MASK))));
    const src_pd = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(src_pdpt.entries[0] & PTE_ADDR_MASK))));
    const dst_pml4_phys = pmm.allocZeroedPage() orelse return null;
    const dst_pdpt_phys = pmm.allocZeroedPage() orelse return null;
    const dst_pd_phys = pmm.allocZeroedPage() orelse return null;

    const dst_pml4 = @as(*PageTable, @ptrFromInt(dst_pml4_phys));
    const dst_pdpt = @as(*PageTable, @ptrFromInt(dst_pdpt_phys));
    const dst_pd = @as(*PageTable, @ptrFromInt(dst_pd_phys));

    dst_pml4.entries[0] = @as(u64, dst_pdpt_phys) | PTE_PRESENT | PTE_WRITABLE | PTE_USER;
    dst_pdpt.entries[0] = @as(u64, dst_pd_phys) | PTE_PRESENT | PTE_WRITABLE | PTE_USER;

    // Share all kernel mappings in PDPT 0 (identity map 0..63 and kernel heap 128)
    for (0..512) |pdi| {
        const pde = src_pd.entries[pdi];
        if ((pde & PTE_PRESENT) != 0 and (pde & PTE_USER) == 0) {
            dst_pd.entries[pdi] = pde;
        }
    }

    // Share higher-half kernel PDPT entries if present
    for (1..512) |pdpti| {
        const pdpte = src_pdpt.entries[pdpti];
        if ((pdpte & PTE_PRESENT) != 0 and (pdpte & PTE_USER) == 0) {
            dst_pdpt.entries[pdpti] = pdpte;
        }
    }

    // Explicitly share 3..4 GiB Kernel MMIO (LAPIC 0xFEE0_0000 / IOAPIC 0xFEC0_0000 at pdptIndex == 3)
    dst_pdpt.entries[3] = src_pdpt.entries[3];

    return dst_pml4_phys;
}

pub fn cloneUserPml4(src_pml4_phys: usize) ?usize {
    const dst_pml4_phys = createFreshUserPml4() orelse return null;
    const src_pml4 = @as(*PageTable, @ptrFromInt(src_pml4_phys));
    const src_pml4e = src_pml4.entries[0];
    if ((src_pml4e & PTE_PRESENT) == 0) return dst_pml4_phys;

    const src_pdpt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(src_pml4e & PTE_ADDR_MASK))));
    const src_pdpte = src_pdpt.entries[0];
    if ((src_pdpte & PTE_PRESENT) == 0) return dst_pml4_phys;

    const src_pd = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(src_pdpte & PTE_ADDR_MASK))));
    const dst_pml4 = @as(*PageTable, @ptrFromInt(dst_pml4_phys));
    const dst_pdpt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(dst_pml4.entries[0] & PTE_ADDR_MASK))));
    const dst_pd = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(dst_pdpt.entries[0] & PTE_ADDR_MASK))));

    for (0..512) |pdi| {
        const pde = src_pd.entries[pdi];
        if ((pde & PTE_PRESENT) == 0 or (pde & PTE_USER) == 0) continue;

        const src_pt = @as(*PageTable, @ptrFromInt(@as(usize, @intCast(pde & PTE_ADDR_MASK))));
        const dst_pt_phys = pmm.allocZeroedPage() orelse return null;
        const dst_pt = @as(*PageTable, @ptrFromInt(dst_pt_phys));
        dst_pd.entries[pdi] = @as(u64, dst_pt_phys) | (pde & 0xFFF);

        for (0..512) |pti| {
            const pte = src_pt.entries[pti];
            if ((pte & PTE_PRESENT) == 0) continue;
            if ((pte & PTE_USER) == 0) {
                dst_pt.entries[pti] = pte;
            } else {
                const new_frame = pmm.allocZeroedPage() orelse return null;
                const old_frame = @as(usize, @intCast(pte & PTE_ADDR_MASK));
                const src_slice = @as([*]const u8, @ptrFromInt(old_frame))[0..PAGE_SIZE];
                const dst_slice = @as([*]u8, @ptrFromInt(new_frame))[0..PAGE_SIZE];
                @memcpy(dst_slice, src_slice);
                dst_pt.entries[pti] = @as(u64, new_frame) | (pte & 0xFFF);
            }
        }
    }
    return dst_pml4_phys;
}
