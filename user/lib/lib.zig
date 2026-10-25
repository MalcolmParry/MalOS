const abi = @import("abi");

pub const stdin: abi.Handle = @enumFromInt(0);
pub const stdout: abi.Handle = @enumFromInt(1);
pub const stderr: abi.Handle = @enumFromInt(2);

pub const syscall = @import("syscall.zig");

pub fn writeAll(handle: abi.Handle, offset: u64, data: []const u8) error{Failed}!void {
    var cur = offset;
    var rest = data;

    while (rest.len != 0) {
        const wrote = syscall.fwrite(handle, cur, rest) catch return error.Failed;
        if (wrote == 0) return error.Failed;
        cur += wrote;
        rest = rest[wrote..];
    }
}

comptime {
    @export(&@import("start.zig")._start, .{ .name = "_start" });
}
