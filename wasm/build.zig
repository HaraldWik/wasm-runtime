const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .freestanding, .cpu_arch = .wasm32 } });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = false;

    b.installArtifact(exe);
}
