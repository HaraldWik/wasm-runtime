// extern fn raw_log(ptr: [*]const u8, len: usize) void;

// export fn msg() void {
//     const a: []const u8 = "Hello, world!\n";
//     const b: []const u8 = "Bye, world!\n";

//     raw_log(a.ptr, a.len);
//     raw_log(b.ptr, b.len);
// }

// export fn loop() void {
//     const str: []const u8 = "Loop, world!\n";
//     for (0..10) |_| {
//         raw_log(str.ptr, str.len);
//     }
// }

extern fn log_number(num: f64) void;

export fn math_i32(a: i32, b: i32, c: i32) i32 {
    return (a + b) * c;
}
export fn math_i64(a: i64, b: i64, c: i64) i64 {
    return (a + b) * c;
}
export fn math_f32(a: f32, b: f32, c: f32) f32 {
    return (a + b) * c;
}
export fn math_f64(a: f64, b: f64, c: f64) f64 {
    return (a + b) * c;
}

export fn calling(param: i32) void {
    const a = @call(.never_inline, math_i32, .{ param, 2, 3 });
    const b = @call(.never_inline, math_i64, .{ a, 2, 3 });
    const c = @call(.never_inline, math_f32, .{ @as(f32, @floatFromInt(b)), 0, 2 });
    const d = @call(.never_inline, math_f64, .{ @as(f64, @floatCast(c)), 1, 1 });

    log_number(d);
}
