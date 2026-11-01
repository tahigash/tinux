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

pub fn setMounted(mounted: bool) void {
    is_mounted = mounted;
}

pub fn mountPrefix() []const u8 {
    return mount_prefix_buf[0..mount_prefix_len];
}

pub fn mountFromDisk(target_canonical: []const u8) Errno!usize {
    if (!virtio_blk.isReady()) return Errno.ENODEV;
    if (is_mounted) return Errno.EBUSY;

    const norm_target = vfs.normalizePath(target_canonical);
    if (norm_target.len == 0 or norm_target.len > mount_prefix_buf.len) return Errno.EINVAL;

    @memcpy(mount_prefix_buf[0..norm_target.len], norm_target);
    mount_prefix_len = norm_target.len;

    _ = vfs.registerNode(norm_target, vfs.S_IFDIR | 0o755, "");

    const total_sectors = virtio_blk.getCapacityBytes() / 512;
    var sector: u64 = 0;
    var consecutive_zero_blocks: usize = 0;
    var loaded_files: usize = 0;
    var hdr_buf: [512]u8 = undefined;

    while (sector < total_sectors) {
        if (!virtio_blk.rwSector(sector, &hdr_buf, false)) {
            return Errno.EIO;
        }

        var is_all_zero = true;
        for (hdr_buf) |b| {
            if (b != 0) {
                is_all_zero = false;
                break;
            }
        }

        if (is_all_zero) {
            consecutive_zero_blocks += 1;
            if (consecutive_zero_blocks >= 2) {
                break;
            }
            sector += 1;
            continue;
        }
        consecutive_zero_blocks = 0;

        if (!std.mem.startsWith(u8, hdr_buf[257..262], "ustar")) {
            break;
        }

        const raw_name = std.mem.sliceTo(hdr_buf[0..100], 0);
        const norm_rel = vfs.normalizePath(raw_name);
        if (norm_rel.len == 0) {
            sector += 1;
            continue;
        }

        const mode_slice = std.mem.trim(u8, hdr_buf[100..108], &[_]u8{ 0, ' ' });
        const file_mode: u32 = if (mode_slice.len > 0) std.fmt.parseInt(u32, mode_slice, 8) catch 0o644 else 0o644;

        const size_slice = std.mem.trim(u8, hdr_buf[124..136], &[_]u8{ 0, ' ' });
        const file_size: usize = if (size_slice.len > 0) std.fmt.parseInt(usize, size_slice, 8) catch 0 else 0;

        const typeflag = hdr_buf[156];

        var full_path_buf: [vfs.MAX_PATH_LEN]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ norm_target, norm_rel }) catch return Errno.EINVAL;

        if (typeflag == '5' or (raw_name.len > 0 and raw_name[raw_name.len - 1] == '/')) {
            _ = vfs.registerNode(full_path, vfs.S_IFDIR | (file_mode & 0o777), "");
            sector += 1;
        } else {
            const node_idx = vfs.registerNode(full_path, vfs.S_IFREG | (file_mode & 0o777), "");
            const data_sectors = (file_size + 511) / 512;
            var s: u64 = 0;
            var offset: usize = 0;
            var data_buf: [512]u8 = undefined;

            while (s < data_sectors) : (s += 1) {
                if (!virtio_blk.rwSector(sector + 1 + s, &data_buf, false)) {
                    return Errno.EIO;
                }
                const chunk = @min(file_size - offset, 512);
                _ = vfs.writeNode(node_idx, offset, data_buf[0..chunk]) catch |err| return err;
                offset += chunk;
            }

            sector += 1 + data_sectors;
            loaded_files += 1;
        }
    }

    is_mounted = true;
    return loaded_files;
}

pub fn syncToDisk() Errno!void {
    if (!is_mounted or !virtio_blk.isReady()) return;

    var sector: u64 = 0;
    const prefix = mountPrefix();

    for (0..vfs.MAX_VFS_NODES) |i| {
        const node = vfs.getNodeSlot(i);
        if (!node.in_use) continue;

        const n_name = node.name();
        if (n_name.len > prefix.len and n_name[prefix.len] == '/' and std.mem.startsWith(u8, n_name, prefix)) {
            const rel_name = n_name[prefix.len + 1 ..];
            if (rel_name.len == 0) continue;

            var hdr: [512]u8 = [_]u8{0} ** 512;
            const is_dir = node.isDir();

            if (is_dir) {
                var name_with_slash: [100]u8 = undefined;
                const n_slice = if (rel_name.len < 99 and rel_name[rel_name.len - 1] != '/')
                    std.fmt.bufPrint(&name_with_slash, "{s}/", .{rel_name}) catch rel_name
                else
                    rel_name;
                const copy_len = @min(n_slice.len, 100);
                @memcpy(hdr[0..copy_len], n_slice[0..copy_len]);
                hdr[156] = '5';
            } else {
                const copy_len = @min(rel_name.len, 100);
                @memcpy(hdr[0..copy_len], rel_name[0..copy_len]);
                hdr[156] = '0';
            }

            _ = std.fmt.bufPrint(hdr[100..108], "{o:0>7}\x00", .{node.mode & 0o777}) catch unreachable;
            @memcpy(hdr[108..116], "0000000\x00");
            @memcpy(hdr[116..124], "0000000\x00");

            if (is_dir) {
                @memcpy(hdr[124..136], "00000000000\x00");
            } else {
                _ = std.fmt.bufPrint(hdr[124..136], "{o:0>11}\x00", .{node.size}) catch unreachable;
            }

            @memcpy(hdr[136..148], "00000000000\x00");

            // Fill checksum field with 8 spaces before computing sum
            @memset(hdr[148..156], ' ');

            @memcpy(hdr[257..263], "ustar\x00");
            @memcpy(hdr[263..265], "00");
            @memcpy(hdr[265..270], "root\x00");
            @memcpy(hdr[297..302], "root\x00");

            var sum: u32 = 0;
            for (hdr) |b| {
                sum += b;
            }
            _ = std.fmt.bufPrint(hdr[148..156], "{o:0>6}\x00 ", .{sum}) catch unreachable;

            if (!virtio_blk.rwSector(sector, &hdr, true)) {
                return Errno.EIO;
            }
            sector += 1;

            if (!is_dir and node.size > 0) {
                const file_data = node.slice();
                var off: usize = 0;
                var data_sector: [512]u8 = undefined;

                while (off < file_data.len) {
                    const chunk = @min(file_data.len - off, 512);
                    @memcpy(data_sector[0..chunk], file_data[off .. off + chunk]);
                    if (chunk < 512) {
                        @memset(data_sector[chunk..512], 0);
                    }
                    if (!virtio_blk.rwSector(sector, &data_sector, true)) {
                        return Errno.EIO;
                    }
                    sector += 1;
                    off += chunk;
                }
            }
        }
    }

    var zero_buf: [512]u8 = [_]u8{0} ** 512;
    if (!virtio_blk.rwSector(sector, &zero_buf, true)) return Errno.EIO;
    sector += 1;
    if (!virtio_blk.rwSector(sector, &zero_buf, true)) return Errno.EIO;
    sector += 1;
}
