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
    // Builder scans bus 0, slot 0..32, func 0. On match, enables Bit 0 (I/O) & Bit 2 (Bus Master)
    // in Command register (offset 0x04), reads BAR0 (offset 0x10), and returns PciDeviceInfo.
}
