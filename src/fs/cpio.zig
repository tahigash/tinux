const std = @import("std");
const vfs = @import("vfs.zig");

pub const CpioNewcHeader = extern struct {
    c_magic: [6]u8,
    c_ino: [8]u8,
    c_mode: [8]u8,
    c_uid: [8]u8,
    c_gid: [8]u8,
    c_nlink: [8]u8,
    c_mtime: [8]u8,
    c_filesize: [8]u8,
    c_devmajor: [8]u8,
    c_devminor: [8]u8,
    c_rdevmajor: [8]u8,
    c_rdevminor: [8]u8,
    c_namesize: [8]u8,
    c_check: [8]u8,

    comptime {
        std.debug.assert(@sizeOf(CpioNewcHeader) == 110);
    }
};

fn parseHex8(field: [8]u8) usize {
    return std.fmt.parseInt(usize, &field, 16) catch 0;
}

pub fn unpackInitramfs(archive: []const u8) usize {
    var offset: usize = 0;
    var count: usize = 0;
    while (offset + @sizeOf(CpioNewcHeader) <= archive.len) {
        const hdr = @as(*align(1) const CpioNewcHeader, @ptrCast(archive.ptr + offset));
        if (!std.mem.eql(u8, &hdr.c_magic, "070701") and !std.mem.eql(u8, &hdr.c_magic, "070702")) {
            break;
        }

        const mode: u32 = @truncate(parseHex8(hdr.c_mode));
        const filesize = parseHex8(hdr.c_filesize);
        const namesize = parseHex8(hdr.c_namesize);
        if (namesize == 0) break;

        const name_start = offset + @sizeOf(CpioNewcHeader);
        if (name_start + namesize > archive.len) break;
        const raw_name = archive[name_start .. name_start + namesize - 1]; // Exclude NUL
        if (std.mem.eql(u8, raw_name, "TRAILER!!!")) break;

        const data_start = std.mem.alignForward(usize, name_start + namesize, 4);
        if (data_start + filesize > archive.len) break;
        const file_data = archive[data_start .. data_start + filesize];

        const norm_name = vfs.normalizePath(raw_name);
        if (norm_name.len > 0) {
            _ = vfs.registerNode(norm_name, mode, file_data);
            count += 1;
        }

        offset = std.mem.alignForward(usize, data_start + filesize, 4);
    }
    return count;
}
