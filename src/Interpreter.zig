const Interpreter = @This();

const std = @import("std");

const Module = @import("Module.zig");
const Opcode = @import("code.zig").Opcode;
const Operation = @import("code.zig").Operation;

gpa: std.mem.Allocator,
module: *const Module,
host_import: []HostImport,

memory: []u8 = &.{},
globals: []Global = &.{},
frames: std.ArrayList(Frame) = .empty,

pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,

    fn fromValueType(value_type: Module.ValueType) Value {
        return switch (value_type) {
            .v128, .funcref, .externref => unreachable,
            inline else => |vt| @unionInit(Value, @tagName(vt), 0),
        };
    }

    // pub fn ptr(self: Value) usize {
    //     return switch (self) {
    //         .i32 => @intCast(self.i32),
    //         .i64 => @intCast(self.i64),
    //         else => return,
    //     };
    // }
};

pub const HostImport = struct {
    module_name: []const u8 = "env",
    field_name: []const u8,
    value: union(Module.ExternalKind) {
        function: *const fn (params: []Value) ?Value,
        table, // TODO
        memory, // TODO
        global, // TODO
    },
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

    pub fn popN(self: *Stack, num: usize) []Value {
        const len = self.array_list.items.len;
        if (num > len) return &.{};

        const start = len - num;
        const slice = self.array_list.items[start..len];

        self.array_list.items.len = start;

        return slice;
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
    code: []Operation,
    stack: Stack,

    pub fn init(gpa: std.mem.Allocator, locals: []Value, code: []Operation) Frame {
        return .{
            .locals = locals,
            .code = code,
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
        .host_import = try gpa.alloc(HostImport, module.imports.len),
        .memory = try gpa.alloc(u8, 1024),
        .globals = globals,
    };
}

pub fn deinit(self: *Interpreter) void {
    const gpa = self.gpa;
    gpa.free(self.host_import);
    gpa.free(self.memory);
    gpa.free(self.globals);
    self.frames.deinit(gpa);
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

    const import_count = self.module.imports.len;

    if (index < import_count) return self.callImport(index, params);

    // const exports = self.module.exports.values();
    // std.log.warn("call {s}", .{if (index < exports.len) exports[index].name else "unknown"});

    const body = self.module.code.functions[index - import_count];

    const locals = try gpa.alloc(Value, params.len + body.locals.len);
    defer gpa.free(locals);

    @memcpy(locals[0..params.len], params);

    for (locals[params.len..], body.locals) |*local, value_type| {
        local.* = .fromValueType(value_type);
    }

    var frame: Frame = .init(gpa, locals, body.code);
    try self.frames.append(gpa, frame);
    defer _ = self.frames.pop();

    try self.execute(&frame);

    return frame.stack;
}

pub fn registerHostImport(self: *Interpreter, host_import: HostImport) error{HostImportNotRequired}!void {
    const index = for (self.module.imports, 0..) |import, i| {
        if (std.mem.eql(u8, import.module_name, host_import.module_name) and std.mem.eql(u8, import.field_name, host_import.field_name)) break i;
    } else return error.HostImportNotRequired;
    self.host_import[index] = host_import;
}

pub fn callImport(self: *Interpreter, index: usize, params: []Value) CallError!Stack {
    const import, const import_index = self.module.getImport(.function, index) orelse std.debug.panic("function not found at index: {d}", .{index});
    // std.log.warn("call import {s}.{s} ({t})", .{ import.module_name, import.field_name, import.kind });
    const host_import = self.host_import[import_index];
    std.debug.assert(std.mem.eql(u8, host_import.module_name, import.module_name));
    std.debug.assert(std.mem.eql(u8, host_import.field_name, import.field_name));

    if (host_import.value.function(params)) |value| {
        var stack: Stack = .{ .gpa = self.gpa };
        try stack.push(value);
        return stack;
    }
    return .{ .gpa = self.gpa };
}

pub fn execute(self: *Interpreter, frame: *Frame) CallError!void {
    for (frame.code) |operation| {
        try self.operate(operation, frame);

        // var buf: [128]u8 = undefined;
        // var stdout: std.Io.File.Writer = .init(.stdout(), std.Options.debug_io, &buf);
        // const log: *std.Io.Writer = &stdout.interface;
        // _ = log.splatByte('\t', self.frames.items.len - 1) catch {};
        // log.writeAll(@tagName(operation)) catch {};
        // switch (operation) {
        //     inline else => |op| if (@TypeOf(op) != void) {
        //         log.writeAll("\x1b[94m") catch {};
        //         log.print(" {any}", .{op}) catch {};
        //         log.writeAll("\x1b[0m") catch {};
        //     },
        // }
        // log.writeByte('\n') catch {};
        // log.writeAll("\x1b[2m") catch {};
        // for (frame.stack.array_list.items) |value| {
        //     _ = log.splatByte('\t', self.frames.items.len) catch {};
        //     log.writeAll(@tagName(value)) catch {};
        //     switch (value) {
        //         inline else => |val| log.print(": {d}\n", .{val}) catch {},
        //     }
        // }
        // log.writeAll("\x1b[0m") catch {};
        // log.flush() catch {};
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
            const function_type = self.module.types[i];

            const params = frame.stack.popN(function_type.params.len);
            var return_stack = try self.callIndex(i, params);
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

        // convertions
        .i32_wrap_i64 => try frame.stack.push(.{ .i32 = @truncate(frame.stack.pop().i64) }),
        .i32_trunc_f32_s => try frame.stack.push(.{ .i32 = @intFromFloat(frame.stack.pop().f32) }),
        .i32_trunc_f32_u => try frame.stack.push(.{ .i32 = @bitCast(@as(u32, @intFromFloat(frame.stack.pop().f32))) }),
        .i32_trunc_f64_s => try frame.stack.push(.{ .i32 = @intFromFloat(frame.stack.pop().f64) }),
        .i32_trunc_f64_u => try frame.stack.push(.{ .i32 = @bitCast(@as(u32, @intFromFloat(frame.stack.pop().f64))) }),

        .i64_extend_i32_s => try frame.stack.push(.{ .i64 = frame.stack.pop().i32 }),
        .i64_extend_i32_u => try frame.stack.push(.{ .i64 = @intCast(@as(u32, @bitCast(frame.stack.pop().i32))) }),

        .i64_trunc_f32_s => try frame.stack.push(.{ .i64 = @intFromFloat(frame.stack.pop().f32) }),
        .i64_trunc_f32_u => try frame.stack.push(.{ .i64 = @bitCast(@as(u64, @intFromFloat(frame.stack.pop().f32))) }),
        .i64_trunc_f64_s => try frame.stack.push(.{ .i64 = @intFromFloat(frame.stack.pop().f64) }),
        .i64_trunc_f64_u => try frame.stack.push(.{ .i64 = @bitCast(@as(u64, @intFromFloat(frame.stack.pop().f64))) }),

        .f32_convert_i32_s => try frame.stack.push(.{ .f32 = @floatFromInt(frame.stack.pop().i32) }),
        .f32_convert_i32_u => try frame.stack.push(.{ .f32 = @floatFromInt(@as(u32, @bitCast(frame.stack.pop().i32))) }),
        .f32_convert_i64_s => try frame.stack.push(.{ .f32 = @floatFromInt(frame.stack.pop().i64) }),
        .f32_convert_i64_u => try frame.stack.push(.{ .f32 = @floatFromInt(@as(u64, @bitCast(frame.stack.pop().i64))) }),

        .f32_demote_f64 => try frame.stack.push(.{ .f32 = @floatCast(frame.stack.pop().f64) }),

        .f64_convert_i32_s => try frame.stack.push(.{ .f64 = @floatFromInt(frame.stack.pop().i32) }),
        .f64_convert_i32_u => try frame.stack.push(.{ .f64 = @floatFromInt(@as(u32, @bitCast(frame.stack.pop().i32))) }),
        .f64_convert_i64_s => try frame.stack.push(.{ .f64 = @floatFromInt(frame.stack.pop().i64) }),
        .f64_convert_i64_u => try frame.stack.push(.{ .f64 = @floatFromInt(@as(u64, @bitCast(frame.stack.pop().i64))) }),

        .f64_promote_f32 => try frame.stack.push(.{ .f64 = @floatCast(frame.stack.pop().f32) }),

        // reinterpret conversions
        .i32_reinterpret_f32 => try frame.stack.push(.{ .i32 = @bitCast(frame.stack.pop().f32) }),
        .f32_reinterpret_i32 => try frame.stack.push(.{ .f32 = @bitCast(frame.stack.pop().i32) }),
        .i64_reinterpret_f64 => try frame.stack.push(.{ .i64 = @bitCast(frame.stack.pop().f64) }),
        .f64_reinterpret_i64 => try frame.stack.push(.{ .f64 = @bitCast(frame.stack.pop().i64) }),

        else => {},
    }
}
