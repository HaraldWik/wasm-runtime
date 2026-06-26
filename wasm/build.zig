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
    exe.rdynamic = true;

    b.installArtifact(exe);

    const wasm2wat = b.findProgram(&.{"wasm2wat"}, &.{}) catch return;
    const wasm2wat_run = b.addSystemCommand(&.{wasm2wat});
    wasm2wat_run.step.dependOn(&exe.step);

    wasm2wat_run.addArtifactArg(exe);
    wasm2wat_run.addArg("-o");
    const wat_name = b.fmt("{s}.wat", .{exe.name});
    const wat = wasm2wat_run.addOutputFileArg(wat_name);

    const install_wat = b.addInstallBinFile(wat, wat_name);
    install_wat.step.dependOn(&wasm2wat_run.step);

    b.getInstallStep().dependOn(&install_wat.step);

    // zig-out/bin/wasm.wasm -o zig-out/bin/wat.wat
}
