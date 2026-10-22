const std = @import("std");
const abi = @import("abi");

pub fn debugPrint(msg: []const u8) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.debug_print),
        @intFromPtr(msg.ptr),
        msg.len,
        0,
    });

    return switch (std.enums.fromInt(abi.Status, result[0]) orelse .unknown) {
        .success => {},
        .invalid_syscall => error.InvalidSyscall,
        .invalid_arg => error.InvalidArg,
        .fault => error.Fault,
        .too_long => error.TooLong,
        .unknown => error.Unknown,
    };
}

pub fn fopen(path: []const u8) !abi.Fd {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fopen),
        @intFromPtr(path.ptr),
        path.len,
        0,
    });

    return switch (std.enums.fromInt(abi.Status, result[0]) orelse .unknown) {
        .success => @enumFromInt(result[1]),
        .invalid_syscall => error.InvalidSyscall,
        .invalid_arg => error.InvalidArg,
        .fault => error.Fault,
        .too_long => error.TooLong,
        .unknown => error.Unknown,
    };
}

pub fn fread(fd: abi.Fd, buffer: []u8) !usize {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.fread),
        @intFromEnum(fd),
        @intFromPtr(buffer.ptr),
        buffer.len,
    });

    return switch (std.enums.fromInt(abi.Status, result[0]) orelse .unknown) {
        .success => result[1],
        .invalid_syscall => error.InvalidSyscall,
        .invalid_arg => error.InvalidArg,
        .fault => error.Fault,
        .too_long => error.TooLong,
        .unknown => error.Unknown,
    };
}

pub fn syscall(args: [4]usize) [2]usize {
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
        : .{ .memory = true });

    return .{ ret0, ret1 };
}
