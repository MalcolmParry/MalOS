const std = @import("std");

pub const Syscall = enum(usize) {
    fopen,
    fclose,
    fread,
    fwrite,
    fclone,
    exit,
};

pub const Status = enum(usize) {
    success,

    bad_syscall,
    bad_arg,
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
    bad_access,
};

pub const Fd = enum(u32) {
    _,

    pub const max = std.math.maxInt(u32);
    pub fn fromUsize(int: usize) !Fd {
        if (int > max) return error.BadFd;
        return @enumFromInt(int);
    }
};

pub const Access = packed struct {
    r: bool = false,
    w: bool = false,
    x: bool = false,

    pub const ro: Access = .{ .r = true };
    pub const wo: Access = .{ .w = true };
    pub const rw: Access = .{ .r = true, .w = true };
    pub const rwx: Access = .{ .r = true, .w = true, .x = true };
};

pub const FOpenFlags = packed struct {
    close_on_exec: bool = true,
    access: Access = .ro,

    const Backing = @Int(.unsigned, @bitSizeOf(FOpenFlags));
    pub fn toUsize(flags: FOpenFlags) usize {
        return @as(Backing, @bitCast(flags));
    }

    pub fn fromUsize(int: usize) !FOpenFlags {
        if (int > std.math.maxInt(Backing)) return error.BadArg;
        return @bitCast(@as(Backing, @intCast(int)));
    }
};

pub const FCloneFlags = packed struct {
    close_on_exec: bool = true,

    const Backing = @Int(.unsigned, @bitSizeOf(FCloneFlags));
    pub fn toUsize(flags: FCloneFlags) usize {
        return @as(Backing, @bitCast(flags));
    }

    pub fn fromUsize(int: usize) !FCloneFlags {
        if (int > std.math.maxInt(Backing)) return error.BadArg;
        return @bitCast(@as(Backing, @intCast(int)));
    }
};
