const std = @import("std");
const Spinlock = @import("Spinlock.zig");
const serial = @import("drivers/x86/serial.zig");

pub var spinlock: Spinlock = .init;
pub const writer = &serial.writer;
pub const term: std.Io.Terminal = .{
    .writer = writer,
    .mode = .escape_codes,
};

pub fn init() void {
    serial.init();
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const lock = spinlock.lock();
    defer lock.unlock();

    std.log.defaultLogFileTerminal(level, scope, format, args, term) catch @panic("failed to print");
}
