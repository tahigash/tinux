.section .text
.code16
.global ap_trampoline_start
.global ap_trampoline_end
/* Physical base address where BSP copies this trampoline (Vector 0x08 -> 0x00008000) */
.equ TRAMPOLINE_BASE, 0x8000
.equ MAILBOX_CR3,     0x8F00
.equ MAILBOX_RSP,     0x8F08
.equ MAILBOX_ENTRY,   0x8F10

.align 16
ap_trampoline_start:
    cli
    cld
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    /* 1. Load temporary 32/64-bit GDT from fixed physical address inside 0x8000 page */
    lgdt (TRAMPOLINE_BASE + (.Lap_gdtr - ap_trampoline_start))
    /* 2. Enable Protected Mode (CR0.PE = Bit 0) */
    movl %cr0, %eax
    orl  $0x00000001, %eax
    movl %eax, %cr0
    /* 3. Far jump to 32-bit Protected Mode (CS = 0x08) */
    ljmpl $0x08, $(TRAMPOLINE_BASE + (.Lap_mode32 - ap_trampoline_start))
.code32
.align 16
.Lap_mode32:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    /* 4. Enable PAE (Bit 5) + OSFXSR (Bit 9) + OSXMMEXCPT (Bit 10) in CR4 */
    movl %cr4, %eax
    orl  $0x00000620, %eax
    movl %eax, %cr4
    /* 5. Load Kernel PML4 physical address from MAILBOX_CR3 (0x8F00) into CR3 */
    movl (MAILBOX_CR3), %eax
    movl %eax, %cr3
    /* 6. Enable Long Mode (LME = Bit 8) in IA32_EFER MSR (0xC0000080) */
    movl $0xC0000080, %ecx
    rdmsr
    orl  $0x00000100, %eax
    wrmsr
    /* 7. Enable Paging (PG=Bit 31), Write Protect (WP=Bit 16), FPU/SSE (MP=Bit 1, clear EM=Bit 2) */
    movl %cr0, %eax
    andl $0xFFFFFFFB, %eax
    orl  $0x80010002, %eax
    movl %eax, %cr0
    /* 8. Far jump to 64-bit Long Mode (CS = 0x18) */
    ljmpl $0x18, $(TRAMPOLINE_BASE + (.Lap_mode64 - ap_trampoline_start))
.code64
.align 16
.Lap_mode64:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs
    /* 9. Load per-AP 64-bit stack pointer from MAILBOX_RSP (0x8F08) */
    movabsq $MAILBOX_RSP, %rax
    movq (%rax), %rsp
    xorq %rbp, %rbp
    /* 10. Jump to Zig apMain() stored at MAILBOX_ENTRY (0x8F10) */
    movabsq $MAILBOX_ENTRY, %rax
    movq (%rax), %rax
    call *%rax
.Lap_halt:
    cli
    hlt
    jmp .Lap_halt
.align 16
.Lap_gdt:
    .quad 0x0000000000000000    /* 0x00: Null descriptor */
    .quad 0x00CF9A000000FFFF    /* 0x08: 32-bit Kernel Code (DPL=0) */
    .quad 0x00CF92000000FFFF    /* 0x10: 32/64-bit Kernel Data (DPL=0) */
    .quad 0x00AF9A000000FFFF    /* 0x18: 64-bit Kernel Code (DPL=0, L=1) */
.Lap_gdt_end:
.Lap_gdtr:
    .word .Lap_gdt_end - .Lap_gdt - 1
    .long TRAMPOLINE_BASE + (.Lap_gdt - ap_trampoline_start)
ap_trampoline_end:
