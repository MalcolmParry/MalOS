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
    path_too_long,
    too_many_fds,
    io,
    corrupt,
    out_of_memory,
    invalid_name,
    not_a_dir,
    is_a_dir,
    name_too_long,
    no_entry,
    read_only,
    not_supported,
    bad_fd,
};

pub const Fd = enum(u32) {
    pub const max = std.math.maxInt(u32);
    _,
};
