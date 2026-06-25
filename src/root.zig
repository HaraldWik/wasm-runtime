const std = @import("std");
const leb = @import("leb.zig");

pub const bin = @import("bin.zig");

pub const Interpreter = struct {
    gpa: std.mem.Allocator,
    frames: std.ArrayList(Frame) = .empty,

    pub const Value = union(enum) {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
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
        i32_div_u = 0x6E,
        i32_rem_s = 0x6F,
        i32_rem_u = 0x70,

        // bitwise
        i32_and = 0x71,
        i32_or = 0x72,
        i32_xor = 0x73,

        // shifts
        i32_shl = 0x74,
        i32_shr_s = 0x75,
        i32_shr_u = 0x76,

        // rotations
        i32_rotl = 0x77,
        i32_rotr = 0x78,

        _,
    };

    pub const Operation = union(Opcode) {
        end: void,
        @"return": void,

        call: u32, // function index

        local_get: u32, // varuint32 (ULEB128)
        local_set: u32, // varuint32 (ULEB128)
        local_tee: u32, // varuint32 (ULEB128)

        i32_const: i32, // SLEB128
        i64_const: i64, // SLEB128
        f32_const: u32, // raw bits (4 bytes)
        f64_const: u64, // raw bits (8 bytes)

        i32_add: void,
        i32_sub: void,
        i32_mul: void,
        i32_div_s: void,
        i32_div_u: void,
        i32_rem_s: void,
        i32_rem_u: void,

        i32_and: void,
        i32_or: void,
        i32_xor: void,

        i32_shl: void,
        i32_shr_s: void,
        i32_shr_u: void,

        i32_rotl: void,
        i32_rotr: void,

        pub fn create(r: *std.Io.Reader, opcode: Opcode) Operation {
            return switch (opcode) {
                .call => .{ .call = leb.readU32(r) catch unreachable },
                .local_get => .{ .local_get = leb.readU32(r) catch unreachable },
                .local_set => .{ .local_set = leb.readU32(r) catch unreachable },
                .local_tee => .{ .local_tee = leb.readU32(r) catch unreachable },
                .i32_const => .{ .i32_const = leb.readI32(r) catch unreachable },
                .i64_const => .{ .i64_const = leb.readI64(r) catch unreachable },
                .f32_const => .{ .f32_const = r.takeInt(u32, .little) catch unreachable },
                .f64_const => .{ .f64_const = r.takeInt(u64, .little) catch unreachable },
                _ => unreachable,
                inline else => |comptime_opcode| @unionInit(Operation, @tagName(comptime_opcode), {}),
            };
        }

        pub fn operate(self: Operation, frame: *Frame) !void {
            switch (self) {
                .end => {},
                .@"return" => {},
                .call => {},

                .local_get => |index| try frame.stack.push(frame.locals[index]),
                .local_set => |index| frame.locals[index] = frame.stack.pop(),
                .local_tee => {},

                .i32_const => |value| try frame.stack.push(.{ .i32 = value }),
                .i64_const => |value| try frame.stack.push(.{ .i64 = value }),
                .f32_const => |value| try frame.stack.push(.{ .f32 = @bitCast(value) }),
                .f64_const => |value| try frame.stack.push(.{ .f64 = @bitCast(value) }),

                .i32_add, .i32_sub, .i32_mul, .i32_div_s => {
                    const rhs = frame.stack.pop().i32;
                    const lhs = frame.stack.pop().i32;
                    const result = switch (self) {
                        .i32_add => lhs + rhs,
                        .i32_sub => lhs - rhs,
                        .i32_mul => lhs * rhs,
                        .i32_div_s => @divTrunc(lhs, rhs),
                        else => unreachable,
                    };
                    try frame.stack.push(.{ .i32 = result });
                },

                else => {},
            }
        }
    };

    pub const Stack = struct {
        gpa: std.mem.Allocator,
        array_list: std.ArrayList(Value) = .empty,

        pub fn push(self: *Stack, value: Value) std.mem.Allocator.Error!void {
            try self.array_list.append(self.gpa, value);
        }

        pub fn pop(self: *Stack) Value {
            return self.array_list.pop().?;
        }

        pub fn popOrNull(self: *Stack) ?Value {
            return self.array_list.pop();
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

    pub fn init(gpa: std.mem.Allocator) Interpreter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Interpreter) void {
        self.frames.deinit(self.gpa);
    }

    pub fn call(self: *Interpreter, body: bin.FunctionBody, params: []Value) !void {
        var frame: Frame = .init(self.gpa, params);
        try self.frames.append(self.gpa, frame);
        defer {
            frame.stack.array_list.deinit(frame.stack.gpa);
            _ = self.frames.pop();
        }

        var code: std.Io.Reader = .fixed(body.code);
        try self.execute(&frame, &code);
    }

    pub fn execute(self: *Interpreter, frame: *Frame, code: *std.Io.Reader) !void {
        _ = self;
        while (true) {
            const opcode = try code.takeEnumNonexhaustive(Opcode, .little);
            if (opcode == .end) break;
            const operation: Operation = .create(code, opcode);
            std.log.info("op: {any}", .{operation});
            try operation.operate(frame);

            std.log.info("stack: {d}", .{frame.stack.array_list.items.len});
            for (frame.stack.array_list.items) |value| {
                std.log.info("\t{any}", .{value});
            }
        }
    }
};
