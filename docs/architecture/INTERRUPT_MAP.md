# Tinux Interrupt and Exception Map

> **Purpose:**
> Documents the complete interrupt, exception, and IRQ routing architecture for the Tinux x86_64 kernel.

---

## 1. Overview of Interrupt Architecture

Tinux configures a 256-entry Interrupt Descriptor Table (IDT) loaded into the processor via the `lidt` instruction. The IDT manages three classes of events:
1. **CPU Exceptions (Vectors 0 to 31):** Hardware-generated traps, faults, and aborts.
2. **Hardware IRQs (Vectors 32 to 255):** External peripheral interrupts routed through the dual 8259A PIC, I/O APIC, and Local APIC.
3. **Software Interrupts (Vector 0x80):** Legacy Linux system call interface, operating alongside the primary fast `SYSCALL`/`SYSRET` mechanism.

All handlers and dispatchers are independent from-scratch implementations written in x86_64 assembly and Zig, without using any proprietary or GPL-licensed Linux kernel code.

---

## 2. CPU Exception Vectors (0 to 31)

When a CPU exception occurs, the hardware automatically pushes execution context onto the active stack. For exceptions that do not push a hardware error code, the low-level assembly stub pushes a dummy zero value to maintain a uniform stack frame.

| Vector | Mnemonic | Description | Type | Error Code | Action in Tinux |
| :---: | :---: | :--- | :---: | :---: | :--- |
| 0 | `#DE` | Divide Error | Fault | No (Dummy 0) | Terminates process with `SIGFPE` or panics if kernel |
| 1 | `#DB` | Debug Exception | Fault/Trap | No (Dummy 0) | Delivers `SIGTRAP` for single-step debugging |
| 2 | `#NMI`| Non-Maskable Interrupt | Interrupt | No (Dummy 0) | Kernel diagnostic report; halts CPU |
| 3 | `#BP` | Breakpoint (`int3`) | Trap | No (Dummy 0) | Halts for GDB debugger attachment |
| 4 | `#OF` | Overflow (`into`) | Trap | No (Dummy 0) | Delivers `SIGSEGV` |
| 5 | `#BR` | BOUND Range Exceeded | Fault | No (Dummy 0) | Delivers `SIGSEGV` |
| 6 | `#UD` | Invalid Opcode | Fault | No (Dummy 0) | Delivers `SIGILL` to user process or panics |
| 7 | `#NM` | Device Not Available | Fault | No (Dummy 0) | Initializes FPU/SSE state via `clts` |
| 8 | `#DF` | Double Fault | Abort | Yes | Uses dedicated IST1 stack; halts kernel |
| 9 | - | Coprocessor Segment Overrun | Fault | No (Dummy 0) | Reserved; panics |
| 10 | `#TS` | Invalid TSS | Fault | Yes | Panics with TSS selector diagnostics |
| 11 | `#NP` | Segment Not Present | Fault | Yes | Panics with segment selector index |
| 12 | `#SS` | Stack-Segment Fault | Fault | Yes | Delivers `SIGBUS` or expands stack |
| 13 | `#GP` | General Protection Fault | Fault | Yes | Diagnoses non-canonical access or SSE unalignment |
| 14 | `#PF` | Page Fault | Fault | Yes | Evaluates `CR2`; demand paging, COW, or `SIGSEGV` |
| 15 | - | Reserved | - | No (Dummy 0) | Ignored |
| 16 | `#MF` | x87 FPU Floating-Point | Fault | No (Dummy 0) | Delivers `SIGFPE` |
| 17 | `#AC` | Alignment Check | Fault | Yes | Delivers `SIGBUS` |
| 18 | `#MC` | Machine Check | Abort | No (Dummy 0) | Hardware error; halts CPU |
| 19 | `#XM` | SIMD Floating-Point | Fault | No (Dummy 0) | Delivers `SIGFPE` |
| 20 | `#VE` | Virtualization Exception | Fault | No (Dummy 0) | Reserved |
| 21..31| - | Reserved / Unused | - | No (Dummy 0) | Unhandled exception panic |

---

## 3. Register Context and `TrapFrame` Layout

The low-level assembly stubs in `src/arch/x86_64/isr.S` consolidate execution context into a uniform 176-byte `TrapFrame` defined in `src/arch/x86_64/idt.zig`:

```zig
pub const TrapFrame = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};
```

### Memory Layout on Stack

```text
Higher Memory Addresses (Pushed by CPU hardware)
  [RSP + 168] SS          (User stack segment)
  [RSP + 160] RSP         (User stack pointer)
  [RSP + 152] RFLAGS      (Processor flags)
  [RSP + 144] CS          (Code segment)
  [RSP + 136] RIP         (Instruction pointer)
  [RSP + 128] ERROR_CODE  (Hardware error code or dummy 0)
  [RSP + 120] VECTOR      (Interrupt vector number 0..255)
  [RSP + 112] R15
  [RSP + 104] R14
  [RSP +  96] R13
  [RSP +  88] R12
  [RSP +  80] R11
  [RSP +  72] R10
  [RSP +  64] R9
  [RSP +  56] R8
  [RSP +  48] RBP
  [RSP +  40] RDI
  [RSP +  32] RSI
  [RSP +  24] RDX
  [RSP +  16] RCX
  [RSP +   8] RBX
  [RSP +   0] RAX         (Top of stack passed to isrDispatch)
Lower Memory Addresses
```

---

## 4. Hardware IRQ Routing (Vectors 32 to 255)

The legacy 8259A Programmable Interrupt Controller (PIC) lines are remapped from the default IBM PC vectors (0..15) to vectors 32..47 to prevent collisions with Intel CPU exception vectors:
* Master PIC base vector: `0x20` (Vector 32)
* Slave PIC base vector: `0x28` (Vector 40)

| Vector | Legacy IRQ | Device / Controller | Function in Tinux |
| :---: | :---: | :--- | :--- |
| 32 | IRQ0 | 8254 PIT Timer | System clock tick (100 Hz); preemptive scheduling |
| 33 | IRQ1 | PS/2 Keyboard | Keyboard scan code processing |
| 34 | IRQ2 | Cascaded Slave PIC | Internal cascade routing |
| 35 | IRQ3 | Serial COM2 / COM4 | Auxiliary serial port |
| 36 | IRQ4 | Serial COM1 (16550A) | UART input interrupt; feeds line discipline in TTY driver |
| 37 | IRQ5 | Parallel Port 2 | Unused |
| 38 | IRQ6 | Floppy Controller | Unused |
| 39 | IRQ7 | Spurious PIC Interrupt | Spurious interrupt handler |
| 40 | IRQ8 | Real-Time Clock (RTC) | Periodic hardware clock |
| 41 | IRQ9 | ACPI / Free | Power management |
| 42 | IRQ10| Open PCI Line | PCI peripheral interrupt line |
| 43 | IRQ11| PCI Shared Line | VirtIO block device and VirtIO network notifications |
| 44 | IRQ12| PS/2 Mouse | Mouse input stream |
| 45 | IRQ13| Coprocessor Error | FPU error handling |
| 46 | IRQ14| Primary IDE / ATA | Legacy hard disk interface |
| 47 | IRQ15| Secondary IDE / ATA | CD-ROM interface |
| 48 | IRQ16| Local APIC Timer | High-precision per-core scheduling tick |
| 128| 0x80 | Software Syscall Gate | Legacy Linux 32-bit/64-bit int 0x80 fallback |
| 255| - | APIC Spurious Interrupt | Handles spurious bus cycles; ignores end-of-interrupt |

---

## 5. End of Interrupt (EOI) Protocol

When an IRQ finishes servicing, the kernel issues an End of Interrupt (EOI) signal:
* **For Master PIC only (Vectors 32..39):**
  Write `0x20` to I/O port `0x20`.
* **For Slave PIC (Vectors 40..47):**
  Write `0x20` to I/O port `0xA0`, followed by `0x20` to I/O port `0x20`.
* **For Local APIC:**
  Write `0x00000000` to the Local APIC EOI register at MMIO address `0xFEE0_00B0`.

---

## 6. System Call Invocation Pathways

Tinux provides two distinct mechanisms for entering kernel mode from user space:

1. **Fast Syscall Path (`SYSCALL` instruction):**
   * Configured via Model-Specific Registers (`MSR_STAR`, `MSR_LSTAR`, `MSR_FMASK`).
   * When userland executes `syscall`, the processor saves user `RIP` to `RCX`, user `RFLAGS` to `R11`, masks flags via `FMASK`, loads kernel `RIP` from `LSTAR`, and switches `CS`/`SS` descriptors.
   * Does not touch the IDT, avoiding memory accesses and descriptor table lookups.
   * Primary interface used by in-tree userland binaries and standard Linux libraries.

2. **Legacy Syscall Gate (`int 0x80`, Vector 128):**
   * Configured in the IDT with Privilege Level 3 (`DPL=3`), allowing user processes to execute software interrupts.
   * Provides compatibility with 32-bit legacy Linux binaries.
