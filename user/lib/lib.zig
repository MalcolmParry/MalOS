pub const syscall = @import("syscall.zig");

comptime {
    @export(&@import("start.zig")._start, .{ .name = "_start" });
}
