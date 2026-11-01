.section .text
.code64
.global syscallEntry
.global enterUserMode
.extern syscallDispatch
.extern kernel_rsp_scratch
.extern user_rsp_scratch

.align 16
syscallEntry:
    /* Save user RSP and switch to kernel syscall stack */
    movq %rsp, user_rsp_scratch(%rip)
    movq kernel_rsp_scratch(%rip), %rsp

    /* Build 128-byte SyscallFrame (16 x 8 bytes -> 16-byte aligned) */
    pushq user_rsp_scratch(%rip)   /* offset 120: user_rsp */
    pushq %rcx                     /* offset 112: user_rip */
    pushq %r11                     /* offset 104: user_rflags */
    pushq %rax                     /* offset 96:  rax (syscall number / return value) */
    pushq %rdi                     /* offset 88:  rdi (arg1) */
    pushq %rsi                     /* offset 80:  rsi (arg2) */
    pushq %rdx                     /* offset 72:  rdx (arg3) */
    pushq %r10                     /* offset 64:  r10 (arg4) */
    pushq %r8                      /* offset 56:  r8  (arg5) */
    pushq %r9                      /* offset 48:  r9  (arg6) */
    pushq %rbx                     /* offset 40:  rbx */
    pushq %rbp                     /* offset 32:  rbp */
    pushq %r12                     /* offset 24:  r12 */
    pushq %r13                     /* offset 16:  r13 */
    pushq %r14                     /* offset 8:   r14 */
    pushq %r15                     /* offset 0:   r15 */

    movq %rsp, %rdi
    call syscallDispatch

    /* Switch RSP to returned *SyscallFrame (enables context switching & rt_sigreturn) */
    movq %rax, %rsp

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    popq %r9
    popq %r8
    popq %r10
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rax
    popq %r11                      /* user_rflags -> %r11 */
    popq %rcx                      /* user_rip    -> %rcx */
    popq %rsp                      /* user_rsp    -> %rsp */
    sysretq

/* fn enterUserMode(entry_rip: usize, user_rsp: usize) callconv(.C) noreturn */
.align 16
enterUserMode:
    cli
    pushq $0x1B                    /* User SS (0x18 | RPL 3) */
    pushq %rsi                     /* User RSP */
    pushq $0x202                   /* RFLAGS (IF=1, Reserved Bit 1=1) */
    pushq $0x23                    /* User CS (0x20 | RPL 3) */
    pushq %rdi                     /* User RIP */

    xorq %rax, %rax
    xorq %rbx, %rbx
    xorq %rcx, %rcx
    xorq %rdx, %rdx
    xorq %rsi, %rsi
    xorq %rdi, %rdi
    xorq %rbp, %rbp
    xorq %r8, %r8
    xorq %r9, %r9
    xorq %r10, %r10
    xorq %r11, %r11
    xorq %r12, %r12
    xorq %r13, %r13
    xorq %r14, %r14
    xorq %r15, %r15
    iretq
