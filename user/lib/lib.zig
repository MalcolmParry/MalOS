const std = @import("std");
const abi = @import("abi");

pub const syscall = @import("syscall.zig");

pub var klog: abi.Handle = undefined;
pub var vmar: abi.Handle = undefined;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const term: std.Io.Terminal = .{ .writer = &writer, .mode = .escape_codes };

    std.log.defaultLogFileTerminal(level, scope, format, args, term) catch {};
    syscall.klogWrite(klog, writer.buffered()) catch {};
}

pub fn panic(str: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = ret_addr;

    std.log.err("panic: {s}", .{str});
    syscall.threadExit();
}

comptime {
    if (!@hasDecl(@import("root"), "_start"))
        @export(&@import("start.zig")._start, .{ .name = "_start" });
}
