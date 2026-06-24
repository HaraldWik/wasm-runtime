const std = @import("std");

pub const bin = @import("bin.zig");

pub const Interpreter = struct {
    pub const Value = union(enum) {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
    };

    pub const Frame = struct {
        locals: []Value,
        stack: std.ArrayList(Value),
        pc: usize,
    };

    pub const Opcode = enum(u8) {
        // control
        end = 0x0B,
        @"return" = 0x0F,
        call = 0x10,

        // locals
        local_get = 0x20,
        local_set = 0x21,
        local_tee = 0x22,

        // constants
        i32_const = 0x41,
        i64_const = 0x42,
        f32_const = 0x43,
        f64_const = 0x44,

        // i32 arithmetic
        i32_add = 0x6A,
        i32_sub = 0x6B,
        i32_mul = 0x6C,
        i32_div_s = 0x6D,

        _,
    };

    pub fn call(self: *Interpreter, body: bin.FunctionBody) !void {
        _ = self;

        for (body.code) |byte| {
            const opcode: Opcode = @enumFromInt(byte);

            switch (opcode) {
                _ => std.debug.print("{x} \n", .{byte}),
                else => std.debug.print("{t}\n", .{opcode}),
            }
        }
    }
};
