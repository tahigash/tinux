const std = @import("std");
const gdt = @import("gdt.zig");
const io = @import("io.zig");
const serial = @import("../../drivers/serial.zig");
const timer = @import("../../drivers/timer.zig");

pub const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,

    comptime {
        std.debug.assert(@sizeOf(TrapFrame) == 176);
        std.debug.assert(@offsetOf(TrapFrame, "vector") == 120);
        std.debug.assert(@offsetOf(TrapFrame, "rip") == 136);
    }
};

pub const IdtEntry = extern struct {
    offset_low: u16 = 0,
    selector: u16 = 0,
    ist: u8 = 0,
    type_attr: u8 = 0,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(IdtEntry) == 16);
    }
};

pub const IdtGate = IdtEntry;

var idt_entries: [256]IdtEntry align(16) = [_]IdtEntry{.{}} ** 256;
extern const isr_stub_table: [32]usize;
extern fn irq0() void;
extern fn irq4() void;

pub var breakpoint_hit_count: usize = 0;

pub fn setGate(vec: u8, handler_addr: usize, ist: u8, type_attr: u8) void {
    idt_entries[vec] = .{
        .offset_low = @truncate(handler_addr),
        .selector = gdt.KERNEL_CODE_SEL,
        .ist = ist & 0x7,
        .type_attr = type_attr,
        .offset_mid = @truncate(handler_addr >> 16),
        .offset_high = @truncate(handler_addr >> 32),
        .reserved = 0,
    };
}

pub fn init() void {
    for (0..32) |vec| {
        const handler_addr = isr_stub_table[vec];
        if (vec == 3) {
            setGate(@truncate(vec), handler_addr, 0, 0xEE); // Trap Gate, DPL=3
        } else if (vec == 8) {
            setGate(@truncate(vec), handler_addr, 1, 0x8E); // Interrupt Gate, IST=1
        } else {
            setGate(@truncate(vec), handler_addr, 0, 0x8E); // Interrupt Gate, DPL=0
        }
    }

    // Hardware IRQs
    setGate(32, @intFromPtr(&irq0), 0, 0x8E);
    setGate(36, @intFromPtr(&irq4), 0, 0x8E);

    var idtr: [10]u8 align(16) = undefined;
    const idt_limit: u16 = @intCast(@sizeOf(@TypeOf(idt_entries)) - 1);
    const idt_base: u64 = @intFromPtr(&idt_entries);
    std.mem.writeInt(u16, idtr[0..2], idt_limit, .little);
    std.mem.writeInt(u64, idtr[2..10], idt_base, .little);

    asm volatile (
        \\ lidt (%[idtr])
        :
        : [idtr] "r" (&idtr),
        : "memory"
    );
}

export fn isrDispatch(frame: *TrapFrame) callconv(.C) void {
    if (frame.vector == 3) {
        breakpoint_hit_count += 1;
        serial.writeString("[TINUX_INTR] Handled #BP (Vector 3) cleanly\n");
        return;
    }
    if (frame.vector == 32) {
        timer.onTick();
        return;
    }
    if (frame.vector == 36) {
        serial.pollRx();
        timer.sendEoi(4);
        return;
    }

    serial.writeString("\n[TINUX_TRAP] CPU EXCEPTION Vector: ");
    serial.writeHex(frame.vector);
    serial.writeString(" ErrorCode: ");
    serial.writeHex(frame.error_code);
    serial.writeString(" RIP: ");
    serial.writeHex(frame.rip);
    serial.writeString(" CS: ");
    serial.writeHex(frame.cs);
    serial.writeString("\n");

    if (frame.vector == 14) {
        const cr2: u64 = asm volatile ("mov %cr2, %[ret]"
            : [ret] "=r" (-> u64),
        );
        serial.writeString("[TINUX_TRAP] CR2 (Fault Addr): ");
        serial.writeHex(cr2);
        serial.writeString("\n");
    }

    serial.writeString("[TINUX_TRAP] RAX: ");
    serial.writeHex(frame.rax);
    serial.writeString(" RBX: ");
    serial.writeHex(frame.rbx);
    serial.writeString(" RCX: ");
    serial.writeHex(frame.rcx);
    serial.writeString(" RDX: ");
    serial.writeHex(frame.rdx);
    serial.writeString("\n[TINUX_TRAP] RSI: ");
    serial.writeHex(frame.rsi);
    serial.writeString(" RDI: ");
    serial.writeHex(frame.rdi);
    serial.writeString(" RBP: ");
    serial.writeHex(frame.rbp);
    serial.writeString(" RSP: ");
    serial.writeHex(frame.rsp);
    serial.writeString("\n");

    io.qemuExit(.failure);
}
