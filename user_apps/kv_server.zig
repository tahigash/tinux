// Build: zig build-exe user_apps/kv_server.zig -target x86_64-linux-musl -O ReleaseSmall -fno-pie -femit-bin=user_apps/kv_server
const std = @import("std");
const linux = std.os.linux;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("[ZIG-APP] Starting Tinux Mini-KV TCP Server on 127.0.0.1:8080...\n", .{});

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    var conn = try server.accept();
    defer conn.stream.close();

    var buf: [256]u8 = undefined;
    const n = try conn.stream.read(&buf);
    if (n > 0) {
        const req = std.mem.trim(u8, buf[0..n], " \r\n");
        try stdout.print("[ZIG-APP] Received command: '{s}'\n", .{req});
        var reply_buf: [256]u8 = undefined;
        const reply = try std.fmt.bufPrint(&reply_buf, "+OK TINUX_KV_ACK:{s}\n", .{req});
        _ = try conn.stream.write(reply);
    }
    try stdout.print("[ZIG-APP] Request handled cleanly. Exiting.\n", .{});
}
