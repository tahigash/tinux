/* Xen PVH Direct Boot ELF Note (XEN_ELFNOTE_PHYS32_ENTRY = 0x12) */
.section .note.Xen, "a", @note
.align 4
    .long 4                     /* namesz: "Xen\0" */
    .long 4                     /* descsz: 32-bit physical entry address */
    .long 0x12                  /* type: XEN_ELFNOTE_PHYS32_ENTRY */
    .asciz "Xen"
    .align 4
    .long _start32
.section .text.boot, "ax", @progbits
.code32
.global _start32
.extern kmain
_start32:
    cli
    cld
    /* 1. Build temporary 4-level page tables identity-mapping first 1 GiB (512 x 2MiB pages) */
    movl $boot_pdpt, %eax
    orl  $0x03, %eax            /* Present | Writable */
    movl %eax, boot_pml4
    movl $boot_pd, %eax
    orl  $0x03, %eax            /* Present | Writable */
    movl %eax, boot_pdpt
    movl $boot_pd, %edi
    movl $0x00000083, %eax      /* Present | Writable | Huge (2 MiB) */
    movl $512, %ecx
1:
    movl %eax, (%edi)
    movl $0, 4(%edi)
    addl $0x200000, %eax        /* Next 2 MiB physical frame */
    addl $8, %edi
    loop 1b
    /* 2. Load CR3 with boot_pml4 physical address */
    movl $boot_pml4, %eax
    movl %eax, %cr3
    /* 3. Enable PAE (Bit 5) + OSFXSR (Bit 9) + OSXMMEXCPT (Bit 10) in CR4 */
    movl %cr4, %eax
    orl  $0x00000620, %eax
    movl %eax, %cr4
    /* 4. Enable Long Mode (LME = Bit 8) in IA32_EFER MSR (0xC0000080) */
    movl $0xC0000080, %ecx
    rdmsr
    orl  $0x00000100, %eax
    wrmsr
    /* 5. Enable Paging (PG=Bit 31), Write Protect (WP=Bit 16), FPU/SSE (MP=Bit 1, clear EM=Bit 2) in CR0 */
    movl %cr0, %eax
    andl $0xFFFFFFFB, %eax      /* Clear CR0.EM (Bit 2) */
    orl  $0x80010002, %eax      /* Set PG (Bit 31), WP (Bit 16), MP (Bit 1) */
    movl %eax, %cr0
    /* 6. Load temporary 64-bit GDT and far-jump to 64-bit Long Mode */
    lgdt boot_gdtr
    ljmp $0x08, $_start64
.code64
.align 16
_start64:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs
    /* Set 16-byte aligned 64-bit kernel boot stack */
    leaq boot_stack_top(%rip), %rsp
    xorq %rbp, %rbp
    call kmain
.Lhalt:
    cli
    hlt
    jmp .Lhalt
.align 16
boot_gdt:
    .quad 0x0000000000000000    /* 0x00: Null descriptor */
    .quad 0x00AF9A000000FFFF    /* 0x08: 64-bit Kernel Code (DPL=0, L=1) */
    .quad 0x00CF92000000FFFF    /* 0x10: 64-bit Kernel Data (DPL=0) */
boot_gdt_end:
boot_gdtr:
    .word boot_gdt_end - boot_gdt - 1
    .quad boot_gdt
.section .bss
.align 4096
boot_pml4:
    .skip 4096
boot_pdpt:
    .skip 4096
boot_pd:
    .skip 4096
.align 16
boot_stack_bottom:
    .skip 65536                 /* 64 KiB Kernel Boot Stack */
.global boot_stack_top
boot_stack_top:
