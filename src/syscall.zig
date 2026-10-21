const std = @import("std");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");

pub const Code = enum {
    debug_print,
};

pub const Status = enum {
    success,
    err_bad_arg,
    err_unknown,
    err_too_big,
    err_fault,
};

pub fn handler(args: [3]usize) [2]usize {
    const code = std.enums.fromInt(Code, args[0]) orelse return .{ @intFromEnum(Status.err_bad_arg), 0 };

    switch (code) {
        .debug_print => {
            const len = args[2];
            const src = @as([*]allowzero const u8, @ptrFromInt(args[1]))[0..len];
            var buffer: [256]u8 = undefined;

            if (len > buffer.len) {
                return .{ @intFromEnum(Status.err_too_big), 0 };
            }

            const dst = buffer[0..len];

            if (!arch.copyFromUser(dst, src)) {
                return .{ @intFromEnum(Status.err_fault), 0 };
            }

            const l = log.spinlock.lock();
            defer l.unlock();

            log.writer.writeAll(dst) catch {
                return .{ @intFromEnum(Status.err_unknown), 0 };
            };

            log.writer.flush() catch {};

            return .{ @intFromEnum(Status.success), 0 };
        },
    }
}
