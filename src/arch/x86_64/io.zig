const std = @import("std");

pub inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub inline fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub inline fn ioWait() void {
    outb(0x80, 0);
}

pub const QemuExitCode = enum(u8) {
    success = 0x10, // QEMU exit status: (0x10 << 1) | 1 = 33
    failure = 0x11, // QEMU exit status: (0x11 << 1) | 1 = 35
};

pub fn qemuExit(code: QemuExitCode) noreturn {
    outb(0x00F4, @intFromEnum(code));
    while (true) {
        asm volatile ("cli; hlt");
    }
}

pub inline fn qemuExitSuccess() noreturn {
    qemuExit(.success);
}

pub inline fn qemuExitFailure() noreturn {
    qemuExit(.failure);
}
