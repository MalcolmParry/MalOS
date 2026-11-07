const std = @import("std");
const lib = @import("lib");

pub const panic = std.debug.FullPanic(lib.panic);
pub const std_options: std.Options = .{
    .logFn = lib.log,
};

pub export fn _start(klog_i: usize) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    lib.klog = @enumFromInt(klog_i);
    std.log.info("hello world from other process", .{});
    lib.syscall.threadExit();
}
