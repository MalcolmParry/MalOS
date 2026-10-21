const std = @import("std");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");
const abi = @import("abi");

pub fn handler(args: [3]usize) [2]usize {
    const code = std.enums.fromInt(abi.Syscall, args[0]) orelse return .{ @intFromEnum(abi.Status.invalid_syscall), 0 };

    switch (code) {
        .debug_print => {
            const status = debugPrint(args);
            return .{ @intFromEnum(status), 0 };
        },
    }
}

fn debugPrint(args: [3]usize) abi.Status {
    const len = args[2];
    const src = @as([*]allowzero const u8, @ptrFromInt(args[1]))[0..len];
    var buffer: [256]u8 = undefined;

    if (len > buffer.len) return .too_long;

    const dst = buffer[0..len];
    if (!arch.copyFromUser(dst, src)) return .fault;

    const l = log.spinlock.lock();
    defer l.unlock();

    log.writer.writeAll(dst) catch return .unknown;
    log.writer.flush() catch {};

    return .success;
}
