const Core = @import("Core.zig");

const Color = enum(u4) {
    Black = 0,
    Blue = 1,
    Green = 2,
    Cyan = 3,
    Red = 4,
    Magenta = 5,
    Brown = 6,
    LightGrey = 7,
    DarkGrey = 8,
    LightBlue = 9,
    LightGreen = 10,
    LightCyan = 11,
    LightRed = 12,
    LightMagenta = 13,
    LightBrown = 14,
    White = 15,
};

pub const CursorType = enum {
    None,
    Block,
    Underline,
};

const Char = packed struct {
    char: u8,
    fg: Color,
    bg: Color,
};

pub const width = 80;
pub const height = 25;
pub var tabLength: u8 = 4;

const videoMemory: *[height][width]Char = @ptrFromInt(0xb8000);

pub var bgColor: Color = .Black;
pub var fgColor: Color = .Green;

const cursor = struct {
    var x: u8 = 0;
    var y: u8 = 0;
};

pub fn Init() void {
    bgColor = .Black;
    fgColor = .Green;
    cursor.x = 0;
    cursor.y = 0;
    UpdateCursor();
    SetCursorType(.Underline);
    Clear();
}

pub fn PrintC(char: u8) void {
    if (char == '\n') {
        Newline();
        return;
    }

    if (char == '\t') {
        for (0..tabLength) |_| {
            PrintC(' ');
        }

        return;
    }

    videoMemory.*[cursor.y][cursor.x] = .{ .char = char, .fg = fgColor, .bg = bgColor };
    cursor.x += 1;

    if (cursor.x >= width) {
        Newline();
        return;
    }

    UpdateCursor();
}

pub fn Print(str: []const u8) void {
    for (str) |char| {
        PrintC(char);
    }
}

pub fn Clear() void {
    for (0..height) |i| {
        ClearLine(@intCast(i));
    }
}

pub fn ClearLine(line: u8) void {
    for (0..width) |i| {
        videoMemory.*[line][i] = .{ .char = ' ', .fg = fgColor, .bg = bgColor };
    }
}

pub fn Newline() void {
    cursor.y += 1;
    cursor.x = 0;

    if (cursor.y >= height)
        Scroll(1);

    UpdateCursor();
}

pub fn Scroll(lines: u8) void {
    for (0..lines) |_| {
        for (0..(height - 1)) |i| {
            @memcpy(&videoMemory.*[i], &videoMemory.*[i + 1]);
        }
    }

    if (cursor.y != 0) {
        cursor.y -= 1;
        UpdateCursor();
    }
}

pub fn SetCursorType(t: CursorType) void {
    if (t == .None) {
        Core.out(0x3d4, @as(u8, 0x0a));
        Core.out(0x3d5, @as(u8, 0x20));
        return;
    }

    const startScanline: u8 = if (t == .Block) 0 else 14;

    Core.out(0x3d4, @as(u8, 0x0a));
    Core.out(0x3d5, (Core.in(u8, 0x3d5) & 0xc0) | startScanline);

    Core.out(0x3d4, @as(u8, 0x0b));
    Core.out(0x3d5, (Core.in(u8, 0x3d5) & 0xe0) | 15);
}

fn UpdateCursor() void {
    const pos: u16 = cursor.y * width + cursor.x;

    Core.out(0x3d4, @as(u8, 0x0f));
    Core.out(0x3d5, @as(u8, @intCast(pos)));
    Core.out(0x3d4, @as(u8, 0x0e));
    Core.out(0x3d5, @as(u8, @intCast(pos >> 8)));
}
