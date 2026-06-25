const Module = @This();

const std = @import("std");
const leb = @import("leb.zig");

gpa: std.mem.Allocator,

types: []FunctionType = &.{},
imports: []Import = &.{},
functions: []u32 = &.{},
tables: []Table = &.{},
memories: []Memory = &.{},
globals: []Global = &.{},
exports: std.array_hash_map.String(Export) = .empty,
// func_index
start: u32 = 0,
elements: []Element = &.{},
code: Code = .{},
data: []DataSegment = &.{},
tags: []Tag = &.{},

pub const ExternalKind = enum(u8) {
    function = 0,
    table = 1,
    memory = 2,
    global = 3,
};

pub const ValueType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    v128 = 0x7B,
    funcref = 0x70,
    externref = 0x6F,
};

pub fn init(gpa: std.mem.Allocator) Module {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Module) void {
    const gpa = self.gpa;

    for (self.elements) |element| gpa.free(element.function_indices);
    for (self.code.functions) |functions| gpa.free(functions.locals);

    gpa.free(self.types);
    gpa.free(self.imports);
    gpa.free(self.functions);
    gpa.free(self.tables);
    gpa.free(self.memories);
    gpa.free(self.globals);
    self.exports.deinit(gpa);
    gpa.free(self.elements);
    gpa.free(self.code.functions);
    gpa.free(self.data);
    gpa.free(self.tags);
}

pub fn parse(self: *Module, r: *std.Io.Reader) !void {
    const magic = try r.takeInt(u32, .little);
    const version = try r.takeInt(u32, .little);

    if (magic != 0x6d736100) return error.NotWasm;
    if (version != 1) return error.UnsupportedVersion;

    while (true) {
        self.parseSection(r) catch |err| switch (err) {
            error.EndOfStream => break,
            error.InvalidEnumTag => return, // tmp
            else => return err,
        };
    }
}

pub const Section = struct {
    id: Id,
    size: usize,

    pub const Id = enum(u8) {
        custom = 0,
        type = 1,
        import = 2,
        function = 3,
        table = 4,
        memory = 5,
        global = 6,
        @"export" = 7,
        start = 8,
        element = 9,
        code = 10,
        data = 11,
        data_count = 12,
        tag = 13,
    };

    pub fn read(r: *std.Io.Reader) std.Io.Reader.TakeEnumError!Section {
        const id = try r.takeEnum(Id, .little);
        const size: usize = try leb.readU32(r);
        return .{
            .id = id,
            .size = size,
        };
    }
};

fn parseSection(self: *Module, r: *std.Io.Reader) !void {
    const section: Section = try .read(r);

    var payload_reader: std.Io.Reader = .fixed(r.buffer[r.seek .. r.seek + section.size]);
    const payload = &payload_reader;

    switch (section.id) {
        .custom => {},
        .type => try self.parseSectionType(payload),
        .import => try self.parseSectionImport(payload),
        .function => try self.parseSectionFunction(payload),
        .table => try self.parseSectionTable(payload),
        .memory => try self.parseSectionMemory(payload),
        .global => try self.parseSectionGlobal(payload),
        .@"export" => try self.parseSectionExport(payload),
        .start => self.start = try leb.readU32(payload),
        .element => try self.parseSectionElement(payload),
        .code => try self.parseSectionCode(payload),
        .data => try self.parseSectionData(payload),
        .data_count => {}, // useless, same value as self.data.len
        .tag => try self.parseSectionTag(payload),
    }

    r.toss(section.size);
}

// type_section
pub const FunctionType = struct {
    params: []ValueType,
    results: []ValueType,
};

fn parseSectionType(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);
    self.types = try self.gpa.alloc(FunctionType, count);
    errdefer self.gpa.free(self.types);

    for (self.types) |*t| {
        const form = try r.takeByte();
        if (form != 0x60) return error.InvalidTypeForm;

        const param_count = try leb.readU32(r);
        const params: []ValueType = @ptrCast(try r.take(param_count));

        const result_count = try leb.readU32(r);
        const results: []ValueType = @ptrCast(try r.take(result_count));

        t.* = .{
            .params = params,
            .results = results,
        };
    }
}

pub const Import = struct {
    module_name: []const u8,
    field_name: []const u8,
    kind: ExternalKind,
    type_index: ?u32 = null, // only for function imports
};

fn parseSectionImport(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);
    self.imports = try self.gpa.alloc(Import, count);
    errdefer self.gpa.free(self.imports);

    for (self.imports) |*import| {
        const module_name_len = try leb.readU32(r);
        const module_name = try r.take(module_name_len);

        const field_name_len = try leb.readU32(r);
        const field_name = try r.take(field_name_len);

        const kind = try r.takeEnum(ExternalKind, .little);

        const type_index = if (kind == .function) try leb.readU32(r) else null;

        import.* = .{
            .module_name = module_name,
            .field_name = field_name,
            .kind = kind,
            .type_index = type_index,
        };
    }
}

fn parseSectionFunction(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);
    self.functions = try self.gpa.alloc(u32, count);
    errdefer self.gpa.free(self.functions);

    for (self.functions) |*f| f.* = try leb.readU32(r);
}

pub const Table = struct {
    elem_type: ValueType,
    min: u32,
    max: ?u32,
};

fn parseSectionTable(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);
    self.tables = try self.gpa.alloc(Table, count);
    errdefer self.gpa.free(self.tables);

    for (self.tables) |*table| {
        const elem_type = try r.takeEnum(ValueType, .little);

        const flags = try leb.readU32(r);
        const min = try leb.readU32(r);

        var max: ?u32 = null;
        if (flags & 0x01 != 0) max = try leb.readU32(r);

        table.* = .{
            .elem_type = elem_type,
            .min = min,
            .max = max,
        };
    }
}

pub const Memory = struct {
    min: u32,
    max: ?u32,
};

fn parseSectionMemory(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);
    self.memories = try self.gpa.alloc(Memory, count);
    errdefer self.gpa.free(self.memories);

    for (self.memories) |*memory| {
        const flags = try leb.readU32(r);
        const min = try leb.readU32(r);

        var max: ?u32 = null;
        if (flags & 0x01 != 0) max = try leb.readU32(r);

        memory.* = .{
            .min = min,
            .max = max,
        };
    }
}

pub const Global = struct {
    value_type: ValueType,
    mutability: Mutability,
    init_expr: InitExpr,

    pub const Mutability = enum(u8) {
        @"const" = 0x00,
        @"var" = 0x01,
    };

    pub const InitExpr = union(enum) {
        i32_const: i32,
        i64_const: i64,
        global_get: u32,
        raw: []const u8,
    };
};

fn parseSectionGlobal(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);
    self.globals = try self.gpa.alloc(Global, count);
    errdefer self.gpa.free(self.globals);

    for (self.globals) |*global| {
        const value_type = try r.takeEnum(ValueType, .little);
        const mutability = try r.takeEnum(Global.Mutability, .little);

        const opcode = try r.takeByte();
        const init_expr: Global.InitExpr = switch (opcode) {
            0x41 => blk: { // i32.const
                const value = try leb.readI32(r);
                const end = try r.takeByte();
                if (end != 0x0B) return error.InvalidInitExpr;

                break :blk .{ .i32_const = value };
            },

            0x42 => blk: { // i64.const
                const value = try leb.readI64(r);
                const end = try r.takeByte();
                if (end != 0x0B) return error.InvalidInitExpr;

                break :blk .{ .i64_const = value };
            },

            0x23 => blk: { // global.get
                const index = try leb.readU32(r);
                const end = try r.takeByte();
                if (end != 0x0B) return error.InvalidInitExpr;

                break :blk .{ .global_get = index };
            },

            else => {
                return error.UnsupportedInitExpr;
            },
        };

        global.* = .{
            .value_type = value_type,
            .mutability = mutability,
            .init_expr = init_expr,
        };
    }
}

pub const Export = struct {
    name: []u8,
    kind: ExternalKind,
    index: u32,
};

fn parseSectionExport(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);
    try self.exports.ensureTotalCapacity(self.gpa, count);
    errdefer self.exports.deinit(self.gpa);

    for (0..count) |_| {
        const name_len = try leb.readU32(r);
        const name = try r.take(@intCast(name_len));
        const kind = try r.takeEnum(ExternalKind, .little);
        const index = try leb.readU32(r);

        const exp: Export = .{
            .name = name,
            .kind = kind,
            .index = index,
        };

        self.exports.putAssumeCapacity(name, exp);
    }
}

pub const Element = struct {
    table_index: u32,
    offset: i32,
    function_indices: []u32,
};

fn parseSectionElement(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);
    self.elements = try self.gpa.alloc(Element, count);
    errdefer self.gpa.free(self.elements);

    for (self.elements) |*element| {
        const table_index = try leb.readU32(r);

        // offset expression (i32.const X, end)
        const opcode = try r.takeByte();
        if (opcode != 0x41) return error.UnsupportedElementExpr;

        const offset = try leb.readI32(r);

        const end = try r.takeByte();
        if (end != 0x0B) return error.InvalidElementExpr;

        const func_count = try leb.readU32(r);
        const funcs = try self.gpa.alloc(u32, func_count);
        errdefer self.gpa.free(funcs);

        for (funcs) |*f| f.* = try leb.readU32(r);

        element.* = .{
            .table_index = table_index,
            .offset = offset,
            .function_indices = funcs,
        };
    }
}

pub const FunctionBody = struct {
    locals: []Local,
    code: []u8,

    pub const Local = struct {
        count: u32,
        value_type: ValueType,
    };

    pub fn localCount(self: FunctionBody) usize {
        var n: usize = 0;
        for (self.locals) |local| n += local.count;
        return n;
    }
};

pub const Code = struct {
    functions: []FunctionBody = &.{},
};

fn parseSectionCode(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);

    self.code.functions = try self.gpa.alloc(FunctionBody, count);
    errdefer self.gpa.free(self.code.functions);

    for (self.code.functions) |*function| {
        const body_size = try leb.readU32(r);
        const body_end = r.seek + body_size;

        const local_count = try leb.readU32(r);
        const locals = try self.gpa.alloc(FunctionBody.Local, local_count);

        for (locals) |*l| {
            l.count = try leb.readU32(r);
            l.value_type = try r.takeEnum(ValueType, .little);
        }

        const code_start = r.seek;
        // const code_len = body_end - code_start;

        function.* = .{
            .locals = locals,
            .code = r.buffer[code_start..body_end],
        };

        r.seek = body_end;
    }
}

pub const DataSegment = struct {
    memory_index: u32,
    offset: i32,
    bytes: []const u8,
};

fn parseSectionData(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);

    self.data = try self.gpa.alloc(DataSegment, count);
    errdefer self.gpa.free(self.data);

    for (self.data) |*segment| {
        const memory_index = try leb.readU32(r);

        const op = try r.takeByte();
        if (op != 0x41) return error.UnsupportedDataExpr;

        const offset = try leb.readI32(r);

        const end = try r.takeByte();
        if (end != 0x0B) return error.InvalidExpr;

        const size = try leb.readU32(r);
        const bytes = try r.take(size);

        segment.* = .{
            .memory_index = memory_index,
            .offset = offset,
            .bytes = bytes,
        };
    }
}

pub const Tag = struct {
    attribute: u32,
    type_index: u32,
};

fn parseSectionTag(self: *Module, r: *std.Io.Reader) !void {
    const count = try leb.readU32(r);

    self.tags = try self.gpa.alloc(Tag, count);
    errdefer self.gpa.free(self.tags);

    for (self.tags) |*tag| {
        const attribute = try leb.readU32(r);
        const type_index = try leb.readU32(r);

        tag.* = .{
            .attribute = attribute,
            .type_index = type_index,
        };
    }
}
