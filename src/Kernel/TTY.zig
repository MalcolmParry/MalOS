const std = @import("std");
const Arch = @import("Arch.zig");

fn WriteCallback(context: void, str: []const u8) !usize {
    _ = context;

    PrintS(str);
    return str.len;
}

pub const size = Arch.VGA.size;
pub const cursor = struct {
    var x: u8 = 0;
    var y: u8 = 0;
};

pub const Writer = std.io.Writer(void, anyerror, WriteCallback);
pub fn Print(comptime format: []const u8, args: anytype) void {
    std.fmt.format(Writer{ .context = {} }, format, args) catch |x| {
        PrintS("Printing Error: ");
        PrintS(@errorName(x));
        PrintC('\n');
    };
}

var shouldUpdateCursor: bool = true;

pub fn PrintC(c: u8) void {
    switch (c) {
        '\n' => {
            cursor.x = 0;
            cursor.y += 1;

            if (cursor.y >= size.y) {
                Scroll();
            }
        },
        '\r' => {
            cursor.x = 0;
        },
        '\t' => {
            for (0..4) |_| {
                Arch.VGA.PutC(cursor.x, cursor.y, ' ');
                cursor.x += 1;
            }
        },
        else => {
            Arch.VGA.PutC(cursor.x, cursor.y, c);
            cursor.x += 1;
        },
    }

    if (cursor.x >= size.x) {
        cursor.y += 1;
        cursor.x = 0;
    }

    if (cursor.y >= size.y) {
        shouldUpdateCursor = false;
        Scroll();
        shouldUpdateCursor = true;
    }

    if (shouldUpdateCursor) Arch.VGA.SetCursorPos(cursor.x, cursor.y);
}

pub fn PrintS(str: []const u8) void {
    shouldUpdateCursor = false;

    for (str) |c| {
        PrintC(c);
    }

    shouldUpdateCursor = true;
    Arch.VGA.SetCursorPos(cursor.x, cursor.y);
}

pub fn ClearLine(y: u8) void {
    for (0..size.x) |x| {
        Arch.VGA.PutC(@intCast(x), y, ' ');
    }
}

pub fn Clear() void {
    for (0..size.y) |y| {
        ClearLine(@intCast(y));
    }
}

pub fn Scroll() void {
    for (0..size.y - 1) |i| {
        @memcpy(&Arch.VGA.videoMemory.*[i], &Arch.VGA.videoMemory.*[i + 1]);
    }

    if (cursor.y != 0) {
        cursor.y -= 1;
        if (shouldUpdateCursor) Arch.VGA.SetCursorPos(cursor.x, cursor.y);
    }
}
