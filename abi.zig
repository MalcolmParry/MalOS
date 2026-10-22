const std = @import("std");

pub const Syscall = enum(usize) {
    debug_print,
    fopen,
    fclose,
    fread,
};

pub const Status = enum(usize) {
    success,
    invalid_syscall,
    invalid_arg,
    fault,
    too_long,
    unknown,
};

pub const Fd = enum(u32) {
    pub const max = std.math.maxInt(u32);
    _,
};
