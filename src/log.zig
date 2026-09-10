const std = @import("std");
const Spinlock = @import("sync/Spinlock.zig");
const serial = @import("drivers/x86/serial.zig");
const vga_text = @import("drivers/x86/vga_text.zig");
const BootInfo = @import("BootInfo.zig");

pub var spinlock: Spinlock = .init;
pub var writer = &temp_writer;
pub var term: std.Io.Terminal = .{
    .writer = &temp_writer,
    .mode = .escape_codes,
};

var temp_writer_buffer: [4096]u8 = undefined;
var temp_writer: std.Io.Writer = .fixed(&temp_writer_buffer);

var vga_text_state: vga_text.Writer = undefined;

pub fn init(boot_info: BootInfo) void {
    outer: {
        if (boot_info.vga_text_info) |info| vga: {
            vga_text_state = vga_text.init(info) catch break :vga;
            writer = &vga_text_state.interface;
            term.writer = &vga_text_state.interface;
            break :outer;
        }

        serial.init();
        writer = &serial.writer;
        term.writer = &serial.writer;
    }

    writer.print("{s}", .{temp_writer.buffered()}) catch @panic("failed to print");
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
