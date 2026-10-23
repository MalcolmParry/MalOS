const std = @import("std");
const Spinlock = @import("sync/Spinlock.zig");
const serial = @import("drivers/x86/serial.zig");
const BootInfo = @import("BootInfo.zig");
const Terminal = @import("tty/Terminal.zig");
const vfs = @import("fs/vfs/vfs.zig");
const devfs = @import("fs/devfs.zig");
const vga_text = @import("drivers/x86/vga_text.zig");

pub var spinlock: Spinlock = .init;
pub var writer: std.Io.Writer = .{
    .buffer = &.{},
    .end = 0,
    .vtable = &.{ .drain = &drain },
};

pub var term: std.Io.Terminal = .{
    .writer = &writer,
    .mode = .escape_codes,
};

var temp_writer_buffer: [4096]u8 = undefined;
var temp_writer: std.Io.Writer = .fixed(&temp_writer_buffer);
var temp_overflow: bool = false;

var vga_text_term: Terminal = .{ .tg = &vga_text.tg };
var vga_text_writer = vga_text_term.writer(&.{});

var using_temp_writer: bool = true;
var using_serial: bool = false;
var using_vga_text: bool = false;

pub fn preinit() !void {
    if (serial.init()) {
        using_serial = true;
        serial.write(temp_writer.buffered());
    }

    if (temp_overflow) std.log.warn("temp writer buffer overflow", .{});
}

pub fn init(boot_info: BootInfo) !void {
    if (boot_info.display == .vga_text) {
        vga_text.init();
        using_vga_text = true;
        try vga_text_writer.w.writeAll(temp_writer.buffered());
    }

    using_temp_writer = false;
    if (temp_overflow) std.log.warn("temp writer buffer overflow", .{});
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

fn drain(_: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
    var wrote: usize = 0;
    for (data[0 .. data.len - 1]) |str| {
        try write(str);
        wrote += str.len;
    }

    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        try write(pattern);
        wrote += pattern.len;
    }

    return wrote;
}

fn write(data: []const u8) !void {
    var rest = data;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
        try writeRaw(rest[0..i]);
        try writeRaw("\r\n");
        rest = rest[i + 1 ..];
    }
    try writeRaw(rest);
}

fn writeRaw(data: []const u8) !void {
    if (using_temp_writer) temp_writer.writeAll(data) catch {
        temp_overflow = true;
    };

    if (using_serial) serial.write(data);
    if (using_vga_text) try vga_text_writer.w.writeAll(data);
}

var console_dentry: vfs.DirEntry = .{
    .node = &console_node,
    .parent = null,
    .name = .initEmbedded("console"),
    .ref_count = .init(0),
};

var console_node: vfs.Node = .{
    .ref_count = .init(1),
    .data = .{ .none = {} },
    .kind = .char_device,
    .sb = &devfs.superblock,
    .vtable = &.{
        .destroy = vfs.Node.default_impls.destroyPanic,
        .open = vfs.Node.Handle.default_impls.OpenDefault(&.{
            .write = &vfsWrite,
        }),
    },
};

fn vfsWrite(_: *vfs.Node.Handle, _: u64, data: []const u8) vfs.WriteError!usize {
    const l = spinlock.lock();
    defer l.unlock();

    write(data) catch return error.Io;
    return data.len;
}

pub fn registerConsoleFile() !void {
    try devfs.root.registerChild(&console_dentry);
}
