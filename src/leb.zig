//! LEB128
const std = @import("std");

pub fn readU32(r: *std.Io.Reader) std.Io.Reader.Error!u32 {
    var result: u32 = 0;
    var shift: u8 = 0;

    while (true) {
        const byte = try r.takeByte();

        // if (shift > 28) return error.IntegerOverflow;

        const payload: u32 = byte & 0x7F;
        result |= payload << @as(u5, @intCast(shift));

        if ((byte & 0x80) == 0) break;

        shift += 7;
    }

    return result;
}

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
