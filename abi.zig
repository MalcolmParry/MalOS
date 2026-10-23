const std = @import("std");

pub const Syscall = enum(usize) {
    fopen,
    fclose,
    fread,
    fwrite,
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
