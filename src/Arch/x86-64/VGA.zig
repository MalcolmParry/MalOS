const std = @import("std");
const Arch = @import("Arch.zig");
const Mem = @import("../../Memory.zig");

pub const Color = enum(u4) {
    Black = 0,
    Blue = 1,
    Green = 2,
    Cyan = 3,
    Red = 4,
    Purple = 5,
    Brown = 6,
    Gray = 7,
    DarkGray = 8,
    LightBlue = 9,
    LightGreen = 10,
    LightCyan = 11,
    LightRed = 12,
    LightPurple = 13,
    Yellow = 14,
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

pub const size = struct {
    pub const x: u8 = 80;
    pub const y: u8 = 25;
};

pub const videoMemory: *[size.y][size.x]Char = @ptrFromInt(0xb_8000 + Mem.kernelVirtBase);

pub var bgColor: Color = .DarkGray;
pub var fgColor: Color = .Green;

pub fn PutC(x: u8, y: u8, c: u8) void {
    videoMemory.*[y][x] = .{ .char = c, .fg = fgColor, .bg = bgColor };
}

pub fn SetColorFromLogLevel(logLevel: std.log.Level) void {
    fgColor = switch (logLevel) {
        .info, .debug => .Green,
        .warn => .Yellow,
        .err => .LightRed,
    };
}

pub fn SetCursorType(t: CursorType) void {
    if (t == .None) {
        Arch.Out(0x3d4, @as(u8, 0x0a));
        Arch.Out(0x3d5, @as(u8, 0x20));
        return;
    }

    const startScanline: u8 = if (t == .Block) 0 else 14;

    Arch.Out(0x3d4, @as(u8, 0x0a));
    Arch.Out(0x3d5, (Arch.in(u8, 0x3d5) & 0xc0) | startScanline);

    Arch.Out(0x3d4, @as(u8, 0x0b));
    Arch.Out(0x3d5, (Arch.in(u8, 0x3d5) & 0xe0) | 15);
}

pub fn SetCursorPos(x: u8, y: u8) void {
    const pos: u16 = @as(u16, @intCast(size.x)) * y + x;

    Arch.Out(0x3d4, @as(u8, 0x0f));
    Arch.Out(0x3d5, @as(u8, @truncate(pos)));
    Arch.Out(0x3d4, @as(u8, 0x0e));
    Arch.Out(0x3d5, @as(u8, @truncate(pos >> 8)));
}

pub fn GetPhysRange() Mem.PhysRange {
    return .{
        .base = 0xb8000,
        .length = @sizeOf(Char) * @as(usize, size.x) * size.y,
    };
}
