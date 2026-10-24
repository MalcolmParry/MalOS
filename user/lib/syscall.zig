const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");

pub fn fopen(path: []const u8, flags: abi.FOpenFlags) !abi.Fd {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fopen),
        @intFromPtr(path.ptr),
        path.len,
        flags.toUsize(),
    });

    return switch (try readStatus(result[0])) {
        .success => @enumFromInt(result[1]),
        .io => error.Io,
        .corrupt => error.Corrupt,
        .out_of_memory => error.OutOfMemory,
        .not_a_dir => error.NotADir,
        .path_too_long => error.PathTooLong,
        .name_too_long => error.NameTooLong,
        .invalid_name => error.InvalidName,
        .no_entry => error.NoEntry,
        .fault => error.Fault,
        .too_many_fds => error.TooManyFds,
        else => unexpected(result[0]),
    };
}

pub fn fclose(fd: abi.Fd) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fclose),
        @intFromEnum(fd),
    });

    return switch (try readStatus(result[0])) {
        .success => {},
        .bad_fd => error.BadFd,
        else => unexpected(result[0]),
    };
}

pub fn fread(fd: abi.Fd, offset: u64, buffer: []u8) !usize {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fread),
        @intFromEnum(fd),
        offset,
        @intFromPtr(buffer.ptr),
        buffer.len,
    });

    return switch (try readStatus(result[0])) {
        .success => result[1],
        .fault => error.Fault,
        .bad_fd => error.BadFd,
        .io => error.Io,
        .corrupt => error.Corrupt,
        .out_of_memory => error.OutOfMemory,
        .is_a_dir => error.IsADir,
        .not_supported => error.NotSupported,
        .bad_access => error.BadAccess,
        else => unexpected(result[0]),
    };
}

pub fn fwrite(fd: abi.Fd, offset: u64, buffer: []const u8) !usize {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fwrite),
        @intFromEnum(fd),
        offset,
        @intFromPtr(buffer.ptr),
        buffer.len,
    });

    return switch (try readStatus(result[0])) {
        .success => result[1],
        .fault => error.Fault,
        .bad_fd => error.BadFd,
        .io => error.Io,
        .corrupt => error.Corrupt,
        .out_of_memory => error.OutOfMemory,
        .is_a_dir => error.IsADir,
        .read_only => error.ReadOnly,
        .not_supported => error.NotSupported,
        .bad_access => error.BadAccess,
        else => unexpected(result[0]),
    };
}

pub fn fclone(old: abi.Fd, new: abi.Fd, flags: abi.FCloneFlags) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fclone),
        @intFromEnum(old),
        @intFromEnum(new),
        flags.toUsize(),
    });

    return switch (try readStatus(result[0])) {
        .success => {},
        .bad_fd => error.BadFd,
        .out_of_memory => error.OutOfMemory,
        else => unexpected(result[0]),
    };
}

pub fn exit(status: usize) noreturn {
    _ = syscall(.{
        @intFromEnum(abi.Syscall.exit),
        status,
    });

    @panic("exit syscall returned");
}

fn readStatus(int: usize) error{Unexpected}!abi.Status {
    return std.enums.fromInt(abi.Status, int) orelse unexpected(int);
}

fn unexpected(status: usize) error{Unexpected} {
    if (builtin.mode == .Debug) {
        // TODO: print warning
    }

    _ = status;
    return error.Unexpected;
}

pub fn syscall(args: anytype) [2]usize {
    const args7 = args ++ @as([7 - args.len]usize, @splat(0));
    return syscall7(args7);
}

pub fn syscall7(args: [7]usize) [2]usize {
    var ret0: usize = undefined;
    var ret1: usize = undefined;

    asm volatile (
        \\ int $0x80
        : [ret0] "={rax}" (ret0),
          [ret1] "={rdi}" (ret1),
        : [arg0] "{rax}" (args[0]),
          [arg1] "{rdi}" (args[1]),
          [arg2] "{rsi}" (args[2]),
          [arg3] "{rdx}" (args[3]),
          [arg4] "{r10}" (args[4]),
          [arg5] "{r8}" (args[5]),
          [arg6] "{r9}" (args[6]),
        : .{ .memory = true });

    return .{ ret0, ret1 };
}
