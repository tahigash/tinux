const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "tinux",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    kernel.addAssemblyFile(b.path("src/arch/x86_64/syscall_entry.S"));
    kernel.addAssemblyFile(b.path("src/arch/x86_64/isr.S"));

    // Code model and entry point
    kernel.code_model = .kernel;
    kernel.entry = .{ .symbol_name = "_start" };

    b.installArtifact(kernel);
}
