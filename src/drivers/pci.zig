const io = @import("../arch/x86_64/io.zig");
pub const CONFIG_ADDRESS: u16 = 0x0CF8;
pub const CONFIG_DATA: u16 = 0x0CFC;
pub const PciDeviceInfo = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    io_base: u16,
    irq_line: u8,
};
pub fn readConfig32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const addr: u32 = 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
    io.outl(CONFIG_ADDRESS, addr);
    return io.inl(CONFIG_DATA);
}
pub fn writeConfig32(bus: u8, slot: u8, func: u8, offset: u8, val: u32) void {
    const addr: u32 = 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
    io.outl(CONFIG_ADDRESS, addr);
    io.outl(CONFIG_DATA, val);
}
pub fn findDeviceAndEnableDma(target_vendor: u16, target_device: u16) ?PciDeviceInfo {
    for (0..32) |slot| {
        const id_reg = readConfig32(0, @intCast(slot), 0, 0x00);
        const vendor: u16 = @truncate(id_reg);
        if (vendor == 0xFFFF) continue;
        const device: u16 = @truncate(id_reg >> 16);

        if (vendor == target_vendor and device == target_device) {
            const cmd_reg = readConfig32(0, @intCast(slot), 0, 0x04);
            writeConfig32(0, @intCast(slot), 0, 0x04, cmd_reg | 0x0000_0005);

            const bar0 = readConfig32(0, @intCast(slot), 0, 0x10);
            const io_base: u16 = @truncate(bar0 & ~@as(u32, 0x3));

            const intr = readConfig32(0, @intCast(slot), 0, 0x3C);
            const irq_line: u8 = @truncate(intr);

            return PciDeviceInfo{
                .bus = 0,
                .slot = @intCast(slot),
                .func = 0,
                .vendor_id = vendor,
                .device_id = device,
                .io_base = io_base,
                .irq_line = irq_line,
            };
        }
    }
    return null;
}
