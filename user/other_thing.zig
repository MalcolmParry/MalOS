const std = @import("std");
const lib = @import("lib");

pub const panic = std.debug.FullPanic(lib.panic);
pub const std_options: std.Options = .{
    .logFn = lib.log,
};

comptime {
    _ = lib;
}

pub fn main(_: lib.Handle) void {
    std.log.info("hello world from other process", .{});
}
