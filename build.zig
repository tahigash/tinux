const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{});

    // Milestone task option (default: TASK-005)
    const task_str = b.option([]const u8, "task", "Milestone task to run (default: TASK-005)") orelse "TASK-005";
    ensureTaskConfig(task_str);

    // Automatic clean-room fallbacks: ensure empty fallbacks exist in .cache/
    // for initramfs.cpio and init_test.elf if missing, allowing bare 'zig build'
    // without pre-existing binary archives while preserving clean-room guardrails.
    ensureInitramfsFallback();
    ensureInitTestFallback();

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

    // Provide userland init_test ELF data via isolated anonymous module in .cache/
    kernel.root_module.addAnonymousImport("init_test", .{
        .root_source_file = b.path(".cache/init_test.zig"),
    });

    // Provide active milestone task configuration via isolated anonymous module in .cache/
    kernel.root_module.addAnonymousImport("task_config", .{
        .root_source_file = b.path(".cache/task_config.zig"),
    });

    kernel.addAssemblyFile(b.path("src/arch/x86_64/boot.S"));
    kernel.addAssemblyFile(b.path("src/arch/x86_64/syscall_entry.S"));
    kernel.addAssemblyFile(b.path("src/arch/x86_64/isr.S"));

    kernel.setLinkerScript(b.path("linker.ld"));

    // Code model and entry point
    kernel.root_module.code_model = .kernel;
    kernel.entry = .{ .symbol_name = "_start32" };

    b.installArtifact(kernel);
}

fn ensureTaskConfig(task_str: []const u8) void {
    const cwd = std.fs.cwd();
    cwd.makePath(".cache") catch {};
    const path = ".cache/task_config.zig";
    if (cwd.createFile(path, .{})) |file| {
        defer file.close();
        var buf: [128]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "pub const task: []const u8 = \"{s}\";\n", .{task_str}) catch return;
        file.writeAll(content) catch {};
    } else |_| {}
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
            "00000000000000000000000000000000000000000000000b00000000TRAILER!!!\x00\x00\x00\x00";

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

fn ensureInitTestFallback() void {
    const cwd = std.fs.cwd();
    cwd.deleteFile("src/proc/init_test.elf") catch {};
    cwd.deleteFile("src/proc/init_test.elf.o") catch {};
    cwd.makePath(".cache") catch {};
    const elf_path = ".cache/init_test.elf";

    const exists = blk: {
        const file = cwd.openFile(elf_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => break :blk true,
        };
        file.close();
        break :blk true;
    };

    if (!exists) {
        // Minimal valid dummy 64-bit ELF executable header (64 bytes)
        // Magic \x7FELF, 64-bit, little endian, version 1, ET_EXEC, EM_X86_64
        const dummy_elf = [_]u8{
            0x7F, 'E',  'L',  'F',  // e_ident[0..4]
            2,                      // ELFCLASS64
            1,                      // ELFDATA2LSB
            1,                      // EV_CURRENT
            0,                      // ELFOSABI_NONE
            0, 0, 0, 0, 0, 0, 0, 0, // padding
            2, 0,                   // e_type: ET_EXEC
            62, 0,                  // e_machine: EM_X86_64
            1, 0, 0, 0,             // e_version: 1
            0, 0x10, 0x40, 0, 0, 0, 0, 0, // e_entry: 0x401000
            64, 0, 0, 0, 0, 0, 0, 0, // e_phoff: 64
            0, 0, 0, 0, 0, 0, 0, 0, // e_shoff: 0
            0, 0, 0, 0,             // e_flags: 0
            64, 0,                  // e_ehsize: 64
            56, 0,                  // e_phentsize: 56
            0, 0,                   // e_phnum: 0
            0, 0,                   // e_shentsize: 0
            0, 0,                   // e_shnum: 0
            0, 0,                   // e_shstrndx: 0
        };

        if (cwd.createFile(elf_path, .{})) |file| {
            defer file.close();
            file.writeAll(&dummy_elf) catch {};
        } else |_| {}
    }

    const zig_mod_path = ".cache/init_test.zig";
    if (cwd.createFile(zig_mod_path, .{})) |file| {
        defer file.close();
        file.writeAll("pub const data: []const u8 = @embedFile(\"init_test.elf\");\n") catch {};
    } else |_| {}
}
