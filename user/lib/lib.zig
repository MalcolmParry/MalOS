const std = @import("std");
pub const abi = @import("abi");
pub const Handle = abi.syscall.Handle;

pub const syscall = @import("syscall.zig");

pub var resources: []const abi.proc_args.Resource = &.{};
pub var klog: Handle = .invalid;
pub var vmar: Handle = .invalid;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [abi.syscall.max_klog_msg]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print(format, args) catch {};
    _ = scope;

    const abi_level: abi.syscall.KLogEntry.Level = switch (level) {
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

pub fn getResource(kind: abi.syscall.ResourceKind, base: u64, len: u64) ?abi.proc_args.Resource {
    for (resources) |resource| {
        if (resource.kind != kind) continue;
        if (resource.base > base) continue;
        if (resource.base + resource.len < base + len) continue;
        return resource;
    }

    return null;
}

comptime {
    if (!@hasDecl(@import("root"), "_start"))
        @export(&@import("start.zig")._start, .{ .name = "_start" });
}
