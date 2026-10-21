const std = @import("std");
const abi = @import("abi");

pub fn debugPrint(msg: []const u8) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.debug_print),
        @intFromPtr(msg.ptr),
        msg.len,
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

pub fn syscall(args: [3]usize) [2]usize {
    var ret0: usize = undefined;
    var ret1: usize = undefined;

    asm volatile (
        \\ int $0x80
        : [ret0] "={rax}" (ret0),
          [ret1] "={rdi}" (ret1),
        : [arg0] "{rax}" (args[0]),
          [arg1] "{rdi}" (args[1]),
          [arg2] "{rsi}" (args[2]),
        : .{ .memory = true });

    return .{ ret0, ret1 };
}
