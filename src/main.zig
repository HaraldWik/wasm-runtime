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

    var module: wasm.Module = .init(gpa);
    defer module.deinit();
    try module.parse(&reader);

    std.debug.print("types:\n", .{});
    for (module.types, 0..) |t, i| {
        std.debug.print("\t{d}: {any}\n", .{ i, t });
    }

    std.debug.print("imports:\n", .{});
    for (module.imports, 0..) |import, i| {
        std.debug.print("\t{d}: {s}.{s} {t} {?}\n", .{ i, import.module_name, import.field_name, import.kind, import.type_index });
    }

    std.debug.print("functions:\n", .{});
    for (module.functions, 0..) |f, i| {
        std.debug.print("\t{d}: {d}\n", .{ i, f });
    }

    std.debug.print("tables:\n", .{});
    for (module.tables, 0..) |table, i| {
        std.debug.print("\t{d}: {any}\n", .{ i, table });
    }

    std.debug.print("memories:\n", .{});
    for (module.memories, 0..) |memory, i| {
        std.debug.print("\t{d}: {any}\n", .{ i, memory });
    }

    std.debug.print("globals:\n", .{});
    for (module.globals, 0..) |globals, i| {
        std.debug.print("\t{d}: {any}\n", .{ i, globals });
    }

    std.debug.print("exports:\n", .{});
    for (module.exports.values(), 0..) |exp, i| {
        std.debug.print("\t{d}: {d} {s} {t}\n", .{ i, exp.index, exp.name, exp.kind });
    }

    std.debug.print("start: {d}\n", .{module.start});

    std.debug.print("elements:\n", .{});
    for (module.elements, 0..) |element, i| {
        std.debug.print("\t{d}: {any}\n", .{ i, element });
    }

    std.debug.print("code:\n", .{});
    for (module.code.functions, 0..) |function, i| {
        std.debug.print("\t{d}: {d} {any}\n", .{ i, function.locals.len, function.locals });
    }

    std.debug.print("data:\n", .{});
    for (module.data, 0..) |segment, i| {
        std.debug.print("\t{d}: index: {d}, offset: {d}, len: {d}\n", .{ i, segment.memory_index, segment.offset, segment.bytes.len });
    }

    std.debug.print("tags:\n", .{});
    for (module.tags, 0..) |tag, i| {
        std.debug.print("\t{d}: attribute: {d}, type_index: {d}\n", .{ i, tag.attribute, tag.type_index });
    }

    std.debug.print("\nEXECUTION\n", .{});

    var interpreter: wasm.Interpreter = try .init(gpa, &module);
    defer interpreter.deinit();

    try interpreter.registerHostImport(.{ .field_name = "log_number", .value = .{ .function = log_number_wasm } });

    var params: [3]wasm.Interpreter.Value = undefined;
    params[0] = .{ .i32 = 1 };
    params[1] = .{ .i32 = 2 };
    params[2] = .{ .i32 = 3 };
    try interpreter.call("calling", &params);
    // try interpreter.call("math_i32", &params);

}

fn log_number_wasm(params: []wasm.Interpreter.Value) ?wasm.Interpreter.Value {
    log_number(params[0].f64);
    return null;
}

pub fn log_number(num: f64) void {
    std.log.info("num: {d}", .{num});
}
