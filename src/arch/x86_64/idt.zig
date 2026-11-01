const std = @import("std");
const serial = @import("../../drivers/serial.zig");
const timer = @import("../../drivers/timer.zig");

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

pub const IdtGate = extern struct {
    offset_low: u16 = 0,
    selector: u16 = 0x08, // Kernel CS
    ist: u8 = 0,
    type_attr: u8 = 0,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    zero: u32 = 0,
};

const IdtDescriptor = packed struct {
    limit: u16,
    base: u64,
};

var idt_entries: [256]IdtGate = [_]IdtGate{.{}} ** 256;

extern fn isr0() void;
extern fn isr1() void;
extern fn isr2() void;
extern fn isr3() void;
extern fn isr4() void;
extern fn isr5() void;
extern fn isr6() void;
extern fn isr7() void;
extern fn isr8() void;
extern fn isr9() void;
extern fn isr10() void;
extern fn isr11() void;
extern fn isr12() void;
extern fn isr13() void;
extern fn isr14() void;
extern fn isr15() void;
extern fn isr16() void;
extern fn isr17() void;
extern fn isr18() void;
extern fn isr19() void;
extern fn isr20() void;
extern fn isr21() void;
extern fn isr22() void;
extern fn isr23() void;
extern fn isr24() void;
extern fn isr25() void;
extern fn isr26() void;
extern fn isr27() void;
extern fn isr28() void;
extern fn isr29() void;
extern fn isr30() void;
extern fn isr31() void;
extern fn irq0() void;
extern fn irq4() void;

pub fn setGate(vec: u8, handler: usize, ist: u8, flags: u8) void {
    idt_entries[vec] = .{
        .offset_low = @truncate(handler & 0xFFFF),
        .selector = 0x08,
        .ist = ist & 0x7,
        .type_attr = flags,
        .offset_mid = @truncate((handler >> 16) & 0xFFFF),
        .offset_high = @truncate((handler >> 32) & 0xFFFF_FFFF),
        .zero = 0,
    };
}

pub fn init() void {
    const isrs = [_]*const fn () callconv(.C) void{
        &isr0,  &isr1,  &isr2,  &isr3,  &isr4,  &isr5,  &isr6,  &isr7,
        &isr8,  &isr9,  &isr10, &isr11, &isr12, &isr13, &isr14, &isr15,
        &isr16, &isr17, &isr18, &isr19, &isr20, &isr21, &isr22, &isr23,
        &isr24, &isr25, &isr26, &isr27, &isr28, &isr29, &isr30, &isr31,
    };

    for (isrs, 0..) |isr_fn, vec| {
        setGate(@truncate(vec), @intFromPtr(isr_fn), 0, 0x8E); // Interrupt gate, DPL 0
    }

    // Hardware IRQs
    setGate(32, @intFromPtr(&irq0), 0, 0x8E); // Vector 32: PIT IRQ0
    setGate(36, @intFromPtr(&irq4), 0, 0x8E); // Vector 36: COM1 UART IRQ4

    const desc = IdtDescriptor{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    asm volatile (
        \\ lidt (%rax)
        :
        : [desc] "{rax}" (&desc),
        : "memory"
    );
}

export fn isrDispatch(frame: *TrapFrame) callconv(.C) void {
    if (frame.vector == 32) {
        timer.onTick();
        return;
    }
    if (frame.vector == 36) {
        serial.pollRx();
        timer.sendEoi(4);
        return;
    }

    serial.print("[TINUX_TRAP] CPU Exception vector {d}, err 0x{X}, rip 0x{X}\n", .{
        frame.vector,
        frame.error_code,
        frame.rip,
    });
    @panic("Unhandled CPU exception");
}
