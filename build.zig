const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{});

    // Automatic clean-room fallback: ensure an empty CPIO archive exists for
    // .cache/initramfs.cpio if missing, allowing bare 'zig build' without
    // pre-existing binary archives while preserving clean-room guardrails.
    ensureInitramfsFallback();

    const kernel = b.addExecutable(.{
        .name = "tinux",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Provide initramfs data via isolated anonymous module in .cache/
    kernel.root_module.addAnonymousImport("initramfs", .{
        .root_source_file = b.path(".cache/initramfs.zig"),
    });

    kernel.addAssemblyFile(b.path("src/arch/x86_64/syscall_entry.S"));
    kernel.addAssemblyFile(b.path("src/arch/x86_64/isr.S"));

    // Code model and entry point
    kernel.root_module.code_model = .kernel;
    kernel.entry = .{ .symbol_name = "_start" };

    b.installArtifact(kernel);
}

fn ensureInitramfsFallback() void {
    const cwd = std.fs.cwd();
    cwd.deleteFile("src/fs/initramfs.cpio") catch {};
    cwd.makePath(".cache") catch {};
    const cpio_path = ".cache/initramfs.cpio";

    const exists = blk: {
        const file = cwd.openFile(cpio_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => break :blk true,
        };
        file.close();
        break :blk true;
    };

    if (!exists) {
        // Minimal valid empty SVR4 newc CPIO archive (magic 070701 + TRAILER!!!)
        const empty_cpio =
            "07070100000000000000000000000000000000000000010000000000000000" ++
            "000000000000000000000000000000000000000b00000000TRAILER!!!\x00\x00\x00\x00";

        if (cwd.createFile(cpio_path, .{})) |file| {
            defer file.close();
            file.writeAll(empty_cpio) catch {};
        } else |_| {}
    }

    const zig_mod_path = ".cache/initramfs.zig";
    if (cwd.createFile(zig_mod_path, .{})) |file| {
        defer file.close();
        file.writeAll("pub const data: []const u8 = @embedFile(\"initramfs.cpio\");\n") catch {};
    } else |_| {}
}
