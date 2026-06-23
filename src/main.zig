const std = @import("std");
const wasm = @import("wasm");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();

    const wasm_path = args.next() orelse return;

    const file = try if (std.Io.Dir.path.isAbsolute(wasm_path))
        std.Io.Dir.openFileAbsolute(io, wasm_path, .{})
    else
        std.Io.Dir.cwd().openFile(io, wasm_path, .{});
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    const bytes = try file_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);

    var parser: wasm.bin.Parser = .init(gpa);
    defer parser.deinit();
    try parser.parse(&reader);

    std.debug.print("types:\n", .{});
    for (parser.types, 0..) |t, i| {
        std.debug.print("\t{d}: {any}\n", .{ i, t });
    }

    std.debug.print("imports:\n", .{});
    for (parser.imports, 0..) |import, i| {
        std.debug.print("\t{d}: {s}.{s} {t} {?}\n", .{ i, import.module_name, import.field_name, import.kind, import.type_index });
    }

    std.debug.print("functions:\n", .{});
    for (parser.functions, 0..) |f, i| {
        std.debug.print("\t{d}: {d}\n", .{ i, f });
    }

    std.debug.print("tables:\n", .{});
    for (parser.tables, 0..) |table, i| {
        std.debug.print("\t{d}: {any}\n", .{ i, table });
    }

    std.debug.print("exports:\n", .{});
    for (parser.exports, 0..) |exp, i| {
        std.debug.print("\t{d}: {d} {s} {t}\n", .{ i, exp.index, exp.name, exp.kind });
    }
}
