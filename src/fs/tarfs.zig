const std = @import("std");
const vfs = @import("vfs.zig");
const virtio_blk = @import("../drivers/virtio_blk.zig");
const Errno = @import("../uapi/errno.zig").Errno;
var is_mounted: bool = false;
var mount_prefix_buf: [64]u8 = [_]u8{ 'm', 'n', 't' } ++ [_]u8{0} ** 61;
var mount_prefix_len: usize = 3;
pub fn isMounted() bool {
    return is_mounted;
}
pub fn mountPrefix() []const u8 {
    return mount_prefix_buf[0..mount_prefix_len];
}
pub fn mountFromDisk(target_canonical: []const u8) Errno!usize {
    // Builder reads 512-byte sectors from virtio_blk, parses USTAR headers,
    // and registers each entry into VFS under "<target_canonical>/<rel_name>"
}
pub fn syncToDisk() Errno!void {
    // Builder iterates all active VFS nodes under "<mount_prefix>/", formats 512-byte USTAR headers
    // with valid octal checksums + padded data sectors, writes them to virtio_blk, and writes 2 zero sectors
}
