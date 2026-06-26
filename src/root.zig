const std = @import("std");
const leb = @import("leb.zig");

pub const Module = @import("Module.zig");

pub const Interpreter = struct {
    gpa: std.mem.Allocator,
    module: *const Module,
    memory: []u8 = &.{},
    globals: []Global = &.{},
    frames: std.ArrayList(Frame) = .empty,

    pub const Value = union(enum) {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,

        pub fn fromValueType(value_type: Module.ValueType) Value {
            return switch (value_type) {
                .v128, .funcref, .externref => unreachable,
                inline else => |vt| @unionInit(Value, @tagName(vt), 0),
            };
        }
    };

    pub const Global = struct {
        value: Value,
        mutability: Module.Global.Mutability,

        pub fn init(module: *const Module, index: usize) Global {
            const global = module.globals[index];

            var value: Value = .fromValueType(global.value_type);

            switch (global.init_expr) {
                .i32_const => |v| value.i32 = v,
                .i64_const => |v| value.i64 = v,
                .f32_const => |v| value.f32 = v,
                .f64_const => |v| value.f64 = v,
                .global_get => |i| value = Global.init(module, i).value,
            }
            return .{
                .value = value,
                .mutability = global.mutability,
            };
        }
    };

    pub const Opcode = enum(u8) {
        // Control
        @"unreachable" = 0x00,
        nop = 0x01,

        block = 0x02,
        loop = 0x03,
        @"if" = 0x04,
        @"else" = 0x05,

        end = 0x0B,
        br = 0x0C,
        br_if = 0x0D,
        br_table = 0x0E,
        @"return" = 0x0F,
        call = 0x10,
        call_indirect = 0x11,

        // Parametric
        drop = 0x1A,
        select = 0x1B,

        // Variables
        local_get = 0x20,
        local_set = 0x21,
        local_tee = 0x22,

        global_get = 0x23,
        global_set = 0x24,

        // Memory
        i32_load = 0x28,
        i64_load = 0x29,
        f32_load = 0x2A,
        f64_load = 0x2B,

        i32_load8_s = 0x2C,
        i32_load8_u = 0x2D,
        i32_load16_s = 0x2E,
        i32_load16_u = 0x2F,

        i64_load8_s = 0x30,
        i64_load8_u = 0x31,
        i64_load16_s = 0x32,
        i64_load16_u = 0x33,
        i64_load32_s = 0x34,

        i32_store = 0x36,
        i64_store = 0x37,
        f32_store = 0x38,
        f64_store = 0x39,

        i32_store8 = 0x3A,
        i32_store16 = 0x3B,
        i64_store8 = 0x3C,
        i64_store16 = 0x3D,
        i64_store32 = 0x3E,

        memory_size = 0x3F,
        memory_grow = 0x40,

        // Constants
        i32_const = 0x41,
        i64_const = 0x42,
        f32_const = 0x43,
        f64_const = 0x44,

        // i32 comparisons
        i32_eqz = 0x45,
        i32_eq = 0x46,
        i32_ne = 0x47,
        i32_lt_s = 0x48,
        i32_lt_u = 0x49,
        i32_gt_s = 0x4A,
        i32_gt_u = 0x4B,
        i32_le_s = 0x4C,
        i32_le_u = 0x4D,
        i32_ge_s = 0x4E,
        i32_ge_u = 0x4F,

        // i64 comparisons
        i64_eqz = 0x50,
        i64_eq = 0x51,
        i64_ne = 0x52,
        i64_lt_s = 0x53,
        i64_lt_u = 0x54,
        i64_gt_s = 0x55,
        i64_gt_u = 0x56,
        i64_le_s = 0x57,
        i64_le_u = 0x58,
        i64_ge_s = 0x59,
        i64_ge_u = 0x5A,

        // i32 arithmetic
        i32_clz = 0x67,
        i32_ctz = 0x68,
        i32_popcnt = 0x69,

        i32_add = 0x6A,
        i32_sub = 0x6B,
        i32_mul = 0x6C,
        i32_div_s = 0x6D,
        i32_div_u = 0x6E,
        i32_rem_s = 0x6F,
        i32_rem_u = 0x70,

        i32_and = 0x71,
        i32_or = 0x72,
        i32_xor = 0x73,
        i32_shl = 0x74,
        i32_shr_s = 0x75,
        i32_shr_u = 0x76,
        i32_rotl = 0x77,
        i32_rotr = 0x78,

        // i64 arithmetic
        i64_clz = 0x79,
        i64_ctz = 0x7A,
        i64_popcnt = 0x7B,

        i64_add = 0x7C,
        i64_sub = 0x7D,
        i64_mul = 0x7E,
        i64_div_s = 0x7F,
        i64_div_u = 0x80,
        i64_rem_s = 0x81,
        i64_rem_u = 0x82,

        i64_and = 0x83,
        i64_or = 0x84,
        i64_xor = 0x85,
        i64_shl = 0x86,
        i64_shr_s = 0x87,
        i64_shr_u = 0x88,
        i64_rotl = 0x89,
        i64_rotr = 0x8A,

        // f32 arithmetic
        f32_abs = 0x8B,
        f32_neg = 0x8C,
        f32_ceil = 0x8D,
        f32_floor = 0x8E,
        f32_trunc = 0x8F,
        f32_nearest = 0x90,
        f32_sqrt = 0x91,

        f32_add = 0x92,
        f32_sub = 0x93,
        f32_mul = 0x94,
        f32_div = 0x95,
        f32_min = 0x96,
        f32_max = 0x97,

        f32_eq = 0x98,
        f32_ne = 0x99,
        f32_lt = 0x9A,
        f32_gt = 0x9B,
        f32_le = 0x9C,
        f32_ge = 0x9D,

        // f64 arithmetic
        f64_abs = 0x9E,
        f64_neg = 0x9F,
        f64_ceil = 0xA0,
        f64_floor = 0xA1,
        f64_trunc = 0xA2,
        f64_nearest = 0xA3,
        f64_sqrt = 0xA4,

        f64_add = 0xA5,
        f64_sub = 0xA6,
        f64_mul = 0xA7,
        f64_div = 0xA8,
        f64_min = 0xA9,
        f64_max = 0xAA,

        f64_eq = 0xAB,
        f64_ne = 0xAC,
        f64_lt = 0xAD,
        f64_gt = 0xAE,
        f64_le = 0xAF,
        f64_ge = 0xB0,

        // conversions
        f32_convert_i32_s = 0xB2,
        f32_convert_i32_u = 0xB3,
        f32_convert_i64_s = 0xB4,
        f32_convert_i64_u = 0xB5,

        f64_convert_i32_s = 0xB6,
        f64_convert_i32_u = 0xB7,
        f64_convert_i64_s = 0xB8,
        f64_convert_i64_u = 0xB9,

        // reinterpret
        i32_reinterpret_f32 = 0xBC,
        i64_reinterpret_f64 = 0xBD,
        f32_reinterpret_i32 = 0xBE,
        f64_reinterpret_i64 = 0xBF,

        _,
    };

    pub const Operation = union(Opcode) {
        @"unreachable",
        nop,

        block: i32, // block type (varint32)
        loop: i32, // block type (varint32)
        @"if": i32, // block type (varint32)
        @"else",

        end,

        br: u32, // label index (ULEB128)
        br_if: u32, // label index (ULEB128)

        br_table: struct {
            targets: []u8, // vector of label indices
            default: u32,

            pub fn target(self: @This(), index: usize) ?u32 {
                const len: usize = @divExact(self.targets.len, 4);
                if (index > len) return null;
                var reader: std.Io.Reader = .fixed(self.targets[index * 4 .. index * 4 + 4]);
                return leb.readU32(&reader) catch unreachable;
            }
        },

        @"return",
        call: u32, // function index (ULEB128)

        call_indirect: struct {
            type_index: u32,
            table: u32,
        },

        // Parametric
        drop,
        select,

        // Variable access
        local_get: u32,
        local_set: u32,
        local_tee: u32,

        global_get: u32,
        global_set: u32,

        // Memory (all use memarg: align + offset)
        i32_load: MemArg,
        i64_load: MemArg,
        f32_load: MemArg,
        f64_load: MemArg,

        i32_load8_s: MemArg,
        i32_load8_u: MemArg,
        i32_load16_s: MemArg,
        i32_load16_u: MemArg,

        i64_load8_s: MemArg,
        i64_load8_u: MemArg,
        i64_load16_s: MemArg,
        i64_load16_u: MemArg,
        i64_load32_s: MemArg,

        i32_store: MemArg,
        i64_store: MemArg,
        f32_store: MemArg,
        f64_store: MemArg,

        i32_store8: MemArg,
        i32_store16: MemArg,
        i64_store8: MemArg,
        i64_store16: MemArg,
        i64_store32: MemArg,

        memory_size: u32,
        memory_grow: u32,

        // Constants
        i32_const: i32, // SLEB128
        i64_const: i64, // SLEB128
        f32_const: u32, // raw bits
        f64_const: u64, // raw bits

        // i32 comparisons
        i32_eqz,
        i32_eq,
        i32_ne,
        i32_lt_s,
        i32_lt_u,
        i32_gt_s,
        i32_gt_u,
        i32_le_s,
        i32_le_u,
        i32_ge_s,
        i32_ge_u,

        // i64 comparisons
        i64_eqz,
        i64_eq,
        i64_ne,
        i64_lt_s,
        i64_lt_u,
        i64_gt_s,
        i64_gt_u,
        i64_le_s,
        i64_le_u,
        i64_ge_s,
        i64_ge_u,

        // i32 arithmetic
        i32_clz,
        i32_ctz,
        i32_popcnt,

        i32_add,
        i32_sub,
        i32_mul,
        i32_div_s,
        i32_div_u,
        i32_rem_s,
        i32_rem_u,

        i32_and,
        i32_or,
        i32_xor,
        i32_shl,
        i32_shr_s,
        i32_shr_u,
        i32_rotl,
        i32_rotr,

        // i64 arithmetic
        i64_clz,
        i64_ctz,
        i64_popcnt,

        i64_add,
        i64_sub,
        i64_mul,
        i64_div_s,
        i64_div_u,
        i64_rem_s,
        i64_rem_u,

        i64_and,
        i64_or,
        i64_xor,
        i64_shl,
        i64_shr_s,
        i64_shr_u,
        i64_rotl,
        i64_rotr,

        // f32 arithmetic
        f32_abs,
        f32_neg,
        f32_ceil,
        f32_floor,
        f32_trunc,
        f32_nearest,
        f32_sqrt,

        f32_add,
        f32_sub,
        f32_mul,
        f32_div,
        f32_min,
        f32_max,

        f32_eq,
        f32_ne,
        f32_lt,
        f32_gt,
        f32_le,
        f32_ge,

        // f64 arithmetic
        f64_abs,
        f64_neg,
        f64_ceil,
        f64_floor,
        f64_trunc,
        f64_nearest,
        f64_sqrt,

        f64_add,
        f64_sub,
        f64_mul,
        f64_div,
        f64_min,
        f64_max,

        f64_eq,
        f64_ne,
        f64_lt,
        f64_gt,
        f64_le,
        f64_ge,

        f32_convert_i32_s,
        f32_convert_i32_u,
        f32_convert_i64_s,
        f32_convert_i64_u,

        f64_convert_i32_s,
        f64_convert_i32_u,
        f64_convert_i64_s,
        f64_convert_i64_u,

        // reinterpret conversions
        i32_reinterpret_f32,
        i64_reinterpret_f64,
        f32_reinterpret_i32,
        f64_reinterpret_i64,

        pub const MemArg = struct {
            alignment: u32,
            offset: u32,
        };

        pub fn create(r: *std.Io.Reader, opcode: Opcode) Operation {
            switch (opcode) {
                .br_table => {
                    const targets_len = leb.readU32(r) catch unreachable;
                    const targets = r.take(targets_len * @sizeOf(u32)) catch unreachable;
                    const default = leb.readU32(r) catch unreachable;

                    return .{ .br_table = .{
                        .targets = targets,
                        .default = default,
                    } };
                },
                _ => unreachable,
                inline else => |comptime_opcode| {
                    const T = @FieldType(Operation, @tagName(comptime_opcode));
                    const t = leb.readIntoAny(T, r) catch unreachable;
                    return @unionInit(Operation, @tagName(comptime_opcode), t);
                },
            }
        }
    };

    pub const Stack = struct {
        gpa: std.mem.Allocator,
        array_list: std.ArrayList(Value) = .empty,

        pub fn deinit(self: *Stack) void {
            self.array_list.deinit(self.gpa);
        }

        pub fn merge(self: *Stack, stack: *Stack) std.mem.Allocator.Error!void {
            try self.array_list.appendSlice(self.gpa, stack.array_list.items);
            stack.deinit();
        }

        pub fn push(self: *Stack, value: Value) std.mem.Allocator.Error!void {
            try self.array_list.append(self.gpa, value);
        }

        pub fn pop(self: *Stack) Value {
            return self.array_list.pop().?;
        }

        pub fn popOrNull(self: *Stack) ?Value {
            return self.array_list.pop();
        }

        pub fn getLast(self: Stack) Value {
            return self.array_list.getLast();
        }

        pub fn getLastOrNull(self: Stack) ?Value {
            return self.array_list.getLastOrNull();
        }
    };

    pub const Frame = struct {
        locals: []Value,
        stack: Stack,

        pub fn init(gpa: std.mem.Allocator, locals: []Value) Frame {
            return .{
                .locals = locals,
                .stack = .{ .gpa = gpa },
            };
        }
    };

    pub fn init(gpa: std.mem.Allocator, module: *const Module) !Interpreter {
        const globals = try gpa.alloc(Global, module.globals.len);
        for (globals, 0..) |*global, i| global.* = .init(module, i);

        return .{
            .gpa = gpa,
            .module = module,
            .memory = try gpa.alloc(u8, 1024),
            .globals = globals,
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.frames.deinit(self.gpa);
        self.gpa.free(self.memory);
        self.gpa.free(self.globals);
    }

    pub const CallError = std.Io.Reader.TakeEnumError || std.mem.Allocator.Error;

    pub fn call(self: *Interpreter, export_symbol: []const u8, params: []Value) CallError!void {
        const exp = self.module.exports.get(export_symbol).?;
        std.debug.assert(exp.kind == .function);

        var stack = try self.callIndex(exp.index, params);
        defer stack.deinit();
    }

    fn callIndex(self: *Interpreter, index: usize, params: []Value) CallError!Stack {
        const gpa = self.gpa;

        std.log.info("call index: {d}, params: {any}", .{ index - self.module.imports.len, params });
        const body = self.module.code.functions[index - self.module.imports.len];

        const locals = try gpa.alloc(Value, params.len + body.locals.len);
        defer gpa.free(locals);
        @memcpy(locals[0..params.len], params);
        for (locals[params.len..], body.locals) |*local, value_type| {
            local.* = .fromValueType(value_type);
        }

        var frame: Frame = .init(gpa, locals);
        try self.frames.append(gpa, frame);
        defer _ = self.frames.pop();

        var code: std.Io.Reader = .fixed(body.code);
        try self.execute(&frame, &code);

        return frame.stack;
    }

    pub fn execute(self: *Interpreter, frame: *Frame, code: *std.Io.Reader) CallError!void {
        while (true) {
            const opcode = try code.takeEnumNonexhaustive(Opcode, .little);
            if (opcode == .end) break;
            const operation: Operation = .create(code, opcode);
            std.log.info("op: {any}", .{operation});
            try self.operate(operation, frame);

            std.log.info("stack: {d}", .{frame.stack.array_list.items.len});
            for (frame.stack.array_list.items) |value| {
                std.log.info("\t{any}", .{value});
            }
        }
    }

    pub fn operate(self: *Interpreter, op: Operation, frame: *Frame) CallError!void {
        switch (op) {
            .@"unreachable" => unreachable,
            .nop => _ = frame.stack.pop(),

            .block => {},
            .loop => {},
            .@"if" => {},
            .@"else" => {},

            .end => {},

            .br => {},
            .br_if => {},
            .br_table => {},

            .@"return" => {},
            .call => |i| {
                var return_stack = try self.callIndex(i, frame.stack.array_list.items);
                try frame.stack.merge(&return_stack);
            },

            .call_indirect => {},

            // Parametric
            .drop => {},
            .select => {},

            // Variable access
            .local_get => |i| try frame.stack.push(frame.locals[i]),
            .local_set => |i| frame.locals[i] = frame.stack.pop(),
            .local_tee => |i| frame.locals[i] = frame.stack.getLast(),

            .global_get => |i| try frame.stack.push(self.globals[i].value),
            .global_set => |i| {
                std.debug.assert(self.globals[i].mutability == .@"var");
                self.globals[i].value = frame.stack.pop();
            },

            // Memory (all use memarg: align + offset)
            .i32_load => |mem_arg| {
                const address: u32 = @intCast(frame.stack.pop().i32);
                const ea = @as(usize, @intCast(address + mem_arg.offset));

                const bytes = self.memory[ea .. ea + 4][0..4];
                const value = std.mem.readInt(i32, bytes, .little);

                try frame.stack.push(.{ .i32 = value });
            },
            .i64_load => |mem_arg| {
                const address: u64 = @intCast(frame.stack.pop().i64);
                const ea = @as(usize, @intCast(address + mem_arg.offset));

                const bytes = self.memory[ea .. ea + 8][0..8];
                const value = std.mem.readInt(i64, bytes, .little);

                try frame.stack.push(.{ .i64 = value });
            },
            .f32_load => |mem_arg| {
                const address: u32 = @intCast(frame.stack.pop().i32);
                const ea = @as(usize, @intCast(address + mem_arg.offset));

                const value = std.mem.readInt(u32, self.memory[ea .. ea + 4][0..4], .little);

                try frame.stack.push(.{ .f32 = @bitCast(value) });
            },
            .f64_load => |mem_arg| {
                const address: u64 = @intCast(frame.stack.pop().i32);
                const ea = @as(usize, @intCast(address + mem_arg.offset));

                const value = std.mem.readInt(u64, self.memory[ea .. ea + 8][0..8], .little);

                try frame.stack.push(.{ .f64 = @bitCast(value) });
            },

            .i32_load8_s => {},
            .i32_load8_u => {},
            .i32_load16_s => {},
            .i32_load16_u => {},

            .i64_load8_s => {},
            .i64_load8_u => {},
            .i64_load16_s => {},
            .i64_load16_u => {},
            .i64_load32_s => {},

            .i32_store => {},
            .i64_store => {},
            .f32_store => {},
            .f64_store => {},

            .i32_store8 => {},
            .i32_store16 => {},
            .i64_store8 => {},
            .i64_store16 => {},
            .i64_store32 => {},

            .memory_size => {},
            .memory_grow => {},

            // Constants
            .i32_const => |v| try frame.stack.push(.{ .i32 = v }),
            .i64_const => |v| try frame.stack.push(.{ .i64 = v }),
            .f32_const => |v| try frame.stack.push(.{ .f32 = @bitCast(v) }),
            .f64_const => |v| try frame.stack.push(.{ .f64 = @bitCast(v) }),

            // i32 comparisons
            .i32_eqz => try frame.stack.push(.{ .i32 = @intFromBool(frame.stack.pop().i32 == 0) }),
            .i32_eq,
            .i32_ne,
            .i32_lt_s,
            .i32_gt_s,
            .i32_le_s,
            .i32_ge_s,
            .i32_lt_u,
            .i32_gt_u,
            .i32_le_u,
            .i32_ge_u,
            => {
                const rhs = frame.stack.pop().i32;
                const lhs = frame.stack.pop().i32;
                const result = switch (op) {
                    .i32_eq => lhs == rhs,
                    .i32_ne => lhs != rhs,
                    .i32_lt_s => lhs < rhs,
                    .i32_gt_s => lhs > rhs,
                    .i32_le_s => lhs <= rhs,
                    .i32_ge_s => lhs >= rhs,
                    .i32_lt_u => @as(u32, @bitCast(lhs)) < @as(u32, @bitCast(rhs)),
                    .i32_gt_u => @as(u32, @bitCast(lhs)) > @as(u32, @bitCast(rhs)),
                    .i32_le_u => @as(u32, @bitCast(lhs)) <= @as(u32, @bitCast(rhs)),
                    .i32_ge_u => @as(u32, @bitCast(lhs)) >= @as(u32, @bitCast(rhs)),
                    else => unreachable,
                };
                try frame.stack.push(.{ .i32 = @intFromBool(result) });
            },

            // i64 comparisons
            .i64_eqz => try frame.stack.push(.{ .i64 = @intFromBool(frame.stack.pop().i64 == 0) }),
            .i64_eq,
            .i64_ne,
            .i64_lt_s,
            .i64_lt_u,
            .i64_gt_s,
            .i64_gt_u,
            .i64_le_s,
            .i64_le_u,
            .i64_ge_s,
            .i64_ge_u,
            => {
                const rhs = frame.stack.pop().i64;
                const lhs = frame.stack.pop().i64;
                const result = switch (op) {
                    .i64_eq => lhs == rhs,
                    .i64_ne => lhs != rhs,
                    .i64_lt_s => lhs < rhs,
                    .i64_gt_s => lhs > rhs,
                    .i64_le_s => lhs <= rhs,
                    .i64_ge_s => lhs >= rhs,
                    .i64_lt_u => @as(u64, @bitCast(lhs)) < @as(u64, @bitCast(rhs)),
                    .i64_gt_u => @as(u64, @bitCast(lhs)) > @as(u64, @bitCast(rhs)),
                    .i64_le_u => @as(u64, @bitCast(lhs)) <= @as(u64, @bitCast(rhs)),
                    .i64_ge_u => @as(u64, @bitCast(lhs)) >= @as(u64, @bitCast(rhs)),
                    else => unreachable,
                };
                try frame.stack.push(.{ .i64 = @intFromBool(result) });
            },

            // i32 arithmetic
            .i32_clz => try frame.stack.push(.{ .i32 = @clz(frame.stack.pop().i32) }),
            .i32_ctz => try frame.stack.push(.{ .i32 = @ctz(frame.stack.pop().i32) }),
            .i32_popcnt => try frame.stack.push(.{ .i32 = @popCount(frame.stack.pop().i32) }),

            .i32_add,
            .i32_sub,
            .i32_mul,
            .i32_div_s,
            .i32_div_u,
            .i32_rem_s,
            .i32_rem_u,
            .i32_and,
            .i32_or,
            .i32_xor,
            .i32_shl,
            .i32_shr_s,
            .i32_shr_u,
            .i32_rotl,
            .i32_rotr,
            => {
                const rhs = frame.stack.pop().i32;
                const lhs = frame.stack.pop().i32;
                const result: i32 = switch (op) {
                    .i32_add => lhs + rhs,
                    .i32_sub => lhs - rhs,
                    .i32_mul => lhs * rhs,
                    .i32_div_s => @divTrunc(lhs, rhs),
                    .i32_div_u => @intCast(@divTrunc(@as(u32, @bitCast(lhs)), @as(u32, @bitCast(rhs)))),
                    .i32_rem_s => @rem(lhs, rhs),
                    .i32_rem_u => @intCast(@rem(@as(u32, @bitCast(lhs)), @as(u32, @bitCast(rhs)))),
                    .i32_and => lhs & rhs,
                    .i32_or => lhs | rhs,
                    .i32_xor => lhs ^ rhs,
                    .i32_shl => lhs << @intCast(rhs & 31),
                    .i32_shr_s => @as(i32, lhs) >> @intCast(rhs & 31),
                    .i32_shr_u => @intCast(@as(u32, @bitCast(lhs)) >> @as(u5, @intCast(rhs & 31))),
                    .i32_rotl => @intCast(std.math.rotl(u32, @as(u32, @bitCast(lhs)), @as(u32, @intCast(rhs & 31)))),
                    .i32_rotr => @intCast(std.math.rotr(u32, @as(u32, @bitCast(lhs)), @as(u32, @intCast(rhs & 31)))),
                    else => unreachable,
                };
                try frame.stack.push(.{ .i32 = result });
            },

            // i64 arithmetic
            .i64_clz => try frame.stack.push(.{ .i64 = @clz(frame.stack.pop().i64) }),
            .i64_ctz => try frame.stack.push(.{ .i64 = @ctz(frame.stack.pop().i64) }),
            .i64_popcnt => try frame.stack.push(.{ .i64 = @popCount(frame.stack.pop().i64) }),

            .i64_add,
            .i64_sub,
            .i64_mul,
            .i64_div_s,
            .i64_div_u,
            .i64_rem_s,
            .i64_rem_u,
            .i64_and,
            .i64_or,
            .i64_xor,
            .i64_shl,
            .i64_shr_s,
            .i64_shr_u,
            .i64_rotl,
            .i64_rotr,
            => {
                const rhs = frame.stack.pop().i64;
                const lhs = frame.stack.pop().i64;
                const result: i64 = switch (op) {
                    .i64_add => lhs + rhs,
                    .i64_sub => lhs - rhs,
                    .i64_mul => lhs * rhs,
                    .i64_div_s => @divTrunc(lhs, rhs),
                    .i64_div_u => @intCast(@divTrunc(@as(u64, @bitCast(lhs)), @as(u64, @bitCast(rhs)))),
                    .i64_rem_s => @rem(lhs, rhs),
                    .i64_rem_u => @intCast(@rem(@as(u64, @bitCast(lhs)), @as(u64, @bitCast(rhs)))),
                    .i64_and => lhs & rhs,
                    .i64_or => lhs | rhs,
                    .i64_xor => lhs ^ rhs,
                    .i64_shl => lhs << @intCast(rhs & 31),
                    .i64_shr_s => @as(i64, lhs) >> @intCast(rhs & 31),
                    .i64_shr_u => @intCast(@as(u64, @bitCast(lhs)) >> @as(u5, @intCast(rhs & 31))),
                    .i64_rotl => @intCast(std.math.rotl(u64, @as(u64, @bitCast(lhs)), @as(u64, @intCast(rhs & 31)))),
                    .i64_rotr => @intCast(std.math.rotr(u64, @as(u64, @bitCast(lhs)), @as(u64, @intCast(rhs & 31)))),
                    else => unreachable,
                };
                try frame.stack.push(.{ .i64 = result });
            },

            // f32 arithmetic
            .f32_abs,
            .f32_neg,
            .f32_ceil,
            .f32_floor,
            .f32_trunc,
            .f32_nearest,
            .f32_sqrt,
            => {
                const v = frame.stack.pop().f32;
                const result = switch (op) {
                    .f32_abs => @abs(v),
                    .f32_neg => -v,
                    .f32_ceil => @ceil(v),
                    .f32_floor => @floor(v),
                    .f32_trunc => @trunc(v),
                    .f32_nearest => @round(v),
                    .f32_sqrt => @sqrt(v),
                    else => unreachable,
                };
                try frame.stack.push(.{ .f32 = result });
            },

            .f32_add,
            .f32_sub,
            .f32_mul,
            .f32_div,
            .f32_min,
            .f32_max,
            => {
                const rhs = frame.stack.pop().f32;
                const lhs = frame.stack.pop().f32;
                const result = switch (op) {
                    .f32_add => lhs + rhs,
                    .f32_sub => lhs - rhs,
                    .f32_mul => lhs * rhs,
                    .f32_div => lhs / rhs,
                    .f32_min => @min(lhs, rhs),
                    .f32_max => @max(lhs, rhs),
                    else => unreachable,
                };
                try frame.stack.push(.{ .f32 = result });
            },

            .f32_eq,
            .f32_ne,
            .f32_lt,
            .f32_gt,
            .f32_le,
            .f32_ge,
            => {
                const rhs = frame.stack.pop().f32;
                const lhs = frame.stack.pop().f32;
                const result = switch (op) {
                    .f32_eq => lhs == rhs,
                    .f32_ne => lhs != rhs,
                    .f32_lt => lhs < rhs,
                    .f32_gt => lhs > rhs,
                    .f32_le => lhs <= rhs,
                    .f32_ge => lhs >= rhs,
                    else => unreachable,
                };
                try frame.stack.push(.{ .i32 = @intFromBool(result) });
            },

            .f32_convert_i32_s => {},
            .f32_convert_i32_u => {},
            .f32_convert_i64_s => {},
            .f32_convert_i64_u => {},

            // f64 arithmetic
            .f64_abs,
            .f64_neg,
            .f64_ceil,
            .f64_floor,
            .f64_trunc,
            .f64_nearest,
            .f64_sqrt,
            => {
                const v = frame.stack.pop().f64;
                const result = switch (op) {
                    .f64_abs => @abs(v),
                    .f64_neg => -v,
                    .f64_ceil => @ceil(v),
                    .f64_floor => @floor(v),
                    .f64_trunc => @trunc(v),
                    .f64_nearest => @round(v),
                    .f64_sqrt => @sqrt(v),
                    else => unreachable,
                };
                try frame.stack.push(.{ .f64 = result });
            },

            .f64_add,
            .f64_sub,
            .f64_mul,
            .f64_div,
            .f64_min,
            .f64_max,
            => {
                const rhs = frame.stack.pop().f64;
                const lhs = frame.stack.pop().f64;
                const result = switch (op) {
                    .f64_add => lhs + rhs,
                    .f64_sub => lhs - rhs,
                    .f64_mul => lhs * rhs,
                    .f64_div => lhs / rhs,
                    .f64_min => @min(lhs, rhs),
                    .f64_max => @max(lhs, rhs),
                    else => unreachable,
                };
                try frame.stack.push(.{ .f64 = result });
            },

            .f64_eq,
            .f64_ne,
            .f64_lt,
            .f64_gt,
            .f64_le,
            .f64_ge,
            => {
                const rhs = frame.stack.pop().f64;
                const lhs = frame.stack.pop().f64;
                const result = switch (op) {
                    .f64_eq => lhs == rhs,
                    .f64_ne => lhs != rhs,
                    .f64_lt => lhs < rhs,
                    .f64_gt => lhs > rhs,
                    .f64_le => lhs <= rhs,
                    .f64_ge => lhs >= rhs,
                    else => unreachable,
                };
                try frame.stack.push(.{ .i32 = @intFromBool(result) });
            },

            .f64_convert_i32_s => {},
            .f64_convert_i32_u => {},
            .f64_convert_i64_s => {},
            .f64_convert_i64_u => {},

            // reinterpret conversions
            .i32_reinterpret_f32 => {
                const v = frame.stack.pop().f32;
                try frame.stack.push(.{ .i32 = @bitCast(v) });
            },
            .f32_reinterpret_i32 => {
                const v = frame.stack.pop().i32;
                try frame.stack.push(.{ .f32 = @bitCast(v) });
            },
            .i64_reinterpret_f64 => {
                const v = frame.stack.pop().f64;
                try frame.stack.push(.{ .i64 = @bitCast(v) });
            },
            .f64_reinterpret_i64 => {
                const v = frame.stack.pop().i64;
                try frame.stack.push(.{ .f64 = @bitCast(v) });
            },
        }
    }
};
