//! LEB128
const std = @import("std");

/// Deprecated; use `readLeb128`.
pub fn readU32(r: *std.Io.Reader) std.Io.Reader.Error!u32 {
    var result: u32 = 0;
    var shift: u8 = 0;

    while (true) {
        const byte = try r.takeByte();

        const payload: u32 = byte & 0x7F;
        result |= payload << @as(u5, @intCast(shift));

        if ((byte & 0x80) == 0) break;

        shift += 7;
    }

    return result;
}

/// Deprecated; use `readLeb128`.
pub fn readI32(r: *std.Io.Reader) std.Io.Reader.Error!i32 {
    var result: i32 = 0;
    var shift: u5 = 0;
    var byte: u8 = undefined;

    while (true) {
        byte = try r.takeByte();

        result |= @as(i32, byte & 0x7f) << shift;
        shift += 7;

        if ((byte & 0x80) == 0) break;
    }

    if (shift < 32 and (byte & 0x40) != 0) {
        result |= @as(i32, -1) << shift;
    }

    return result;
}

/// Deprecated; use `readLeb128`.
pub fn readI64(r: *std.Io.Reader) std.Io.Reader.Error!i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    var byte: u8 = undefined;

    while (true) {
        byte = try r.takeByte();

        result |= @as(i64, byte & 0x7f) << shift;
        shift += 7;

        if ((byte & 0x80) == 0) break;
    }

    if (shift < 64 and (byte & 0x40) != 0) {
        result |= @as(i64, -1) << shift;
    }

    return result;
}

pub fn readInt(comptime T: type, r: *std.Io.Reader) std.Io.Reader.Error!T {
    const info = @typeInfo(T).int;
    const bits = info.bits;
    const signed = info.signedness == .signed;

    var result: T = 0;
    var shift: std.math.Log2IntCeil(T) = 0;
    const ShiftInt = std.math.Log2Int(T);
    var byte: u8 = undefined;

    while (true) {
        byte = try r.takeByte();

        result |= @as(T, @intCast(byte & 0x7f)) << @as(ShiftInt, @intCast(shift));
        shift += 7;

        if ((byte & 0x80) == 0)
            break;
    }

    if (signed and shift < bits and (byte & 0x40) != 0) {
        result |= @as(T, -1) << @as(ShiftInt, @intCast(shift));
    }

    return result;
}

/// reads any value using leb128 for ints
pub fn readValue(comptime T: type, r: *std.Io.Reader) std.Io.Reader.Error!T {
    var t: T = undefined;
    switch (@typeInfo(T)) {
        .void => t = {},
        .int => t = try readInt(T, r),
        .@"struct" => |s| inline for (s.fields) |field| {
            const field_val = try readValue(field.type, r);
            @field(t, field.name) = field_val;
        },
        else => @compileError("invalid type found " ++ @typeName(T)),
    }
    return t;
}
