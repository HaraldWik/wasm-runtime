export fn add(a: i32, b: i32) i32 {
    return a +% b;
}

export fn sub(a: i32, b: i32) i32 {
    return a -% b;
}

export fn call(a: i32, b: i32, c: i32) i32 {
    return add(c, sub(a, b));
}
