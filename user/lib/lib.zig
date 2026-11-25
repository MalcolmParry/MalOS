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
    var buffer: [abi.max_klog_msg]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print(format, args) catch {};
    _ = scope;

    const abi_level: abi.KLogEntry.Level = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };

    syscall.klogWrite(klog, writer.buffered(), abi_level) catch {};
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
