const Arch = @import("Arch.zig");

pub const Color = enum(u4) {
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

pub const size = struct {
    pub const x: u8 = 80;
    pub const y: u8 = 25;
};

pub const videoMemory: *[size.y][size.x]Char = @ptrFromInt(0xffff_ffff_c00b_8000);

pub const bgColor: Color = .Black;
pub const fgColor: Color = .Green;

pub fn PutC(x: u8, y: u8, c: u8) void {
    videoMemory.*[y][x] = .{ .char = c, .fg = fgColor, .bg = bgColor };
}

pub fn SetCursorType(t: CursorType) void {
    if (t == .None) {
        Arch.out(0x3d4, @as(u8, 0x0a));
        Arch.out(0x3d5, @as(u8, 0x20));
        return;
    }

    const startScanline: u8 = if (t == .Block) 0 else 14;

    Arch.out(0x3d4, @as(u8, 0x0a));
    Arch.out(0x3d5, (Arch.in(u8, 0x3d5) & 0xc0) | startScanline);

    Arch.out(0x3d4, @as(u8, 0x0b));
    Arch.out(0x3d5, (Arch.in(u8, 0x3d5) & 0xe0) | 15);
}

pub fn SetCursorPos(x: u8, y: u8) void {
    const pos: u16 = @as(u16, @intCast(size.x)) * y + x;

    Arch.out(0x3d4, @as(u8, 0x0f));
    Arch.out(0x3d5, @as(u8, @truncate(pos)));
    Arch.out(0x3d4, @as(u8, 0x0e));
    Arch.out(0x3d5, @as(u8, @truncate(pos >> 8)));
}
