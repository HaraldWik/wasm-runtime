//! Binary

const std = @import("std");

pub const Section = enum(u8) {
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

pub const ExternalKind = enum(u8) {
    function = 0,
    table = 1,
    memory = 2,
    global = 3,
};

pub const type_section = struct {
    pub const ValType = enum(u8) {
        i32 = 0x7F,
        i64 = 0x7E,
        f32 = 0x7D,
        f64 = 0x7C,
    };

    pub const Func = struct {
        params: []ValType,
        results: []ValType,
    };
};

pub const Import = struct {
    module_name: []const u8,
    field_name: []const u8,
    kind: ExternalKind,
    type_index: ?u32 = null, // only for function imports
};

pub const Table = struct {
    elem_type: ElemType,
    min: u32,
    max: ?u32,

    pub const ElemType = enum(u8) {
        funcref = 0x70,
        externref = 0x6F,
    };
};

pub const Export = struct {
    name: []u8,
    kind: ExternalKind,
    index: u32,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,

    types: []type_section.Func = &.{},
    imports: []Import = &.{},
    functions: []u32 = &.{},
    tables: []Table = &.{},
    exports: []Export = &.{},

    pub fn init(gpa: std.mem.Allocator) Parser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Parser) void {
        const gpa = self.gpa;
        for (self.types) |t| {
            gpa.free(t.params);
            gpa.free(t.results);
        }
        gpa.free(self.types);
        gpa.free(self.imports);
        gpa.free(self.functions);
        gpa.free(self.tables);
        gpa.free(self.exports);
    }

    pub fn parse(self: *Parser, r: *std.Io.Reader) !void {
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

    pub fn parseSection(self: *Parser, r: *std.Io.Reader) !void {
        const section = try r.takeEnum(Section, .little);
        const size: usize = @intCast(try readLeb(r));

        std.log.info("{t} {Bi}", .{ section, size });

        var payload_reader: std.Io.Reader = .fixed(r.buffer[r.seek .. r.seek + size]);
        const payload = &payload_reader;

        switch (section) {
            .custom => {},
            .type => try self.parseSectionType(payload),
            .import => try self.parseSectionImport(payload),
            .function => try self.parseSectionFunction(payload),
            .table => try self.parseSectionTable(payload),
            .memory => {},
            .global => {},
            .@"export" => try self.parseSectionExport(payload),
            .start => {},
            .element => {},
            .code => {},
            .data => {},
            .data_count => {},
            .tag => {},
        }

        r.toss(size);
    }

    pub fn parseSectionType(self: *Parser, r: *std.Io.Reader) !void {
        const type_count = try readLeb(r);
        self.types = try self.gpa.alloc(type_section.Func, type_count);
        errdefer self.gpa.free(self.types);

        for (self.types) |*t| {
            const form = try r.takeByte();
            if (form != 0x60) return error.InvalidTypeForm;

            const param_count = try readLeb(r);
            const params = try self.gpa.alloc(type_section.ValType, param_count);
            for (params) |*param| {
                param.* = try r.takeEnum(type_section.ValType, .little);
            }

            const result_count = try readLeb(r);
            const results = try self.gpa.alloc(type_section.ValType, result_count);
            for (results) |*result| {
                result.* = try r.takeEnum(type_section.ValType, .little);
            }

            t.* = .{ .params = params, .results = results };
        }
    }

    pub fn parseSectionImport(self: *Parser, r: *std.Io.Reader) !void {
        const import_count = try readLeb(r);
        self.imports = try self.gpa.alloc(Import, import_count);
        errdefer self.gpa.free(self.imports);

        for (self.imports) |*import| {
            const module_name_len = try readLeb(r);
            const module_name = try r.take(module_name_len);

            const field_name_len = try readLeb(r);
            const field_name = try r.take(field_name_len);

            const kind = try r.takeEnum(ExternalKind, .little);

            const type_index = if (kind == .function) try readLeb(r) else null;

            import.* = .{
                .module_name = module_name,
                .field_name = field_name,
                .kind = kind,
                .type_index = type_index,
            };
        }
    }

    pub fn parseSectionFunction(self: *Parser, r: *std.Io.Reader) !void {
        const function_count = try readLeb(r);
        self.functions = try self.gpa.alloc(u32, function_count);
        errdefer self.gpa.free(self.functions);

        for (self.functions) |*f| f.* = try readLeb(r);
    }

    pub fn parseSectionTable(self: *Parser, r: *std.Io.Reader) !void {
        const table_count = try readLeb(r);
        self.tables = try self.gpa.alloc(Table, table_count);
        errdefer self.gpa.free(self.tables);

        for (self.tables) |*table| {
            const elem_type = try r.takeEnum(Table.ElemType, .little);

            const flags = try readLeb(r);
            const min = try readLeb(r);

            var max: ?u32 = null;
            if ((flags & 0x01) != 0) {
                max = try readLeb(r);
            }

            table.* = .{
                .elem_type = elem_type,
                .min = min,
                .max = max,
            };
        }
    }

    pub fn parseSectionExport(self: *Parser, r: *std.Io.Reader) !void {
        const export_count = try readLeb(r);
        self.exports = try self.gpa.alloc(Export, export_count);
        errdefer self.gpa.free(self.exports);

        for (self.exports) |*exp| {
            const name_len = try readLeb(r);
            const name = try r.take(@intCast(name_len));
            const kind = try r.takeEnum(ExternalKind, .little);
            const index = try readLeb(r);

            exp.* = .{
                .name = name,
                .kind = kind,
                .index = index,
            };
        }
    }
};

/// LEB128
pub fn readLeb(r: *std.Io.Reader) !u32 {
    var result: u32 = 0;
    var shift: u8 = 0;

    while (true) {
        const byte = try r.takeByte();

        if (shift > 28) return error.IntegerOverflow;

        const payload: u32 = byte & 0x7F;
        result |= payload << @as(u5, @intCast(shift));

        if ((byte & 0x80) == 0) break;

        shift += 7;
    }

    return result;
}
