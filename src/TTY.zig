const std = @import("std");
const arch = @import("Arch.zig");

pub const size = arch.vga.size;
pub const cursor = struct {
    var x: u8 = 0;
    var y: u8 = 0;
};

fn drain(this: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
    printStr(this.buffer[0..this.end]);
    this.end = 0;
    var written: usize = 0;

    for (data[0 .. data.len - 1]) |x| {
        printStr(x);
        written += x.len;
    }

    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        printStr(pattern);
        written += pattern.len;
    }

    return written;
}

const vtable: std.io.Writer.VTable = .{
    .drain = &drain,
};

var buffer: [64]u8 = undefined;
pub var writer = std.Io.Writer{ .vtable = &vtable, .buffer = &buffer };
fn print(comptime format: []const u8, args: anytype) void {
    writer.print(format, args) catch |x| {
        printStr("Printing Error: ");
        printStr(@errorName(x));
        printChar('\n');
        @panic("printing error");
    };

    writer.flush() catch @panic("error while flushing tty");
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    arch.vga.setColorFromLogLevel(message_level);
    if (scope == std.log.default_log_scope) {
        print(format, args);
        return;
    }

    print("{s}: ", .{@tagName(scope)});
    print(format, args);
}

var update_cursor: bool = true;

pub fn printChar(c: u8) void {
    switch (c) {
        '\n' => {
            cursor.x = 0;
            cursor.y += 1;

            if (cursor.y >= size.y) {
                scroll();
            }
        },
        '\r' => {
            cursor.x = 0;
        },
        '\t' => {
            for (0..4) |_| {
                arch.vga.putChar(cursor.x, cursor.y, ' ');
                cursor.x += 1;
            }
        },
        else => {
            arch.vga.putChar(cursor.x, cursor.y, c);
            cursor.x += 1;
        },
    }

    if (cursor.x >= size.x) {
        cursor.y += 1;
        cursor.x = 0;
    }

    if (cursor.y >= size.y) {
        update_cursor = false;
        scroll();
        update_cursor = true;
    }

    if (update_cursor) arch.vga.setCursorPos(cursor.x, cursor.y);
}

pub fn printStr(str: []const u8) void {
    update_cursor = false;

    for (str) |c| {
        printChar(c);
    }

    update_cursor = true;
    arch.vga.setCursorPos(cursor.x, cursor.y);
}

pub fn clearLine(y: u8) void {
    for (0..size.x) |x| {
        arch.vga.putChar(@intCast(x), y, ' ');
    }
}

pub fn clear() void {
    for (0..size.y) |y| {
        clearLine(@intCast(y));
    }
}

pub fn scroll() void {
    for (0..size.y - 1) |i| {
        @memcpy(&arch.vga.video_memory.*[i], &arch.vga.video_memory.*[i + 1]);
    }

    clearLine(size.y - 1);

    if (cursor.y != 0) {
        cursor.y -= 1;
        if (update_cursor) arch.vga.setCursorPos(cursor.x, cursor.y);
    }
}
