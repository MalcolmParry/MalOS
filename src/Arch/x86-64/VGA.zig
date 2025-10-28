const std = @import("std");
const arch = @import("Arch.zig");
const mem = @import("../../Memory.zig");

pub const Color = enum(u4) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    purple = 5,
    brown = 6,
    gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_purple = 13,
    yellow = 14,
    white = 15,
};

pub const CursorType = enum {
    none,
    block,
    underline,
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

pub const video_memory: *[size.y][size.x]Char = @ptrFromInt(0xb_8000 + mem.kernel_virt_base);

pub var bg_color: Color = .dark_gray;
pub var fg_color: Color = .green;

pub fn putChar(x: u8, y: u8, c: u8) void {
    video_memory.*[y][x] = .{ .char = c, .fg = fg_color, .bg = bg_color };
}

pub fn setColorFromLogLevel(logLevel: std.log.Level) void {
    fg_color = switch (logLevel) {
        .info, .debug => .green,
        .warn => .yellow,
        .err => .light_red,
    };
}

pub fn setCursorType(t: CursorType) void {
    if (t == .none) {
        arch.out(0x3d4, @as(u8, 0x0a));
        arch.out(0x3d5, @as(u8, 0x20));
        return;
    }

    const startScanline: u8 = if (t == .block) 0 else 14;

    arch.out(0x3d4, @as(u8, 0x0a));
    arch.out(0x3d5, (arch.in(u8, 0x3d5) & 0xc0) | startScanline);

    arch.out(0x3d4, @as(u8, 0x0b));
    arch.out(0x3d5, (arch.in(u8, 0x3d5) & 0xe0) | 15);
}

pub fn setCursorPos(x: u8, y: u8) void {
    const pos: u16 = @as(u16, @intCast(size.x)) * y + x;

    arch.out(0x3d4, @as(u8, 0x0f));
    arch.out(0x3d5, @as(u8, @truncate(pos)));
    arch.out(0x3d4, @as(u8, 0x0e));
    arch.out(0x3d5, @as(u8, @truncate(pos >> 8)));
}

pub fn getPhysRange() mem.PhysRange {
    return .{
        .base = 0xb8000,
        .len = @sizeOf(Char) * @as(usize, size.x) * size.y,
    };
}
