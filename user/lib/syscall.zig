const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");

pub fn handleClose(handle: abi.Handle) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.handle_close),
        @intFromEnum(handle),
    });

    return switch (try readStatus(result[0])) {
        .success => {},
        .bad_handle => error.BadHandle,
        else => unexpected(result[0]),
    };
}

pub fn handleClone(old: abi.Handle, new: abi.Handle) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.handle_clone),
        @intFromEnum(old),
        @intFromEnum(new),
    });

    return switch (try readStatus(result[0])) {
        .success => {},
        .bad_handle => error.BadHandle,
        .out_of_memory => error.OutOfMemory,
        else => unexpected(result[0]),
    };
}

pub fn fopen(path: []const u8, flags: abi.FOpenFlags) !abi.Handle {
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
        .too_many_handles => error.TooManyHandles,
        else => unexpected(result[0]),
    };
}

pub fn fread(handle: abi.Handle, offset: u64, buffer: []u8) !usize {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fread),
        @intFromEnum(handle),
        offset,
        @intFromPtr(buffer.ptr),
        buffer.len,
    });

    return switch (try readStatus(result[0])) {
        .success => result[1],
        .fault => error.Fault,
        .bad_handle => error.BadHandle,
        .bad_handle_kind => error.BadHandleKind,
        .io => error.Io,
        .corrupt => error.Corrupt,
        .out_of_memory => error.OutOfMemory,
        .is_a_dir => error.IsADir,
        .not_supported => error.NotSupported,
        .bad_access => error.BadAccess,
        else => unexpected(result[0]),
    };
}

pub fn fwrite(handle: abi.Handle, offset: u64, buffer: []const u8) !usize {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fwrite),
        @intFromEnum(handle),
        offset,
        @intFromPtr(buffer.ptr),
        buffer.len,
    });

    return switch (try readStatus(result[0])) {
        .success => result[1],
        .fault => error.Fault,
        .bad_handle => error.BadHandle,
        .bad_handle_kind => error.BadHandleKind,
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

pub fn syscall(args: anytype) [4]usize {
    const args7 = args ++ @as([7 - args.len]usize, @splat(0));
    return syscall7(args7);
}

pub fn syscall7(args: [7]usize) [4]usize {
    var ret0: usize = undefined;
    var ret1: usize = undefined;
    var ret2: usize = undefined;
    var ret3: usize = undefined;

    asm volatile (
        \\ int $0x80
        : [ret0] "={rax}" (ret0),
          [ret1] "={rdi}" (ret1),
          [ret2] "={rsi}" (ret2),
          [ret3] "={rdx}" (ret3),
        : [arg0] "{rax}" (args[0]),
          [arg1] "{rdi}" (args[1]),
          [arg2] "{rsi}" (args[2]),
          [arg3] "{rdx}" (args[3]),
          [arg4] "{r10}" (args[4]),
          [arg5] "{r8}" (args[5]),
          [arg6] "{r9}" (args[6]),
        : .{ .memory = true });

    return .{ ret0, ret1, ret2, ret3 };
}
